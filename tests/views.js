// Exercise the actual tab/pagination/theme functions without a browser or GPU.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../app.js'),'utf8'),html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
function func(name){const start=source.indexOf('function '+name+'(');let level=0,begin=source.indexOf('{',start);for(let i=begin;i<source.length;i++){if(source[i]==='{')level++;if(source[i]==='}'&&--level===0)return source.slice(start,i+1)}throw Error(name)}
const elements={};function get(id){return elements[id]??=( {hidden:false,attrs:{},classList:{toggle(){}},setAttribute(k,v){this.attrs[k]=v},querySelector(){return {clientHeight:300}},scrollIntoView(o){this.scrolledInto=JSON.stringify(o)}})}
let renders=0,stored,fits=0;const sent=[];const context=vm.createContext({$:get,send(a){sent.push(a)},blockPage:99,minerPage:0,renderBlocks(){renders++},renderMiners(){renders++},renderLog(){renders++},fitMetrics(){fits++},document:{documentElement:{dataset:{}}},getComputedStyle(){return {getPropertyValue(key){return key==='--table-row-height'?'72px':'42px'}}},localStorage:{setItem(k,v){stored=v}}});
vm.runInContext(source.match(/const tabNames=\[[^\]]*\];/)[0],context);  // the real tab list, so the test cannot drift from it
for(const name of ['selectTab','pageInfo','applyTheme'])vm.runInContext(func(name),context);
context.selectTab('miners');assert.equal(get('view-miners').hidden,false);assert.equal(get('view-dashboard').hidden,true);assert.equal(get('tab-miners').attrs['aria-selected'],'true');assert.equal(get('tab-dashboard').tabIndex,-1);
context.selectTab('setup');assert.equal(get('view-miners').hidden,true);assert.equal(get('view-setup').hidden,false);
context.selectTab('invalid');assert.equal(get('view-dashboard').hidden,false);
assert.deepEqual(sent,[]);assert.equal(vm.runInContext('tabNames',context).join(),'dashboard,blocks,miners,setup');   // WALLET, NEW WALLET and FORUM are gone
context.selectTab('wallet');assert.equal(get('view-dashboard').hidden,false);context.selectTab('forum');assert.equal(get('view-dashboard').hidden,false);assert.deepEqual(sent,[]);   // an old link to a removed tab lands on the dashboard
let p=context.pageInfo('blocks',8);assert.equal(p.count,3);assert.equal(p.start,6);assert.equal(get('blocksNext').disabled,true);assert.equal(get('blocksPrev').disabled,false);
p=context.pageInfo('miners',0);assert.equal(p.start,0);assert.equal(get('minersPrev').disabled,true);assert.equal(get('minersNext').disabled,true);
get('blocks').querySelector=()=>({clientHeight:50});p=context.pageInfo('blocks',8);assert.equal(p.count,1);
// the dashboard fits its metrics again when it shows
const fits0=fits;context.selectTab('dashboard');assert.equal(fits,fits0+1);context.selectTab('miners');assert.equal(fits,fits0+1);
context.applyTheme(true);assert.equal(stored,'dark');assert.equal(get('themeToggle').attrs['aria-checked'],'true');context.applyTheme(false);assert.equal(stored,'light');assert.equal(get('themeLabel').textContent,'LIGHT');
console.log('Tab selection (four tabs; removed tabs fall back to the dashboard), hidden panels, pagination bounds, short windows, theme persistence, and metrics fitted on DASHBOARD passed');

// Whole page: load the real app.js against a stub DOM and replay Swift's messages.
function node(tag){const kids=[],fields={},cls=new Set();const e={tag,hidden:false,disabled:false,value:'',checked:false,title:'',textContent:'',innerHTML:'',className:'',attrs:{},dataset:{},style:{},children:kids,clientHeight:300,fields,
 classList:{add(c){cls.add(c)},remove(c){cls.delete(c)},toggle(c,on){(on??!cls.has(c))?cls.add(c):cls.delete(c)},contains(c){return cls.has(c)}},
 setAttribute(k,v){this.attrs[k]=String(v)},getAttribute(k){return this.attrs[k]??null},append(...c){kids.push(...c)},replaceChildren(...c){kids.splice(0,kids.length,...c)},querySelector(){return node('q')},querySelectorAll(){return []},focus(){doc.activeElement=this},scrollIntoView(o){this.scrolledInto=o},getClientRects(){return this.hidden?[]:[{}]},
 reset(){for(const f of Object.values(fields))f.value=''},checkValidity(){return true},reportValidity(){},requestSubmit(){this.onsubmit?.({preventDefault(){},target:this})}};
 e.elements=new Proxy(fields,{get:(t,k)=>k===Symbol.iterator?function*(){yield*Object.values(t)}:typeof k==='string'?(t[k]??=node('input')):undefined});return e}
