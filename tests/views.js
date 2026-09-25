// Exercise the actual tab/pagination/theme functions without a browser or GPU.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../app.js'),'utf8'),html=fs.readFileSync(require('node:path').join(__dirname,'../index.html'),'utf8');
function func(name){const start=source.indexOf('function '+name+'(');let level=0,begin=source.indexOf('{',start);for(let i=begin;i<source.length;i++){if(source[i]==='{')level++;if(source[i]==='}'&&--level===0)return source.slice(start,i+1)}throw Error(name)}
const elements={};function get(id){return elements[id]??=( {hidden:false,attrs:{},classList:{toggle(){}},setAttribute(k,v){this.attrs[k]=v},querySelector(){return {clientHeight:300}},scrollIntoView(o){this.scrolledInto=JSON.stringify(o)}})}
get('walletReceive').hidden=true;get('walletSeedBox').hidden=true;
let renders=0,stored,rxCloses=0,fits=0;const sent=[];const context=vm.createContext({$:get,send(a){sent.push(a)},blockPage:99,minerPage:0,renderBlocks(){renders++},renderMiners(){renders++},renderLog(){renders++},closeReceive(){rxCloses++},fitMetrics(){fits++},document:{documentElement:{dataset:{}}},getComputedStyle(){return {getPropertyValue(key){return key==='--table-row-height'?'72px':'42px'}}},localStorage:{setItem(k,v){stored=v}}});
vm.runInContext(source.match(/const tabNames=\[[^\]]*\];/)[0],context);  // the real tab list, so the test cannot drift from it
for(const name of ['selectTab','pageInfo','applyTheme'])vm.runInContext(func(name),context);
context.selectTab('miners');assert.equal(get('view-miners').hidden,false);assert.equal(get('view-dashboard').hidden,true);assert.equal(get('tab-miners').attrs['aria-selected'],'true');assert.equal(get('tab-dashboard').tabIndex,-1);
context.selectTab('setup');assert.equal(get('view-miners').hidden,true);assert.equal(get('view-setup').hidden,false);
context.selectTab('invalid');assert.equal(get('view-dashboard').hidden,false);
assert.deepEqual(sent,[]);context.selectTab('wallet');context.selectTab('create');assert.deepEqual(sent,['walletRefresh','walletRefresh']);
context.selectTab('forum');assert.equal(get('view-forum').hidden,false);assert.equal(sent.at(-1),'forumRefresh');assert.equal(vm.runInContext('tabNames',context).slice(4).join(),'create,forum,setup');
let p=context.pageInfo('blocks',8);assert.equal(p.count,3);assert.equal(p.start,6);assert.equal(get('blocksNext').disabled,true);assert.equal(get('blocksPrev').disabled,false);
p=context.pageInfo('miners',0);assert.equal(p.start,0);assert.equal(get('minersPrev').disabled,true);assert.equal(get('minersNext').disabled,true);
get('blocks').querySelector=()=>({clientHeight:50});p=context.pageInfo('blocks',8);assert.equal(p.count,1);
// RECEIVE is the WALLET tab's dialog: leaving the tab closes it, staying does not; the dashboard fits its metrics again;
// NEW WALLET brings a seed that is waiting back into view
get('walletReceive').hidden=false;context.selectTab('wallet');assert.equal(rxCloses,0);context.selectTab('blocks');assert.equal(rxCloses,1);get('walletReceive').hidden=true;context.selectTab('setup');assert.equal(rxCloses,1);
const fits0=fits;context.selectTab('dashboard');assert.equal(fits,fits0+1);context.selectTab('miners');assert.equal(fits,fits0+1);
context.selectTab('create');assert.equal(get('walletSeedBox').scrolledInto,undefined);get('walletSeedBox').hidden=false;context.selectTab('create');assert.equal(get('walletSeedBox').scrolledInto,'{"block":"nearest"}');
context.applyTheme(true);assert.equal(stored,'dark');assert.equal(get('themeToggle').attrs['aria-checked'],'true');context.applyTheme(false);assert.equal(stored,'light');assert.equal(get('themeLabel').textContent,'LIGHT');
console.log('Tab selection, hidden panels, pagination bounds, short windows, theme persistence, RECEIVE closed on leaving WALLET, metrics fitted on DASHBOARD, and a waiting seed brought into view on NEW WALLET passed');

// Whole page: load the real app.js against a stub DOM and replay Swift's messages.
function node(tag){const kids=[],fields={},cls=new Set();const e={tag,hidden:false,disabled:false,value:'',checked:false,title:'',textContent:'',innerHTML:'',className:'',attrs:{},dataset:{},style:{},children:kids,clientHeight:300,fields,
 classList:{add(c){cls.add(c)},remove(c){cls.delete(c)},toggle(c,on){(on??!cls.has(c))?cls.add(c):cls.delete(c)},contains(c){return cls.has(c)}},
 setAttribute(k,v){this.attrs[k]=String(v)},getAttribute(k){return this.attrs[k]??null},append(...c){kids.push(...c)},replaceChildren(...c){kids.splice(0,kids.length,...c)},querySelector(){return node('q')},querySelectorAll(){return []},focus(){doc.activeElement=this},scrollIntoView(o){this.scrolledInto=o},getClientRects(){return this.hidden?[]:[{}]},
 reset(){for(const f of Object.values(fields))f.value=''},checkValidity(){return true},reportValidity(){},requestSubmit(){this.onsubmit?.({preventDefault(){},target:this})}};
 e.elements=new Proxy(fields,{get:(t,k)=>k===Symbol.iterator?function*(){yield*Object.values(t)}:typeof k==='string'?(t[k]??=node('input')):undefined});return e}
const dom={},$=id=>dom[id]??=node(id),posts=[],doc={getElementById:id=>$(id),createElement:tag=>node(tag),documentElement:null,activeElement:null,listeners:{},addEventListener(t,f){(this.listeners[t]??=[]).push(f)}};let marks=0;
// what the banner covers: the controls of each view's top panel title, and the dashboard's payout line
const covered=['walletBackupBtn','walletRxBtn','walletLockBtn','refresh','autoStart','nukeBtn','payout'];
doc.querySelectorAll=sel=>sel==='.view>.workspace:first-child>.panel-title :is(button,a,input,select),#payout'?covered.map($):[];
class FormData{constructor(f){this.f=f}get(k){const i=this.f.fields[k];return !i?null:i.type==='checkbox'?(i.checked?'on':null):i.value}*[Symbol.iterator](){for(const k of Object.keys(this.f.fields))yield [k,this.get(k)]}}
doc.documentElement=node('html');const page=vm.createContext({document:doc,localStorage:{getItem(){return null},setItem(){}},matchMedia:()=>({matches:false}),addEventListener(){},getComputedStyle:()=>({getPropertyValue:()=>'',lineHeight:'18px'}),setTimeout,clearTimeout,FormData,
 identiconSvg:async a=>{marks++;return '<svg>'+a+'</svg>'},webkit:{messageHandlers:{native:{postMessage:m=>posts.push(JSON.parse(JSON.stringify(m)))}}}});
