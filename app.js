'use strict';
const $=id=>document.getElementById(id), send=(action,extra={})=>{if(!['copy','open'].includes(action))noticeSticky=false;window.webkit?.messageHandlers.native.postMessage({action,...extra})};
let profile={}, miner={}, chain={}, running=false, history=[], noticeSticky=false, pendingProfile=null, poolNote='', engineError='';
let startAfterSave=false;
let sched={data:{},paused:false,reason:'',hold:'',override:false},schedShown='';
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
 case 'miner':{miner=msg.data;const down=miner.pool_connected===false,st=down?String(miner.pool_status||'reconnecting').replace(/\.$/,''):'';$('hashrate').textContent=down?'—':miner.hashrate_pretty||'—';$('gpu').textContent=miner.gpu||'MetalDAG';$('uptime').textContent='SESSION '+fmt(miner.uptime_s)+'s';$('engineStatus').textContent=down?'■ RECONNECTING':miner.running?'■ MINING':'■ INITIALIZING';$('engineStatus').title=st;if(st!==poolNote){notice(st?'Pool connection lost — '+st+'. Hashing is paused until the pool answers.':'Pool connection restored. Mining resumed.');poolNote=st}history.push(down?0:miner.hashrate_hps||0);history=history.slice(-150);const hi=Math.max(...history,1),lo=Math.min(...history),span=Math.max(hi-lo,hi*.01),base=(hi+lo-span)/2;$('chartLine').setAttribute('d',history.map((h,i)=>`${i?'L':'M'}${(i*800/149).toFixed(1)},${(84-(h-base)/span*78).toFixed(1)}`).join(' '));render();break}
 case 'minerPending':if(running&&miner.running){$('hashrate').textContent='—';$('engineStatus').textContent='■ WAITING FOR ENGINE';$('engineStatus').title=msg.message||''}break;
 case 'started':engineError='';setRunning(true);notice('Starting MetalDAG engine. The initial DAG build can take a few minutes.');break;
 case 'stopped':setRunning(false);if(msg.code===0||msg.code===15)notice('Mining stopped.');else notice('Engine exited ('+msg.code+(engineError?'): '+engineError:'). Check the engine log.'),true);break;
 case 'error':notice(msg.message,true);break;
 case 'offline':blockData=[];minerData=[];blockRevision++;minerRevision++;chain={};render();$('connection').textContent='○ EXPLORER OFFLINE';$('blockRows').innerHTML='<tr><td colspan="4" class="empty">Explorer unavailable. Retrying every 5 seconds.</td></tr>';$('minerRows').innerHTML='<tr><td colspan="5" class="empty">Miner registry unavailable.</td></tr>';$('minerCount').textContent='— ONLINE';notice(msg.message);break;
 case 'networkError':{minerData=[];minerRevision++;$('minerCount').textContent='REGISTRY UNAVAILABLE';const td=el('td',(msg.message||'Miner registry unavailable')+'.','empty');td.colSpan=5;const tr=el('tr');tr.append(td);$('minerRows').replaceChildren(tr);break}
 case 'log':{const t=msg.message.replace(/\x1b\[[0-9;?]*[A-Za-z]/g,'');if(running&&msg.source!=='login')for(const m of t.matchAll(/(?:^|\r)error: ([^\r\n]+)/gm))engineError=m[1].trim().slice(0,300);logText=(logText+'\n'+t).slice(-18000);renderLog();break}
 case 'nuked':pendingProfile=null;hideOffer();schedShown='';$('settings').reset();profile={};selectTab('setup');break;
 case 'schedule':sched=msg;renderSchedule();
  if(msg.event==='paused')notice('Paused by schedule — '+msg.reason+'. Mining resumes when the schedule allows.');
  else if(msg.event==='blocked'){notice('The schedule holds mining — '+msg.reason+'. MINE ANYWAY starts now and holds until the schedule next changes.',true);showOffer()}
  else if(msg.event==='resumed')notice('The schedule allows mining again — starting.');
  else if(msg.event==='saved')notice('Schedule saved.');break;
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
 for(const key of tabNames){const active=key===name;$('view-'+key).hidden=!active;$('view-'+key).classList.toggle('active',active);$('tab-'+key).classList.toggle('selected',active);$('tab-'+key).setAttribute('aria-selected',String(active));$('tab-'+key).tabIndex=active?0:-1}
 if(name==='dashboard')fitMetrics();
 if(name==='blocks')renderBlocks();if(name==='miners')renderMiners();if(name==='setup')renderLog();
}
const tabNames=['dashboard','blocks','miners','setup'];
for(const name of tabNames){const tab=$('tab-'+name);tab.onclick=e=>{e.preventDefault();selectTab(name)};tab.onkeydown=e=>{const n=tabNames.length;let i=tabNames.indexOf(name);if(e.key==='ArrowRight')i=(i+1)%n;else if(e.key==='ArrowLeft')i=(i+n-1)%n;else if(e.key==='Home')i=0;else if(e.key==='End')i=n-1;else return;e.preventDefault();selectTab(tabNames[i]);$('tab-'+tabNames[i]).focus()}}
function pageInfo(kind,total){const wrap=$(kind).querySelector('.table-wrap');const style=getComputedStyle($(kind).querySelector('table'));const rowHeight=parseFloat(style.getPropertyValue('--table-row-height'))||72;const headHeight=parseFloat(style.getPropertyValue('--table-head-height'))||42;const count=Math.max(1,Math.floor((wrap.clientHeight-headHeight)/rowHeight));const pages=Math.max(1,Math.ceil(total/count));let page=kind==='blocks'?blockPage:minerPage;page=Math.min(page,pages-1);if(kind==='blocks')blockPage=page;else minerPage=page;$(kind+'Page').textContent=`${page+1} / ${pages} · ${total} ${kind==='blocks'?'recent blocks':'miners'}`;$(kind+'Prev').disabled=page===0;$(kind+'Next').disabled=page>=pages-1;return {start:page*count,count}}
async function renderBlocks(){if($('view-blocks').hidden)return;const revision=++blockRevision;const {start,count}=pageInfo('blocks',blockData.length);const rows=await Promise.all(blockData.slice(start,start+count).map(async b=>{const tr=el('tr'),height=el('td'),a=el('a','#'+fmt(b.height));a.href='#';a.onclick=e=>{e.preventDefault();send('open',{path:'/block/'+b.height})};height.append(a);const payouts=(b.tx?.[0]?.vout||[]).filter(o=>o.value>0);const who=el('td');if(payouts.length){const sp=payouts[0].scriptPubKey||{};who.append(await person(sp.address||sp.addresses?.[0]||decodeScript(sp.hex,profile.network==='mainnet'?'xpa':'txa'),payouts.length>1?`+ ${payouts.length-1} other payout outputs`:''))}else who.textContent='No spendable payout';tr.append(height,who,el('td',fmt(payouts.reduce((n,o)=>n+o.value,0),8)+' XID'),el('td',age(b.time)));return tr}));if(revision!==blockRevision)return;$('blockRows').replaceChildren(...rows);if(!rows.length)$('blockRows').innerHTML='<tr><td colspan="4" class="empty">No verified blocks available.</td></tr>'}
async function renderMiners(){if($('view-miners').hidden)return;const revision=++minerRevision;const {start,count}=pageInfo('miners',minerData.length);const rows=await Promise.all(minerData.slice(start,start+count).map(async r=>{const tr=el('tr'),td=el('td');td.append(await person(r.address,r.worker||'unnamed'));const on=Number(r.last)>Date.now()/1000-300,status=el('td');status.append(el('span',on?'ONLINE':'SEEN '+age(r.last)+' AGO',on?'online':'offline'));tr.append(td,status,el('td',fmt(r.hashrate_mhs,2)+' MH/s'),el('td',fmt(r.shares)),el('td',fmt(r.blocks)));return tr}));if(revision!==minerRevision)return;$('minerRows').replaceChildren(...rows);if(!rows.length)$('minerRows').innerHTML='<tr><td colspan="5" class="empty">No miners reported by this pool.</td></tr>'}
$('blocksPrev').onclick=()=>{blockPage=Math.max(0,blockPage-1);renderBlocks()};$('blocksNext').onclick=()=>{blockPage++;renderBlocks()};$('minersPrev').onclick=()=>{minerPage=Math.max(0,minerPage-1);renderMiners()};$('minersNext').onclick=()=>{minerPage++;renderMiners()};
let logText='No mining session started.';
// long lines wrap (never cut at the right edge); the oldest lines give way so the latest stay whole in view
function renderLog(){const e=$('log'),lines=logText.split('\n').filter(Boolean);let n=Math.max(1,Math.floor((e.clientHeight-16)/(parseFloat(getComputedStyle(e).lineHeight)||18)));e.textContent=lines.slice(-n).join('\n');
 while(n>1&&e.scrollHeight>e.clientHeight+1){n--;e.textContent=lines.slice(-n).join('\n')}}
$('copyLog').onclick=()=>send('copy',{text:logText});$('minimize').onclick=()=>send('minimize');
let resizeTick;window.addEventListener('resize',()=>{clearTimeout(resizeTick);resizeTick=setTimeout(()=>{renderBlocks();renderMiners();renderLog();fitMetrics()},80)});
function applyTheme(dark){document.documentElement.dataset.theme=dark?'dark':'light';$('themeToggle').setAttribute('aria-checked',String(dark));$('themeLabel').textContent=dark?'DARK':'LIGHT';try{localStorage.setItem('mmm-theme',dark?'dark':'light')}catch{}}
let initialTheme;try{initialTheme=localStorage.getItem('mmm-theme')}catch{}applyTheme(initialTheme?initialTheme==='dark':window.matchMedia('(prefers-color-scheme: dark)').matches);
$('themeToggle').onclick=()=>applyTheme(document.documentElement.dataset.theme!=='dark');selectTab('dashboard');

$('nukeBtn').onclick=()=>send('nuke');
$('autoStart').onchange=()=>send('autoStartPreference',{enabled:$('autoStart').checked});
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
