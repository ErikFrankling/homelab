import {HOUR,DAY,WINDOWS,windowKind,accountState,pointScales,pooledRate,stackHistory,forecastStack,cycleSummaries,maskedMatch,modelStacks,firstUsedIndex,time,percent} from './model.mjs';
const $=id=>document.getElementById(id), NS='http://www.w3.org/2000/svg';
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=t=>t?new Intl.DateTimeFormat(undefined,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}).format(t):'Not reported';
const fmtDay=t=>new Intl.DateTimeFormat(undefined,{month:'short',day:'numeric'}).format(t);
const fmtWeekday=t=>new Intl.DateTimeFormat(undefined,{weekday:'short',month:'short',day:'numeric'}).format(t);
const fmtHour=t=>new Intl.DateTimeFormat(undefined,{hour:'2-digit',minute:'2-digit'}).format(t);
const num=n=>Number(n.toFixed(1)).toLocaleString();
const tok=n=>{if(n===null||n===undefined||!Number.isFinite(n))return '—';const a=Math.abs(n);return a>=1e9?(n/1e9).toFixed(a>=1e11?0:a>=1e10?1:2)+'B':a>=1e6?(n/1e6).toFixed(a>=1e8?0:a>=1e7?1:2)+'M':a>=1e3?(n/1e3).toFixed(a>=1e5?0:1)+'K':String(Math.round(n));};
const reqs=n=>`${(n||0).toLocaleString()} request${n===1?'':'s'}`;
const localDate=t=>{const d=new Date(t);return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;};
const providerName=p=>p==='claude'?'Claude':p==='codex'?'Codex':p==='xai'?'xAI':p||'Other';
// Data colors only. Claude accounts get warm shades, Codex accounts cool ones.
const palette={claude:['#f0a77c','#e8c48a','#d9826b','#f3d2b3','#c99a6c'],codex:['#8faeff','#7fd6e8','#b3a3ff','#6f8fd6','#a9c7ff']};
const modelColors=['#8faeff','#f0a77c','#a5d8a6','#d7a4e9','#e7cf87','#7f8a96'];
const RANGES={'24h':{label:'24 hours',ms:DAY},'7d':{label:'7 days',ms:7*DAY},'30d':{label:'30 days',ms:30*DAY},all:{label:'all time',ms:null}};
const AHEAD={none:0,'1d':DAY,'3d':3*DAY,'7d':7*DAY,'14d':14*DAY,'30d':30*DAY};
// The visible window: a preset (past + ahead, follows the clock) or a custom
// window from dragging or zooming (stays put until a preset is picked again).
const hashState=()=>{const h=location.hash.slice(1),p=new URLSearchParams(h.includes('=')?h:`past=${h}`);return {past:p.get('past'),ahead:p.get('ahead')};};
let past=RANGES[hashState().past]?hashState().past:RANGES[localStorage.getItem('runway-range')]?localStorage.getItem('runway-range'):'7d';
let ahead=AHEAD[hashState().ahead]!==undefined?hashState().ahead:AHEAD[localStorage.getItem('runway-ahead')]!==undefined?localStorage.getItem('runway-ahead'):'7d';
let custom=null;
let others=[],data=[],daily=null,hourly=null,comp=null,spendError=null,loading=false,kind='weekly',unit='tokens',mode='bars',retryTimer,failures=0,resetBusy=false,compTimer,compSeq=0;
const attempts=new Map(),messages=new Map();
async function api(path,body,timeout=20000){
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeout);
 try{const r=await fetch('/api/v1/'+path,{method:body?'POST':'GET',cache:'no-store',headers:{'x-cpa-usage-keeper-request':'fetch',...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined,signal:controller.signal});if(!r.ok)throw new Error(`Request failed (${r.status})`);return await r.json();}finally{clearTimeout(timer);}
}
const wait=ms=>new Promise(r=>setTimeout(r,ms));
async function refreshAccounts(ids){
 if(!ids.length)return;
 ids.forEach(id=>attempts.set(id,Date.now()));
 const response=await api('quota/refresh',{auth_indexes:ids});
 const pending=new Set((response.tasks||[]).map(t=>t.authIndex));
 for(const item of response.rejected||[])messages.set(item.authIndex||item.auth_index,'Provider refresh was not accepted. Will retry.');
 const deadline=Date.now()+45000;
 while(pending.size&&Date.now()<deadline){
  await wait(1200);
  await Promise.all([...pending].map(async id=>{
   try{const task=await api('quota/refresh/'+encodeURIComponent(id));
    if(task.status==='completed'){pending.delete(id);if(/^(Provider refresh|Could not read refresh)/.test(messages.get(id)||''))messages.delete(id);}
    else if(['failed','error'].includes(task.status)){pending.delete(id);messages.set(id,'Provider refresh failed. Will retry automatically.');}
   }catch{pending.delete(id);messages.set(id,'Could not read refresh status. Will check again.');}
  }));
 }
 for(const id of pending)messages.set(id,'Provider refresh is still pending. Checking again shortly.');
}
function needsRefresh(cache){
 const now=Date.now(),observed=time(cache?.refreshed_at);
 return !observed||now-observed>5*60000||cache.status==='failed'||!cache.quota?.quota?.length||cache.quota.quota.some(r=>time(r.resetAt)!==null&&time(r.resetAt)<=now);
}
// Keeper's histories are per slot (primary/secondary); file them by window length.
async function loadHistories(id){
 const out={},base='quota/history/'+encodeURIComponent(id);
 const initial=await api(base,undefined,90000);
 const put=h=>{const k=windowKind(h?.selected_window?.window_seconds);if(k)out[k]=h;};
 put(initial);
 await Promise.all((initial.windows||[]).filter(w=>w.window_role!==initial.selected_window?.window_role).map(async w=>put(await api(base+'?window_role='+encodeURIComponent(w.window_role),undefined,90000))));
 return out;
}
const accountFrom=(a,index,cache,old)=>({id:a.identity,name:a.alias||a.displayName||a.name||`${a.provider} ${index+1}`,provider:a.provider||a.type,disabled:a.disabled,plan:cache?.quota?.subscription?.plan||old?.plan||'Unknown plan',cache:cache?.quota?cache:old?.cache,histories:{...old?.histories},historiesAt:old?.historiesAt||0,errors:[]});
async function load(forceIds=null){
 if(loading||resetBusy)return;
 clearTimeout(retryTimer);loading=true;$('refresh').disabled=true;$('updated').textContent='Checking accounts…';
 const spendDone=loadSpend();
 try{
  const all=(await api('usage/identities')).identities.filter(a=>!a.is_deleted);
  others=all.filter(a=>!['claude','codex'].includes(a.provider||a.type)).map(a=>({id:a.identity,provider:a.provider||a.type,disabled:a.disabled}));
  const identities=all.filter(a=>['claude','codex'].includes(a.provider||a.type));
  const ids=identities.map(a=>a.identity);
  let cached=ids.length?await api('quota/cache',{auth_indexes:ids}):{items:[]};
  const existing=new Map(data.map(a=>[a.id,a]));
  data=identities.map((a,i)=>accountFrom(a,i,cached.items?.find(c=>c.auth_index===a.identity),existing.get(a.identity)));renderAccounts();
  const refreshIds=forceIds===true?ids:forceIds||identities.filter(a=>!a.disabled&&needsRefresh(cached.items?.find(c=>c.auth_index===a.identity))&&Date.now()-(attempts.get(a.identity)||0)>60000).map(a=>a.identity);
  if(refreshIds.length){$('updated').textContent=`Fetching fresh limits for ${refreshIds.length} account(s)…`;try{await refreshAccounts(refreshIds);}catch{for(const id of refreshIds)messages.set(id,'Provider refresh failed. Will retry automatically.');}cached=await api('quota/cache',{auth_indexes:ids});}
  const previous=new Map(data.map(a=>[a.id,a]));
  data=identities.map((a,i)=>accountFrom(a,i,cached.items?.find(c=>c.auth_index===a.identity),previous.get(a.identity)));
  // Keeper takes seconds per history on a busy account: two at a time, every 5 minutes,
  // sooner for accounts just refreshed by hand. Live limits still come from the cache each minute.
  const due=data.filter(a=>forceIds===true||(Array.isArray(forceIds)&&forceIds.includes(a.id))||Date.now()-a.historiesAt>5*60000);
  const queue=due.map(a=>({a,tries:0}));render();
  // A failed history goes to the back of the queue once before the next minute's retry.
  await Promise.all([0,1].map(async()=>{for(let job;(job=queue.shift());){const {a}=job;try{a.histories=await loadHistories(a.id);a.historiesAt=Date.now();}catch{if(job.tries++<1)queue.push(job);else a.errors.push('History unavailable; retrying automatically.');}render();}}));
  $('error').hidden=true;$('updated').textContent='Updated '+fmtHour(Date.now());failures=0;
 }catch(e){failures++;$('error').textContent=e.message+'. Retrying automatically. Previous readings keep their original timestamps.';$('error').hidden=false;$('updated').textContent='Connection interrupted';}
 finally{await spendDone;loading=false;$('refresh').disabled=false;render();retryTimer=setTimeout(()=>load(),failures?Math.min(60000,10000*2**failures):60000);}
}
// Token history: all of it per day (Keeper's longest custom range, 365 days) and
// the last 24 hours per hour. The visible window picks from these locally.
async function loadSpend(){
 const now=Date.now();
 try{
  const [d,h]=await Promise.all([api(`usage/analysis?range=custom&start=${localDate(now-364*DAY)}&end=${localDate(now)}`,undefined,60000),api('usage/analysis?range=24h',undefined,60000)]);
  daily=d;hourly=h;spendError=null;if(comp)comp.stale=true;
 }catch(e){spendError=e.message;}
}
function seriesFrom(result,trim){
 const usage=result.token_usage||[],i0=trim?firstUsedIndex(usage):0,mu=result.model_usage||{buckets:[],series:[]};
 return {buckets:usage.slice(i0).map(b=>({...b,t:time(b.bucket)})),models:(mu.series||[]).map(s=>({model:s.model,values:(s.total_tokens||[]).slice(i0)}))};
}
function firstData(now){
 const d=daily?seriesFrom(daily,true).buckets[0]?.t:null;
 const q=Math.min(...data.flatMap(a=>Object.values(a.histories||{}).flatMap(h=>(h?.cycles||[]).map(c=>time(c.first_observed_at)).filter(Boolean))));
 const t=Math.min(d??Infinity,q);return Number.isFinite(t)?t:now-7*DAY;
}
function currentWindow(now){
 if(custom)return custom;
 return {start:past==='all'?firstData(now):now-RANGES[past].ms,end:now+AHEAD[ahead]};
}
// Tokens in the visible window: per hour inside the last day, else per day.
function spendFor(win,now){
 const lo=win.start,hi=Math.min(win.end,now);
 const useHourly=!!hourly&&hi-lo<=2*DAY&&lo>=now-25*HOUR,src=useHourly?hourly:daily;
 if(!src)return null;
 const s=seriesFrom(src,!useHourly),step=useHourly?HOUR:DAY;
 const idx=s.buckets.map((b,i)=>i).filter(i=>s.buckets[i].t+step>lo&&s.buckets[i].t<hi);
 return {lo,hi,step,hourly:useHourly,buckets:idx.map(i=>s.buckets[i]),
  stacks:modelStacks({buckets:idx,series:s.models.map(m=>({model:m.model,total_tokens:idx.map(i=>m.values[i])}))})};
}
// By-account and by-model totals for the visible days, fetched after the window settles.
function composition(view){
 if(view.hourly)return {credentials:hourly.credentials_composition||[],models:hourly.model_composition||[]};
 const start=localDate(Math.max(view.lo,Date.now()-364*DAY)),end=localDate(view.hi),key=`${start}_${end}`;
 if(comp?.key===key&&!comp.stale)return comp;
 clearTimeout(compTimer);
 compTimer=setTimeout(async()=>{const seq=++compSeq;try{const r=await api(`usage/analysis?range=custom&start=${start}&end=${end}`,undefined,60000);if(seq!==compSeq)return;comp={key,credentials:r.credentials_composition||[],models:r.model_composition||[]};scheduleRender();}catch{}},350);
 return comp?{...comp,updating:true}:null;
}
function weeklyGroups(now){
 return ['claude','codex'].map(p=>{
  const scales=pointScales(data.filter(a=>a.provider===p),'weekly');
  const accounts=data.filter(a=>!a.disabled&&a.provider===p).map(a=>accountState(a,'weekly',now));
  const known=accounts.filter(a=>!a.stale&&a.remaining!==null);
  const tokens=known.every(a=>scales.get(a.id))?known.reduce((n,a)=>n+a.remaining*scales.get(a.id).value,0):null;
  return {p,accounts,known,tokens,left:known.reduce((n,a)=>n+a.remaining,0)/100,next:known.map(a=>a.reset).filter(t=>t>now).sort((a,b)=>a-b)[0]};
 }).filter(g=>g.accounts.length);
}
const windowName=(win,now)=>custom?`${fmtDay(win.start)} – ${fmtDay(Math.min(win.end,now))}`:past==='all'?'all time':'last '+RANGES[past].label;
function renderKpis(view,win,now){
 const cards=[];
 if(view){
  const b=view.buckets,total=b.reduce((n,x)=>n+(x.total_tokens||0),0),requests=b.reduce((n,x)=>n+(x.requests||0),0),output=b.reduce((n,x)=>n+(x.output_tokens||0),0),cache=b.reduce((n,x)=>n+(x.cache_read_tokens||0),0);
  const used=b.filter(x=>(x.total_tokens||0)>0),peak=b.reduce((m,x)=>!m||(x.total_tokens||0)>(m.total_tokens||0)?x:m,null);
  const u=view.hourly?'hour':'day',avg=used.length?total/used.length:0;
  cards.push(`<article class="stat"><small>Tokens · ${esc(windowName(win,now))}</small><strong>${tok(total)}</strong><p>${tok(cache)} cache reads · ${tok(output)} output</p></article>`);
  cards.push(`<article class="stat"><small>Requests</small><strong>${requests.toLocaleString()}</strong><p>${b.length?`from ${view.hourly?fmt(b[0].t):fmtDay(b[0].t)}`:'none in view'}</p></article>`);
  cards.push(`<article class="stat"><small>Average per active ${u}</small><strong>${tok(avg)}</strong><p>${used.length} active ${u}${used.length===1?'':'s'}</p></article>`);
  cards.push(`<article class="stat"><small>Busiest ${u}</small><strong>${peak?.total_tokens?tok(peak.total_tokens):'—'}</strong><p>${peak?.total_tokens?(view.hourly?fmt(peak.t):fmtWeekday(peak.t)):'No usage in view'}</p></article>`);
 }else cards.push(`<article class="stat"><small>Tokens</small><strong>…</strong><p>${esc(spendError?spendError+'. Retrying.':'Loading')}</p></article>`);
 for(const g of weeklyGroups(now)){
  cards.push(`<article class="stat" style="--series:${palette[g.p][0]}"><small>${providerName(g.p)} left this week</small><strong>${g.known.length?(g.tokens!==null?'≈'+tok(g.tokens):num(g.left*100)+'%'):'—'}<span> tokens</span></strong><p>${num(g.left)} of ${g.accounts.length} account${g.accounts.length===1?'':'s'} · ${g.known.length!==g.accounts.length?`${g.accounts.length-g.known.length} without a current reading · `:''}next reset ${g.next?fmt(g.next):'not reported'}</p></article>`);
 }
 $('kpis').innerHTML=cards.join('');
}
function node(tag,attrs={},text){const el=document.createElementNS(NS,tag);for(const [k,v]of Object.entries(attrs))el.setAttribute(k,v);if(text!==undefined)el.textContent=text;return el;}
function niceMax(v){if(!(v>0))return 1;const e=10**Math.floor(Math.log10(v)),f=v/e;return (f<=1?1:f<=2?2:f<=2.5?2.5:f<=5?5:10)*e;}
function timeTicks(svg,d0,d1,x,H,W){
 const n=W<600?3:6,span=d1-d0;
 for(let i=0;i<=n;i++){const t=d0+span*i/n;svg.append(node('text',{x:x(t),y:H-10,'text-anchor':i===0?'start':i===n?'end':'middle'},span>3*DAY?fmtDay(t):span>DAY?fmt(t):fmtHour(t)));}
}
let renderQueued=false;
function scheduleRender(){if(renderQueued)return;renderQueued=true;requestAnimationFrame(()=>{renderQueued=false;renderCharts();});}
// Timeline strip: all token history per day plus the look-ahead. The bright
// window is what every panel shows; drag it, drag its edges, or drag elsewhere.
let navDrag=null;
function navExtent(win,now){return {start:Math.min(firstData(now),win.start),end:Math.max(now+AHEAD[ahead],win.end,now+HOUR)};}
function renderNav(win,now){
 const svg=$('nav'),W=Math.max(300,svg.clientWidth||1100),H=46;svg.replaceChildren();svg.setAttribute('viewBox',`0 0 ${W} ${H}`);
 const ext=navDrag?.ext||navExtent(win,now),x=t=>(t-ext.start)/(ext.end-ext.start)*W,barH=30;
 svg.append(node('rect',{x:0,y:0,width:W,height:barH,fill:'#14171a',rx:4}));
 if(now<ext.end)svg.append(node('rect',{x:x(now),y:0,width:W-x(now),height:barH,fill:'#ffffff08'}));
 const b=daily?seriesFrom(daily,true).buckets:[],max=Math.max(1,...b.map(v=>v.total_tokens||0));
 for(const v of b){if(!v.total_tokens)continue;const h=(v.total_tokens/max)*(barH-4);svg.append(node('rect',{x:x(v.t)+.5,width:Math.max(1,x(v.t+DAY)-x(v.t)-1),y:barH-h,height:h,fill:'#56657a'}));}
 svg.append(node('line',{x1:x(now),x2:x(now),y1:0,y2:barH,stroke:'#a4b1bc','stroke-dasharray':'2 3'}));
 const n=W<600?3:6;for(let i=0;i<=n;i++){const t=ext.start+(ext.end-ext.start)*i/n;svg.append(node('text',{x:x(t),y:H-2,'text-anchor':i===0?'start':i===n?'end':'middle'},fmtDay(t)));}
 const x0=Math.max(0,x(win.start)),x1=Math.min(W,x(win.end));
 svg.append(node('rect',{x:x0,y:0,width:Math.max(2,x1-x0),height:barH,fill:'#c5d1e01f',stroke:'#c5d1e0','stroke-width':1.5,rx:3}));
 for(const hx of [x0,x1])svg.append(node('rect',{x:hx-3,y:7,width:6,height:barH-14,rx:2,fill:'#c5d1e0'}));
 svg._nav={ext,W};
}
function navPointer(e){const svg=$('nav'),r=svg.getBoundingClientRect(),{ext,W}=svg._nav;const px=(e.clientX-r.left)/r.width*W;return {px,t:ext.start+px/W*(ext.end-ext.start),pxPerMs:W/(ext.end-ext.start)};}
$('nav').addEventListener('pointerdown',e=>{
 const now=Date.now(),win=currentWindow(now),p=navPointer(e),{ext}=$('nav')._nav,x=t=>(t-ext.start)*p.pxPerMs;
 const mode=Math.abs(p.px-x(win.start))<10?'start':Math.abs(p.px-x(win.end))<10?'end':p.t>win.start&&p.t<win.end?'move':'new';
 navDrag={mode,t0:p.t,win0:{...win},ext};$('nav').setPointerCapture(e.pointerId);
 if(mode==='new'){custom={start:p.t,end:p.t+HOUR};navDrag.mode='end';navDrag.win0=custom;}
 e.preventDefault();
});
$('nav').addEventListener('pointermove',e=>{
 if(!navDrag)return;const p=navPointer(e),d=p.t-navDrag.t0,{win0,ext}=navDrag,min=3*HOUR;
 let s=win0.start,en=win0.end;
 if(navDrag.mode==='move'){const span=en-s;s=Math.min(Math.max(ext.start,s+d),ext.end-span);en=s+span;}
 else if(navDrag.mode==='start')s=Math.min(Math.max(ext.start,s+d),en-min);
 else en=Math.max(Math.min(ext.end,en+d),s+min);
 custom={start:s,end:en};scheduleRender();
});
const navEnd=()=>{if(navDrag){navDrag=null;scheduleRender();}};
$('nav').addEventListener('pointerup',navEnd);$('nav').addEventListener('pointercancel',navEnd);
// Mouse on a chart: drag to move through time, pinch or Ctrl+wheel to zoom, double-click to reset.
let panning=null;
function attachPanZoom(svg){
 svg.addEventListener('pointerdown',e=>{if(e.pointerType!=='mouse'||e.button!==0||!svg._map)return;e.preventDefault();panning={svg,x0:e.clientX,win0:currentWindow(Date.now()),map:svg._map,moved:false};svg.setPointerCapture(e.pointerId);});
 svg.addEventListener('pointermove',e=>{
  if(!panning||panning.svg!==svg)return;const dx=e.clientX-panning.x0;if(!panning.moved&&Math.abs(dx)<4)return;panning.moved=true;svg.style.cursor='grabbing';
  const {d0,d1,L,R,W}=panning.map,r=svg.getBoundingClientRect(),dt=-dx/(r.width*(W-L-R)/W)*(d1-d0);
  custom={start:panning.win0.start+dt,end:panning.win0.end+dt};scheduleRender();
 });
 const end=()=>{if(panning?.svg===svg){panning=null;svg.style.cursor='';}};
 svg.addEventListener('pointerup',end);svg.addEventListener('pointercancel',end);
 svg.addEventListener('wheel',e=>{
  if(!(e.ctrlKey||e.metaKey)||!svg._map)return;e.preventDefault();
  const {d0,d1,L,R,W}=svg._map,r=svg.getBoundingClientRect(),tc=d0+((e.clientX-r.left)/r.width*W-L)/(W-L-R)*(d1-d0);
  const win=currentWindow(Date.now()),f=Math.exp(Math.max(-1,Math.min(1,e.deltaY*0.002)));
  let s=tc-(tc-win.start)*f,en=tc+(win.end-tc)*f;if(en-s<3*HOUR){const c=(s+en)/2;s=c-1.5*HOUR;en=c+1.5*HOUR;}if(en-s>400*DAY)return;
  custom={start:s,end:en};scheduleRender();
 },{passive:false});
 svg.addEventListener('dblclick',()=>{custom=null;scheduleRender();});
}
function renderSpend(view){
 const svg=$('spend');svg.replaceChildren();$('spend-tip').hidden=true;svg._map=null;
 if(!view){$('spend-note').textContent=spendError?`Could not load token history: ${spendError}. Retrying.`:'Loading token history…';$('spend-legend').innerHTML='';$('by-account').innerHTML='';$('by-model').innerHTML='';return;}
 const {buckets,stacks,step}=view,n=buckets.length,d0=view.lo,d1=view.hi;
 $('spend-note').textContent=`${view.hourly?'Per hour':'Per day'} · split by model${mode==='total'?' · running total from the start of the view':''}`;
 $('spend-legend').innerHTML=stacks.map((s,i)=>`<span><i class="sw" style="background:${modelColors[i%modelColors.length]}"></i>${esc(s.model)} <b>${tok(s.total)}</b></span>`).join('');
 const W=Math.max(300,svg.clientWidth||1100),H=W<600?240:300,L=W<600?44:56,R=10,T=14,B=30;svg.setAttribute('viewBox',`0 0 ${W} ${H}`);
 if(d1<=d0){svg.append(node('text',{x:L,y:T+40},'The view is all in the future; tokens appear up to now.'));return;}
 svg._map={d0,d1,L,R,W};
 const x=t=>L+(Math.min(Math.max(t,d0),d1)-d0)/(d1-d0)*(W-L-R);
 const values=stacks.map(s=>buckets.map((_,i)=>s.values[i]||0));
 if(mode==='total')for(const v of values)for(let i=1;i<n;i++)v[i]+=v[i-1];
 const totals=buckets.map((_,i)=>values.reduce((t,v)=>t+v[i],0));
 const max=niceMax(Math.max(0,...totals)),y=v=>H-B-v/max*(H-T-B);
 for(let k=0;k<=4;k++){const v=max*k/4;svg.append(node('line',{x1:L,x2:W-R,y1:y(v),y2:y(v),stroke:'#2b3036'}),node('text',{x:L-8,y:y(v)+4,'text-anchor':'end'},tok(v)));}
 timeTicks(svg,d0,d1,x,H,W);
 if(!n){svg.append(node('text',{x:L+8,y:T+40},'No usage recorded in this window.'));}
 else if(mode==='bars'){
  for(let i=0;i<n;i++){const a=x(buckets[i].t),b=x(buckets[i].t+step),gap=Math.min(6,(b-a)*.2);let base=0;values.forEach((v,s)=>{if(!v[i])return;svg.append(node('rect',{x:a+gap/2,width:Math.max(1,b-a-gap),y:y(base+v[i]),height:Math.max(.5,y(base)-y(base+v[i])),fill:modelColors[s%modelColors.length]}));base+=v[i];});}
 }else{
  const cx=i=>x(buckets[i].t+step/2);let lower=buckets.map(()=>0);
  values.forEach((v,s)=>{const upper=lower.map((b,i)=>b+v[i]);const pts=upper.map((u,i)=>`${cx(i)},${y(u)}`).concat(lower.map((b,i)=>`${cx(i)},${y(b)}`).reverse());svg.append(node('polygon',{points:pts.join(' '),fill:modelColors[s%modelColors.length],opacity:.9}));lower=upper;});
 }
 const hover=node('rect',{x:0,y:T,width:0,height:H-T-B,fill:'#ffffff10',visibility:'hidden'});svg.append(hover);
 svg.onpointermove=e=>{
  if(panning?.moved)return;
  const rect=svg.getBoundingClientRect(),t=d0+((e.clientX-rect.left)/rect.width*W-L)/(W-L-R)*(d1-d0),i=buckets.findIndex(b=>t>=b.t&&t<b.t+step);
  if(i<0){hover.setAttribute('visibility','hidden');$('spend-tip').hidden=true;return;}
  hover.setAttribute('x',x(buckets[i].t));hover.setAttribute('width',x(buckets[i].t+step)-x(buckets[i].t));hover.setAttribute('visibility','visible');
  const b=buckets[i],label=view.hourly?`${fmtWeekday(b.t)} ${fmtHour(b.t)}–${fmtHour(b.t+step)}`:fmtWeekday(b.t);
  const lines=stacks.map((s,k)=>({m:s.model,v:values[k][i]})).filter(l=>l.v>0).map(l=>`${l.m}: ${tok(l.v)}`);
  $('spend-tip').textContent=`${label}${mode==='total'?' · running total':''}\n${tok(totals[i])} tokens${mode==='bars'?` · ${reqs(b.requests)}`:''}\n${lines.join('\n')}`;
  $('spend-tip').hidden=false;$('spend-tip').style.left=Math.min(Math.max(0,e.clientX-rect.left+12),Math.max(0,rect.width-240))+'px';
 };svg.onpointerleave=()=>{hover.setAttribute('visibility','hidden');$('spend-tip').hidden=true;};
 const c=composition(view);
 if(!c){$('by-account').innerHTML=$('by-model').innerHTML='<p class="empty">Loading…</p>';return;}
 const note=c.updating?' <span class="subtle">· updating</span>':'';
 const accounts=c.credentials.filter(x=>x.total_tokens>0),maxA=Math.max(1,...accounts.map(x=>x.total_tokens));
 $('by-account').innerHTML=accounts.map(cr=>{const a=[...data,...others].find(a=>maskedMatch(cr.key,a.id));return `<div class="share"><div><span class="provider ${a?.provider||''}">${esc(providerName(a?.provider))}</span>${esc(cr.label)}${a?.disabled?' <span class="subtle">· disabled</span>':''}</div><b>${tok(cr.total_tokens)}</b><div class="bar"><span style="width:${cr.total_tokens/maxA*100}%"></span></div><small>${reqs(cr.requests)} · ${num(cr.percent||0)}%</small></div>`;}).join('')+note||'<p class="empty">No usage in this window.</p>';
 const models=c.models.filter(m=>m.total_tokens>0),maxM=Math.max(1,...models.map(m=>m.total_tokens));
 $('by-model').innerHTML=models.map(m=>`<div class="share"><div>${esc(m.label)}</div><b>${tok(m.total_tokens)}</b><div class="bar"><span style="width:${m.total_tokens/maxM*100}%"></span></div><small>${reqs(m.requests)} · ${num(m.percent||0)}%</small></div>`).join('')+note||'<p class="empty">No usage in this window.</p>';
}
// Accounts of one provider with their remaining allowance in the chosen unit.
function poolAccounts(provider,k,now){
 const all=data.filter(a=>a.provider===provider),scales=pointScales(all,k);
 const scaleOf=a=>unit==='tokens'?scales.get(a.id)?.value??null:1;
 const counters={claude:0,codex:0};
 const states=all.map(a=>({...accountState(a,k,now),scale:scaleOf(a),scaleSource:scales.get(a.id)?.source,color:palette[a.provider][counters[a.provider]++%5]}));
 return {all:states,enabled:states.filter(a=>!a.disabled&&a.scale)};
}
const amount=v=>unit==='tokens'?tok(v):`${num(v)}%`;
function renderAllowance(now,win){
 const lookback=Number($('lookback').value)*HOUR,provider=$('pool').value,pace=Number($('pace').value)/100;
 $('pace-value').textContent=`at ${pace}× the pace`;
 const {all,enabled}=poolAccounts(provider,kind,now);
 // No usable time in the chosen window (everything empty) widens it until there is.
 let rate=null,used=lookback;
 for(const h of [lookback,72*HOUR,168*HOUR,720*HOUR].filter(h=>h>=lookback)){rate=pooledRate(all,now,h,a=>a.scale);used=h;if(rate)break;}
 const usedLabel=used>=48*HOUR?`${Math.round(used/DAY)} days`:`${Math.round(used/HOUR)} hours`;
 const perHour=rate?rate.perHour*pace:0;
 const d0=win.start,d1=win.end,fEnd=Math.max(now+AHEAD[ahead],d1);
 const earliest=Math.min(...enabled.flatMap(a=>a.points.map(p=>p.t)),now);
 const h0=Math.max(d0,earliest),h1=Math.min(d1,now);
 const history=h1>h0?stackHistory(enabled,h0,h1):[],forecast=fEnd>now?forecastStack(enabled,now,fEnd,perHour,WINDOWS[kind]):[];
 const total=s=>s.values.reduce((n,v)=>n+(v??0),0);
 const nowState={values:enabled.map(a=>a.remaining===null||a.stale?null:a.remaining*a.scale)},current=total(nowState);
 const unitNote=unit==='tokens'?'tokens, estimated from what 1% of each account bought in its latest cycle':'percent of one account; 100% = one full allowance';
 $('chart-note').textContent=`${providerName(provider)} · ${kind==='short'?'5-hour':'weekly'} allowance of every enabled account, stacked · ${unitNote}`;
 // Plain-language outlook from now: how long what is left lasts, and the next refills.
 const zero=current>0&&forecast.find(p=>!p.reset&&total(p)===0&&p.t>now),refills=[];
 for(let i=1;i<forecast.length;i++)if(forecast[i].reset)forecast[i].values.forEach((v,k)=>{const d=v-forecast[i-1].values[k];if(d>0)refills.push({t:forecast[i].t,a:enabled[k],d});});
 const nextRefills=refills.slice(0,3).map(r=>`${fmt(r.t)} +${amount(r.d)} (${esc(r.a.name)})`);
 $('outlook').innerHTML=`<strong>${amount(current)}</strong> left now${rate?` · pace ${amount(rate.perHour)}/hour over the last ${usedLabel}${used!==lookback?' (nothing could be used in the chosen window)':''}${pace!==1?` × ${pace}`:''}`:' · no measured pace yet'}${zero?` · runs out ${fmt(zero.t)}`:current>0&&rate&&AHEAD[ahead]>0?' · lasts past the look-ahead':''}${nextRefills.length?`<br>Next refills: ${nextRefills.join(' · ')}`:AHEAD[ahead]?'':'<br>Pick a look-ahead at the top to see refills and the expected use.'}`;
 $('legend').innerHTML=enabled.map(a=>`<span><i class="sw" style="background:${a.color}"></i>${esc(a.name)} <b class="${a.remaining===0?'warning':''}">${a.remaining===null||a.stale?'no reading':`${num(a.remaining)}%`}${unit==='tokens'&&a.remaining?` · ${tok(a.remaining*a.scale)}`:''}</b>${unit==='tokens'&&a.scaleSource!=='own'?' <small>(typical rate)</small>':''}</span>`).join('')+(all.filter(a=>!a.disabled&&!a.scale).length?`<span>${all.filter(a=>!a.disabled&&!a.scale).length} account(s) without a token rate yet</span>`:'')||'<span>No enabled accounts.</span>';
 const svg=$('chart');svg.replaceChildren();$('tooltip').hidden=true;
 const W=Math.max(300,svg.clientWidth||1100),H=W<600?280:360,L=W<600?46:58,R=12,T=24,B=30;svg.setAttribute('viewBox',`0 0 ${W} ${H}`);
 svg._map={d0,d1,L,R,W};
 const inView=forecast.filter((p,i)=>(p.t>=d0&&p.t<=d1)||(forecast[i+1]&&p.t<d0&&forecast[i+1].t>d0));
 const max=niceMax(Math.max(...history.map(total),...inView.map(total),1e-9)),x=t=>L+(t-d0)/(d1-d0)*(W-L-R),y=v=>H-B-v/max*(H-T-B);
 for(let k=0;k<=4;k++){const v=max*k/4;svg.append(node('line',{x1:L,x2:W-R,y1:y(v),y2:y(v),stroke:'#2b3036'}),node('text',{x:L-8,y:y(v)+4,'text-anchor':'end'},amount(v)));}
 timeTicks(svg,d0,d1,x,H,W);
 const clip=node('clipPath',{id:'plot-clip'});clip.append(node('rect',{x:L,y:0,width:W-L-R,height:H}));svg.append(clip);
 const g=node('g',{'clip-path':'url(#plot-clip)'});svg.append(g);
 if(now<d1)g.append(node('rect',{x:x(now),y:T,width:x(d1)-x(now),height:H-T-B,fill:'#ffffff06'}));
 // Stacked areas, one band per account; the top edge is everything you can still spend.
 const bands=(series,opacity)=>{let lower=series.map(()=>0);enabled.forEach((a,k)=>{const upper=series.map((s,i)=>lower[i]+(s.values[k]??0));if(upper.some((u,i)=>u>lower[i])){const pts=series.map((s,i)=>`${x(s.t).toFixed(1)},${y(upper[i]).toFixed(1)}`).concat(series.map((s,i)=>`${x(s.t).toFixed(1)},${y(lower[i]).toFixed(1)}`).reverse());g.append(node('polygon',{points:pts.join(' '),fill:a.color,opacity}));}lower=upper;});};
 const line=(series,attrs)=>g.append(node('path',{d:series.map((s,i)=>`${i?'L':'M'}${x(s.t).toFixed(1)},${y(total(s)).toFixed(1)}`).join(' '),fill:'none','stroke-linejoin':'round',...attrs}));
 if(history.length){bands(history,.55);line(history,{stroke:'#eff4f6','stroke-width':2});}
 if(forecast.length>1){bands(forecast,.3);line(forecast,{stroke:'#eff4f6','stroke-width':2,'stroke-dasharray':'6 5'});}
 if(now>=d0&&now<=d1)g.append(node('line',{x1:x(now),x2:x(now),y1:T-6,y2:H-B,stroke:'#a4b1bc','stroke-dasharray':'3 5'}),node('text',{x:x(now)+5,y:T-10},'now'));
 if(!history.some(s=>total(s)>0)&&!inView.some(s=>total(s)>0))svg.append(node('text',{x:L+8,y:T+40},enabled.length?'Nothing left in this window.':'No quota history in this window.'));
 const series=[...history.map(s=>({...s,kind:'Observed'})),...forecast.filter(s=>s.t>=d0&&s.t<=d1).map(s=>({...s,kind:'Expected'}))];
 const hover=node('line',{y1:T,y2:H-B,stroke:'#ffffff40',visibility:'hidden'});svg.append(hover);
 svg.onpointermove=e=>{
  if(panning?.moved)return;
  const rect=svg.getBoundingClientRect(),t=d0+((e.clientX-rect.left)/rect.width*W-L)/(W-L-R)*(d1-d0);
  const s=series.reduce((b,p)=>!b||Math.abs(p.t-t)<Math.abs(b.t-t)?p:b,null);if(!s)return;
  hover.setAttribute('x1',x(s.t));hover.setAttribute('x2',x(s.t));hover.setAttribute('visibility','visible');
  $('tooltip').hidden=false;$('tooltip').textContent=`${s.kind} · ${fmt(s.t)}\n${amount(total(s))} left in total\n${enabled.map((a,k)=>`${a.name}: ${s.values[k]===null?'no reading':amount(s.values[k])}`).join('\n')}`;
  $('tooltip').style.left=Math.min(Math.max(0,e.clientX-rect.left+12),Math.max(0,rect.width-260))+'px';
 };svg.onpointerleave=()=>{hover.setAttribute('visibility','hidden');$('tooltip').hidden=true;};
}
function renderCycles(win){
 const rows=data.flatMap(a=>cycleSummaries(a.histories?.weekly).filter(c=>(c.end===null||c.end>=win.start)&&c.start<=win.end).map(c=>({a,...c}))).sort((x,y)=>y.start-x.start||x.a.name.localeCompare(y.a.name));
 $('cycles').innerHTML=rows.length?`<div class="table"><table><thead><tr><th>Account</th><th>Week</th><th>Used</th><th>Tokens</th><th>Tokens per 1%</th></tr></thead><tbody>${rows.map(r=>`<tr><td><span class="provider ${r.a.provider}">${providerName(r.a.provider)}</span>${esc(r.a.name)}${r.a.disabled?' <span class="subtle">· disabled</span>':''}</td><td data-l="Week">${fmt(r.start)} → ${fmt(r.end)}${r.status==='current'?' <span class="badge">current</span>':''}</td><td data-l="Used"><div class="used"><div class="bar"><span style="width:${Math.min(100,r.used)}%"></span></div>${r.used}%${r.status==='current'&&r.remaining!==null?` <span class="subtle">· ${num(r.remaining)}% left</span>`:''}</div></td><td data-l="Tokens">${tok(r.tokens)}</td><td data-l="Tokens per 1%">${r.perPoint?tok(r.perPoint):'—'}</td></tr>`).join('')}</tbody></table></div>`:'<p class="empty">No weekly cycles in this window.</p>';
}
function renderCharts(){
 const now=Date.now(),win=currentWindow(now),view=spendFor(win,now);
 document.querySelectorAll('[data-range]').forEach(b=>b.classList.toggle('active',!custom&&b.dataset.range===past));
 document.querySelectorAll('[data-ahead]').forEach(b=>b.classList.toggle('active',!custom&&b.dataset.ahead===ahead));
 $('window-label').textContent=`${fmt(win.start)} → ${fmt(win.end)}`;$('reset-view').hidden=!custom;
 renderNav(win,now);renderKpis(view,win,now);renderSpend(view);renderAllowance(now,win);renderCycles(win);
}
function render(){renderCharts();renderAccounts();}
function rowCard(row,observed){
 const remaining=percent(typeof row.usedPercent==='number'?100-row.usedPercent:typeof row.remainingFraction==='number'?row.remainingFraction*100:null);
 const reset=time(row.resetAt),stale=!observed||Date.now()-observed>15*60000||(reset!==null&&reset<=Date.now());
 const status=remaining===null?'Not reported':row.active===false?'Inactive':row.allowed===false?'Restricted':stale?'Stale reading':remaining===0?'Depleted':'Remaining';
 return `<div class="limit"><div class="limit-heading"><span>${esc(row.label||row.key)}</span><span class="subtle">${esc(status)}</span></div><strong class="${remaining===0?'warning':''}">${remaining===null?'Not reported':num(remaining)+'%'}${remaining!==null?'<small> left</small>':''}</strong><div class="bar"><span style="width:${remaining??0}%;${row.active===false?'background:var(--muted)':''}"></span></div><p>Resets ${fmt(reset)}</p></div>`;
}
function renderAccounts(){
 const now=Date.now();$('coverage').textContent=`${data.length} accounts · every reported limit`;
 $('accounts').innerHTML=data.map(a=>{
  const q=a.cache?.quota,rows=[...(q?.quota||[])],observed=time(a.cache?.refreshed_at);
  for(const k of ['short','weekly'])if(!rows.some(r=>r.window?.seconds===WINDOWS[k]&&r.scope!=='model'))rows.unshift({key:k,label:k==='short'?'5 hours':'Weekly'});
  const grants=q?.claudeResetGrants,credit=q?.rateLimitResetCreditsAvailableCount;
  return `<article class="account"><div class="account-heading"><div><h3><span class="provider ${a.provider}">${providerName(a.provider)}</span>${esc(a.name)}</h3><p>${esc(a.plan)}${a.disabled?' · Disabled':''} · Updated ${fmt(observed)}${observed&&now-observed>15*60000?' · stale':''}</p></div><div class="account-actions"><button data-refresh="${esc(a.id)}" ${loading||resetBusy?'disabled':''}>Refresh limits</button><button data-reset="${esc(a.id)}" ${resetBusy||loading?'disabled':''}>Reset usage${a.provider==='claude'&&grants?' · '+grants.availableCount:a.provider==='codex'&&typeof credit==='number'?' · '+credit:''}</button></div></div><div class="limits">${rows.map(r=>rowCard(r,observed)).join('')}</div>${grants?.grants?.length?`<p class="grant-note">${grants.grants.map(g=>`${esc(g.label)}: ${g.resetsLeft}/${g.resetsTotal} left${g.usableNow?' · available now':' · unavailable now'}`).join('<br>')}</p>`:''}<p class="account-message" role="status">${esc(messages.get(a.id)||a.errors.join(' '))}</p></article>`;
 }).join('')||'<p class="empty">No accounts loaded yet. Retrying automatically.</p>';
}
async function resetAccount(id){
 if(resetBusy||loading)return;resetBusy=true;renderAccounts();const a=data.find(a=>a.id===id);
 try{
  const body={auth_index:id};
  if(a.provider==='claude'){
   const info=await api('quota/claude-reset-grants/'+encodeURIComponent(id));
   const grants=(info.status?.grants||[]).filter(g=>g.usableNow&&g.resetsLeft>0&&!g.paused);
   if(!grants.length){messages.set(id,'No reset grant is usable now. '+(info.status?.grants||[]).map(g=>`${g.label}: ${g.resetsLeft} left${g.useRequiresLimit?' (requires hitting its limit)':''}`).join(' '));return;}
   // Present every usable grant; never silently choose one when there are several.
   const dialog=$('reset-dialog'),choices=$('reset-grant');
   choices.innerHTML=grants.map(g=>`<option value="${esc(g.id)}">${esc(g.label)} · ${g.resetsLeft} left · clears ${esc(g.clears.map(k=>k==='seven_day_overage_included'?'Fable allowance':k.replaceAll('_',' ')).join(', '))}</option>`).join('');
   $('reset-account-name').textContent=a.name;dialog.returnValue='';dialog.showModal();
   const confirmed=await new Promise(resolve=>dialog.addEventListener('close',()=>resolve(dialog.returnValue==='confirm'),{once:true}));
   if(!confirmed)return;body.grant_id=choices.value;body.organization_id=info.organizationId;
  }else{
   const info=await api('quota/reset-credits/'+encodeURIComponent(id));
   if(!(info.availableCount>0)){messages.set(id,'No reset credits available for this account.');return;}
   if(!confirm(`Use one of ${info.availableCount} provider reset credits for ${a.name}?`))return;
  }
  // Never retry a reset: a lost response can still mean the credit was consumed.
  const result=await api('quota/reset',body);
  messages.set(id,result.code==='reset'?`Usage reset.${result.recoveryFailed?' Routing recovery failed; check account management.':''}`:`Provider result: ${result.code||'unknown'}. Check the refreshed limits before trying again.`);
 }catch(e){messages.set(id,`${e.message}. Reset outcome may be unknown; check limits and credits before trying again.`);}
 finally{resetBusy=false;renderAccounts();await load([id]);}
}
$('accounts').onclick=e=>{const b=e.target.closest('button');if(b?.dataset.refresh)load([b.dataset.refresh]);if(b?.dataset.reset)resetAccount(b.dataset.reset);};
for(const id of ['pool','lookback'])$(id).onchange=scheduleRender;
$('pace').oninput=scheduleRender;$('refresh').onclick=()=>load(true);
const saveView=()=>{localStorage.setItem('runway-range',past);localStorage.setItem('runway-ahead',ahead);history.replaceState(null,'',`#past=${past}&ahead=${ahead}`);};
for(const b of document.querySelectorAll('[data-range]'))b.onclick=()=>{past=b.dataset.range;custom=null;saveView();scheduleRender();};
for(const b of document.querySelectorAll('[data-ahead]'))b.onclick=()=>{ahead=b.dataset.ahead;custom=null;saveView();scheduleRender();};
$('reset-view').onclick=()=>{custom=null;scheduleRender();};
window.addEventListener('hashchange',()=>{const h=hashState();if(RANGES[h.past])past=h.past;if(AHEAD[h.ahead]!==undefined)ahead=h.ahead;custom=null;scheduleRender();});
attachPanZoom($('spend'));attachPanZoom($('chart'));
for(const b of document.querySelectorAll('[data-mode]'))b.onclick=()=>{mode=b.dataset.mode;document.querySelectorAll('[data-mode]').forEach(x=>x.classList.toggle('active',x===b));scheduleRender();};
for(const b of document.querySelectorAll('[data-unit]'))b.onclick=()=>{unit=b.dataset.unit;document.querySelectorAll('[data-unit]').forEach(x=>x.classList.toggle('active',x===b));scheduleRender();};
for(const b of document.querySelectorAll('[data-kind]'))b.onclick=()=>{kind=b.dataset.kind;document.querySelectorAll('[data-kind]').forEach(x=>x.classList.toggle('active',x===b));scheduleRender();};
let resizeTimer;window.addEventListener('resize',()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(render,100);});
window.addEventListener('online',()=>load());document.addEventListener('visibilitychange',()=>{if(!document.hidden)load();});
render();load();