const dom={},$=id=>dom[id]??=node(id),posts=[],doc={getElementById:id=>$(id),createElement:tag=>node(tag),documentElement:null,activeElement:null,listeners:{},addEventListener(t,f){(this.listeners[t]??=[]).push(f)}};let marks=0;
// what the banner covers: the controls of each view's top panel title, and the dashboard's payout line
class FormData{constructor(f){this.f=f}get(k){const i=this.f.fields[k];return !i?null:i.type==='checkbox'?(i.checked?'on':null):i.value}*[Symbol.iterator](){for(const k of Object.keys(this.f.fields))yield [k,this.get(k)]}}
doc.documentElement=node('html');const page=vm.createContext({document:doc,localStorage:{getItem(){return null},setItem(){}},matchMedia:()=>({matches:false}),addEventListener(){},getComputedStyle:()=>({getPropertyValue:()=>'',lineHeight:'18px'}),setTimeout,clearTimeout,FormData,
 identiconSvg:async a=>{marks++;return '<svg>'+a+'</svg>'},webkit:{messageHandlers:{native:{postMessage:m=>posts.push(JSON.parse(JSON.stringify(m)))}}}});
page.window=page;
vm.runInContext(source,page);
const js=expr=>vm.runInContext(expr,page),last=()=>posts[posts.length-1],fill=(form,v)=>{for(const [k,x] of Object.entries(v))$(form).elements[k].value=x};
(async()=>{
 const receive=m=>page.receive(m);
 // Errors stay until the user's next command; the 15 s chain tick does not replace them.
 const testnet='Testnet A is the rehearsal chain. Rewards are test coins.';
 await receive({type:'error',message:'Enter an IP address.'});await receive({type:'chain',data:{}});assert.equal($('notice').textContent,'Enter an IP address.');
 $('refresh').onclick();await receive({type:'chain',data:{}});assert.equal($('notice').textContent,testnet);
 // SETUP save: the page's profile changes only when Swift accepts the save.
 await receive({type:'profile',data:{network:'testnet',address:'txa1rold',explorer:'https://superknet.com'}});
 fill('settings',{network:'mainnet',address:'xpa1rnew',worker:'w',host:'h',port:'1',password:'',mode:'solo',explorer:'https://x.example/'});$('settings').onsubmit({preventDefault(){},target:$('settings')});
 assert.equal(last().action,'save');assert.equal(last().profile.explorer,'https://x.example');assert.equal(js('profile.network'),'testnet');
 await receive({type:'setupRequired',message:'Keychain denied.'});assert.equal(js('profile.network'),'testnet');
 $('settings').onsubmit({preventDefault(){},target:$('settings')});await receive({type:'reset'});assert.equal(js('profile.network'),'mainnet');assert.equal($('networkLabel').textContent,'MAINNET / GENESIS VERIFIED BEFORE START');
 // Engine: RECONNECTING while the pool is down, WAITING when stats stop, and the exit reason from the log.
 await receive({type:'started'});assert.equal($('mineTitle').innerHTML,'Every hash <br>counts.');
 await receive({type:'miner',data:{running:true,pool_connected:false,pool_status:'reconnecting in 5s',hashrate_pretty:'0 H/s',hashrate_hps:0,uptime_s:9}});assert.equal($('hashrate').textContent,'—');assert.equal($('engineStatus').textContent,'■ RECONNECTING');assert.match($('notice').textContent,/reconnecting in 5s/);
 await receive({type:'miner',data:{running:true,pool_connected:true,pool_status:'connected',hashrate_pretty:'14.3 MH/s',hashrate_hps:14.3e6,uptime_s:11}});assert.equal($('hashrate').textContent,'14.3 MH/s');assert.equal($('engineStatus').textContent,'■ MINING');
 const metric=i=>$('metrics').children[i];
 for(const [h,v,u] of [[8.12e6,'8.12 M','MH/s'],[999.99e6,'999.99 M','MH/s'],[1234567890,'1.23 G','GH/s'],[12345678901234,'12.35 T','TH/s'],[2.5e18,'2,500 P','PH/s']]){await receive({type:'chain',data:{hashrate:h}});assert.equal(metric(1).children[1].textContent,v);assert.equal(metric(1).children[2].textContent,u+' · chain estimate');assert.equal(metric(1).children[1].title,v);assert.equal(metric(1).children[2].title,u+' · chain estimate')}
 await receive({type:'chain',data:{}});assert.equal(metric(1).children[1].textContent,'—');assert.equal(metric(0).children[2].title,'verified explorer tip');
 const worker=await js("person('txa1rabc','w'.repeat(64))");assert.equal(worker.children[1].children[0].title,'w'.repeat(64));
 await receive({type:'minerPending',message:'Waiting for mining engine statistics…'});assert.equal($('hashrate').textContent,'—');assert.equal($('engineStatus').textContent,'■ WAITING FOR ENGINE');
 await receive({type:'log',message:'[-] Failed to connect to pool!\nerror: pool 127.0.0.1:3335 unreachable\n'});await receive({type:'stopped',code:1});await receive({type:'chain',data:{}});
 assert.equal($('notice').textContent,'Engine exited (1): pool 127.0.0.1:3335 unreachable');assert.equal($('mineTitle').innerHTML,'Ready when <br>you are.');
 await receive({type:'started'});await receive({type:'stopped',code:6});assert.equal($('notice').textContent,'Engine exited (6). Check the engine log.');
 // A metric too wide for its column shrinks to fit, one size per row (values, notes), never below 60% (notes: 9 px); one that fits keeps its size
 const cols=(texts,px)=>texts.map(t=>({t,style:{},clientWidth:134,base:px,get scrollWidth(){return Math.ceil(t.length*(parseFloat(this.style.fontSize)||px)*.6)}}));
 const vals=cols(['1,234,567','987.65 T','—'],26),notes=cols(['verified explorer tip','this mining session'],12),gcs=page.getComputedStyle;
 page.getComputedStyle=e=>({getPropertyValue:()=>'',lineHeight:'18px',fontSize:(e.base||12)+'px'});
 $('metrics').querySelectorAll=sel=>sel==='strong'?vals:sel==='small'?notes:[];js('fitMetrics()');
 assert.deepEqual(vals.map(e=>e.style.fontSize),['24.5px','24.5px','24.5px']);assert.ok(vals.every(e=>e.scrollWidth<=e.clientWidth));
 assert.deepEqual(notes.map(e=>e.style.fontSize),['10.5px','10.5px']);assert.ok(notes.every(e=>e.scrollWidth<=e.clientWidth));
 const huge=cols(['123,456,789,012,345,678'],26);$('metrics').querySelectorAll=sel=>sel==='strong'?huge:[];js('fitMetrics()');assert.equal(huge[0].style.fontSize,'15.6px');   // the floor: past it the ellipsis and the title say it
 const fine=cols(['12,345'],26);fine[0].style.fontSize='20px';$('metrics').querySelectorAll=sel=>sel==='strong'?fine:[];js('fitMetrics()');assert.equal(fine[0].style.fontSize,'');   // fits: its own size again
 $('metrics').querySelectorAll=()=>[];page.getComputedStyle=gcs;
 // The engine log wraps long lines: the oldest lines give way until the latest fit whole
 const log=$('log'),logH=log.clientHeight;log.clientHeight=100;Object.defineProperty(log,'scrollHeight',{configurable:true,get(){return this.textContent.split('\n').length*40}});
 await receive({type:'log',message:'one\ntwo\nthree\nfour\nfive'});js("selectTab('setup')");assert.equal(log.textContent,'four\nfive');
 delete log.scrollHeight;log.clientHeight=logH;
 // Identicons are drawn once per address, however often the rows re-render.
 const before=marks;await js("person('txa1rsame')");await js("person('txa1rsame')");assert.equal(marks-before,1);
 console.log('Sticky notices, network hash units and metric titles, metrics shrunk to fit (one size per row, with a floor), the engine log\'s latest lines whole, worker-name title, setup save echo, pool reconnect, minerPending, engine exit reason, and identicon memo passed');
 let np;
 // Schedule: the form follows Swift; saved on change; bad input refused here; paused status; START's offer
 await receive({type:'stopped',code:15});
 const hours={mode:'hours',idle:10,from:'22:00',to:'07:00',hot:true},sf=$('scheduleForm');
 await receive({type:'schedule',data:hours,paused:false,reason:'',hold:'outside mining hours 22:00–07:00',override:false});
 assert.equal(sf.elements.mode.value,'hours');assert.equal(sf.elements.from.value,'22:00');assert.equal(sf.elements.hot.checked,true);assert.equal(sf.dataset.mode,'hours');assert.equal($('scheduleNote').textContent,'now: outside mining hours 22:00–07:00');assert.equal($('engineStatus').textContent,'■ STOPPED');
 sf.elements.from.value='23:30';sf.onchange();assert.deepEqual(last(),{action:'schedule',mode:'hours',idle:10,from:'23:30',to:'07:00',hot:true});
 np=posts.length;sf.elements.to.value='23:30';sf.onchange();assert.equal(posts.length,np);assert.match($('notice').textContent,/two different times/);
 sf.elements.mode.value='idle';for(const v of ['0','121','1.5','']){sf.elements.idle.value=v;sf.onchange();assert.equal(posts.length,np,v)}assert.match($('notice').textContent,/1 to 120/);
 sf.elements.idle.value='30';sf.onchange();assert.deepEqual(last(),{action:'schedule',mode:'idle',idle:30,from:'22:00',to:'07:00',hot:true});   // the hidden hours keep their saved values
 await receive({type:'schedule',data:hours,paused:false,reason:'',hold:'',override:false});assert.equal(sf.elements.to.value,'23:30');   // same state again: a half-typed field is left alone
 const power={mode:'power',idle:30,from:'22:00',to:'07:00',hot:false};
 await receive({type:'schedule',data:power,paused:true,reason:'on battery power',hold:'on battery power',override:false,event:'paused'});
 assert.equal(sf.elements.mode.value,'power');assert.equal($('engineStatus').textContent,'■ PAUSED BY SCHEDULE — ON BATTERY POWER');assert.equal($('engineStatus').title,'on battery power');assert.match($('notice').textContent,/^Paused by schedule — on battery power/);assert.equal($('schedOffer').hidden,true);assert.equal($('actionNote').textContent,'Paused by schedule: on battery power. Mining resumes when it allows.');assert.equal($('actionNote').classList.contains('held'),true);
 fill('settings',{network:'testnet',address:'txa1rx',worker:'w',host:'h',port:'1',password:'',mode:'solo',explorer:'https://superknet.com'});$('start').onclick();assert.equal(last().action,'save');assert.equal(last().startAfterSave,true);
 await receive({type:'schedule',data:power,paused:true,reason:'on battery power',hold:'on battery power',override:false,event:'blocked'});
 assert.equal($('schedOffer').hidden,false);assert.equal($('actionNote').hidden,true);assert.equal($('schedWhy').textContent,'PAUSED BY SCHEDULE — ON BATTERY POWER');assert.match($('notice').textContent,/MINE ANYWAY/);
 $('mineAnyway').onclick();assert.deepEqual(last(),{action:'mineAnyway'});assert.equal($('schedOffer').hidden,true);assert.equal($('actionNote').hidden,false);
 await receive({type:'started'});await receive({type:'schedule',data:power,paused:false,reason:'',hold:'on battery power',override:true});assert.equal($('scheduleNote').textContent,'MINE ANYWAY — until the schedule next changes');assert.equal($('engineStatus').textContent,'■ STARTING / MINING');assert.doesNotMatch($('actionNote').textContent,/^Paused/);assert.equal($('actionNote').classList.contains('held'),false);
 $('start').onclick();assert.deepEqual(last(),{action:'stop'});await receive({type:'stopped',code:15});await receive({type:'schedule',data:power,paused:false,reason:'',hold:'on battery power',override:false});assert.equal($('engineStatus').textContent,'■ STOPPED');
 await receive({type:'schedule',data:power,paused:true,reason:'on battery power',hold:'on battery power',override:false,event:'blocked'});$('stayStopped').onclick();assert.deepEqual(last(),{action:'scheduleStay'});assert.equal($('schedOffer').hidden,true);
 await receive({type:'schedule',data:power,paused:true,reason:'on battery power',hold:'on battery power',override:false,event:'blocked'});await receive({type:'started'});assert.equal($('schedOffer').hidden,true);   // mining: no offer
 // NUKE: back to SETUP with the form cleared
 fill('settings',{address:'txa1rgone'});await receive({type:'nuked'});assert.equal($('settings').elements.address.value,'');assert.equal($('view-setup').hidden,false);assert.equal($('schedOffer').hidden,true);assert.equal(js('JSON.stringify(profile)'),'{}');
 console.log('Schedule: form from Swift, saved on change, local refusals, hidden fields keep saved values, no clobbering, paused status and title, blocked START offer, MINE ANYWAY, STAY STOPPED, NUKE passed');
})().catch(e=>{console.error(e);process.exit(1)});
