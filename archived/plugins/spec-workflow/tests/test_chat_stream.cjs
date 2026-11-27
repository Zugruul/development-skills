// #523 deterministic browser ReadableStream behavior, independent synthetic frames.
const fs=require('fs'), assert=require('assert');
const html=fs.readFileSync(process.argv[2],'utf8');
function extract(name){const m=html.match(new RegExp('(?:async )?function '+name+'\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n'));assert(m,'missing '+name);return m[0];}
if(html.includes('function readChatStream(')) eval(extract('readChatStream'));
if(process.argv[3] !== '--dispatch')
(async()=>{
 let release;const gate=new Promise(r=>release=r);let observed=[];
 const enc=new TextEncoder();
 const response={body:new ReadableStream({async start(c){
   const bytes=enc.encode('event: text\ndata: {"phase":1,"text":"héllo"}\n\n');
   for(const b of bytes)c.enqueue(Uint8Array.of(b));
   await gate;c.enqueue(enc.encode('event: done\ndata: {"text":"final","chips":[]}\n\n'));c.close();
 }})};
 const pending=readChatStream(response,(kind,payload)=>{observed.push([kind,payload]);if(kind==='text'){assert.equal(payload.text,'héllo');release();}});
 const result=await pending;assert.equal(result.text,'final');assert.equal(observed[0][0],'text');
 await assert.rejects(readChatStream({body:new ReadableStream({start(c){c.close();}})},()=>{}),/incomplete|terminal|ended/i);
 console.log('browser stream framing, split UTF-8, before-final visibility and incomplete EOF pass');
})().catch(e=>{console.error(e);process.exitCode=1});
// Execute the real dispatcher against a minimal DOM, controlled fetch and speech sink.
async function dispatchCases(){
 eval(extract('dispatchNextChat'));
 let rows=[], spoken=[], pending=[], stopped=0, requests=[];
 global.window={assistantChat:{queue:[],exchanges:[],switchGen:0,inFlight:false},__assistantSelected:'A'};
 const log={scrollTop:0,clientHeight:10,get scrollHeight(){return rows.reduce((n,r)=>n+r.textContent.length,0);}};
 global.document={getElementById:()=>log};
 global.CHAT_SCROLL_BOTTOM_SLACK_PX=4;
 global.isChatLogAtBottom=eval('('+extract('isChatLogAtBottom')+')');
 global.scrollChatLogToBottom=eval('('+extract('scrollChatLogToBottom')+')');
 global.appendChatRow=(_log,role,text,chips)=>{const row={role,textContent:text,chips,parentNode:log,remove(){rows=rows.filter(x=>x!==row);},setAttribute(){},appendChild(){}};rows.push(row);return row;};
 global.startChatElapsed=()=>{};global.stopChatElapsed=()=>{stopped++;};
 global.renderChatOffline=()=>{throw Error('unexpected offline')};
 global.renderChatGated=()=>{};global.speakReply=text=>spoken.push(text);global.newClientTurnId=()=> 'voice-id';
 global.enrichChatRowMarkdown=(row,text)=>{row.textContent=text;row.markdown=true;};
 global.fetch=async(url,opts)=>{requests.push(opts);return await new Promise(resolve=>pending.push(resolve));};
 const enc=new TextEncoder();let controller;
 function stream(){return {status:200,headers:{get:()=> 'text/event-stream'},body:new ReadableStream({start(c){controller=c;}})};}
 function frame(kind,payload){controller.enqueue(enc.encode('event: '+kind+'\ndata: '+JSON.stringify(payload)+'\n\n'));}
 window.assistantChat.queue.push({text:'one'}, {text:'two'});
 const first=dispatchNextChat(); pending.shift()(stream());
 await new Promise(r=>setImmediate(r));frame('text',{phase:1,text:'live'});
 await new Promise(r=>setImmediate(r));
 assert(rows.some(x=>x.role==='assistant'&&x.textContent==='live'),'live row before final');
 assert.equal(spoken.length,0);assert.equal(window.assistantChat.exchanges.length,0);
 frame('text',{phase:1,text:'x'.repeat(100)});await new Promise(r=>setImmediate(r));
 assert(log.scrollTop+log.clientHeight>=log.scrollHeight,'follow growth while reading bottom');
 log.scrollTop=0;
 frame('text',{phase:1,text:'x'.repeat(200)});await new Promise(r=>setImmediate(r));
 assert.equal(log.scrollTop,0,'preserve user scroll position');
 for(const row of rows)row.parentNode=null;rows=[]; // history/show-last rebuild

 frame('text',{phase:2,text:'followup'});frame('done',{text:'final',chips:[]});controller.close();await first;
 assert(rows.some(r=>r.role==='assistant'&&r.textContent==='final'),'final survives detached live row');
 assert.deepEqual(spoken,['final']);assert.equal(window.assistantChat.exchanges.length,1);
 assert.equal(requests.length,2,'queue dispatches in order');
 // An outgoing failed stream must not clear incoming timer, queue or in-flight state.
 pending.shift()(stream());await new Promise(r=>setImmediate(r));
 window.assistantChat.switchGen++;
 window.assistantChat.queue=[{text:'incoming'}];window.assistantChat.inFlight=true;
 const before=stopped;controller.error(Error('outgoing failed'));
 await new Promise(r=>setImmediate(r));
 assert.equal(stopped,before);assert.equal(window.assistantChat.inFlight,true);
 assert.equal(window.assistantChat.queue[0].text,'incoming');assert.deepEqual(spoken,['final']);
 console.log('dispatcher live row, final-only speech/cache, queue and stale-error isolation pass');
}
// Run after the framing test's microtasks so the global fetch stubs cannot interfere.
if(process.argv[3] === '--dispatch') setImmediate(()=>dispatchCases().catch(e=>{console.error(e);process.exitCode=1;}));
