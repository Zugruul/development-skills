"""#523 real protocol projection; synthetic timing/failure/transport variants."""
import contextlib
from types import SimpleNamespace
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
from assistant import adapters, claude, turns
from assistant.engine import AssistantEngine

FIXTURE = Path(__file__).parent / 'fixtures/chat-stream/claude.json'

class Streaming(unittest.TestCase):
    def test_directive_privacy_every_boundary(self):
        for raw in ['hello\n```CaPaBiLiTy\n{"secret":"private"}\n```\nafter',
                    'hello\n```capability\nprivate', 'hello\n```capability  ',
                    'hello\n```capability-notes\nordinary\n```']:
            for split in range(len(raw)+1):
                f = turns.PublicTextFilter()
                seen = [f.feed(raw[:split]), f.feed(raw[split:]), f.finish()]
                self.assertTrue(all('private' not in x for x in seen))
                self.assertEqual(seen[-1], turns.parse_capability_directives(raw)[0])
        f = turns.PublicTextFilter()
        self.assertEqual(f.feed('prompt ordinary prose'), 'prompt ordinary prose')

    def test_both_phases_and_complete_only_once(self):
        calls, events = [], []
        def complete(ctx, **kw):
            calls.append(ctx)
            return {'text':'final', 'usage': {'output_tokens': 1}}
        def stream(ctx, on_text, **kw):
            on_text('safe\n```capability\nprivate\n```')
            return complete(ctx)
        complete.stream = stream
        def hook(text, ctx, fn, kw):
            return fn(ctx, **(kw or {}))
        with patch.object(turns, 'compose_context', return_value={
                'context_for_adapter':{}, 'chips':[], 'budget_report':{}}):
            result = turns.run_turn({}, None, None, {}, 'hi', get_adapter=lambda _: complete,
                                    on_reply=hook, on_text=lambda phase, text: events.append((phase,text)))
        self.assertEqual(len(calls), 2)
        self.assertEqual({e[0] for e in events}, {1,2})
        self.assertNotIn('private', str(events))
        self.assertEqual(result['usage']['output_tokens'], 2)
        del complete.stream
        calls.clear(); events.clear()
        with patch.object(turns, 'compose_context', return_value={
                'context_for_adapter':{}, 'chips':[], 'budget_report':{}}):
            turns.run_turn({}, None, None, {}, 'hi', get_adapter=lambda _: complete,
                           on_text=lambda *e: events.append(e))
        self.assertEqual(len(calls), 1)
        self.assertEqual(events, [])  # completed answer must never be fake streamed

    def stub(self, directory, body):
        binary = Path(directory)/'claude'
        binary.write_text('#!'+sys.executable+'\nimport sys,os,json,time\n'
                          'if "--help" in sys.argv:\n print("--include-partial-messages --output-format stream-json --verbose");sys.exit()\n'+body)
        binary.chmod(0o755)
        return dict(os.environ, PATH=directory+os.pathsep+os.environ['PATH'])

    def test_real_protocol_before_completion_and_isolation(self):
        events = json.loads(FIXTURE.read_text())['events']
        records = [e['event'] for e in events]
        with tempfile.TemporaryDirectory() as d:
            env = self.stub(d, 'assert "--safe-mode" in sys.argv and "--strict-mcp-config" in sys.argv\n'
                            'assert "--include-partial-messages" in sys.argv\n'
                            'os.write(2,b"x"*200000)\n'
                            'records='+repr(records)+'\n'
                            'for e in records[:-1]: print(json.dumps(e),flush=True)\n'
                            'time.sleep(.5)\nprint(json.dumps(records[-1]),flush=True)\n')
            received=[]; start=time.monotonic()
            result=claude.complete_stream({'model':'test','input':'hi'},
                lambda text: received.append((time.monotonic()-start,text)), env=env, timeout=3)
            self.assertLess(received[0][0], 2)
            self.assertLess(received[0][0], result['timings']['elapsed_seconds']-.3)
            self.assertEqual(''.join(x[1] for x in received), result['text'])
            self.assertEqual(result['usage'], records[-1]['usage'])

    def test_stream_failures_never_retry(self):
        variants = [('print("bad",flush=True)',adapters.UnparseableOutput),
                    ('print(json.dumps({"type":"stream_event","event":"bad"}))',adapters.UnparseableOutput),
                    ('print(json.dumps({"type":"stream_event","event":{"type":"content_block_delta","delta":1}}))',adapters.UnparseableOutput),
                    ('print(json.dumps({"type":"result","is_error":True,"result":"Not logged in"}))',adapters.AuthExpired),
                    ('sys.exit(7)',adapters.NonzeroExit),
                    ('time.sleep(9)',adapters.Timeout),
                    ('print(json.dumps({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}}),flush=True)',adapters.UnparseableOutput)]
        for body,error in variants:
            with self.subTest(error=error), tempfile.TemporaryDirectory() as d:
                env=self.stub(d, 'open('+repr(d+'/calls')+',"a").write("call\\n")\n'+body)
                with self.assertRaises(error):
                    claude.complete_stream({'model':'test','input':'hi'}, lambda _:None, env=env, timeout=.3)
                self.assertEqual(Path(d+'/calls').read_text(), 'call\n')

    def test_pump_bounds_descendant_pipes_on_timeout(self):
        with tempfile.TemporaryDirectory() as d:
            pidfile=Path(d)/'pid'
            code='import subprocess,sys,time; p=subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"]);open(sys.argv[1],"w").write(str(p.pid));print("hi",flush=True);time.sleep(30)'
            start=time.monotonic()
            with self.assertRaises(adapters.Timeout):
                adapters.invoke_cli_stream([sys.executable,'-c',code,str(pidfile)], lambda _:None, timeout=.3)
            self.assertLess(time.monotonic()-start, 2)
            # Direct process is reaped; descendant must not remain running.
            stat=Path('/proc')/pidfile.read_text()/'stat'
            if stat.exists(): self.assertEqual(stat.read_text().split()[2], 'Z')

    def test_engine_real_effect_recovery_and_transcript(self):
        from assistant import capability_index as ci, engine as engine_module
        from assistant.store import SessionStore
        for disconnect in (False, True, "during-effect", "success", "disabled", "first-failure"):
            with self.subTest(disconnect=disconnect), tempfile.TemporaryDirectory() as d, contextlib.ExitStack() as stack:
                root=Path(d)/'assistant';root.mkdir()
                cfg={'fileOutput':False,'llm':{'provider':'stream-test'},'capabilities':{'echo':{'enabled':disconnect != 'disabled'}}}
                skill=root/'.claude/skills/echo';skill.mkdir(parents=True)
                counter=Path(d)/'effects'
                import yaml
                (skill/'capability.yaml').write_text(yaml.safe_dump({'version':1,'provisioning':{'check':[sys.executable,'-c','pass'],'ttlSeconds':60},'permissions':[],'invoke':{'exec':[
                    sys.executable,'-c','from pathlib import Path; p=Path('+repr(str(counter))+');p.write_text(p.read_text()+"x" if p.exists() else "x");import time;time.sleep(1.2);print("RESULT-123")']}}))
                engine=AssistantEngine(lambda:[('a',root)], Path(d)/'state')
                engine._roster_provider_for=lambda *a: lambda *a: []
                engine.capability_index_for=lambda *a: None
                stack.enter_context(patch.object(engine_module.default_store,'discover_candidates',return_value=[(root,cfg)]))
                stack.enter_context(patch.object(engine_module.default_store,'resolve_assistant',return_value=(root,cfg)))
                stack.enter_context(patch.object(ci,'resolve_by_name',return_value=SimpleNamespace(name='echo',provisioned_ok=True)))
                stack.enter_context(patch.object(turns,'compose_context',return_value={'context_for_adapter':{'input':'hi'},'chips':[],'budget_report':{}}))
                calls=[];events=[]
                def complete(ctx, **kwargs): raise AssertionError('stream path expected')
                def stream(ctx,on_text,**kwargs):
                    calls.append(ctx)
                    if disconnect == 'first-failure':
                        on_text('partial');raise adapters.Timeout('initial completion timed out')
                    if len(calls)==1:
                        answer='working\n```capability\n{"name":"echo","params":{}}\n```'
                        for char in answer:on_text(char)
                        return {'text':answer}
                    on_text('followup')
                    if disconnect == 'success':return {'text':'final RESULT-123'}
                    raise adapters.Timeout('followup timed out')
                complete.stream=stream
                stack.enter_context(patch.dict(adapters._REGISTRY,{'stream-test':complete}))
                def emit(kind,payload):
                    events.append((kind,payload))
                    if ((disconnect is True and kind=='text' and payload['phase']==2) or
                        (disconnect == 'during-effect' and kind=='heartbeat')):
                        raise BrokenPipeError('client left')
                engine.stream_chat({'message':'hi'},emit)
                if disconnect in ('disabled','first-failure'):
                    self.assertFalse(counter.exists())
                    self.assertEqual(len(calls),1)
                    history=SessionStore(root).history()['exchanges']
                    if disconnect == 'first-failure':
                        self.assertEqual(history,[]);self.assertEqual(events[-1][0],'error')
                    else:self.assertIn('disabled',history[0]['assistant'])
                    continue
                self.assertEqual(counter.read_text(),'x')
                self.assertEqual(len(calls),1 if disconnect == "during-effect" else 2)
                history=SessionStore(root).history()['exchanges']
                self.assertEqual(len(history),1)
                self.assertIn('RESULT-123',history[0]['assistant'])
                self.assertNotIn('"name"',str(events))
                if disconnect in (False,'success'):self.assertEqual(events[-1][0],'done')
                if disconnect == 'success':
                    self.assertEqual({p['phase'] for k,p in events if k=='text'},{1,2})
                    self.assertEqual(history[0]['assistant'],'final RESULT-123')
                self.assertEqual(SessionStore(root).load_state()['turn_count'],1)

    def test_tool_cycle_boundaries_hide_directives_in_both_completions(self):
        # Synthetic legal stream-json tool cycle around captured public shapes.
        directive='```capability\n{"name":"echo","params":{"secret":"PRIVATE-523"}}\n```'
        for boundary in ('message','text-block'):
            for split in range(len('```capability')+1):
                with self.subTest(boundary=boundary,split=split), tempfile.TemporaryDirectory() as d:
                    events=[]
                    def event(inner):
                        events.append({'type':'stream_event','parent_tool_use_id':None,'event':inner})
                    event({'type':'message_start','message':{'role':'assistant','content':[]}})
                    event({'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}})
                    event({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'Preparing the file.'}})
                    event({'type':'content_block_stop','index':0})
                    if boundary == 'message':
                        event({'type':'content_block_start','index':1,'content_block':{'type':'tool_use','name':'Write','input':{}}})
                        event({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json':'PRIVATE-TOOL-523'}})
                        event({'type':'message_stop'})
                        events.append({'type':'user','message':{'role':'user','content':[{'type':'tool_result','content':'inert write result'}]}})
                        event({'type':'message_start','message':{'role':'assistant','content':[]}})
                    event({'type':'content_block_start','index':2,'content_block':{'type':'text','text':''}})
                    for text in (directive[:split],directive[split:]):
                        event({'type':'content_block_delta','index':2,'delta':{'type':'text_delta','text':text}})
                    event({'type':'content_block_stop','index':2})
                    event({'type':'message_stop'})
                    events.append({'type':'result','is_error':False,'result':directive})
                    env=self.stub(d,'for e in '+repr(events)+':print(json.dumps(e),flush=True)')
                    out=Path(d)/'output';out.mkdir()
                    calls=[];public=[]
                    def complete(ctx,**kwargs):raise AssertionError('must stream')
                    def stream(ctx,on_text,**kwargs):
                        calls.append(ctx)
                        return claude.complete_stream(ctx,on_text,env=env,timeout=2)
                    complete.stream=stream
                    def followup(text,ctx,fn,kwargs):
                        result=fn(ctx,**(kwargs or {}))
                        return {'text':turns.parse_capability_directives(result['text'])[0]}
                    with patch.object(turns,'compose_context',return_value={
                            'context_for_adapter':{'model':'test','input':'hi','fileOutputDir':str(out)},
                            'chips':[],'budget_report':{}}):
                        result=turns.run_turn({},None,None,{},'hi',get_adapter=lambda _:complete,
                            on_reply=followup,on_text=lambda phase,text:public.append((phase,text)))
                    self.assertEqual(len(calls),2)
                    self.assertEqual({phase for phase,_ in public},{1,2})
                    self.assertTrue(all('PRIVATE' not in text and '```capability' not in text for _,text in public), public)
                    self.assertEqual(result['text'],'')

    def test_fallback_once_and_codex_capture(self):
        from assistant import codex
        records=json.loads((FIXTURE.parent/'codex.json').read_text())['events']
        text,usage=codex._parse_jsonl('\n'.join(json.dumps(e['event']) for e in records))
        self.assertEqual(text,records[0]['event']['item']['text'])
        self.assertEqual(usage,records[-1]['event']['usage'])
        self.assertFalse(hasattr(codex.complete,'stream'))
        with tempfile.TemporaryDirectory() as d:
            env=self.stub(d, 'open('+repr(d+'/calls')+',"a").write("call\\n")\nprint(json.dumps({"type":"result","result":"final"}))')
            binary=Path(d)/'claude'
            binary.write_text(binary.read_text().replace('--include-partial-messages --output-format stream-json --verbose','old CLI help'))
            seen=[]
            with adapters.stream_transport(lambda:None):
                result=claude.complete_stream({'model':'test','input':'hi'},seen.append,env=env,timeout=2)
            self.assertEqual(result['text'],'final');self.assertEqual(seen,[])
            self.assertEqual(Path(d+'/calls').read_text(),'call\n')

    def test_callback_cancellation_cleans_child_and_workdir(self):
        with tempfile.TemporaryDirectory() as d:
            env=self.stub(d, 'open('+repr(d+'/pid')+',"w").write(str(os.getpid()))\n'
                'print(json.dumps({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}}),flush=True)\ntime.sleep(20)')
            work=Path(d)/'work';work.mkdir()
            def cancel(_):raise adapters.StreamCancelled('gone')
            start=time.monotonic()
            with patch.object(claude,'_isolated_cwd',return_value=str(work)), self.assertRaises(adapters.StreamCancelled):
                claude.complete_stream({'model':'test','input':'hi'},cancel,env=env,timeout=3)
            self.assertLess(time.monotonic()-start,2)
            self.assertFalse(work.exists())
            with self.assertRaises(ProcessLookupError):os.kill(int(Path(d+'/pid').read_text()),0)

    def test_provider_to_real_engine_to_http_and_durable_final(self):
        from assistant import engine as engine_module
        from assistant.store import SessionStore
        spec=importlib.util.spec_from_file_location('nv_real_stream_test',SCRIPTS/'neural-view.py')
        nv=importlib.util.module_from_spec(spec);spec.loader.exec_module(nv)
        with tempfile.TemporaryDirectory() as d, contextlib.ExitStack() as stack:
            root=Path(d)/'repo';root.mkdir()
            cfg={'fileOutput':False,'llm':{'provider':'stream-test','model':'test'}}
            marker=Path(d)/'completed'
            env=self.stub(d,'print(json.dumps({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"visible"}}}),flush=True)\n'
                'time.sleep(.5)\nopen('+repr(str(marker))+',"w").write("done")\nprint(json.dumps({"type":"result","result":"final","usage":{"output_tokens":7}}),flush=True)')
            def complete(ctx,**kwargs):raise AssertionError('stream expected')
            complete.stream=lambda ctx,on_text,**kwargs:claude.complete_stream(ctx,on_text,env=env,timeout=3)
            stack.enter_context(patch.dict(adapters._REGISTRY,{'stream-test':complete}))
            stack.enter_context(patch.object(engine_module.default_store,'discover_candidates',return_value=[(root,cfg)]))
            stack.enter_context(patch.object(engine_module.default_store,'resolve_assistant',return_value=(root,cfg)))
            stack.enter_context(patch.object(turns,'compose_context',return_value={'context_for_adapter':{'model':'test','input':'hi'},'chips':[{'slug':'recall-note'}],'budget_report':{}}))
            engine=AssistantEngine(lambda:[('a',root)],Path(d)/'state')
            engine._roster_provider_for=lambda *a: lambda *a:[]
            nv.ENGINE=engine
            server=ThreadingHTTPServer(('127.0.0.1',0),nv.Handler)
            thread=threading.Thread(target=server.serve_forever);thread.start()
            try:
                connection=HTTPConnection('127.0.0.1',server.server_port,timeout=3)
                start=time.monotonic()
                connection.request('POST','/assistant/chat','{"message":"hi"}',{'Accept':'text/event-stream'})
                response=connection.getresponse();seen=b''
                while b'visible' not in seen:
                    line=response.fp.readline()
                    self.assertTrue(line,'EOF before visible text')
                    seen+=line
                self.assertLess(time.monotonic()-start,2)
                self.assertFalse(marker.exists(),'text must flush before provider finishes')
                seen+=response.read();connection.close()
                self.assertEqual(seen.count(b'event: done'),1)
                self.assertIn(b'recall-note',seen)
                history=SessionStore(root).history()['exchanges']
                self.assertEqual(len(history),1);self.assertEqual(history[0]['assistant'],'final')
                self.assertEqual(SessionStore(root).load_state()['turn_count'],1)
                for headers in ({},{'Accept':'text/event-stream'}):
                    connection=HTTPConnection('127.0.0.1',server.server_port,timeout=2)
                    connection.request('POST','/assistant/chat','{}',headers)
                    response=connection.getresponse()
                    self.assertEqual(response.status,400)
                    self.assertEqual(response.getheader('Content-Type'),'application/json')
                    self.assertEqual(json.loads(response.read())['error'],'message is required')
                    connection.close()
            finally:
                server.shutdown();server.server_close();thread.join()

    def test_stream_request_body_stall_is_bounded(self):
        spec=importlib.util.spec_from_file_location('nv_stall_test',SCRIPTS/'neural-view.py')
        nv=importlib.util.module_from_spec(spec);spec.loader.exec_module(nv)
        server=ThreadingHTTPServer(('127.0.0.1',0),nv.Handler)
        thread=threading.Thread(target=server.serve_forever);thread.start()
        connection=HTTPConnection('127.0.0.1',server.server_port,timeout=3)
        try:
            connection.putrequest('POST','/assistant/chat')
            connection.putheader('Accept','text/event-stream')
            connection.putheader('Content-Length','100')
            connection.endheaders();connection.send(b'{')
            response=connection.getresponse()
            self.assertEqual(response.status,408)
            self.assertIn('timed out',json.loads(response.read())['error'])
        finally:
            connection.close();server.shutdown();server.server_close();thread.join()

    def test_http_mount_flushes_before_provider_finishes(self):
        spec=importlib.util.spec_from_file_location('nv_stream_test', SCRIPTS/'neural-view.py')
        nv=importlib.util.module_from_spec(spec);spec.loader.exec_module(nv)
        first=threading.Event(); release=threading.Event()
        class Engine:
            def stream_chat(self, body, emit):
                emit('start',{'turn_id':'test'})
                emit('text',{'phase':1,'text':'visible'})
                first.set(); release.wait(3)
                emit('done',{'text':'final','chips':[],'warnings':[]})
                return 200,{},'text/event-stream'
            def handle(self,*args,**kwargs): return 400,{'error':'message is required'},'application/json'
        nv.ENGINE=Engine()
        server=ThreadingHTTPServer(('127.0.0.1',0), nv.Handler)
        thread=threading.Thread(target=server.serve_forever);thread.start()
        try:
            connection=HTTPConnection('127.0.0.1',server.server_port, timeout=2)
            start=time.monotonic()
            connection.request('POST','/assistant/chat','{"message":"hi"}',{'Accept':'text/event-stream'})
            response=connection.getresponse()
            self.assertEqual(response.getheader('Content-Type'), 'text/event-stream')
            seen=b''
            while b'visible' not in seen:
                line=response.fp.readline()
                self.assertTrue(line,'EOF before visible text')
                seen+=line
            self.assertLess(time.monotonic()-start,2)
            self.assertFalse(release.is_set())
            release.set(); response.read();connection.close()
        finally:
            release.set();server.shutdown();server.server_close();thread.join()

if __name__ == '__main__': unittest.main()
