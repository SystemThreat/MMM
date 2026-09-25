'use strict';
const $=id=>document.getElementById(id), send=(action,extra={})=>{if(!['walletRefresh','copy','open','forumRefresh','walletQR'].includes(action))noticeSticky=false;window.webkit?.messageHandlers.native.postMessage({action,...extra})};
let profile={}, miner={}, chain={}, running=false, history=[], noticeSticky=false, pendingProfile=null, poolNote='', engineError='';
let startAfterSave=false;
let sched={data:{},paused:false,reason:'',hold:'',override:false},schedShown='',forum={},rvSeq=0,rvAddress='',bpFile='';
let blockData=[], minerData=[], blockPage=0, minerPage=0, blockRevision=0, minerRevision=0;
const fmt=(v,d=0)=>typeof v==='number'?v.toLocaleString('en-US',{maximumFractionDigits:d}):'—';
const short=a=>a?`${a.slice(0,11)}…${a.slice(-7)}`:'Unknown recipient';
const age=t=>!t?'—':`${Math.max(0,Math.floor((Date.now()/1000-t)/60))}m`;
const sentence=t=>String(t).charAt(0).toUpperCase()+String(t).slice(1);
function el(tag,text,cls){const e=document.createElement(tag);e.textContent=text??'';if(cls)e.className=cls;return e}
function notice(s,sticky){if(noticeSticky&&!sticky)return;$('notice').textContent=s;noticeSticky=!!sticky}
const marks=new Map();function mark(a){let p=marks.get(a);if(!p){p=identiconSvg(a,32).catch(()=>'');marks.set(a,p);if(marks.size>500)marks.delete(marks.keys().next().value)}return p}
async function person(address,worker){const e=el('span','','person');if(address){const icon=el('span');try{icon.innerHTML=await mark(address)}catch{}e.append(icon)}const d=el('div');if(worker){const w=el('b',worker);w.title=worker;d.append(w)}const a=el('a',short(address));a.href='#';a.title=address||'';a.onclick=ev=>{ev.preventDefault();if(address)send('open',{path:'/address/'+encodeURIComponent(address)})};const line=el('span','','addr-line');line.append(a);d.append(line);if(address)line.append(copyBtn(address,'Copy the full address'));e.append(d);return e}
function linkLine(text,full,path,origin,what){const line=el('span','','addr-line'),a=el('a',text);a.href='#';a.title=full;a.onclick=e=>{e.preventDefault();send('open',origin?{path,origin}:{path})};line.append(a,copyBtn(full,'Copy the full '+what));return line}
function txLine(id,origin){return linkLine(id.slice(0,16)+'…'+id.slice(-6),id,'/tx/'+id,origin,'txid')}
function copyBtn(text,title){const c=el('button','⧉ COPY','copy-btn');c.type='button';c.title=title;c.onclick=ev=>{ev.preventDefault();ev.stopPropagation();send('copy',{text});c.textContent='✓ COPIED';c.classList.add('done');clearTimeout(c._t);c._t=setTimeout(()=>{c.textContent='⧉ COPY';c.classList.remove('done')},1400)};return c}
// the receipt grows to fit; when the window is too short it scrolls and says so
function showReceipt(kind,...parts){const r=$('walletReceipt');r.hidden=false;r.scrollTop=0;r.classList.toggle('partial',!!kind);r.classList.toggle('refused',kind==='refused');r.replaceChildren(...parts);setTimeout(receiptFit)}
function receiptFit(){const r=$('walletReceipt');r.classList.toggle('more',!r.hidden&&r.scrollHeight-r.scrollTop>r.clientHeight+2)}
// a hash rate in the unit that keeps it short: M up to 999.99, then G, T, P
const hashUnit=h=>h>=1e15?[1e15,'P']:h>=1e12?[1e12,'T']:h>=1e9?[1e9,'G']:[1e6,'M'];
function render(){
 const [hd,hu]=hashUnit(chain.hashrate||0);
 $('metrics').replaceChildren();for(const [label,value,note] of [['CHAIN HEIGHT',fmt(chain.height),'verified explorer tip'],['NETWORK HASH',chain.hashrate==null?'—':fmt(chain.hashrate/hd,2)+' '+hu,hu+'H/s · chain estimate'],['ACCEPTED',fmt(miner.accepted),'this mining session'],['REJECTED',fmt(miner.rejected),'this mining session'],['BLOCKS FOUND',fmt(miner.blocks_found),'reported by the pool'],['MEMPOOL',fmt(chain.mempool),'pending transactions']]){const m=el('div','','metric'),v=el('strong',value),n=el('small',note);v.title=value;n.title=note;m.append(el('label',label),v,n);$('metrics').append(m)}fitMetrics();
 $('nerd').replaceChildren();for(const [k,v] of [['DAG epoch',miner.dag_epoch==null?'—':fmt(miner.dag_epoch)+(miner.dag_epoch_next_s>0?' · next in '+(miner.dag_epoch_next_s>=86400?fmt(miner.dag_epoch_next_s/86400,1)+' d':fmt(miner.dag_epoch_next_s/3600,1)+' h'):'')],['DAG size',miner.dag_bytes==null?'—':fmt(miner.dag_bytes/2**30,2)+' GiB'],['DAG traffic ≈',miner.dag_traffic_gbs==null?'—':fmt(miner.dag_traffic_gbs,2)+' GB/s'],['Total hashes',fmt(miner.total_hashes)],['Best share',miner.best_share_bits==null?'—':miner.best_share_bits>0?miner.best_share_bits+' bits':'waiting for first share'],['Pool difficulty',fmt(miner.difficulty,8)],['Chain difficulty',fmt(chain.difficulty,8)],['System memory',miner.system_memory_bytes==null?'—':fmt(miner.system_memory_bytes/2**30,0)+' GiB']]){const row=el('div');row.append(el('dt',k),el('dd',v));$('nerd').append(row)}
}
// metric values (and their notes) too wide for their columns shrink to fit instead of being cut off: "1,234,5…" reads as
// another number. One size per row, the widest one's (down to 60%, never below 9 px). Measured only while the dashboard
// shows: its tab and resizes run it again.
function fitMetrics(){for(const sel of ['strong','small']){const els=[...$('metrics').querySelectorAll(sel)];for(const e of els)e.style.fontSize='';if(!els.length||!els[0].clientWidth)continue;
 const k=Math.min(...els.map(e=>e.clientWidth/Math.max(1,e.scrollWidth)));if(k>=1)continue;
 const f=parseFloat(getComputedStyle(els[0]).fontSize),min=Math.max(9,Math.round(f*6)/10);let s=Math.max(min,Math.floor(f*k*2)/2);const size=()=>{for(const e of els)e.style.fontSize=s+'px'};size();
 while(s>min&&els.some(e=>e.scrollWidth>e.clientWidth)){s=Math.max(min,s-.5);size()}}}