page.window=page;$('walletReceive').hidden=true;   // as index.html has it: closed at load
vm.runInContext(source,page);
const js=expr=>vm.runInContext(expr,page),last=()=>posts[posts.length-1],fill=(form,v)=>{for(const [k,x] of Object.entries(v))$(form).elements[k].value=x};
const walletState={wallets:[{name:'wallet.mmm',file:'/x/wallet.mmm',format:'mmm5',default:true,selected:true},{name:'wallet003.mmm',file:'/x/wallet003.mmm',format:'mmm5'}],selected:'/x/wallet.mmm',selectedIndex:101,cliFound:true,balances:{}};
(async()=>{
 const receive=m=>page.receive(m);
 // Switching wallet file sends only the file, so Swift keeps that file's own saved index.
 await receive({type:'wallet',data:walletState});assert.equal($('walletIdx').value,101);
 $('walletFileSel').onchange({target:{value:'/x/wallet003.mmm'}});assert.deepEqual(last(),{action:'walletSelect',file:'/x/wallet003.mmm'});
 $('walletFileSel').value='/x/wallet003.mmm';$('walletIdx').value='7';$('walletIdx').onchange();assert.deepEqual(last(),{action:'walletSelect',file:'/x/wallet003.mmm',index:7});
 // Errors stay until the user's next command; the 15 s chain tick and tab refreshes do not replace them.
 const testnet='Testnet A is the rehearsal chain. Rewards are test coins.',seedFail='Wallet created, but the seed reveal failed — run `xcoin-wallet-cli --file ~/.xcoin/wallet004.mmm seed` in Terminal to back it up NOW.';
 await receive({type:'error',message:'Enter an IP address.'});await receive({type:'chain',data:{}});assert.equal($('notice').textContent,'Enter an IP address.');
 $('refresh').onclick();await receive({type:'chain',data:{}});assert.equal($('notice').textContent,testnet);
 await receive({type:'walletStatus',state:'fail',message:seedFail});js("selectTab('wallet')");await receive({type:'walletStatus',state:'working',message:'Unlocking the wallet…'});await receive({type:'walletStatus',state:'ok',message:'Wallet unlocked.'});await receive({type:'chain',data:{}});assert.equal($('notice').textContent,seedFail);
 // NEW WALLET: a create keeps its status and a disabled button across tab switches.
 js("selectTab('create')");fill('walletCreateForm',{name:'wallet004.mmm',pass:'pw',pass2:'pw'});$('walletCreateForm').onsubmit({preventDefault(){},target:$('walletCreateForm')});assert.equal(last().action,'walletCreate');
 await receive({type:'walletStatus',state:'working',message:'Provisioning…'});js("selectTab('wallet')");await receive({type:'wallet',data:walletState});assert.equal($('createBtn').disabled,true);assert.equal($('createState').textContent,'WORKING…');
 await receive({type:'walletStatus',state:'ok',message:'Card wallet created.'});assert.equal($('createState').textContent,'✓ DONE');assert.equal($('walletCreateForm').elements.name.value,'');await receive({type:'wallet',data:walletState});assert.equal($('createBtn').disabled,false);
 fill('walletCreateForm',{name:'wallet005.mmm',pass:'pw',pass2:'pw'});$('walletCreateForm').onsubmit({preventDefault(){},target:$('walletCreateForm')});await receive({type:'walletStatus',state:'working',message:'Creating wallet005.mmm…'});assert.equal($('createState').textContent,'WORKING…');
 await receive({type:'walletSeed',name:'wallet005.mmm',seed:'abandon'});assert.equal($('createState').textContent,'✓ DONE');assert.equal($('walletSeedBox').hidden,false);assert.equal(JSON.stringify($('walletSeedBox').scrolledInto),'{"block":"nearest"}');   // brought into view in the scrolling panel
 // a seed that arrives while another tab shows: a sticky notice says it waits (the unlock's own notices do not replace it);
 // NEW WALLET brings the box into view; I WROTE IT DOWN ends the notice
 assert.equal($('notice').textContent,'Write the seed of wallet005.mmm on paper now: it is on the NEW WALLET tab and is shown only once.');
 js("selectTab('wallet')");await receive({type:'walletSeed',name:'wallet006.mmm',seed:'zoo'});$('walletSeedBox').scrolledInto=null;
 await receive({type:'walletStatus',state:'working',message:'Unlocking the wallet…'});await receive({type:'walletStatus',state:'ok',message:'Wallet unlocked.'});await receive({type:'chain',data:{}});
 assert.equal($('notice').textContent,'Write the seed of wallet006.mmm on paper now: it is on the NEW WALLET tab and is shown only once.');
 js("selectTab('create')");assert.equal(JSON.stringify($('walletSeedBox').scrolledInto),'{"block":"nearest"}');
 $('walletSeedBox').children[2].onclick();assert.equal($('walletSeedBox').hidden,true);assert.equal($('view-wallet').hidden,false);assert.equal($('notice').textContent,'wallet006.mmm is ready. Keep the paper with its seed somewhere safe.');assert.equal(js('noticeSticky'),false);await receive({type:'walletStatus',state:'ok',message:'Wallet unlocked.'});
 // AMOUNT: a lone decimal comma becomes a dot; a grouped number is refused locally.
 fill('walletSendForm',{dest:'txa1rabc',amount:'0,5',passphrase:''});$('walletSendForm').onsubmit({preventDefault(){},target:$('walletSendForm')});assert.equal(last().amount,'0.5');
 const n=posts.length;fill('walletSendForm',{amount:'1.234,5'});$('walletSendForm').onsubmit({preventDefault(){},target:$('walletSendForm')});assert.equal(posts.length,n);assert.match($('notice').textContent,/dot for decimals/);
 assert.equal(js('xcfFmt(123456789012345)'),'1234567.89012345');
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
 console.log('Wallet key index kept per file, sticky notices, create status, seed box brought into view, network hash units and metric titles, metrics shrunk to fit (one size per row, with a floor), the engine log\'s latest lines whole, a seed waiting on NEW WALLET (sticky notice, back in view, ended by I WROTE IT DOWN), worker-name title, amount comma, setup save echo, pool reconnect, minerPending, engine exit reason, and identicon memo passed');
 // Card banner: the ticker says each phase, the tap counts down, CANCEL asks Swift, CLOSE only hides.
 const text=n=>(n.textContent||'')+n.children.map(text).join(''),banner=$('cardBanner'),count=$('cardCount'),D=vm.runInContext('Date',page),realNow=D.now,clock={t:1e12};D.now=()=>clock.t;banner.hidden=true;
 await receive({type:'cardPrompt',phase:'touchid'});assert.equal(banner.hidden,false);assert.equal($('cardText').textContent,'AUTHORIZE WITH TOUCH ID');assert.equal(count.textContent,'');
 const strips=$('cardTrack').children;assert.equal(strips.length,2);assert.equal(text(strips[0]),text(strips[1]));assert.match(text(strips[0]),/^(AUTHORIZE WITH TOUCH ID◆){5,}$/);
 await receive({type:'cardPrompt',phase:'tap',seconds:60});assert.equal($('cardText').textContent,'TAP & HOLD YOUR XCOIN CARD FLAT ON THE READER');assert.equal(banner.dataset.phase,'tap');assert.equal(count.textContent,'01:00');
 clock.t+=13000;js('cardTick()');assert.equal(count.textContent,'00:47');
 clock.t+=47000;js('cardTick()');assert.equal(count.textContent,'TIME UP — TAP OR CANCEL');assert.equal(count.classList.contains('up'),true);assert.equal(banner.classList.contains('up'),true);
 await receive({type:'cardPrompt',phase:'tap',seconds:45});assert.equal(count.textContent,'45');assert.equal(count.classList.contains('up'),false);clock.t+=44500;js('cardTick()');assert.equal(count.textContent,'01');
 await receive({type:'cardPrompt',phase:'retry',attempt:1});assert.equal($('cardText').textContent,'THE READER RESET THE CARD — KEEP IT ON THE READER — READING AGAIN');assert.equal($('cardCancel').disabled,false);assert.equal(count.textContent,'');
 await receive({type:'cardPrompt',phase:'retry',attempt:2,seconds:60});assert.equal($('cardText').textContent,'THE READER RESET THE CARD — KEEP IT ON THE READER — READING AGAIN');assert.equal(count.textContent,'01:00');   // the CLI waits for the card again: a fresh countdown
 clock.t+=15000;js('cardTick()');assert.equal(count.textContent,'00:45');assert.equal($('cardText').textContent,'THE READER RESET THE CARD — KEEP IT ON THE READER — READING AGAIN. NOTHING DETECTED? UNPLUG THE READER, PLUG IT BACK IN, TAP AGAIN');assert.equal(banner.classList.contains('alt'),true);
 // nothing read for 15 s: the replug hint takes turns with the tap words; the countdown keeps running; a card read ends it
 const HINT='NOTHING DETECTED? UNPLUG THE READER, PLUG IT BACK IN, TAP AGAIN';
 await receive({type:'cardPrompt',phase:'tap',seconds:60});clock.t+=14000;js('cardTick()');assert.doesNotMatch(text(strips[0]),/NOTHING DETECTED/);assert.equal(banner.classList.contains('alt'),false);
 clock.t+=1000;js('cardTick()');assert.match(text($('cardTrack').children[0]),/^(TAP & HOLD YOUR XCOIN CARD FLAT ON THE READER◆NOTHING DETECTED\? UNPLUG THE READER, PLUG IT BACK IN, TAP AGAIN◆){2,}$/);assert.equal($('cardText').textContent,'TAP & HOLD YOUR XCOIN CARD FLAT ON THE READER. '+HINT);assert.equal(count.textContent,'00:45');
 assert.equal(banner.classList.contains('alt'),true);clock.t+=3900;js('cardTick()');assert.equal(banner.classList.contains('alt'),true);clock.t+=100;js('cardTick()');assert.equal(banner.classList.contains('alt'),false);clock.t+=4000;js('cardTick()');assert.equal(banner.classList.contains('alt'),true);   // reduced motion: the hint from 15 s, then 4 s turns
 await receive({type:'cardPrompt',phase:'signing',cardRead:true});assert.doesNotMatch(text($('cardTrack').children[0]),/NOTHING DETECTED/);assert.equal(banner.classList.contains('alt'),false);
 await receive({type:'cardPrompt',phase:'tap',blank:true,seconds:45});clock.t+=15000;js('cardTick()');assert.match(text($('cardTrack').children[0]),/^TAP & HOLD THE NEW BLANK CARD FLAT ON THE READER◆NOTHING DETECTED/);   // a new wait starts its own 15 s
 await receive({type:'cardPrompt',phase:'failed',refused:true});assert.equal($('cardText').textContent,'✗ NOT SENT — THE NETWORK REFUSED IT');await receive({type:'cardPrompt',phase:'failed'});assert.equal($('cardText').textContent,'✗ STOPPED — THE MESSAGE ABOVE SAYS WHY');
 await receive({type:'cardPrompt',phase:'tap',seconds:45});clock.t+=44500;js('cardTick()');
 await receive({type:'cardPrompt',phase:'signing',cardRead:true});assert.match($('cardText').textContent,/^CARD READ ✓/);assert.equal(count.textContent,'');
 // "keep the card on the reader" only when Swift says this action waited for / read a card
 await receive({type:'cardPrompt',phase:'signing',i:1,n:4});assert.equal($('cardText').textContent,'SIGNING TRANSACTION 1 OF 4');
 await receive({type:'cardPrompt',phase:'signing',i:2,n:4,card:true});assert.equal($('cardText').textContent,'SIGNING TRANSACTION 2 OF 4 — KEEP THE CARD ON THE READER');
 assert.equal(banner.classList.contains('static'),false);assert.equal($('cardCancel').disabled,false);$('cardCancel').onclick();assert.deepEqual(last(),{action:'walletCancel'});assert.equal($('cardCancel').disabled,true);assert.equal($('cardCancel').textContent,'CANCELLING…');
 await receive({type:'cardPrompt',phase:'cancelled'});await receive({type:'walletStatus',state:'fail',message:'Cancelled.'});assert.equal(banner.hidden,false);assert.equal(banner.classList.contains('static'),true);assert.equal($('cardCancel').textContent,'CLOSE ✕');assert.equal($('cardCancel').disabled,false);assert.equal($('notice').textContent,'Cancelled.');
 let n0=posts.length;$('cardCancel').onclick();assert.equal(posts.length,n0);assert.equal(banner.hidden,true);
 // Only cardPrompt's terminal phases close the banner: a walletStatus or an unrelated error never does.
 await receive({type:'cardPrompt',phase:'tap',seconds:60});await receive({type:'walletStatus',state:'fail',message:'no card presented in time'});assert.equal(banner.dataset.phase,'tap');assert.equal(banner.hidden,false);
 await receive({type:'cardPrompt',phase:'failed'});assert.equal(banner.dataset.phase,'failed');assert.equal(banner.classList.contains('static'),true);
 await receive({type:'cardPrompt',phase:'done'});assert.equal(banner.hidden,true);D.now=realNow;
 // An error while an action runs (create while busy, a bad watch address): a sticky notice, nothing else changes.
 await receive({type:'walletStatus',state:'working',message:'Signing — tap your xCoin card on the NFC reader…'});await receive({type:'cardPrompt',phase:'tap',seconds:60});
 await receive({type:'error',message:'Not a valid txa1r… address to watch.'});
 assert.equal($('notice').textContent,'Not a valid txa1r… address to watch.');assert.equal($('walletState').textContent,'WORKING…');assert.equal($('walletSendBtn').disabled,true);assert.equal(banner.dataset.phase,'tap');assert.equal(banner.hidden,false);
 await receive({type:'cardPrompt',phase:'done'});await receive({type:'walletStatus',state:'ok',message:'Wallet unlocked.'});
 // From broadcast-begin on, CANCEL is disabled and says why; clicking it asks Swift nothing.
 await receive({type:'cardPrompt',phase:'signing',i:4,n:4});await receive({type:'cardPrompt',phase:'broadcasting',n:4});
 assert.equal($('cardText').textContent,'BROADCASTING 4 TRANSACTIONS');assert.equal($('cardCancel').disabled,true);assert.equal($('cardCancel').textContent,'BROADCASTING — CANNOT CANCEL');
 n0=posts.length;$('cardCancel').onclick();assert.equal(posts.length,n0);assert.equal(banner.hidden,false);
 await receive({type:'cardPrompt',phase:'broadcasting',i:3,n:4});assert.equal($('cardText').textContent,'SENT 3 OF 4 — BROADCASTING THE REST');assert.equal($('cardCancel').disabled,true);
 const strip=$('cardTrack').children[0];await receive({type:'cardPrompt',phase:'broadcasting',i:3,n:4});assert.equal($('cardTrack').children[0],strip);   // same words: the scroll is not restarted
 await receive({type:'cardPrompt',phase:'broadcasting',i:4,n:4});assert.equal($('cardText').textContent,'SENT 4 OF 4');assert.equal($('cardCancel').textContent,'BROADCASTING — CANNOT CANCEL');
 await receive({type:'cardPrompt',phase:'broadcasting',n:1});assert.equal($('cardText').textContent,'BROADCASTING');
 // quitting during a broadcast: MMM says it waits, CANCEL stays locked
 await receive({type:'cardPrompt',phase:'broadcasting',n:2,i:1,quitting:true});assert.equal($('cardText').textContent,'FINISHING BROADCAST — MMM WILL QUIT WHEN IT IS DONE');assert.equal($('cardCancel').disabled,true);
 // a refused CANCEL leaves the page waiting for the result; the end closes the banner
 await receive({type:'walletStatus',state:'working',message:'Signing offline and broadcasting…'});assert.equal(banner.hidden,false);assert.equal($('cardCancel').disabled,true);
 await receive({type:'cardPrompt',phase:'done'});assert.equal(banner.hidden,true);
 // The next action's CANCEL works again.
 await receive({type:'cardPrompt',phase:'touchid'});assert.equal($('cardCancel').disabled,false);assert.equal($('cardCancel').textContent,'CANCEL ✕');
 // CANCEL with nothing running: Swift answers done, never cancelled, and the banner just goes.
 $('cardCancel').onclick();assert.deepEqual(last(),{action:'walletCancel'});await receive({type:'cardPrompt',phase:'done'});assert.equal(banner.hidden,true);assert.equal(js('cardPhase'),'done');
 // the controls the banner covers leave the tab order (inert) while it shows, its end line included, and come back when it closes
 const under=()=>covered.map(i=>!!$(i).inert),none=covered.map(()=>false),all=covered.map(()=>true);
 assert.deepEqual(under(),none);await receive({type:'cardPrompt',phase:'tap',seconds:60});assert.deepEqual(under(),all);
 await receive({type:'cardPrompt',phase:'provisioning'});assert.deepEqual(under(),all);await receive({type:'cardPrompt',phase:'failed'});assert.deepEqual(under(),all);
 $('cardCancel').onclick();assert.equal(banner.hidden,true);assert.deepEqual(under(),none);   // CLOSE on the end line
 await receive({type:'cardPrompt',phase:'touchid'});assert.deepEqual(under(),all);await receive({type:'cardPrompt',phase:'done'});assert.deepEqual(under(),none);
 assert.notEqual($('cardText').textContent,'CANCELLED');
 // LOCK sits next to UNLOCKED, asks Swift to forget the address, and the unlock form comes back.
 await receive({type:'wallet',data:{...walletState,walletAddress:'txa1rme',balances:{}}});assert.equal($('walletState').textContent,'✓ UNLOCKED');assert.equal($('walletLockBtn').hidden,false);assert.equal($('walletUnlockForm').hidden,true);
 $('walletLockBtn').onclick();assert.deepEqual(last(),{action:'walletLock'});await receive({type:'walletLocked'});assert.match($('notice').textContent,/UNLOCK again/);
 await receive({type:'wallet',data:walletState});assert.equal($('walletLockBtn').hidden,true);assert.equal($('walletUnlockForm').hidden,false);assert.equal($('walletState').textContent,'LOCKED');
 await receive({type:'walletStatus',state:'working',message:'Signing…'});assert.equal($('walletLockBtn').disabled,true);
 // Receipt: every txid with a link and COPY; "N transactions" when split; a partial send says what did not go out.
 const tx=k=>String(k).repeat(64),rc=$('walletReceipt'),part=c=>rc.children.find(k=>k.className===c);
 await receive({type:'walletSent',txid:tx(1),txids:[tx(1),tx(2),tx(3),tx(4)],transactions:4,partial:false,amount:'1500.00000000',fee:'0.00400000',vsize:4000});
 assert.equal($('walletLockBtn').disabled,false);assert.equal(rc.hidden,false);assert.equal(text(rc.children[0].children[0]),'SENT ✓ 4 TRANSACTIONS');assert.match(text(rc.children[0]),/1500\.00000000 XID · fee 0\.00400000 XID · 4000 vB/);
 let rows=part('wr-list').children;assert.equal(rows.length,4);assert.equal(rows[2].children[0].title,tx(3));assert.match($('notice').textContent,/Sent in 4 transactions/);
 rows[2].children[0].onclick({preventDefault(){}});assert.deepEqual(last(),{action:'open',path:'/tx/'+tx(3)});rows[3].children[1].onclick({preventDefault(){},stopPropagation(){}});assert.deepEqual(last(),{action:'copy',text:tx(4)});
 await receive({type:'walletSent',txid:tx(5),txids:[tx(5),tx(6)],transactions:4,partial:true,broadcast_error:'explorer refused tx 3: mempool full'});
 const why='Sent 2 of 4 transactions: explorer refused tx 3: mempool full';await receive({type:'walletStatus',state:'fail',message:why});
 assert.equal(text(rc.children[0].children[0]),'⚠ SENT 2 OF 4 TRANSACTIONS');assert.equal(part('wr-list').children.length,3);assert.equal(text(part('wr-list').children[0]),'SENT:');assert.match(text(part('wr-miss')),/^STOPPED: .*mempool full/);assert.equal(rc.classList.contains('partial'),true);
 assert.match(text(part('wr-unsure')),/^Check the explorer before re-sending the rest/);assert.doesNotMatch(text(rc),/NOT SENT/);
 part('wr-list').children[1].children[1].onclick({preventDefault(){},stopPropagation(){}});assert.deepEqual(last(),{action:'copy',text:tx(5)});await receive({type:'chain',data:{}});assert.equal($('notice').textContent,why);   // copying a txid keeps the error up
 // The CLI's unsent_txids: the first one's broadcast result is unknown, so it is shown to look up, never as NOT SENT.
 const u=[tx(8),tx(9),tx('a')];await receive({type:'walletSent',txid:tx(5),txids:[tx(5)],transactions:4,partial:true,broadcast_error:'cannot reach the explorer: timed out',unsent_txids:u});
 assert.equal(text(part('wr-unsure')),'Check this txid on the explorer before re-sending — the connection may have dropped after it went out.');
 // the uncertain txid right under the head's warning, before the (long) reason
 assert.equal(rc.children.indexOf(part('wr-unsure')),1);const unsure=rc.children[2];assert.equal(unsure.className,'addr-line');assert.equal(unsure.children[0].title,tx(8));assert.equal(rc.children[3],part('wr-miss'));
 unsure.children[0].onclick({preventDefault(){}});assert.deepEqual(last(),{action:'open',path:'/tx/'+tx(8)});unsure.children[1].onclick({preventDefault(){},stopPropagation(){}});assert.deepEqual(last(),{action:'copy',text:tx(8)});
 // then SENT: and NOT BROADCAST: (all the others), each txid with its link and COPY, each exactly once
 const never=part('wr-list wr-never'),titles=l=>l.children.filter(k=>k.className==='addr-line').map(k=>k.children[0].title);
 assert.deepEqual(rc.children.map(k=>k.className),['wr-head','wr-unsure','addr-line','wr-miss','wr-list','wr-list wr-never']);
 assert.equal(text(part('wr-list').children[0]),'SENT:');assert.deepEqual(titles(part('wr-list')),[tx(5)]);
 assert.equal(text(never.children[0]),'NOT BROADCAST:');assert.deepEqual(titles(never),[tx(9),tx('a')]);assert.doesNotMatch(text(rc),/NOT SENT/);
 never.children[2].children[0].onclick({preventDefault(){}});assert.deepEqual(last(),{action:'open',path:'/tx/'+tx('a')});never.children[1].children[1].onclick({preventDefault(){},stopPropagation(){}});assert.deepEqual(last(),{action:'copy',text:tx(9)});
 await receive({type:'walletSent',txid:tx(5),txids:[tx(5),tx(6),tx(7)],transactions:4,partial:true,broadcast_error:'x',unsent_txids:[tx(8)]});assert.equal(part('wr-list wr-never'),undefined);assert.deepEqual(titles(part('wr-list')),[tx(5),tx(6),tx(7)]);
 await receive({type:'walletSent',txid:tx(5),txids:[tx(5)],transactions:3,partial:true,broadcast_error:'x',unsent_txids:[tx(8),tx(9)]});assert.deepEqual(titles(part('wr-list wr-never')),[tx(9)]);
 // a refusal the network answered: NOT SENT, certain; its plain words whole; the form kept to send again after the next block
 const refusedWhy='Nothing was sent: these coins are already being spent by an earlier send that has not confirmed yet. Wait for the next block, then send again. (insufficient fee)';
 fill('walletSendForm',{dest:'txa1rkeep',amount:'2.5'});await receive({type:'walletSent',txids:[],transactions:1,partial:false,refused:{i:1,n:1,reason:'insufficient-fee'},message:refusedWhy});
 assert.equal(text(rc.children[0]),'NOT SENT — THE NETWORK REFUSED IT');assert.equal(text(part('wr-miss')),refusedWhy);assert.equal(rc.classList.contains('refused'),true);assert.equal(rc.classList.contains('partial'),true);
 assert.equal(part('wr-list'),undefined);assert.equal($('walletSendForm').elements.dest.value,'txa1rkeep');assert.equal($('walletSendForm').elements.amount.value,'2.5');assert.equal($('walletSendBtn').disabled,false);
 await receive({type:'walletSent',txids:[],transactions:4,refused:{i:1,n:4,reason:'min-relay-fee'},message:'Nothing was sent: x'});assert.equal(text(part('wr-refused')),'None of the 4 transactions went out.');
 // the third of four refused: SENT: the first two; NOT SENT: the refused one and the rest; no look-it-up wording
 await receive({type:'walletSent',txid:tx(1),txids:[tx(1),tx(2)],transactions:4,partial:true,refused:{i:3,n:4,reason:'bad-txns-inputs-missingorspent'},broadcast_error:'these coins were already spent (bad-txns-inputs-missingorspent)',unsent_txids:[tx(3),tx(4)]});
 assert.equal(text(rc.children[0].children[0]),'⚠ SENT 2 OF 4 TRANSACTIONS');assert.equal(text(part('wr-refused')),'TRANSACTION 3 OF 4: NOT SENT — THE NETWORK REFUSED IT');assert.equal(text(part('wr-miss')),'These coins were already spent (bad-txns-inputs-missingorspent)');
 assert.deepEqual(titles(part('wr-list')),[tx(1),tx(2)]);assert.equal(text(part('wr-list wr-never').children[0]),'NOT SENT:');assert.deepEqual(titles(part('wr-list wr-never')),[tx(3),tx(4)]);assert.equal(part('wr-unsure'),undefined);assert.equal(rc.classList.contains('refused'),false);
 await receive({type:'walletSent',txid:tx(7),fee:'0.0001',vsize:200});assert.equal(part('wr-unsure'),undefined);assert.equal(rc.classList.contains('refused'),false);assert.equal(text(rc.children[0].children[0]),'SENT ✓');assert.equal(part('wr-list').children.length,1);assert.equal(part('wr-miss'),undefined);assert.equal(rc.classList.contains('partial'),false);
 // Receipt links open the explorer the send used; the last session's interrupted send is shown with its wallet.
 await receive({type:'walletSent',txid:tx(2),txids:[tx(2)],transactions:2,partial:true,broadcast_error:'x',unsent_txids:[tx(3)],explorer:'https://old.example'});
 part('wr-list').children[1].children[0].onclick({preventDefault(){}});assert.deepEqual(last(),{action:'open',path:'/tx/'+tx(2),origin:'https://old.example'});
 rc.children[2].children[0].onclick({preventDefault(){}});assert.deepEqual(last(),{action:'open',path:'/tx/'+tx(3),origin:'https://old.example'});
 // re-shown at launch (after auto-start's setupRequired chose SETUP): the WALLET tab shows it; a live send's receipt never moves tabs
 js("selectTab('dashboard')");await receive({type:'walletSent',txid:tx(2),txids:[tx(2)],transactions:1,fee:'0.0001',vsize:200});assert.equal($('view-wallet').hidden,true);
 await receive({type:'setupRequired',message:'Automatic mining is on.'});assert.equal($('view-setup').hidden,false);
 await receive({type:'walletSent',txid:tx(2),txids:[tx(2)],transactions:2,partial:true,broadcast_error:'x',unsent_txids:[tx(3)],relaunch:true});assert.equal($('view-wallet').hidden,false);assert.equal($('tab-wallet').getAttribute('aria-selected'),'true');assert.equal(rc.hidden,false);
 js("selectTab('setup')");
 const who='txa1r'+'q'.repeat(58),closed='MMM was closed while a send was broadcasting. Check this wallet on the explorer before sending again.\nWallet: '+who;
 await receive({type:'sendInterrupted',address:who,explorer:'https://old.example',txids:[tx(6)],message:closed});await receive({type:'chain',data:{}});
 assert.equal($('notice').textContent,closed);assert.equal(rc.hidden,false);assert.equal($('view-wallet').hidden,false);assert.equal($('view-setup').hidden,true);assert.equal(rc.classList.contains('partial'),true);assert.match(text(rc.children[0]),/MMM WAS CLOSED WHILE A SEND WAS BROADCASTING/);
 assert.equal(rc.children[2].children[0].title,who);rc.children[2].children[0].onclick({preventDefault(){}});assert.deepEqual(last(),{action:'open',path:'/address/'+who,origin:'https://old.example'});
 rc.children[2].children[1].onclick({preventDefault(){},stopPropagation(){}});assert.deepEqual(last(),{action:'copy',text:who});assert.equal(part('wr-list').children[0].children[0].title,tx(6));
 // A failed send's error stays whole in the notice.
 const long='error: this payment needs 180 inputs, more than the 72 one standard transaction can carry — '+'x'.repeat(600)+'\n  split the send';await receive({type:'walletStatus',state:'fail',message:long});assert.equal($('notice').textContent,long);
 console.log('Card banner phases, the controls under it out of the tab order while it shows, card words, reader-reset line with its own countdown and hint, replug hint from 15 s (hint first, alternating, ended by a card read), refused end, quitting words, ticker strips, countdown and time-up, cancel/close wiring, broadcast lock, terminal-only banner close, unrelated errors, idle cancel, lock, multi-txid, partial and uncertain-txid receipts, SENT/NOT BROADCAST labels, receipt explorer links, re-shown receipts on the WALLET tab, interrupted send, whole error notices, and NOT SENT only for a refusal the network answered passed');
 const tick=()=>new Promise(r=>setTimeout(r,0)),ev0={preventDefault(){},stopPropagation(){}};
 // FORUM tab: the sign-in form works as it did in SETUP; the identity only on request; OPEN FORUM
 js("selectTab('forum')");assert.equal($('view-forum').hidden,false);assert.deepEqual(last(),{action:'forumRefresh'});
 await receive({type:'forumCred',saved:false});assert.equal($('passLabel').hidden,false);assert.equal($('loginBtn').textContent,'SIGN IN TO MINEDIFFERENT ↗');
 const rem=$('loginForm').elements.remember;rem.type='checkbox';rem.checked=true;fill('loginForm',{passphrase:'pw'});$('loginForm').onsubmit({preventDefault(){},target:$('loginForm')});assert.deepEqual(last(),{action:'login',passphrase:'pw',remember:true});
 await receive({type:'forumCred',saved:true});assert.equal($('passLabel').hidden,true);assert.equal($('rememberLabel').hidden,true);assert.equal($('forgetBtn').hidden,false);assert.equal($('loginBtn').textContent,'SIGN IN WITH TOUCH ID ↗');
 $('loginForm').onsubmit({preventDefault(){},target:$('loginForm')});assert.deepEqual(last(),{action:'loginTouch'});$('forgetBtn').onclick();assert.deepEqual(last(),{action:'loginForget'});
 await receive({type:'loginStatus',state:'running'});assert.equal($('loginBtn').disabled,true);await receive({type:'loginStatus',state:'ok',message:'Signed in.'});assert.equal($('loginState').textContent,'✓ SIGNED IN — CHECK YOUR BROWSER');assert.equal($('loginBtn').disabled,false);
 const XID='xid1'+'q'.repeat(58);
 await receive({type:'forumIdentity',state:'idle',wallet:'wallet.mmm',card:false,xid:'',last:0});assert.equal($('fidBox').hidden,true);assert.equal($('fidShow').hidden,false);assert.equal($('fidShow').disabled,false);assert.equal($('forumLast').textContent,'NO SIGN-IN FROM THIS MAC YET');
 fill('loginForm',{passphrase:'secret'});$('fidShow').onclick();assert.deepEqual(last(),{action:'forumIdentity',passphrase:'secret'});assert.equal($('loginForm').elements.passphrase.value,'');
 await receive({type:'forumIdentity',state:'working',wallet:'wallet.mmm',xid:'',last:0});assert.equal($('fidShow').disabled,true);assert.equal($('fidShow').textContent,'READING…');
 await receive({type:'forumIdentity',state:'idle',wallet:'wallet.mmm',xid:XID,last:1790000000});assert.equal($('fidBox').hidden,false);assert.equal($('fidShow').hidden,true);assert.equal($('fidWallet').textContent,'wallet.mmm · KEY 101');assert.equal($('fidWallet').title,'wallet.mmm · KEY 101');assert.match($('forumLast').textContent,/^LAST SIGN-IN FROM THIS MAC: ./);
 const idLine=$('fidBox').children[1];assert.equal(idLine.children[0].textContent,XID);idLine.children[1].onclick(ev0);assert.deepEqual(last(),{action:'copy',text:XID});
 await tick();assert.equal($('fidBox').children[0].innerHTML,'<svg>'+XID+'</svg>');   // the forum's own mark: seeded by the xid
 await receive({type:'forumIdentity',state:'idle',wallet:'',xid:'',last:0});assert.equal($('fidShow').disabled,true);   // no wallet file: nothing to read
 $('forumOpen').onclick();assert.deepEqual(last(),{action:'openForum'});
 console.log('FORUM tab: moved sign-in (typed, Touch ID, forget, status), identity on request with passphrase hand-off, mark, COPY, last sign-in, OPEN FORUM passed');
 // RECEIVE: on the selected row; Swift draws the QR; the amount is checked here first; stale answers dropped
 js("selectTab('wallet')");const me='txa1r'+'m'.repeat(58),png='data:image/png;base64,AAAA';
 await receive({type:'wallet',data:{...walletState,walletAddress:me,balances:{}}});await tick();
 const rvb=$('walletRxBtn');assert.equal(rvb.hidden,false);assert.equal($('walletBalances').children.flatMap(r=>r.children).some(k=>k.tag==='button'&&k.textContent.startsWith('RECEIVE')),false);   // not a row column any more
 const beneath=['walletTitle','walletHead','walletBalances','walletActions'];assert.deepEqual(beneath.map(i=>!!$(i).inert),[false,false,false,false]);
 rvb.focus();rvb.onclick();assert.equal($('walletReceive').hidden,false);assert.deepEqual(last(),{action:'walletQR',address:me,amount:'',seq:js('rvSeq')});
 assert.deepEqual(beneath.map(i=>$(i).inert),[true,true,true,true]);assert.equal(doc.activeElement,$('rvAmount'));assert.equal($('rvQr').hidden,false);assert.equal($('rvImg').hidden,true);   // a placeholder box until the QR comes
 await receive({type:'walletQR',address:me,seq:js('rvSeq'),uri:'xcoin:'+me,png,modules:45});assert.equal($('rvImg').src,png);assert.equal($('rvImg').style.width,'180px');assert.equal($('rvImg').hidden,false);
 const uriLine=$('rvUri').children[0];assert.equal(uriLine.children[0].textContent,'xcoin:'+me);uriLine.children[1].onclick(ev0);assert.deepEqual(last(),{action:'copy',text:'xcoin:'+me});
 $('rvAddr').children[0].children[1].onclick(ev0);assert.deepEqual(last(),{action:'copy',text:me});
 // Tab and Shift+Tab wrap inside the panel
 const f=[$('rvClose'),$('rvAmount'),uriLine.children[1],$('rvAddr').children[0].children[1]];$('walletReceive').querySelectorAll=()=>f;let prevented=0;const key=(k,sh)=>doc.listeners.keydown.forEach(h=>h({key:k,shiftKey:!!sh,preventDefault(){prevented++}}));
 f[3].focus();key('Tab');assert.equal(doc.activeElement,f[0]);assert.equal(prevented,1);f[1].focus();key('Tab');assert.equal(doc.activeElement,f[1]);assert.equal(prevented,1);   // mid-panel: the browser moves on
 f[0].focus();key('Tab',true);assert.equal(doc.activeElement,f[3]);$('rvClose').hidden=true;f[1].focus();key('Tab',true);assert.equal(doc.activeElement,f[3]);$('rvClose').hidden=false;   // a hidden control is skipped
 const pageBody=node('body');pageBody.focus();key('Tab');assert.equal(doc.activeElement,f[0]);pageBody.focus();key('Tab',true);assert.equal(doc.activeElement,f[3]);   // a click on the QR or the note left focus on the page: Tab comes back in
 assert.equal(html.includes('id="walletReceive" class="wallet-receive" role="dialog" aria-modal="true" aria-label="Receive XID" tabindex="-1"'),true);   // a click inside the panel keeps focus in it
 $('rvAmount').value='0,5';js('requestQR()');assert.deepEqual(last(),{action:'walletQR',address:me,amount:'0.5',seq:js('rvSeq')});
 const old=js('rvSeq');$('rvAmount').value='2';js('requestQR()');await receive({type:'walletQR',address:me,seq:old,uri:'xcoin:'+me+'?amount=0.5',png:'data:old',modules:45});assert.equal($('rvImg').src,png);
 let np=posts.length;for(const bad of ['1,234','abc','1.123456789','0','-1','1e3','.']){$('rvAmount').value=bad;js('requestQR()');assert.equal(posts.length,np,bad);assert.equal($('rvImg').hidden,true,bad);assert.equal($('rvQr').hidden,true,bad);assert.equal($('rvNote').classList.contains('err'),true,bad)}
 await receive({type:'walletQR',address:me,seq:old,uri:'xcoin:'+me,png,modules:45});assert.equal($('rvImg').hidden,true);   // a QR for an older amount never comes back
 $('rvAmount').value='';js('requestQR()');assert.equal(posts.length,np+1);await receive({type:'walletQR',address:me,seq:js('rvSeq'),error:'Amount: above 0.'});assert.equal($('rvImg').hidden,true);assert.equal($('rvQr').hidden,true);assert.equal($('rvNote').textContent,'Amount: above 0.');
 await receive({type:'walletQR',address:me,seq:js('rvSeq'),uri:'xcoin:'+me,png,modules:49});assert.equal($('rvQr').hidden,false);assert.equal($('rvImg').style.width,'196px');
 // Escape and CLOSE give focus back to RECEIVE and wake the rows beneath
 node('body').focus();key('Escape');assert.equal($('walletReceive').hidden,true);assert.equal(doc.activeElement,rvb);   // Escape with focus outside the panelassert.deepEqual(beneath.map(i=>$(i).inert),[false,false,false,false]);
 rvb.onclick();$('rvClose').onclick();assert.equal($('walletReceive').hidden,true);assert.equal(doc.activeElement,rvb);assert.deepEqual(beneath.map(i=>$(i).inert),[false,false,false,false]);rvb.onclick();
 $('rvClose').onclick();prevented=0;key('Escape');key('Tab');assert.equal(prevented,0);assert.equal($('walletReceive').hidden,true);rvb.onclick();   // closed: the page's keys are its own again
 $('rvAmount').focus();await receive({type:'wallet',data:walletState});assert.equal($('walletReceive').hidden,true);assert.equal($('walletRxBtn').hidden,true);assert.deepEqual(beneath.map(i=>$(i).inert),[false,false,false,false]);   // locked, or another file: the panel closes
 await receive({type:'wallet',data:{...walletState,walletAddress:me,balances:{}}});await tick();$('walletRxBtn').onclick();$('rvClose').onclick();assert.equal($('walletReceive').hidden,true);
 // another tab (the nav is not inert): RECEIVE closes and wakes the rows beneath; Escape there is the page's own again
 rvb.onclick();assert.equal($('walletReceive').hidden,false);js("selectTab('blocks')");assert.equal($('walletReceive').hidden,true);assert.deepEqual(beneath.map(i=>$(i).inert),[false,false,false,false]);
 prevented=0;key('Escape');assert.equal(prevented,0);js("selectTab('wallet')");assert.equal($('walletReceive').hidden,true);
 console.log('RECEIVE: closed on leaving the WALLET tab, header button beside LOCK, rows beneath inert, Tab and Shift+Tab kept inside (also after a click leaves focus on the page), focus back to RECEIVE on Escape and CLOSE, no empty QR box on an error, QR image at 4 px per module, URI and address COPY, decimal comma, local amount refusals, stale and out-of-date answers dropped, close on lock/file change passed');
 // Backup badge from card-status; MAKE BACKUP CARD; the banner's swap, blank-card tap and write
 const cardWallet=(backup,format='mmm2')=>({...walletState,wallets:[{name:'w4.mmm',file:'/x/w4.mmm',format,card:true,default:true,selected:true}],selected:'/x/w4.mmm',selectedCard:true,backup});
 await receive({type:'wallet',data:cardWallet({card:true,format:'mmm2',count:1,backup_supported:true,note:'',cards:[{uid:'04AA',label:'primary',permanent:true,created:'2026-09-24'}]})});
 assert.equal($('walletBackup').hidden,false);assert.equal($('walletBackup').textContent,'NO BACKUP CARD ⚠');assert.equal($('walletBackupBtn').hidden,false);assert.match($('walletBackup').title,/primary · 04AA · sealed · 2026-09-24/);
 await receive({type:'walletBackup',file:'/x/w4.mmm',data:{card:true,format:'mmm2',count:3,backup_supported:true,cards:[]}});assert.equal($('walletBackup').textContent,'BACKED UP ✓ (3 cards)');
 await receive({type:'walletBackup',file:'/x/other.mmm',data:{card:true,count:1,backup_supported:true}});assert.equal($('walletBackup').textContent,'BACKED UP ✓ (3 cards)');   // another file's late answer
 await receive({type:'wallet',data:cardWallet({card:true,format:'mmm5',backup_supported:false,note:'made with dex-wallet-cli'},'mmm5')});assert.equal($('walletBackup').textContent,'made with dex-wallet-cli');assert.equal($('walletBackup').className,'backup-badge note');assert.equal($('walletBackupBtn').hidden,true);
 const otherMac="This wallet's cards were set up on another Mac, so a backup card can only be made there.";
 await receive({type:'wallet',data:cardWallet({card:true,format:'mmm2',count:0,backup_supported:false,note:otherMac,cards:[]})});assert.equal($('walletBackup').textContent,otherMac);assert.equal($('walletBackup').className,'backup-badge note');assert.equal($('walletBackup').title,otherMac);assert.equal($('walletBackupBtn').hidden,true);assert.doesNotMatch($('walletBackup').textContent,/NO BACKUP CARD/);
 await receive({type:'walletBackup',file:'/x/w4.mmm',data:{card:true,format:'mmm2',count:0,backup_supported:false,note:''}});assert.equal($('walletBackup').textContent,'A backup card cannot be made for this wallet on this Mac.');assert.equal($('walletBackupBtn').hidden,true);   // no libraries, no note: still neutral
 await receive({type:'wallet',data:cardWallet({card:true,format:'mmm5',backup_supported:false},'mmm5')});assert.equal($('walletBackup').textContent,'Backup cards for this wallet are made with dex-wallet-cli.');
 await receive({type:'wallet',data:{...walletState,backup:{}}});assert.equal($('walletBackup').hidden,true);assert.equal($('walletBackupBtn').hidden,true);   // not a card wallet: nothing
 await receive({type:'wallet',data:cardWallet({card:true,format:'mmm2',unknown:true})});assert.equal($('walletBackup').hidden,true);assert.equal($('walletBackupBtn').hidden,true);   // a CLI without card-status: no guess
 await receive({type:'wallet',data:cardWallet({card:true,format:'mmm2',count:0,backup_supported:true})});assert.equal($('walletBackup').textContent,'NO BACKUP CARD ⚠');$('walletBackupBtn').onclick();assert.deepEqual(last(),{action:'walletBackup',file:'/x/w4.mmm'});
 await receive({type:'walletStatus',state:'working',message:'Backup card…'});assert.equal($('walletBackupBtn').disabled,true);
 await receive({type:'cardPrompt',phase:'touchid'});await receive({type:'cardPrompt',phase:'tap',seconds:60});assert.equal($('cardText').textContent,'TAP & HOLD YOUR XCOIN CARD FLAT ON THE READER');
 await receive({type:'cardPrompt',phase:'signing',cardRead:true});await receive({type:'cardPrompt',phase:'swap'});assert.equal($('cardText').textContent,'REMOVE YOUR WALLET CARD — PLACE A NEW BLANK CARD ON THE READER');assert.equal($('cardCancel').disabled,false);assert.equal($('cardCount').textContent,'');
 await receive({type:'cardPrompt',phase:'tap',blank:true,seconds:60});assert.equal($('cardText').textContent,'TAP & HOLD THE NEW BLANK CARD FLAT ON THE READER');assert.equal($('cardCount').textContent,'01:00');
 $('cardCancel').onclick();assert.deepEqual(last(),{action:'walletCancel'});   // CANCEL works until the write starts
 await receive({type:'cardPrompt',phase:'provisioning'});assert.equal($('cardText').textContent,'WRITING YOUR BACKUP CARD — KEEP IT ON THE READER');assert.equal($('cardCancel').disabled,true);assert.equal($('cardCancel').textContent,'WRITING — CANNOT CANCEL');
 n0=posts.length;$('cardCancel').onclick();assert.equal(posts.length,n0);assert.equal($('cardBanner').hidden,false);   // the write is never interrupted
 await receive({type:'walletStatus',state:'working',message:'x'});await receive({type:'error',message:'unrelated'});assert.equal($('cardBanner').dataset.phase,'provisioning');
 await receive({type:'cardPrompt',phase:'provisioning',written:true});assert.match($('cardText').textContent,/^BACKUP CARD WRITTEN ✓/);assert.equal($('cardCancel').disabled,true);
 await receive({type:'cardPrompt',phase:'provisioning',quitting:true});assert.equal($('cardText').textContent,'FINISHING THE BACKUP CARD — MMM WILL QUIT WHEN IT IS DONE');
 await receive({type:'cardPrompt',phase:'tap',blank:true,seconds:60});assert.equal($('cardText').textContent,'TAP & HOLD THE NEW BLANK CARD FLAT ON THE READER');   // a new card wallet: its card is a blank one
 await receive({type:'cardPrompt',phase:'provisioning',new:true});assert.equal($('cardText').textContent,'SETTING UP YOUR NEW CARD — KEEP IT ON THE READER');assert.equal($('cardCancel').disabled,true);assert.equal($('cardCancel').textContent,'WRITING — CANNOT CANCEL');
 await receive({type:'cardPrompt',phase:'provisioning',new:true,written:true});assert.match($('cardText').textContent,/^NEW CARD WRITTEN ✓ — FINISHING/);
 await receive({type:'cardPrompt',phase:'provisioning',new:true,quitting:true});assert.equal($('cardText').textContent,'FINISHING THE NEW CARD — MMM WILL QUIT WHEN IT IS DONE');
 await receive({type:'cardPrompt',phase:'done'});assert.equal($('cardBanner').hidden,true);await receive({type:'walletStatus',state:'ok',message:'Backup card written ✓'});assert.equal($('walletBackupBtn').disabled,false);
 // after a card wallet is created: the prompt with its button, gone once the backup exists
 js("selectTab('create')");await receive({type:'walletCardCreated',name:'w9.mmm',file:'/x/w9.mmm'});assert.equal($('walletBackupPrompt').hidden,false);assert.equal($('bpName').textContent,'w9.mmm');
 $('bpMake').onclick();assert.deepEqual(last(),{action:'walletBackup',file:'/x/w9.mmm'});
 await receive({type:'walletBackupDone',file:'/x/w9.mmm',cards:2,message:'Backup card written ✓ — 2 cards now open w9.mmm.'});assert.equal($('walletBackupPrompt').hidden,true);assert.match($('notice').textContent,/^Backup card written ✓/);
 await receive({type:'walletCardCreated',name:'w9.mmm',file:'/x/w9.mmm'});$('bpLater').onclick();assert.equal($('walletBackupPrompt').hidden,true);
 console.log('Backup: badge wording per format/count, the CLI note in a neutral badge with no button when no backup can be made here, late answers, no guess without card-status, button file, swap/blank-tap/write banner words (backup and new card), CANCEL until the write and never after, post-create prompt passed');
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
 // NUKE closes the new panels
 await receive({type:'walletCardCreated',name:'w9.mmm',file:'/x/w9.mmm'});await receive({type:'nuked'});assert.equal($('walletBackupPrompt').hidden,true);assert.equal($('walletReceive').hidden,true);assert.equal($('schedOffer').hidden,true);
 console.log('Schedule: form from Swift, saved on change, local refusals, hidden fields keep saved values, no clobbering, paused status and title, blocked START offer, MINE ANYWAY, STAY STOPPED, NUKE passed');
})().catch(e=>{console.error(e);process.exit(1)});
