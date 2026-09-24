'use strict';
const $=id=>document.getElementById(id), send=(action,extra={})=>window.webkit?.messageHandlers.native.postMessage({action,...extra});
let profile={}, miner={}, chain={}, running=false, history=[];
let startAfterSave=false;
let blockData=[], minerData=[], blockPage=0, minerPage=0, blockRevision=0, minerRevision=0;
const fmt=(v,d=0)=>typeof v==='number'?v.toLocaleString(undefined,{maximumFractionDigits:d}):'—';
const short=a=>a?`${a.slice(0,11)}…${a.slice(-7)}`:'Unknown recipient';
const age=t=>!t?'—':`${Math.max(0,Math.floor((Date.now()/1000-t)/60))}m`;
function el(tag,text,cls){const e=document.createElement(tag);e.textContent=text??'';if(cls)e.className=cls;return e}
function notice(s){$('notice').textContent=s}
async function person(address,worker){const e=el('span','','person');if(address){const icon=el('span');try{icon.innerHTML=await identiconSvg(address,32)}catch{}e.append(icon)}const d=el('div');if(worker)d.append(el('b',worker));const a=el('a',short(address));a.href='#';a.title=address||'';a.onclick=ev=>{ev.preventDefault();if(address)send('open',{path:'/address/'+encodeURIComponent(address)})};d.append(a);e.append(d);return e}
function render(){
 $('metrics').replaceChildren();for(const [label,value,note] of [['CHAIN HEIGHT',fmt(chain.height),'verified explorer tip'],['NETWORK HASH',chain.hashrate==null?'—':fmt(chain.hashrate/1e6,2)+' M','MH/s · chain estimate'],['ACCEPTED',fmt(miner.accepted),'this mining session'],['REJECTED',fmt(miner.rejected),'this mining session'],['BLOCKS FOUND',fmt(miner.blocks_found),'reported by the pool'],['MEMPOOL',fmt(chain.mempool),'pending transactions']]){const m=el('div','','metric');m.append(el('label',label),el('strong',value),el('small',note));$('metrics').append(m)}
 $('nerd').replaceChildren();for(const [k,v] of [['DAG epoch',miner.dag_epoch==null?'—':fmt(miner.dag_epoch)+(miner.dag_epoch_next_s>0?' · next in '+(miner.dag_epoch_next_s>=86400?fmt(miner.dag_epoch_next_s/86400,1)+' d':fmt(miner.dag_epoch_next_s/3600,1)+' h'):'')],['DAG size',miner.dag_bytes==null?'—':fmt(miner.dag_bytes/2**30,2)+' GiB'],['DAG traffic ≈',miner.dag_traffic_gbs==null?'—':fmt(miner.dag_traffic_gbs,2)+' GB/s'],['Total hashes',fmt(miner.total_hashes)],['Best share',miner.best_share_bits==null?'—':miner.best_share_bits>0?miner.best_share_bits+' bits':'waiting for first share'],['Pool difficulty',fmt(miner.difficulty,8)],['Chain difficulty',fmt(chain.difficulty,8)],['System memory',miner.system_memory_bytes==null?'—':fmt(miner.system_memory_bytes/2**30,0)+' GiB']]){const row=el('div');row.append(el('dt',k),el('dd',v));$('nerd').append(row)}
}
function setRunning(value){running=value;$('start').textContent=value?'STOP MINING ■':'START MINING ↗';for(const e of $('settings').elements)e.disabled=value;$('engineStatus').textContent=value?'■ STARTING / MINING':'■ STOPPED';$('mineTitle').innerHTML=value?'Every hash<br>counts.':'Ready when<br>you are.';if(!value){miner={};$('hashrate').textContent='—';$('uptime').textContent='SESSION —';history=[];$('chartLine').setAttribute('d','');render()}}
window.receive=async msg=>{
 switch(msg.type){
 case 'autoStartPreference':$('autoStart').checked=msg.enabled;break;
 case 'credential':$('settings').elements.password.value=msg.password||'';break;
 case 'setupRequired':selectTab('setup');notice(msg.message);break;
 case 'profile':profile=msg.data;for(const [k,v]of Object.entries(profile))if($('settings').elements[k])$('settings').elements[k].value=v;updateProfile();break;
 case 'reset':chain={};miner={};blockData=[];minerData=[];blockPage=0;minerPage=0;blockRevision++;minerRevision++;$('blockRows').replaceChildren();$('minerRows').replaceChildren();$('minerCount').textContent='— ONLINE';render();break;
 case 'chain':chain=msg.data;$('connection').textContent='■ EXPLORER LIVE';$('lastUpdated').textContent='UPDATED '+new Date().toLocaleTimeString();notice(profile.network==='mainnet'?'Mainnet explorer verified.':'Testnet A is the rehearsal chain. Rewards are test coins.');render();break;
 case 'network':minerData=(msg.data.leaderboard||[]).slice().sort((a,b)=>(b.last||0)-(a.last||0));$('minerCount').textContent=fmt(msg.data.active_miners)+' ONLINE';renderMiners();break;
 case 'blocks':blockData=msg.data;renderBlocks();break;
 case 'miner':miner=msg.data;$('hashrate').textContent=miner.hashrate_pretty||'—';$('gpu').textContent=miner.gpu||'MetalDAG';$('uptime').textContent='SESSION '+fmt(miner.uptime_s)+'s';$('engineStatus').textContent=miner.running?'■ MINING':'■ INITIALIZING';history.push(miner.hashrate_hps||0);history=history.slice(-150);const max=Math.max(...history,1);$('chartLine').setAttribute('d',history.map((h,i)=>`${i?'L':'M'}${i*800/149},${85-h/max*75}`).join(' '));render();break;
 case 'started':setRunning(true);notice('Starting MetalDAG engine. The initial DAG build can take a few minutes.');break;
 case 'stopped':setRunning(false);notice(msg.code===0||msg.code===15?'Mining stopped.':'Engine exited ('+msg.code+'). Check the engine log.');break;
 case 'error':notice(msg.message);break;
 case 'offline':blockData=[];minerData=[];blockRevision++;minerRevision++;chain={};render();$('connection').textContent='○ EXPLORER OFFLINE';$('blockRows').innerHTML='<tr><td colspan="4" class="empty">Explorer unavailable. Retrying every 5 seconds.</td></tr>';$('minerRows').innerHTML='<tr><td colspan="5" class="empty">Miner registry unavailable.</td></tr>';$('minerCount').textContent='— ONLINE';notice(msg.message);break;
 case 'networkError':minerData=[];minerRevision++;$('minerCount').textContent='REGISTRY UNAVAILABLE';$('minerRows').replaceChildren();break;
 case 'log':logText=(logText+'\n'+msg.message.replace(/\x1b\[[0-9;?]*[A-Za-z]/g,'')).slice(-18000);renderLog();break;
 case 'loginStatus':$('loginState').textContent=msg.state==='running'?'SIGNING IN…':msg.state==='ok'?'✓ SIGNED IN — CHECK YOUR BROWSER':msg.state==='idle'?'NOT SIGNED IN':'✗ FAILED — SEE ENGINE LOG';$('loginBtn').disabled=msg.state==='running';if(msg.message)notice(msg.message);break;
 case 'forumCred':forumSaved=!!msg.saved;renderForum();break;
 case 'wallet':wallet=msg.data;renderWallet();break;
 case 'walletStatus':$('walletState').textContent=msg.state==='working'?'WORKING…':msg.state==='ok'?'✓ UNLOCKED':'✗ FAILED';if(msg.state==='fail')notice(msg.message||'Wallet action failed.');$('walletUnlockBtn').disabled=$('walletSendBtn').disabled=msg.state==='working';break;
 case 'walletSent':{$('walletUnlockBtn').disabled=$('walletSendBtn').disabled=false;const r=$('walletReceipt');r.hidden=false;const a=el('a',msg.txid.slice(0,20)+'…');a.href='#';a.onclick=e=>{e.preventDefault();send('open',{path:'/tx/'+msg.txid})};r.replaceChildren(el('b','SENT ✓ '),a,el('span',' · fee '+msg.fee+' XCF · '+msg.vsize+' vB'));$('walletSendForm').reset();notice('Sent. The explorer shows it once the next block confirms it.');break}
 }
};
async function updateProfile(){$('networkLabel').textContent=profile.network==='mainnet'?'MAINNET / GENESIS VERIFIED BEFORE START':'TESTNET A / REHEARSAL';$('actionNote').textContent=profile.network==='mainnet'?'Uses the selected mainnet pool and genesis.':'Testnet rewards are rehearsal coins.';$('payout').replaceChildren(profile.address?await person(profile.address):el('span','Set your payout address below.'))}
$('settings').onsubmit=e=>{e.preventDefault();profile=Object.fromEntries(new FormData(e.target));for(const k in profile)if(k!=='password')profile[k]=profile[k].trim();profile.explorer=profile.explorer.replace(/\/$/,'');const password=profile.password;delete profile.password;send('save',{profile,password,startAfterSave});startAfterSave=false;updateProfile();notice('Setup saved. Checking explorer network…')};
$('settings').elements.network.onchange=()=>{const f=$('settings').elements;f.address.value='';f.address.placeholder=f.network.value==='mainnet'?'xpa1r…':'txa1r…';f.host.value='';f.port.value='';f.worker.value='';f.password.value='';f.explorer.value=f.network.value==='testnet'?'https://superknet.com':''};
$('start').onclick=()=>{if(running){send('stop');return}if(!$('settings').checkValidity()){selectTab('setup');$('settings').reportValidity();return}startAfterSave=true;$('settings').requestSubmit()};$('refresh').onclick=()=>send('refresh');render();
// Decode the node's witness-v3 script when RPC omits its address string.
function decodeScript(hex,hrp){if(!/^5320[0-9a-f]{64}$/i.test(hex||''))return '';let acc=0,bits=0,data=[3];for(const byte of hex.slice(4).match(/../g)){acc=(acc<<8)|parseInt(byte,16);bits+=8;while(bits>=5){bits-=5;data.push((acc>>>bits)&31)}}if(bits)data.push((acc<<(5-bits))&31);const expanded=[...hrp].map(c=>c.charCodeAt(0)>>5).concat([0],[...hrp].map(c=>c.charCodeAt(0)&31));let chk=1;for(const v of [...expanded,...data,0,0,0,0,0,0]){const top=chk>>>25;chk=((chk&0x1ffffff)<<5)^v;[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3].forEach((g,i)=>{if((top>>i)&1)chk^=g})}chk^=0x2bc830a3;for(let i=0;i<6;i++)data.push((chk>>>(5*(5-i)))&31);return hrp+'1'+data.map(v=>'qpzry9x8gf2tvdw0s3jn54khce6mua7l'[v]).join('')}

// Tabs do not navigate away from the local app or scroll the document.
function selectTab(name){
 if(!tabNames.includes(name))name='dashboard';
 for(const key of tabNames){const active=key===name;$('view-'+key).hidden=!active;$('view-'+key).classList.toggle('active',active);$('tab-'+key).classList.toggle('selected',active);$('tab-'+key).setAttribute('aria-selected',String(active));$('tab-'+key).tabIndex=active?0:-1}
 if(name==='blocks')renderBlocks();if(name==='miners')renderMiners();if(name==='setup')renderLog();if(name==='wallet')send('walletRefresh');
}
const tabNames=['dashboard','blocks','miners','wallet','setup'];
for(const name of tabNames){const tab=$('tab-'+name);tab.onclick=e=>{e.preventDefault();selectTab(name)};tab.onkeydown=e=>{const n=tabNames.length;let i=tabNames.indexOf(name);if(e.key==='ArrowRight')i=(i+1)%n;else if(e.key==='ArrowLeft')i=(i+n-1)%n;else if(e.key==='Home')i=0;else if(e.key==='End')i=n-1;else return;e.preventDefault();selectTab(tabNames[i]);$('tab-'+tabNames[i]).focus()}}
function pageInfo(kind,total){const wrap=$(kind).querySelector('.table-wrap');const style=getComputedStyle($(kind).querySelector('table'));const rowHeight=parseFloat(style.getPropertyValue('--table-row-height'))||72;const headHeight=parseFloat(style.getPropertyValue('--table-head-height'))||42;const count=Math.max(1,Math.floor((wrap.clientHeight-headHeight)/rowHeight));const pages=Math.max(1,Math.ceil(total/count));let page=kind==='blocks'?blockPage:minerPage;page=Math.min(page,pages-1);if(kind==='blocks')blockPage=page;else minerPage=page;$(kind+'Page').textContent=`${page+1} / ${pages} · ${total} ${kind==='blocks'?'recent blocks':'miners'}`;$(kind+'Prev').disabled=page===0;$(kind+'Next').disabled=page>=pages-1;return {start:page*count,count}}
async function renderBlocks(){if($('view-blocks').hidden)return;const revision=++blockRevision;const {start,count}=pageInfo('blocks',blockData.length);const rows=await Promise.all(blockData.slice(start,start+count).map(async b=>{const tr=el('tr'),height=el('td'),a=el('a','#'+fmt(b.height));a.href='#';a.onclick=e=>{e.preventDefault();send('open',{path:'/block/'+b.height})};height.append(a);const payouts=(b.tx?.[0]?.vout||[]).filter(o=>o.value>0);const who=el('td');if(payouts.length){const sp=payouts[0].scriptPubKey||{};who.append(await person(sp.address||sp.addresses?.[0]||decodeScript(sp.hex,profile.network==='mainnet'?'xpa':'txa'),payouts.length>1?`+ ${payouts.length-1} other payout outputs`:''))}else who.textContent='No spendable payout';tr.append(height,who,el('td',fmt(payouts.reduce((n,o)=>n+o.value,0),8)+' XCF'),el('td',age(b.time)));return tr}));if(revision!==blockRevision)return;$('blockRows').replaceChildren(...rows);if(!rows.length)$('blockRows').innerHTML='<tr><td colspan="4" class="empty">No verified blocks available.</td></tr>'}
async function renderMiners(){if($('view-miners').hidden)return;const revision=++minerRevision;const {start,count}=pageInfo('miners',minerData.length);const rows=await Promise.all(minerData.slice(start,start+count).map(async r=>{const tr=el('tr'),td=el('td');td.append(await person(r.address,r.worker||'unnamed'));const on=Number(r.last)>Date.now()/1000-300,status=el('td');status.append(el('span',on?'ONLINE':'SEEN '+age(r.last)+' AGO',on?'online':'offline'));tr.append(td,status,el('td',fmt(r.hashrate_mhs,2)+' MH/s'),el('td',fmt(r.shares)),el('td',fmt(r.blocks)));return tr}));if(revision!==minerRevision)return;$('minerRows').replaceChildren(...rows);if(!rows.length)$('minerRows').innerHTML='<tr><td colspan="5" class="empty">No miners reported by this pool.</td></tr>'}
$('blocksPrev').onclick=()=>{blockPage=Math.max(0,blockPage-1);renderBlocks()};$('blocksNext').onclick=()=>{blockPage++;renderBlocks()};$('minersPrev').onclick=()=>{minerPage=Math.max(0,minerPage-1);renderMiners()};$('minersNext').onclick=()=>{minerPage++;renderMiners()};
let logText='No mining session started.';
function renderLog(){const lines=Math.max(1,Math.floor(($('log').clientHeight-16)/(parseFloat(getComputedStyle($('log')).lineHeight)||18)));$('log').textContent=logText.split('\n').filter(Boolean).slice(-lines).join('\n')}
$('copyLog').onclick=()=>send('copy',{text:logText});$('minimize').onclick=()=>send('minimize');
let resizeTick;window.addEventListener('resize',()=>{clearTimeout(resizeTick);resizeTick=setTimeout(()=>{renderBlocks();renderMiners();renderLog()},80)});
function applyTheme(dark){document.documentElement.dataset.theme=dark?'dark':'light';$('themeToggle').setAttribute('aria-checked',String(dark));$('themeLabel').textContent=dark?'DARK':'LIGHT';try{localStorage.setItem('mmm-theme',dark?'dark':'light')}catch{}}
let initialTheme;try{initialTheme=localStorage.getItem('mmm-theme')}catch{}applyTheme(initialTheme?initialTheme==='dark':window.matchMedia('(prefers-color-scheme: dark)').matches);
$('themeToggle').onclick=()=>applyTheme(document.documentElement.dataset.theme!=='dark');selectTab('dashboard');

$('autoStart').onchange=()=>send('autoStartPreference',{enabled:$('autoStart').checked});
let forumSaved=false;
function renderForum(){$('passLabel').hidden=forumSaved;$('rememberLabel').hidden=forumSaved;$('forgetBtn').hidden=!forumSaved;$('loginBtn').textContent=forumSaved?'SIGN IN WITH TOUCH ID ↗':'SIGN IN TO MINEDIFFERENT ↗'}
$('loginForm').onsubmit=e=>{e.preventDefault();if(forumSaved){send('loginTouch');return}const f=new FormData(e.target);send('login',{passphrase:String(f.get('passphrase')||''),remember:f.get('remember')==='on'});e.target.reset()};
$('forgetBtn').onclick=()=>send('loginForget');
renderForum();

// ── WALLET tab: balances from the explorer, sends via the offline keytool ────
let wallet={},walletRevision=0;
const xcfFmt=sats=>(sats/1e8).toLocaleString(undefined,{maximumFractionDigits:8});
async function renderWallet(){
 const revision=++walletRevision;
 const box=$('walletBalances');box.replaceChildren();
 const unlocked=!!wallet.walletAddress;
 $('walletState').textContent=wallet.cliFound===false?'✗ WALLET CLI NOT FOUND':unlocked?'✓ UNLOCKED':'LOCKED';
 $('walletUnlockForm').hidden=unlocked||wallet.cliFound===false;
 $('walletSendForm').hidden=!unlocked||wallet.cliFound===false;
 if(wallet.cliFound===false){box.append(el('p','Install the wallet CLI (github.com/SystemThreat/xcoin-wallet) to ~/x-Coin/wallet-cli, then reopen this tab.','empty'));return}
 $('walletSendForm').elements.dest.placeholder=(profile.network==='mainnet'?'xpa1r…':'txa1r…');
 const rows=[];
 if(wallet.walletAddress)rows.push(['THIS MAC\u2019S WALLET (SENDS FROM HERE)',wallet.walletAddress]);
 if(wallet.payout&&wallet.payout!==wallet.walletAddress)rows.push(['MINING PAYOUT ADDRESS',wallet.payout]);
 if(!rows.length){box.append(el('p','Unlock to derive this Mac\u2019s wallet address; set a payout address in SETUP to watch it here.','empty'));return}
 for(const [label,addr] of rows){
  const row=el('div','','wallet-row');const b=(wallet.balances||{})[addr];
  row.append(el('label',label));row.append(await person(addr));
  row.append(el('strong',b?xcfFmt(b.spendable_sats)+' XCF':'—'));
  row.append(el('small',b?(b.immature_sats>0?'+ '+xcfFmt(b.immature_sats)+' maturing':'spendable'):'explorer unavailable'));
  if(revision!==walletRevision)return;
  box.append(row);
 }
 if(wallet.payout&&wallet.walletAddress&&wallet.payout!==wallet.walletAddress)box.append(el('p','Your payout address is not this wallet\u2019s key 0 — sends draw from the wallet balance above. Point mining at the wallet address to make them one.','wallet-note'));
}
$('walletUnlockForm').onsubmit=e=>{e.preventDefault();const f=new FormData(e.target);send('walletUnlock',{passphrase:String(f.get('passphrase')||''),remember:f.get('remember')==='on'});e.target.reset()};
$('walletSendForm').onsubmit=e=>{e.preventDefault();const f=new FormData(e.target);$('walletReceipt').hidden=true;send('walletSend',{dest:String(f.get('dest')||'').trim(),amount:String(f.get('amount')||'').trim()})};