function setRunning(value){running=value;$('start').textContent=value?'STOP MINING ■':'START MINING ↗';for(const e of $('settings').elements)e.disabled=value;$('engineStatus').textContent=value?'■ STARTING / MINING':engineIdle();$('mineTitle').innerHTML=value?'Every hash <br>counts.':'Ready when <br>you are.';showActionNote();if(value)hideOffer();if(!value){miner={};poolNote='';$('engineStatus').title=sched.paused?sched.reason:'';$('hashrate').textContent='—';$('uptime').textContent='SESSION —';history=[];$('chartLine').setAttribute('d','');render()}}
window.receive=async msg=>{
 switch(msg.type){
 case 'autoStartPreference':$('autoStart').checked=msg.enabled;break;
 case 'credential':$('settings').elements.password.value=msg.password||'';break;
 case 'setupRequired':pendingProfile=null;selectTab('setup');notice(msg.message,true);break;
 case 'profile':if(pendingProfile)notice('Setup saved. Checking explorer network…');pendingProfile=null;profile=msg.data;for(const [k,v]of Object.entries(profile))if($('settings').elements[k])$('settings').elements[k].value=v;updateProfile();break;
 case 'reset':chain={};miner={};blockData=[];minerData=[];blockPage=0;minerPage=0;blockRevision++;minerRevision++;$('blockRows').replaceChildren();$('minerRows').replaceChildren();$('minerCount').textContent='— ONLINE';render();if(pendingProfile){profile={...profile,...pendingProfile};pendingProfile=null;updateProfile();notice('Setup saved. Checking explorer network…')}break;
 case 'chain':chain=msg.data;$('connection').textContent='■ EXPLORER LIVE';$('lastUpdated').textContent='UPDATED '+new Date().toLocaleTimeString();notice(profile.network==='mainnet'?'Mainnet explorer verified.':'Testnet A is the rehearsal chain. Rewards are test coins.');render();break;
 case 'network':minerData=(msg.data.leaderboard||[]).slice().sort((a,b)=>(b.last||0)-(a.last||0));$('minerCount').textContent=fmt(msg.data.active_miners)+' ONLINE';renderMiners();break;
 case 'blocks':blockData=msg.data;renderBlocks();break;
 case 'miner':{miner=msg.data;const down=miner.pool_connected===false,st=down?String(miner.pool_status||'reconnecting').replace(/\.$/,''):'';$('hashrate').textContent=down?'—':miner.hashrate_pretty||'—';$('gpu').textContent=miner.gpu||'MetalDAG';$('uptime').textContent='SESSION '+fmt(miner.uptime_s)+'s';$('engineStatus').textContent=down?'■ RECONNECTING':miner.running?'■ MINING':'■ INITIALIZING';$('engineStatus').title=st;if(st!==poolNote){notice(st?'Pool connection lost — '+st+'. Hashing is paused until the pool answers.':'Pool connection restored. Mining resumed.');poolNote=st}history.push(down?0:miner.hashrate_hps||0);history=history.slice(-150);const max=Math.max(...history,1);$('chartLine').setAttribute('d',history.map((h,i)=>`${i?'L':'M'}${i*800/149},${85-h/max*75}`).join(' '));render();break}
 case 'minerPending':if(running&&miner.running){$('hashrate').textContent='—';$('engineStatus').textContent='■ WAITING FOR ENGINE';$('engineStatus').title=msg.message||''}break;
 case 'started':engineError='';setRunning(true);notice('Starting MetalDAG engine. The initial DAG build can take a few minutes.');break;
 case 'stopped':setRunning(false);if(msg.code===0||msg.code===15)notice('Mining stopped.');else notice('Engine exited ('+msg.code+(engineError?'): '+engineError:'). Check the engine log.'),true);break;
 case 'error':notice(msg.message,true);break;
 case 'offline':blockData=[];minerData=[];blockRevision++;minerRevision++;chain={};render();$('connection').textContent='○ EXPLORER OFFLINE';$('blockRows').innerHTML='<tr><td colspan="4" class="empty">Explorer unavailable. Retrying every 5 seconds.</td></tr>';$('minerRows').innerHTML='<tr><td colspan="5" class="empty">Miner registry unavailable.</td></tr>';$('minerCount').textContent='— ONLINE';notice(msg.message);break;
 case 'networkError':{minerData=[];minerRevision++;$('minerCount').textContent='REGISTRY UNAVAILABLE';const td=el('td',(msg.message||'Miner registry unavailable')+'.','empty');td.colSpan=5;const tr=el('tr');tr.append(td);$('minerRows').replaceChildren(tr);break}
 case 'log':{const t=msg.message.replace(/\x1b\[[0-9;?]*[A-Za-z]/g,'');if(running&&msg.source!=='login')for(const m of t.matchAll(/(?:^|\r)error: ([^\r\n]+)/gm))engineError=m[1].trim().slice(0,300);logText=(logText+'\n'+t).slice(-18000);renderLog();break}
 case 'loginStatus':$('loginState').textContent=msg.state==='running'?'SIGNING IN…':msg.state==='ok'?'✓ SIGNED IN — CHECK YOUR BROWSER':msg.state==='idle'?'NOT SIGNED IN':'✗ FAILED — SEE ENGINE LOG';$('loginBtn').disabled=msg.state==='running';if(msg.message)notice(msg.message,msg.state==='fail');break;
 case 'forumCred':forumSaved=!!msg.saved;renderForum();break;
 case 'wallet':wallet=msg.data;renderWallet();break;
 case 'walletStatus':walletBusy=msg.state==='working';$('walletBackupBtn').disabled=$('bpMake').disabled=walletBusy;renderIdentity();if(createPending||!$('view-create').hidden){$('createState').textContent=walletBusy?'WORKING…':msg.state==='ok'?'✓ DONE':'✗ FAILED';$('createBtn').disabled=walletBusy||wallet.cliFound===false;if(!walletBusy)createPending=false;if(msg.state==='ok')$('walletCreateForm').elements.name.value='';if(msg.message&&msg.state!=='fail')notice(msg.message)}$('walletState').textContent=walletBusy?'WORKING…':msg.state==='ok'?'✓ UNLOCKED':'✗ FAILED';if(msg.state==='fail')notice(msg.message||'Wallet action failed.',true);$('walletUnlockBtn').disabled=$('walletSendBtn').disabled=$('walletLockBtn').disabled=walletBusy;break;
 case 'nuked':pendingProfile=null;walletBusy=createPending=false;cardPrompt({phase:'done'});closeReceive();hideOffer();schedShown='';$('walletBackupPrompt').hidden=true;for(const id of ['settings','loginForm','walletUnlockForm','walletSendForm','walletWatchForm','walletCreateForm'])$(id)?.reset();wallet={};profile={};$('walletReceipt').hidden=true;$('walletSeedBox').hidden=true;$('walletIdx').value=0;forumSaved=false;renderForum();$('walletState').textContent='LOCKED';$('loginState').textContent='NOT SIGNED IN';selectTab('setup');break;
 case 'walletSeed':{walletBusy=createPending=false;$('createState').textContent='✓ DONE';const b=$('walletSeedBox');b.hidden=false;b.replaceChildren(el('b','MASTER SEED OF '+msg.name+' — WRITE IT ON PAPER NOW. It is shown ONCE and never again; anyone with it controls the wallet.'),el('code',msg.seed),(()=>{const d=el('button','I WROTE IT DOWN — OPEN WALLET ↗');d.type='button';d.onclick=()=>{b.replaceChildren();b.hidden=true;$('walletCreateForm').elements.name.value='';noticeSticky=false;notice(msg.name+' is ready. Keep the paper with its seed somewhere safe.');selectTab('wallet')};return d})());b.scrollIntoView({block:'nearest'});
  // on another tab the box is out of sight: the notice says a one-time seed is waiting, until I WROTE IT DOWN (NEW WALLET brings the box into view)
  notice('Write the seed of '+msg.name+' on paper now: it is on the NEW WALLET tab and is shown only once.',true);break}
 case 'walletSent':{if(msg.relaunch)selectTab('wallet');walletBusy=false;$('walletUnlockBtn').disabled=$('walletSendBtn').disabled=$('walletLockBtn').disabled=$('walletBackupBtn').disabled=$('bpMake').disabled=false;const ids=msg.txids?.length?msg.txids:msg.txid?[msg.txid]:[],n=Math.max(msg.transactions||0,ids.length,1),head=el('div','','wr-head'),rf=msg.refused;
  // refused: the network ANSWERED no, so it (and anything after it) certainly did not go out; its words shown whole; the form is kept to send again
  if(rf&&!ids.length){head.append(el('b','NOT SENT — THE NETWORK REFUSED IT'));const why=[el('small',msg.message||'The network refused this transaction.','wr-miss')];if(n>1)why.push(el('small',`None of the ${n} transactions went out.`,'wr-refused'));showReceipt('refused',head,...why);break}
  head.append(el('b',msg.partial?`⚠ SENT ${ids.length} OF ${n} TRANSACTIONS`:n>1?`SENT ✓ ${n} TRANSACTIONS`:'SENT ✓'));if(msg.amount)head.append(el('span',' · '+msg.amount+' XCF'));if(msg.fee)head.append(el('span',' · fee '+msg.fee+' XCF · '+msg.vsize+' vB'));
  // the uncertain txid may have gone out (lost connection): never under NOT BROADCAST
  const txList=(label,list,cls)=>{const d=el('div','',cls);if(label)d.append(el('small',label,'wr-label'));for(const id of list)d.append(txLine(id,msg.explorer));return d};
  const unsent=msg.unsent_txids||[],stop=el('small','STOPPED: '+(msg.broadcast_error||'the send did not finish'),'wr-miss'),rest=[];
  if(!msg.partial)rest.push(txList('',ids,'wr-list'));
  else if(rf){rest.push(el('small',`TRANSACTION ${rf.i} OF ${n}: NOT SENT — THE NETWORK REFUSED IT`,'wr-refused'),el('small',sentence(msg.broadcast_error||'The network refused it.'),'wr-miss'),txList('SENT:',ids,'wr-list'));if(unsent.length)rest.push(txList('NOT SENT:',unsent,'wr-list wr-never'))}
  else{if(unsent[0])rest.push(el('small','Check this txid on the explorer before re-sending — the connection may have dropped after it went out.','wr-unsure'),txLine(unsent[0],msg.explorer),stop);
   else rest.push(stop,el('small','Check the explorer before re-sending the rest — the connection may have dropped after a transaction went out.','wr-unsure'));
   rest.push(txList('SENT:',ids,'wr-list'));if(unsent.length>1)rest.push(txList('NOT BROADCAST:',unsent.slice(1),'wr-list wr-never'))}
  head.title=head.textContent;showReceipt(!!msg.partial,head,...rest);
  $('walletSendForm').reset();if(!msg.partial)notice(n>1?`Sent in ${n} transactions. The explorer shows them once the next block confirms them.`:'Sent. The explorer shows it once the next block confirms it.');break}
 case 'sendInterrupted':{selectTab('wallet');const head=el('div','','wr-head'),rest=[el('small','Check this wallet on the explorer before sending again — MMM cannot tell what went out.','wr-unsure')];head.append(el('b','⚠ MMM WAS CLOSED WHILE A SEND WAS BROADCASTING'));
  if(msg.address)rest.push(linkLine(short(msg.address),msg.address,'/address/'+msg.address,msg.explorer,'address'));if(msg.txids?.length){const list=el('div','','wr-list');for(const id of msg.txids)list.append(txLine(id,msg.explorer));rest.push(el('small','Reported sent before it closed:','wr-miss'),list)}
  showReceipt(true,head,...rest);notice(msg.message,true);break}
 case 'walletLocked':$('walletReceipt').hidden=true;notice('Locked. UNLOCK again to send from this wallet — no restart needed.');break;
 case 'cardPrompt':cardPrompt(msg);break;
 case 'schedule':sched=msg;renderSchedule();
  if(msg.event==='paused')notice('Paused by schedule — '+msg.reason+'. Mining resumes when the schedule allows.');
  else if(msg.event==='blocked'){notice('The schedule holds mining — '+msg.reason+'. MINE ANYWAY starts now and holds until the schedule next changes.',true);showOffer()}
  else if(msg.event==='resumed')notice('The schedule allows mining again — starting.');
  else if(msg.event==='saved')notice('Schedule saved.');break;
 case 'forumIdentity':forum=msg;renderIdentity();break;
 case 'walletQR':if(msg.seq===rvSeq&&msg.address===rvAddress&&!$('walletReceive').hidden)showQR(msg);break;
 case 'walletBackup':if(msg.file===wallet.selected){wallet.backup=msg.data;renderBackup()}break;
 case 'walletCardCreated':bpFile=msg.file;$('bpName').textContent=msg.name;$('walletBackupPrompt').hidden=false;$('bpMake').disabled=walletBusy;break;
 case 'walletBackupDone':if(msg.file===bpFile)$('walletBackupPrompt').hidden=true;notice(msg.message,true);break;
 }
};
function showActionNote(){$('actionNote').textContent=actionNote();$('actionNote').classList.toggle('held',sched.paused&&!running)}
const actionNote=()=>sched.paused&&!running?'Paused by schedule: '+sched.reason+'. Mining resumes when it allows.':profile.network==='mainnet'?'Uses the selected mainnet pool and genesis.':'Testnet rewards are rehearsal coins.';
async function updateProfile(){$('networkLabel').textContent=profile.network==='mainnet'?'MAINNET / GENESIS VERIFIED BEFORE START':'TESTNET A / REHEARSAL';showActionNote();$('payout').replaceChildren(profile.address?await person(profile.address):el('span','Set your payout address below.'))}
$('settings').onsubmit=e=>{e.preventDefault();const next=Object.fromEntries(new FormData(e.target));for(const k in next)if(k!=='password')next[k]=next[k].trim();next.explorer=next.explorer.replace(/\/$/,'');const password=next.password;delete next.password;pendingProfile=next;send('save',{profile:next,password,startAfterSave});startAfterSave=false;notice('Saving setup…')};
$('settings').elements.network.onchange=()=>{const f=$('settings').elements;f.address.value='';f.address.placeholder=f.network.value==='mainnet'?'xpa1r…':'txa1r…';f.host.value='';f.port.value='';f.worker.value='';f.password.value='';f.explorer.value=f.network.value==='testnet'?'https://superknet.com':''};
$('start').onclick=()=>{hideOffer();if(running){send('stop');return}if(!$('settings').checkValidity()){selectTab('setup');$('settings').reportValidity();return}startAfterSave=true;$('settings').requestSubmit()};$('refresh').onclick=()=>send('refresh');render();
// Decode the node's witness-v3 script when RPC omits its address string.
function decodeScript(hex,hrp){if(!/^5320[0-9a-f]{64}$/i.test(hex||''))return '';let acc=0,bits=0,data=[3];for(const byte of hex.slice(4).match(/../g)){acc=(acc<<8)|parseInt(byte,16);bits+=8;while(bits>=5){bits-=5;data.push((acc>>>bits)&31)}}if(bits)data.push((acc<<(5-bits))&31);const expanded=[...hrp].map(c=>c.charCodeAt(0)>>5).concat([0],[...hrp].map(c=>c.charCodeAt(0)&31));let chk=1;for(const v of [...expanded,...data,0,0,0,0,0,0]){const top=chk>>>25;chk=((chk&0x1ffffff)<<5)^v;[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3].forEach((g,i)=>{if((top>>i)&1)chk^=g})}chk^=0x2bc830a3;for(let i=0;i<6;i++)data.push((chk>>>(5*(5-i)))&31);return hrp+'1'+data.map(v=>'qpzry9x8gf2tvdw0s3jn54khce6mua7l'[v]).join('')}

// Tabs do not navigate away from the local app or scroll the document.
function selectTab(name){
 if(!tabNames.includes(name))name='dashboard';
 if(name!=='wallet'&&!$('walletReceive').hidden)closeReceive();   // RECEIVE is the WALLET tab's dialog: leaving the tab closes it
 for(const key of tabNames){const active=key===name;$('view-'+key).hidden=!active;$('view-'+key).classList.toggle('active',active);$('tab-'+key).classList.toggle('selected',active);$('tab-'+key).setAttribute('aria-selected',String(active));$('tab-'+key).tabIndex=active?0:-1}
 if(name==='dashboard')fitMetrics();
 if(name==='create'&&!$('walletSeedBox').hidden)$('walletSeedBox').scrollIntoView({block:'nearest'});   // a seed that arrived while away, back in view
 if(name==='blocks')renderBlocks();if(name==='miners')renderMiners();if(name==='setup')renderLog();if(name==='wallet'||name==='create')send('walletRefresh');if(name==='forum')send('forumRefresh');
}
const tabNames=['dashboard','blocks','miners','wallet','create','forum','setup'];
for(const name of tabNames){const tab=$('tab-'+name);tab.onclick=e=>{e.preventDefault();selectTab(name)};tab.onkeydown=e=>{const n=tabNames.length;let i=tabNames.indexOf(name);if(e.key==='ArrowRight')i=(i+1)%n;else if(e.key==='ArrowLeft')i=(i+n-1)%n;else if(e.key==='Home')i=0;else if(e.key==='End')i=n-1;else return;e.preventDefault();selectTab(tabNames[i]);$('tab-'+tabNames[i]).focus()}}
function pageInfo(kind,total){const wrap=$(kind).querySelector('.table-wrap');const style=getComputedStyle($(kind).querySelector('table'));const rowHeight=parseFloat(style.getPropertyValue('--table-row-height'))||72;const headHeight=parseFloat(style.getPropertyValue('--table-head-height'))||42;const count=Math.max(1,Math.floor((wrap.clientHeight-headHeight)/rowHeight));const pages=Math.max(1,Math.ceil(total/count));let page=kind==='blocks'?blockPage:minerPage;page=Math.min(page,pages-1);if(kind==='blocks')blockPage=page;else minerPage=page;$(kind+'Page').textContent=`${page+1} / ${pages} · ${total} ${kind==='blocks'?'recent blocks':'miners'}`;$(kind+'Prev').disabled=page===0;$(kind+'Next').disabled=page>=pages-1;return {start:page*count,count}}
async function renderBlocks(){if($('view-blocks').hidden)return;const revision=++blockRevision;const {start,count}=pageInfo('blocks',blockData.length);const rows=await Promise.all(blockData.slice(start,start+count).map(async b=>{const tr=el('tr'),height=el('td'),a=el('a','#'+fmt(b.height));a.href='#';a.onclick=e=>{e.preventDefault();send('open',{path:'/block/'+b.height})};height.append(a);const payouts=(b.tx?.[0]?.vout||[]).filter(o=>o.value>0);const who=el('td');if(payouts.length){const sp=payouts[0].scriptPubKey||{};who.append(await person(sp.address||sp.addresses?.[0]||decodeScript(sp.hex,profile.network==='mainnet'?'xpa':'txa'),payouts.length>1?`+ ${payouts.length-1} other payout outputs`:''))}else who.textContent='No spendable payout';tr.append(height,who,el('td',fmt(payouts.reduce((n,o)=>n+o.value,0),8)+' XCF'),el('td',age(b.time)));return tr}));if(revision!==blockRevision)return;$('blockRows').replaceChildren(...rows);if(!rows.length)$('blockRows').innerHTML='<tr><td colspan="4" class="empty">No verified blocks available.</td></tr>'}
async function renderMiners(){if($('view-miners').hidden)return;const revision=++minerRevision;const {start,count}=pageInfo('miners',minerData.length);const rows=await Promise.all(minerData.slice(start,start+count).map(async r=>{const tr=el('tr'),td=el('td');td.append(await person(r.address,r.worker||'unnamed'));const on=Number(r.last)>Date.now()/1000-300,status=el('td');status.append(el('span',on?'ONLINE':'SEEN '+age(r.last)+' AGO',on?'online':'offline'));tr.append(td,status,el('td',fmt(r.hashrate_mhs,2)+' MH/s'),el('td',fmt(r.shares)),el('td',fmt(r.blocks)));return tr}));if(revision!==minerRevision)return;$('minerRows').replaceChildren(...rows);if(!rows.length)$('minerRows').innerHTML='<tr><td colspan="5" class="empty">No miners reported by this pool.</td></tr>'}
$('blocksPrev').onclick=()=>{blockPage=Math.max(0,blockPage-1);renderBlocks()};$('blocksNext').onclick=()=>{blockPage++;renderBlocks()};$('minersPrev').onclick=()=>{minerPage=Math.max(0,minerPage-1);renderMiners()};$('minersNext').onclick=()=>{minerPage++;renderMiners()};
let logText='No mining session started.';
// long lines wrap (never cut at the right edge); the oldest lines give way so the latest stay whole in view
function renderLog(){const e=$('log'),lines=logText.split('\n').filter(Boolean);let n=Math.max(1,Math.floor((e.clientHeight-16)/(parseFloat(getComputedStyle(e).lineHeight)||18)));e.textContent=lines.slice(-n).join('\n');
 while(n>1&&e.scrollHeight>e.clientHeight+1){n--;e.textContent=lines.slice(-n).join('\n')}}
$('copyLog').onclick=()=>send('copy',{text:logText});$('minimize').onclick=()=>send('minimize');
let resizeTick;window.addEventListener('resize',()=>{clearTimeout(resizeTick);resizeTick=setTimeout(()=>{renderBlocks();renderMiners();renderLog();receiptFit();fitMetrics()},80)});$('walletReceipt').onscroll=receiptFit;
function applyTheme(dark){document.documentElement.dataset.theme=dark?'dark':'light';$('themeToggle').setAttribute('aria-checked',String(dark));$('themeLabel').textContent=dark?'DARK':'LIGHT';try{localStorage.setItem('mmm-theme',dark?'dark':'light')}catch{}}
let initialTheme;try{initialTheme=localStorage.getItem('mmm-theme')}catch{}applyTheme(initialTheme?initialTheme==='dark':window.matchMedia('(prefers-color-scheme: dark)').matches);
$('themeToggle').onclick=()=>applyTheme(document.documentElement.dataset.theme!=='dark');selectTab('dashboard');

$('nukeBtn').onclick=()=>send('nuke');
$('autoStart').onchange=()=>send('autoStartPreference',{enabled:$('autoStart').checked});
let forumSaved=false;
function renderForum(){$('passLabel').hidden=forumSaved;$('rememberLabel').hidden=forumSaved;$('forgetBtn').hidden=!forumSaved;$('loginBtn').textContent=forumSaved?'SIGN IN WITH TOUCH ID ↗':'SIGN IN TO MINEDIFFERENT ↗'}
$('loginForm').onsubmit=e=>{e.preventDefault();if(forumSaved){send('loginTouch');return}const f=new FormData(e.target);send('login',{passphrase:String(f.get('passphrase')||''),remember:f.get('remember')==='on'});e.target.reset()};
$('forgetBtn').onclick=()=>send('loginForget');
renderForum();

function renderCreate(){
 const f=$('walletCreateForm');
 $('createBtn').disabled=wallet.cliFound===false||walletBusy;
 if(wallet.cliFound===false){$('createState').textContent='✗ WALLET CLI NOT FOUND';return}
 if(!f.elements.name.value){const ns=(wallet.wallets||[]).map(w=>/wallet(\d+)\.mmm$/.exec(w.name)).filter(Boolean).map(m=>+m[1]);f.elements.name.value='wallet'+String(Math.max(0,...ns)+1).padStart(3,'0')+'.mmm'}
}
// ── WALLET tab: balances from the explorer, sends via the offline keytool ────
let wallet={},walletRevision=0,walletBusy=false,createPending=false;
// a copied balance must paste back into AMOUNT: dot decimals, no grouping
const xcfFmt=sats=>(sats/1e8).toLocaleString('en-US',{maximumFractionDigits:8,useGrouping:false});
async function renderWallet(){
 const revision=++walletRevision;
 const box=$('walletBalances');box.replaceChildren();
 const sel=$('walletFileSel');sel.replaceChildren();
 for(const f of (wallet.wallets||[])){const o=el('option',f.name+(f.default?' (default)':'')+(f.card?' \u00b7 NFC card':''));o.value=f.file;o.selected=!!f.selected;sel.append(o)}
 if(!(wallet.wallets||[]).length)sel.append(el('option','no wallet files found'));
 const selInfo=(wallet.wallets||[]).find(f=>f.selected);
 $('walletFormat').textContent=selInfo?selInfo.format.toUpperCase()+(selInfo.card?' \u00b7 TAP TO UNLOCK':''):'';
 $('walletIdx').value=wallet.selectedIndex??0;
 $('wSendPassLabel').hidden=!wallet.needsPassphraseEntry;
 $('wRememberLabel').hidden=!wallet.selectedIsDefault;
 $('walletNote').textContent=wallet.selectedCard
  ?'Touch ID approves; then tap your xCoin card on the NFC reader. Keys never leave this Mac.'
  :'Touch ID approves every send. Signing is offline on this Mac; the explorer only relays.';
 renderBackup();if(!$('walletReceive').hidden&&rvAddress!==wallet.walletAddress)closeReceive();
 const unlocked=!!wallet.walletAddress;$('walletRxBtn').hidden=!unlocked||wallet.cliFound===false;
 $('walletState').textContent=wallet.cliFound===false?'✗ WALLET CLI NOT FOUND':unlocked?'✓ UNLOCKED':'LOCKED';
 $('walletLockBtn').hidden=!unlocked||wallet.cliFound===false;$('walletLockBtn').disabled=walletBusy;
 $('walletUnlockForm').hidden=unlocked||wallet.cliFound===false;
 $('walletSendForm').hidden=!unlocked||wallet.cliFound===false;
 renderCreate();
 if(wallet.cliFound===false){box.append(el('p','Install the wallet CLI (github.com/SystemThreat/xcoin-wallet) to ~/x-Coin/wallet-cli, then reopen this tab.','empty'));return}
 $('walletSendForm').elements.dest.placeholder=(profile.network==='mainnet'?'xpa1r…':'txa1r…');
 const rows=[];
 if(wallet.walletAddress)rows.push(['SELECTED WALLET \u00b7 INDEX '+(wallet.selectedIndex??0)+' (SENDS FROM HERE)',wallet.walletAddress]);
 if(wallet.payout&&wallet.payout!==wallet.walletAddress)rows.push(['MINING PAYOUT ADDRESS',wallet.payout]);
 for(const a of (wallet.watched||[]))if(a!==wallet.payout&&a!==wallet.walletAddress)rows.push(['WATCHED',a,true]);
 if(!rows.length){box.append(el('p','Unlock to derive this Mac\u2019s wallet address; set a payout address in SETUP to watch it here.','empty'));return}
 for(const [label,addr,removable] of rows){
  const row=el('div','','wallet-row');const b=(wallet.balances||{})[addr];
  row.append(el('label',label));row.append(await person(addr));
  row.append(el('strong',b?xcfFmt(b.spendable_sats)+' XCF':'—'));
  const note=b?((b.immature_sats>0?'+ '+xcfFmt(b.immature_sats)+' maturing':'spendable')+(b.carried_sats>0?' \u00b7 incl. '+xcfFmt(b.carried_sats)+' single-leaf':'')):'explorer unavailable';
  const small=el('small',note);
  if(removable){const x=el('button',' ✕','text-button');x.type='button';x.title='stop watching';x.onclick=()=>send('walletWatchRemove',{address:addr});small.append(x)}
  row.append(small);
  if(revision!==walletRevision)return;
  box.append(row);
 }
 if(wallet.payout&&wallet.walletAddress&&wallet.payout!==wallet.walletAddress)box.append(el('p','Your payout address is not this wallet\u2019s key 0 — sends draw from the wallet balance above. Point mining at the wallet address to make them one.','wallet-note'));
}
$('walletWatchForm').onsubmit=e=>{e.preventDefault();const f=new FormData(e.target);send('walletWatchAdd',{address:String(f.get('address')||'').trim()});e.target.reset()};
$('walletUnlockForm').onsubmit=e=>{e.preventDefault();const f=new FormData(e.target);send('walletUnlock',{passphrase:String(f.get('passphrase')||''),remember:f.get('remember')==='on'});e.target.reset()};
// dot decimals, no grouping: a lone decimal comma is read as a dot; any other comma is refused
function amountText(raw){let a=String(raw||'').trim();if(/^[1-9]\d{0,2}(,\d{3})+$/.test(a))return {error:'\u201c'+a+'\u201d is ambiguous \u2014 type the amount with a dot for decimals and no thousands separators (e.g. 1000 or 1.5).'};if(/^\d*,\d+$/.test(a))a=a.replace(',','.');if(a.includes(','))return {error:'Write the amount with a dot for decimals and no thousands separators, e.g. 1234.5'};return {amount:a}}
$('walletSendForm').onsubmit=e=>{e.preventDefault();const f=new FormData(e.target),t=amountText(f.get('amount'));if(t.error){notice(t.error,true);return}const amount=t.amount;$('walletReceipt').hidden=true;send('walletSend',{dest:String(f.get('dest')||'').trim(),amount,passphrase:String(f.get('passphrase')||'')});e.target.elements.passphrase.value=''};
$('walletFileSel').onchange=e=>{$('walletReceipt').hidden=true;send('walletSelect',{file:e.target.value})};
$('walletIdx').onchange=()=>{$('walletReceipt').hidden=true;send('walletSelect',{file:$('walletFileSel').value,index:Math.max(0,Number($('walletIdx').value)||0)})};
$('walletBrowse').onclick=()=>send('walletBrowse');
$('walletLockBtn').onclick=()=>send('walletLock');
$('walletCreateForm').onsubmit=e=>{e.preventDefault();const f=new FormData(e.target);if(String(f.get('pass')||'')!==String(f.get('pass2')||'')){$('createState').textContent='✗ PASSPHRASES DIFFER';notice('Passphrases do not match.',true);return}$('walletSeedBox').hidden=true;createPending=true;send('walletCreate',{name:String(f.get('name')||'').trim(),passphrase:String(f.get('pass')||''),card:f.get('card')==='on'});e.target.elements.pass.value='';e.target.elements.pass2.value=''};
// ── Card / Touch ID banner: the step the wallet CLI waits for, as a ticker; a countdown for the tap; CANCEL ──
let cardTimer=0,cardDeadline=0,cardClockLong=false,cardShown='',cardPhase='done',cardTapAt=0,cardHintOn=false,cardWords='';
const CARD_HINT='NOTHING DETECTED? UNPLUG THE READER, PLUG IT BACK IN, TAP AGAIN';
const cardFinal=p=>p==='failed'||p==='cancelled',cardLocked=p=>p==='broadcasting'||p==='provisioning',cardWaits=p=>p==='tap'||p==='retry';
function cardText(m){switch(m.phase){
 case 'touchid':return 'AUTHORIZE WITH TOUCH ID';
 case 'tap':return m.blank?'TAP & HOLD THE NEW BLANK CARD FLAT ON THE READER':'TAP & HOLD YOUR XCOIN CARD FLAT ON THE READER';
 case 'swap':return 'REMOVE YOUR WALLET CARD — PLACE A NEW BLANK CARD ON THE READER';
 case 'provisioning':{const c=m.new?'NEW CARD':'BACKUP CARD';return m.quitting?`FINISHING THE ${c} — MMM WILL QUIT WHEN IT IS DONE`:m.written?`${c} WRITTEN ✓ — FINISHING, KEEP IT ON THE READER`:m.new?'SETTING UP YOUR NEW CARD — KEEP IT ON THE READER':'WRITING YOUR BACKUP CARD — KEEP IT ON THE READER'}
 case 'signing':return m.i?`SIGNING TRANSACTION ${m.i} OF ${m.n}`+(m.card?' — KEEP THE CARD ON THE READER':''):m.cardRead?'CARD READ ✓ — WORKING, PLEASE WAIT':'WORKING — PLEASE WAIT';
 case 'broadcasting':return m.quitting?'FINISHING BROADCAST — MMM WILL QUIT WHEN IT IS DONE':m.i?`SENT ${m.i} OF ${m.n}`+(m.i<m.n?' — BROADCASTING THE REST':''):m.n>1?`BROADCASTING ${m.n} TRANSACTIONS`:'BROADCASTING';
 case 'retry':return 'THE READER RESET THE CARD — KEEP IT ON THE READER — READING AGAIN';
 case 'failed':return m.refused?'✗ NOT SENT — THE NETWORK REFUSED IT':'✗ STOPPED — THE MESSAGE ABOVE SAYS WHY';
 case 'cancelled':return 'CANCELLED';
 default:return ''}}
function cardClock(s){return cardClockLong?String(Math.floor(s/60)).padStart(2,'0')+':'+String(s%60).padStart(2,'0'):String(s).padStart(2,'0')}
// a card wait (a tap, or the read again after a reader reset) with nothing read for 15 s: the reader may need a replug;
// the hint takes turns with the wait's words, hint first (4 s each without motion)
function cardTick(){clearTimeout(cardTimer);const ms=cardDeadline-Date.now(),left=Math.max(0,Math.ceil(ms/1000)),c=$('cardCount');c.classList.toggle('up',!left);$('cardBanner').classList.toggle('up',!left);c.textContent=left?cardClock(left):'TIME UP — TAP OR CANCEL';
 if(cardWaits(cardPhase)){const on=Date.now()-cardTapAt;if(on>=15000&&!cardHintOn){cardHintOn=true;cardStrips([cardWords,CARD_HINT])}if(cardHintOn)$('cardBanner').classList.toggle('alt',Math.floor((on-15000)/4000)%2===0)}
 if(left||cardHintOn)cardTimer=setTimeout(cardTick,left?ms%1000||1000:1000)}
// two identical strips scrolled by -50%: the seam never shows; rebuilt only when the words change
function cardStrips(words){const key=words.join('\n');if(key===cardShown)return;cardShown=key;$('cardText').textContent=words.join('. ');const unit=words.reduce((a,w)=>a+w.length+3,0),reps=Math.max(2,Math.ceil(120/unit)),strip=()=>{const s=el('span','','cb-strip');for(let k=0;k<reps;k++)for(const w of words)s.append(el('span',w),el('i','◆'));return s},t=$('cardTrack');t.style.animationDuration=Math.round(reps*unit*0.13)+'s';t.replaceChildren(strip(),strip())}
// the banner overlays the top of the view: while it shows, the controls under it are inert — out of the tab order, so
// keyboard focus never lands where it cannot be seen: each view's top panel title (WALLET: MAKE BACKUP CARD, RECEIVE,
// LOCK; BLOCKS: REFRESH; SETUP: the auto-start box, NUKE; the rest of the title stays readable) and the dashboard's
// payout line, which a short hero puts at the top of the lime panel
function bannerCover(up){for(const e of document.querySelectorAll('.view>.workspace:first-child>.panel-title :is(button,a,input,select),#payout'))e.inert=up}
function bannerHide(){$('cardBanner').hidden=true;cardShown='';bannerCover(false)}
function cardPrompt(m){
 const b=$('cardBanner'),text=cardText(m),end=cardFinal(m.phase);clearTimeout(cardTimer);cardPhase=m.phase;cardHintOn=false;b.classList.remove('alt');
 if(!text){bannerHide();return}
 b.hidden=false;bannerCover(true);b.dataset.phase=m.phase;b.classList.toggle('static',end);b.classList.remove('up');$('cardCount').classList.remove('up');$('cardCount').textContent='';
 cardStrips([text]);
 // from broadcast-begin (or a card write) on Swift refuses CANCEL: stopping it could hide whether a transaction went out, or half-write a card
 const c=$('cardCancel'),locked=cardLocked(m.phase);c.disabled=locked;c.textContent=end?'CLOSE ✕':locked?(m.phase==='provisioning'?'WRITING — CANNOT CANCEL':'BROADCASTING — CANNOT CANCEL'):'CANCEL ✕';
 if(cardWaits(m.phase)&&(m.phase==='tap'||m.seconds)){const s=Math.min(300,Math.max(1,Math.round(Number(m.seconds))||60));cardClockLong=s>=60;cardDeadline=Date.now()+s*1000;cardTapAt=Date.now();cardWords=text;cardTick()}
 if(end)cardTimer=setTimeout(bannerHide,4000);
}
$('cardCancel').onclick=()=>{if(cardLocked(cardPhase))return;if(cardFinal(cardPhase)){clearTimeout(cardTimer);bannerHide();return}const c=$('cardCancel');c.disabled=true;c.textContent='CANCELLING…';send('walletCancel')};
// ── RECEIVE: Swift draws the QR (CoreImage, black on white); the page only asks and shows ──
function addrCopyLine(text,title){const line=el('div','','rv-line');line.append(el('code',text),copyBtn(text,title));return line}
const rvBeneath=()=>['walletTitle','walletHead','walletBalances','walletActions'].map($);
function openReceive(addr){rvAddress=addr;$('walletReceive').hidden=false;for(const e of rvBeneath())e.inert=true;$('rvAmount').value='';$('rvImg').hidden=true;$('rvQr').hidden=false;$('rvAddr').replaceChildren(addrCopyLine(addr,'Copy the address'));requestQR();$('rvAmount').focus()}
// back: CLOSE or Escape returns focus to RECEIVE; a close because the wallet changed does not
function closeReceive(back){const open=!$('walletReceive').hidden;rvSeq++;rvAddress='';$('walletReceive').hidden=true;for(const e of rvBeneath())e.inert=false;if(open&&back&&!$('walletRxBtn').hidden)$('walletRxBtn').focus()}
const rvFocusable=()=>[...$('walletReceive').querySelectorAll('button,input')].filter(e=>!e.disabled&&e.getClientRects().length);
function requestQR(){const t=amountText($('rvAmount').value),a=t.amount||'';let err=t.error;if(!err&&a&&!(/^\d{0,8}(\.\d{0,8})?$/.test(a)&&Number(a)>0))err='Amount: above 0, up to 8 decimals, with a dot (e.g. 1.5).';rvSeq++;if(err){showQR({error:err});return}send('walletQR',{address:rvAddress,amount:a,seq:rvSeq})}
// a QR that no longer matches the typed amount is never left on screen
function showQR(m){const img=$('rvImg'),note=$('rvNote');note.classList.toggle('err',!!m.error);$('rvQr').hidden=!!m.error;if(m.error){img.hidden=true;$('rvUri').replaceChildren(el('span','—'));note.textContent=m.error;return}
 img.src=m.png;img.style.width=img.style.height=(m.modules*4)+'px';img.hidden=false;$('rvUri').replaceChildren(addrCopyLine(m.uri,'Copy the payment request'));note.textContent='Scan with an xCoin wallet, or share the request. '+(profile.network==='mainnet'?'Mainnet XCF only.':'Testnet A coins only.')}
let rvTick;$('rvAmount').oninput=()=>{clearTimeout(rvTick);rvTick=setTimeout(requestQR,250)};$('rvClose').onclick=()=>closeReceive(true);$('walletRxBtn').onclick=()=>{if(wallet.walletAddress)openReceive(wallet.walletAddress)};
function rvKeys(e){if($('walletReceive').hidden)return;if(e.key==='Escape'){e.preventDefault();closeReceive(true);return}if(e.key!=='Tab')return;const f=rvFocusable();if(!f.length)return;const i=f.indexOf(document.activeElement);
 if(e.shiftKey?i<=0:i===-1||i===f.length-1){e.preventDefault();(e.shiftKey?f[f.length-1]:f[0]).focus()}}
document.addEventListener('keydown',rvKeys);
// ── Backup cards: the header badge from card-status (no tap); MAKE BACKUP CARD ──
function renderBackup(){const b=wallet.backup||{},sel=(wallet.wallets||[]).find(f=>f.selected),badge=$('walletBackup'),btn=$('walletBackupBtn');let text='',cls='',tip='';
 if(sel?.card&&b.card&&!b.unknown){if(b.backup_supported===false){text=b.note||(sel.format==='mmm5'?'Backup cards for this wallet are made with dex-wallet-cli.':'A backup card cannot be made for this wallet on this Mac.');cls='note';tip=text}else{const n=Number(b.count)||0;text=n>=2?`BACKED UP ✓ (${n} cards)`:'NO BACKUP CARD ⚠';cls=n>=2?'ok':'warn';tip=[b.note,...(b.cards||[]).map(c=>[c.label,c.uid,c.permanent?'sealed':'resettable',c.created].filter(Boolean).join(' · '))].filter(Boolean).join('\n')}}
 badge.hidden=!text;badge.textContent=text;badge.className='backup-badge '+cls;badge.title=tip;btn.hidden=!(sel?.card&&b.backup_supported===true&&wallet.cliFound!==false);btn.disabled=walletBusy}
$('walletBackupBtn').onclick=()=>{if(wallet.selected)send('walletBackup',{file:wallet.selected})};
$('bpMake').onclick=()=>{if(bpFile)send('walletBackup',{file:bpFile})};$('bpLater').onclick=()=>{$('walletBackupPrompt').hidden=true};
// ── FORUM: the identity (key 101) shows only on request; the sign-in form above is unchanged ──
function renderIdentity(){const f=forum,box=$('fidBox'),show=$('fidShow');$('fidWallet').textContent=$('fidWallet').title=f.wallet?f.wallet+' · KEY 101':'';box.hidden=!f.xid;show.hidden=!!f.xid;show.disabled=f.state==='working'||walletBusy||!f.wallet;show.textContent=f.state==='working'?'READING…':'SHOW MY IDENTITY ↗';
 if(!f.xid)box.dataset.xid='';else if(box.dataset.xid!==f.xid){const xid=f.xid,icon=el('span','','fid-mark');box.dataset.xid=xid;mark(xid).then(svg=>{if(box.dataset.xid===xid)icon.innerHTML=svg});box.replaceChildren(icon,addrCopyLine(xid,'Copy your forum identity'))}
 $('forumLast').textContent=f.last>0?'LAST SIGN-IN FROM THIS MAC: '+new Date(f.last*1000).toLocaleString():'NO SIGN-IN FROM THIS MAC YET'}
$('fidShow').onclick=()=>{const pf=$('loginForm').elements.passphrase;send('forumIdentity',{passphrase:String(pf.value||'')});pf.value=''};
$('forumOpen').onclick=()=>send('openForum');
// ── Mining schedule (SETUP): saved on change; Swift decides and reports the hold ──
function engineIdle(){return sched.paused?'■ PAUSED BY SCHEDULE — '+String(sched.reason||'').toUpperCase():'■ STOPPED'}
function renderSchedule(){const d=sched.data||{},form=$('scheduleForm'),f=form.elements,key=JSON.stringify(d);
 if(key!==schedShown){schedShown=key;f.mode.value=d.mode||'always';f.idle.value=d.idle??10;f.from.value=d.from||'22:00';f.to.value=d.to||'07:00';f.hot.checked=!!d.hot}
 form.dataset.mode=f.mode.value;
 const note=$('scheduleNote');note.textContent=sched.override?'MINE ANYWAY — until the schedule next changes':sched.paused?'PAUSED — '+sched.reason+' · resumes when allowed':sched.hold?'now: '+sched.hold:(d.mode||'always')==='always'&&!d.hot?'mines whenever MMM mines':'now: mining allowed';note.title=note.textContent;
 if(!running){$('engineStatus').textContent=engineIdle();$('engineStatus').title=sched.paused?sched.reason:''}showActionNote();
 if(!sched.paused||running)hideOffer()}
function showOffer(){$('schedWhy').textContent='PAUSED BY SCHEDULE — '+String(sched.reason||'').toUpperCase();$('schedOffer').hidden=false;$('actionNote').hidden=true}
function hideOffer(){$('schedOffer').hidden=true;$('actionNote').hidden=false}
$('scheduleForm').onsubmit=e=>e.preventDefault();
$('scheduleForm').onchange=()=>{const form=$('scheduleForm'),f=form.elements,d=sched.data||{},mode=f.mode.value,idle=Number(f.idle.value),hhmm=/^([01]\d|2[0-3]):[0-5]\d$/,okIdle=Number.isInteger(idle)&&idle>=1&&idle<=120,okHours=hhmm.test(f.from.value)&&hhmm.test(f.to.value)&&f.from.value!==f.to.value;form.dataset.mode=mode;
 if(mode==='idle'&&!okIdle){notice('Idle minutes: a whole number from 1 to 120.',true);return}
 if(mode==='hours'&&!okHours){notice('Mining hours: two different times, e.g. 22:00 to 07:00.',true);return}
 send('schedule',{mode,idle:okIdle?idle:d.idle??10,from:okHours?f.from.value:d.from||'22:00',to:okHours?f.to.value:d.to||'07:00',hot:!!f.hot.checked})};
$('mineAnyway').onclick=()=>{hideOffer();send('mineAnyway')};$('stayStopped').onclick=()=>{hideOffer();send('scheduleStay')};
