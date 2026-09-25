// Exercise the actual tab/pagination/theme functions without a browser or GPU.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../app.js'),'utf8');
function func(name){const start=source.indexOf('function '+name+'(');let level=0,begin=source.indexOf('{',start);for(let i=begin;i<source.length;i++){if(source[i]==='{')level++;if(source[i]==='}'&&--level===0)return source.slice(start,i+1)}throw Error(name)}
const elements={};function get(id){return elements[id]??=( {hidden:false,attrs:{},classList:{toggle(){}},setAttribute(k,v){this.attrs[k]=v},querySelector(){return {clientHeight:300}}})}
let renders=0,stored;const sent=[];const context=vm.createContext({$:get,send(a){sent.push(a)},blockPage:99,minerPage:0,renderBlocks(){renders++},renderMiners(){renders++},renderLog(){renders++},document:{documentElement:{dataset:{}}},getComputedStyle(){return {getPropertyValue(key){return key==='--table-row-height'?'72px':'42px'}}},localStorage:{setItem(k,v){stored=v}}});
vm.runInContext(source.match(/const tabNames=\[[^\]]*\];/)[0],context);  // the real tab list, so the test cannot drift from it
for(const name of ['selectTab','pageInfo','applyTheme'])vm.runInContext(func(name),context);
context.selectTab('miners');assert.equal(get('view-miners').hidden,false);assert.equal(get('view-dashboard').hidden,true);assert.equal(get('tab-miners').attrs['aria-selected'],'true');assert.equal(get('tab-dashboard').tabIndex,-1);
context.selectTab('setup');assert.equal(get('view-miners').hidden,true);assert.equal(get('view-setup').hidden,false);
context.selectTab('invalid');assert.equal(get('view-dashboard').hidden,false);
assert.deepEqual(sent,[]);context.selectTab('wallet');context.selectTab('create');assert.deepEqual(sent,['walletRefresh','walletRefresh']);
let p=context.pageInfo('blocks',8);assert.equal(p.count,3);assert.equal(p.start,6);assert.equal(get('blocksNext').disabled,true);assert.equal(get('blocksPrev').disabled,false);
p=context.pageInfo('miners',0);assert.equal(p.start,0);assert.equal(get('minersPrev').disabled,true);assert.equal(get('minersNext').disabled,true);
get('blocks').querySelector=()=>({clientHeight:50});p=context.pageInfo('blocks',8);assert.equal(p.count,1);
context.applyTheme(true);assert.equal(stored,'dark');assert.equal(get('themeToggle').attrs['aria-checked'],'true');context.applyTheme(false);assert.equal(stored,'light');assert.equal(get('themeLabel').textContent,'LIGHT');
console.log('Tab selection, hidden panels, pagination bounds, short windows, and theme persistence passed');

// Whole page: load the real app.js against a stub DOM and replay Swift's messages.
function node(tag){const kids=[],fields={},cls=new Set();const e={tag,hidden:false,disabled:false,value:'',checked:false,title:'',textContent:'',innerHTML:'',className:'',attrs:{},dataset:{},style:{},children:kids,clientHeight:300,fields,
 classList:{add(c){cls.add(c)},remove(c){cls.delete(c)},toggle(c,on){(on??!cls.has(c))?cls.add(c):cls.delete(c)},contains(c){return cls.has(c)}},
 setAttribute(k,v){this.attrs[k]=String(v)},getAttribute(k){return this.attrs[k]??null},append(...c){kids.push(...c)},replaceChildren(...c){kids.splice(0,kids.length,...c)},querySelector(){return node('q')},focus(){},
 reset(){for(const f of Object.values(fields))f.value=''},checkValidity(){return true},reportValidity(){},requestSubmit(){this.onsubmit?.({preventDefault(){},target:this})}};
 e.elements=new Proxy(fields,{get:(t,k)=>k===Symbol.iterator?function*(){yield*Object.values(t)}:typeof k==='string'?(t[k]??=node('input')):undefined});return e}
const dom={},$=id=>dom[id]??=node(id),posts=[];let marks=0;
class FormData{constructor(f){this.f=f}get(k){const i=this.f.fields[k];return !i?null:i.type==='checkbox'?(i.checked?'on':null):i.value}*[Symbol.iterator](){for(const k of Object.keys(this.f.fields))yield [k,this.get(k)]}}
const page=vm.createContext({document:{getElementById:$,createElement:node,documentElement:node('html')},localStorage:{getItem(){return null},setItem(){}},matchMedia:()=>({matches:false}),addEventListener(){},getComputedStyle:()=>({getPropertyValue:()=>'',lineHeight:'18px'}),setTimeout,clearTimeout,FormData,
 identiconSvg:async a=>{marks++;return '<svg>'+a+'</svg>'},webkit:{messageHandlers:{native:{postMessage:m=>posts.push(JSON.parse(JSON.stringify(m)))}}}});
