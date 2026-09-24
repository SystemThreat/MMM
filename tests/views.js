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
})().catch(e=>{console.error(e);process.exit(1)});
