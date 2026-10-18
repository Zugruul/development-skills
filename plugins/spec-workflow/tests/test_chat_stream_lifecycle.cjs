// #523 review regressions: actual switch and dispatcher lifecycle, synthetic SSE.
const fs=require('fs'), assert=require('node:assert/strict'), {test}=require('node:test');
const html=fs.readFileSync(process.argv[2],'utf8');
function extract(name){
  const match=html.match(new RegExp('(?:async )?function '+name+'\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n'));
  assert(match,'missing '+name);return match[0];
}
for(const name of ['readChatStream','dispatchNextChat','switchAssistantTo','startChatElapsed','stopChatElapsed']) eval(extract(name));
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function setup(){
  const state={rows:[],spoken:[],requests:[],pending:[],cleared:[]};
  const log={scrollTop:0,clientHeight:10,get scrollHeight(){return state.rows.reduce((n,row)=>n+row.textContent.length,0);}};
  global.window={assistantChat:{queue:[],exchanges:[],switchGen:0,inFlight:false,elapsedTimer:null},__assistantSelected:'A'};
  global.document={getElementById:id=>id==='ast-chat-log'?log:null};
  let timer=0;
  global.setInterval=()=>++timer;
  global.clearInterval=id=>state.cleared.push(id);
  for(const name of ['setVoiceHeaderName','gateVoiceAndChat','renderAssistantDigest','setAssistantMediaCtx','renderChatGated','enrichChatRowMarkdown'])global[name]=()=>{};
  global.renderChatOffline=()=>assert.fail('unexpected offline UI');
  global.speakReply=text=>state.spoken.push(text);global.newClientTurnId=()=> 'voice';
  global.isChatLogAtBottom=()=>log.scrollTop+log.clientHeight>=log.scrollHeight-4;
  global.scrollChatLogToBottom=()=>{log.scrollTop=log.scrollHeight;};
  global.appendChatRow=(_,role,text)=>{
    const row={role,textContent:text,parentNode:log,setAttribute(key,value){if(key==='data-role')this.role=value;}};
    state.rows.push(row);return row;
  };
  global.fetch=async(url,opts)=>{
    state.requests.push([url,JSON.parse(opts.body)]);
    if(url==='/assistant/select')return {ok:true,json:async()=>({selected:'B'})};
    return new Promise((resolve,reject)=>state.pending.push({resolve,reject}));
  };
  state.detach=()=>{for(const row of state.rows)row.parentNode=null;state.rows=[];};
  state.log=log;
  return state;
}
function response(text){return {status:200,headers:{get:()=> 'application/json'},json:async()=>({text,chips:[]})};}
function stream(){
  let controller;
  const response={status:200,headers:{get:()=> 'text/event-stream'},body:new ReadableStream({start(c){controller=c;}})};
  const enc=new TextEncoder();
  return {response,frame:(kind,data)=>controller.enqueue(enc.encode('event: '+kind+'\ndata: '+JSON.stringify(data)+'\n\n')),close:()=>controller.close()};
}
for(const outcome of ['success','error']) test('actual switch releases A ownership before B; stale '+outcome+' cannot alter B',async()=>{
  const state=setup();window.assistantChat.queue.push({text:'A question'});
  const outgoing=dispatchNextChat();const a=stream();state.pending.shift().resolve(a.response);
  await tick();
  const timerA=window.assistantChat.elapsedTimer;
  await switchAssistantTo('B');
  assert.equal(window.assistantChat.inFlight,false,'confirmed switch releases outgoing dispatch');
  assert.equal(window.assistantChat.elapsedTimer,null,'confirmed switch stops outgoing timer');
  assert.deepEqual(state.cleared,[timerA]);
  window.assistantChat.queue.push({text:'B question'});
  const incoming=dispatchNextChat();const b=state.pending.shift();
  assert(b,'B starts before A completes');
  const timerB=window.assistantChat.elapsedTimer;
  a.frame('text',{phase:1,text:'A stale text'});
  if(outcome==='success')a.frame('done',{text:'A final',chips:[]});else a.frame('error',{error:'A transport failed'});
  await outgoing;
  assert(!state.rows.some(row=>row.role==='assistant' && row.textContent.startsWith('A')),'stale stream text stays hidden');
  assert.equal(window.assistantChat.inFlight,true);
  assert.equal(window.assistantChat.elapsedTimer,timerB);
  assert.deepEqual(state.cleared,[timerA]);
  assert.deepEqual(window.assistantChat.exchanges,[]);
  b.resolve(response('B final'));await incoming;
  assert.deepEqual(state.spoken,['B final']);
  assert.equal(window.assistantChat.exchanges[0].assistant,'B final');
  assert.equal(window.assistantChat.inFlight,false);
});
for(const outcome of ['error','EOF'])for(const position of ['bottom','up'])test('rebuilt log surfaces stream '+outcome+' while scrolled '+position,async()=>{
  const state=setup();window.assistantChat.queue.push({text:'question'});
  const pending=dispatchNextChat();const wire=stream();state.pending.shift().resolve(wire.response);
  await tick();wire.frame('text',{phase:1,text:'provisional'});await tick();
  state.detach();
  appendChatRow(state.log,'assistant','older history '.repeat(20));
  state.log.scrollTop=position==='bottom'?state.log.scrollHeight:0;
  if(outcome==='error')wire.frame('error',{error:'provider timed out'});else wire.close();
  await pending;
  assert(state.rows.some(row=>row.role==='system' && /timed out|terminal reply/.test(row.textContent)),'error is visible in current log');
  assert.equal(window.assistantChat.inFlight,false);
  if(position==='up')assert.equal(state.log.scrollTop,0,'error does not yank a scrolled-up reader');
  else assert(isChatLogAtBottom(state.log),'error follows a reader at the bottom');
  assert.deepEqual(window.assistantChat.exchanges,[]);assert.deepEqual(state.spoken,[]);
});