page.window=page;vm.runInContext(source,page);
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
 await receive({type:'walletSeed',name:'wallet005.mmm',seed:'abandon'});assert.equal($('createState').textContent,'✓ DONE');assert.equal($('walletSeedBox').hidden,false);await receive({type:'walletStatus',state:'ok',message:'Wallet unlocked.'});
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
 await receive({type:'minerPending',message:'Waiting for mining engine statistics…'});assert.equal($('hashrate').textContent,'—');assert.equal($('engineStatus').textContent,'■ WAITING FOR ENGINE');
 await receive({type:'log',message:'[-] Failed to connect to pool!\nerror: pool 127.0.0.1:3335 unreachable\n'});await receive({type:'stopped',code:1});await receive({type:'chain',data:{}});
 assert.equal($('notice').textContent,'Engine exited (1): pool 127.0.0.1:3335 unreachable');assert.equal($('mineTitle').innerHTML,'Ready when <br>you are.');
 await receive({type:'started'});await receive({type:'stopped',code:6});assert.equal($('notice').textContent,'Engine exited (6). Check the engine log.');
 // Identicons are drawn once per address, however often the rows re-render.
 const before=marks;await js("person('txa1rsame')");await js("person('txa1rsame')");assert.equal(marks-before,1);
 console.log('Wallet key index kept per file, sticky notices, create status, amount comma, setup save echo, pool reconnect, minerPending, engine exit reason, and identicon memo passed');
 // Card banner: the ticker says each phase, the tap counts down, CANCEL asks Swift, CLOSE only hides.
 const text=n=>(n.textContent||'')+n.children.map(text).join(''),banner=$('cardBanner'),count=$('cardCount'),D=vm.runInContext('Date',page),realNow=D.now,clock={t:1e12};D.now=()=>clock.t;banner.hidden=true;
 await receive({type:'cardPrompt',phase:'touchid'});assert.equal(banner.hidden,false);assert.equal($('cardText').textContent,'AUTHORIZE WITH TOUCH ID');assert.equal(count.textContent,'');
 const strips=$('cardTrack').children;assert.equal(strips.length,2);assert.equal(text(strips[0]),text(strips[1]));assert.match(text(strips[0]),/^(AUTHORIZE WITH TOUCH ID◆){5,}$/);
 await receive({type:'cardPrompt',phase:'tap',seconds:60});assert.equal($('cardText').textContent,'TAP & HOLD YOUR XCOIN CARD FLAT ON THE READER');assert.equal(banner.dataset.phase,'tap');assert.equal(count.textContent,'01:00');
 clock.t+=13000;js('cardTick()');assert.equal(count.textContent,'00:47');
 clock.t+=47000;js('cardTick()');assert.equal(count.textContent,'TIME UP — TAP OR CANCEL');assert.equal(count.classList.contains('up'),true);assert.equal(banner.classList.contains('up'),true);
 await receive({type:'cardPrompt',phase:'tap',seconds:45});assert.equal(count.textContent,'45');assert.equal(count.classList.contains('up'),false);clock.t+=44500;js('cardTick()');assert.equal(count.textContent,'01');
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
 assert.notEqual($('cardText').textContent,'CANCELLED');
 // LOCK sits next to UNLOCKED, asks Swift to forget the address, and the unlock form comes back.
 await receive({type:'wallet',data:{...walletState,walletAddress:'txa1rme',balances:{}}});assert.equal($('walletState').textContent,'✓ UNLOCKED');assert.equal($('walletLockBtn').hidden,false);assert.equal($('walletUnlockForm').hidden,true);
 $('walletLockBtn').onclick();assert.deepEqual(last(),{action:'walletLock'});await receive({type:'walletLocked'});assert.match($('notice').textContent,/UNLOCK again/);
 await receive({type:'wallet',data:walletState});assert.equal($('walletLockBtn').hidden,true);assert.equal($('walletUnlockForm').hidden,false);assert.equal($('walletState').textContent,'LOCKED');
 await receive({type:'walletStatus',state:'working',message:'Signing…'});assert.equal($('walletLockBtn').disabled,true);
 // Receipt: every txid with a link and COPY; "N transactions" when split; a partial send says what did not go out.
 const tx=k=>String(k).repeat(64),rc=$('walletReceipt'),part=c=>rc.children.find(k=>k.className===c);
 await receive({type:'walletSent',txid:tx(1),txids:[tx(1),tx(2),tx(3),tx(4)],transactions:4,partial:false,amount:'1500.00000000',fee:'0.00400000',vsize:4000});
 assert.equal($('walletLockBtn').disabled,false);assert.equal(rc.hidden,false);assert.equal(text(rc.children[0].children[0]),'SENT ✓ 4 TRANSACTIONS');assert.match(text(rc.children[0]),/1500\.00000000 XCF · fee 0\.00400000 XCF · 4000 vB/);
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
 await receive({type:'walletSent',txid:tx(7),fee:'0.0001',vsize:200});assert.equal(part('wr-unsure'),undefined);assert.equal(text(rc.children[0].children[0]),'SENT ✓');assert.equal(part('wr-list').children.length,1);assert.equal(part('wr-miss'),undefined);assert.equal(rc.classList.contains('partial'),false);
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
 console.log('Card banner phases, card words, quitting words, ticker strips, countdown and time-up, cancel/close wiring, broadcast lock, terminal-only banner close, unrelated errors, idle cancel, lock, multi-txid, partial and uncertain-txid receipts, SENT/NOT BROADCAST labels, receipt explorer links, re-shown receipts on the WALLET tab, interrupted send, and whole error notices passed');
})().catch(e=>{console.error(e);process.exit(1)});
