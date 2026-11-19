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
let range=RANGES[location.hash.slice(1)]?location.hash.slice(1):RANGES[localStorage.getItem('runway-range')]?localStorage.getItem('runway-range'):'7d';
let others=[],data=[],spend=null,spendError=null,loading=false,kind='weekly',unit='tokens',mode='bars',retryTimer,failures=0,resetBusy=false,spendSeq=0;
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
  const queue=[...due];render();
  await Promise.all([0,1].map(async()=>{for(let a;(a=queue.shift());){try{a.histories=await loadHistories(a.id);a.historiesAt=Date.now();}catch{a.errors.push('History unavailable; retrying automatically.');}render();}}));
  $('error').hidden=true;$('updated').textContent='Updated '+fmtHour(Date.now());failures=0;
 }catch(e){failures++;$('error').textContent=e.message+'. Retrying automatically. Previous readings keep their original timestamps.';$('error').hidden=false;$('updated').textContent='Connection interrupted';}
 finally{await spendDone;loading=false;$('refresh').disabled=false;render();retryTimer=setTimeout(()=>load(),failures?Math.min(60000,10000*2**failures):60000);}
}
async function loadSpend(){
 const seq=++spendSeq,now=Date.now();
 // "All time" asks Keeper for its longest supported custom range and trims empty days.
 const query=range==='all'?`range=custom&start=${localDate(now-364*DAY)}&end=${localDate(now)}`:`range=${range}`;
 try{const result=await api('usage/analysis?'+query);if(seq!==spendSeq)return;spend={range,result};spendError=null;}
 catch(e){if(seq!==spendSeq)return;spendError=e.message;}
}
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
// The selected token range, trimmed to recorded days for "All time".
function spendView(){
 if(!spend||spend.range!==range)return null;
 const r=spend.result,usage=r.token_usage||[],i0=range==='all'?firstUsedIndex(usage):0;
 const buckets=usage.slice(i0).map(b=>({...b,t:time(b.bucket)}));
 const mu=r.model_usage||{buckets:[],series:[]};
 const stacks=modelStacks({buckets:(mu.buckets||[]).slice(i0),series:(mu.series||[]).map(s=>({...s,total_tokens:(s.total_tokens||[]).slice(i0)}))});
 const hourly=r.granularity==='hourly';
 return {buckets,stacks,hourly,step:hourly?HOUR:DAY,credentials:r.credentials_composition||[],models:r.model_composition||[]};
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
function renderKpis(view,now){
 const cards=[];
 if(view){
  const b=view.buckets,total=b.reduce((n,x)=>n+(x.total_tokens||0),0),requests=b.reduce((n,x)=>n+(x.requests||0),0),output=b.reduce((n,x)=>n+(x.output_tokens||0),0),cache=b.reduce((n,x)=>n+(x.cache_read_tokens||0),0);
  const used=b.filter(x=>(x.total_tokens||0)>0),peak=b.reduce((m,x)=>!m||(x.total_tokens||0)>(m.total_tokens||0)?x:m,null);
  const unit=view.hourly?'hour':'day',avg=used.length?total/used.length:0;
  cards.push(`<article class="stat"><small>Tokens · ${esc(range==='all'?'all time':'last '+RANGES[range].label)}</small><strong>${tok(total)}</strong><p>${tok(cache)} cache reads · ${tok(output)} output</p></article>`);
  cards.push(`<article class="stat"><small>Requests</small><strong>${requests.toLocaleString()}</strong><p>${b.length?`since ${view.hourly?fmt(b[0].t):fmtDay(b[0].t)}`:''}</p></article>`);
  cards.push(`<article class="stat"><small>Average per active ${unit}</small><strong>${tok(avg)}</strong><p>${used.length} active ${unit}${used.length===1?'':'s'}</p></article>`);
  cards.push(`<article class="stat"><small>Busiest ${unit}</small><strong>${peak?tok(peak.total_tokens):'—'}</strong><p>${peak?.total_tokens?(view.hourly?fmt(peak.t):fmtWeekday(peak.t)):'No usage yet'}</p></article>`);
 }else cards.push(`<article class="stat"><small>Tokens</small><strong>…</strong><p>${esc(spendError?spendError+'. Retrying.':'Loading')}</p></article>`);
 for(const g of weeklyGroups(now)){
  const color=palette[g.p][0];
  cards.push(`<article class="stat" style="--series:${color}"><small>${providerName(g.p)} left this week</small><strong>${g.known.length?(g.tokens!==null?'≈'+tok(g.tokens):num(g.left*100)+'%'):'—'}<span> tokens</span></strong><p>${num(g.left)} of ${g.accounts.length} account${g.accounts.length===1?'':'s'} · ${g.known.length!==g.accounts.length?`${g.accounts.length-g.known.length} without a current reading · `:''}next reset ${g.next?fmt(g.next):'not reported'}</p></article>`);
 }
 $('kpis').innerHTML=cards.join('');
}
function node(tag,attrs={},text){const el=document.createElementNS(NS,tag);for(const [k,v]of Object.entries(attrs))el.setAttribute(k,v);if(text!==undefined)el.textContent=text;return el;}
function niceMax(v){if(!(v>0))return 1;const e=10**Math.floor(Math.log10(v)),f=v/e;return (f<=1?1:f<=2?2:f<=2.5?2.5:f<=5?5:10)*e;}
function renderSpend(view){
 const svg=$('spend');svg.replaceChildren();$('spend-tip').hidden=true;
 if(!view){$('spend-note').textContent=spendError?`Could not load token history: ${spendError}. Retrying.`:'Loading token history…';$('spend-legend').innerHTML='';$('by-account').innerHTML='';$('by-model').innerHTML='';return;}
 const {buckets,stacks,hourly,step}=view,n=buckets.length;
 $('spend-note').textContent=`${hourly?'Per hour':'Per day'} · split by model${mode==='total'?' · running total':''}`;
 $('spend-legend').innerHTML=stacks.map((s,i)=>`<span><i class="sw" style="background:${modelColors[i%modelColors.length]}"></i>${esc(s.model)} <b>${tok(s.total)}</b></span>`).join('');
 const W=Math.max(300,svg.clientWidth||1100),H=W<600?240:300,L=W<600?44:56,R=10,T=14,B=30;svg.setAttribute('viewBox',`0 0 ${W} ${H}`);
 if(!n){svg.append(node('text',{x:L,y:T+40},'No usage recorded in this range.'));return;}
 // Values per bucket per model; running total accumulates each model separately.
 const values=stacks.map(s=>buckets.map((_,i)=>s.values[i]||0));
 if(mode==='total')for(const v of values)for(let i=1;i<n;i++)v[i]+=v[i-1];
 const totals=buckets.map((_,i)=>values.reduce((t,v)=>t+v[i],0));
 const max=niceMax(Math.max(...totals)),band=(W-L-R)/n,x=i=>L+i*band,y=v=>H-B-v/max*(H-T-B);
 for(let k=0;k<=4;k++){const v=max*k/4;svg.append(node('line',{x1:L,x2:W-R,y1:y(v),y2:y(v),stroke:'#2b3036'}),node('text',{x:L-8,y:y(v)+4,'text-anchor':'end'},tok(v)));}
 const every=Math.max(1,Math.ceil(n/(W<600?5:hourly?12:10)));
 for(let i=0;i<n;i+=every)svg.append(node('text',{x:x(i)+band/2,y:H-10,'text-anchor':'middle'},hourly?fmtHour(buckets[i].t):fmtDay(buckets[i].t)));
 if(mode==='bars'){
  const gap=Math.min(6,band*.2);
  for(let i=0;i<n;i++){let base=0;values.forEach((v,s)=>{if(!v[i])return;svg.append(node('rect',{x:x(i)+gap/2,width:Math.max(1,band-gap),y:y(base+v[i]),height:Math.max(.5,y(base)-y(base+v[i])),fill:modelColors[s%modelColors.length]}));base+=v[i];});}
 }else{
  let lower=buckets.map(()=>0);
  values.forEach((v,s)=>{const upper=lower.map((b,i)=>b+v[i]);const pts=upper.map((u,i)=>`${x(i)+band/2},${y(u)}`).concat(lower.map((b,i)=>`${x(i)+band/2},${y(b)}`).reverse());svg.append(node('polygon',{points:pts.join(' '),fill:modelColors[s%modelColors.length],opacity:.9}));lower=upper;});
 }
 const hover=node('rect',{x:0,y:T,width:band,height:H-T-B,fill:'#ffffff10',visibility:'hidden'});svg.append(hover);
 svg.onpointermove=e=>{
  const rect=svg.getBoundingClientRect(),px=(e.clientX-rect.left)/rect.width*W,i=Math.floor((px-L)/band);
  if(i<0||i>=n){hover.setAttribute('visibility','hidden');$('spend-tip').hidden=true;return;}
  hover.setAttribute('x',x(i));hover.setAttribute('visibility','visible');
  const b=buckets[i],label=hourly?`${fmtWeekday(b.t)} ${fmtHour(b.t)}–${fmtHour(b.t+step)}`:fmtWeekday(b.t);
  const lines=stacks.map((s,k)=>({m:s.model,v:values[k][i]})).filter(l=>l.v>0).map(l=>`${l.m}: ${tok(l.v)}`);
  $('spend-tip').textContent=`${label}${mode==='total'?' · running total':''}\n${tok(totals[i])} tokens${mode==='bars'?` · ${(b.requests||0).toLocaleString()} requests`:''}\n${lines.join('\n')}`;
  $('spend-tip').hidden=false;$('spend-tip').style.left=Math.min(Math.max(0,e.clientX-rect.left+12),Math.max(0,rect.width-240))+'px';
 };svg.onpointerleave=()=>{hover.setAttribute('visibility','hidden');$('spend-tip').hidden=true;};
 const accounts=view.credentials.filter(c=>c.total_tokens>0),maxA=Math.max(1,...accounts.map(c=>c.total_tokens));
 $('by-account').innerHTML=accounts.map(c=>{const a=[...data,...others].find(a=>maskedMatch(c.key,a.id));return `<div class="share"><div><span class="provider ${a?.provider||''}">${esc(providerName(a?.provider))}</span>${esc(c.label)}${a?.disabled?' <span class="subtle">· disabled</span>':''}</div><b>${tok(c.total_tokens)}</b><div class="bar"><span style="width:${c.total_tokens/maxA*100}%"></span></div><small>${reqs(c.requests)} · ${num(c.percent||0)}%</small></div>`;}).join('')||'<p class="empty">No usage in this range.</p>';
 const models=view.models.filter(m=>m.total_tokens>0),maxM=Math.max(1,...models.map(m=>m.total_tokens));
 $('by-model').innerHTML=models.map(m=>`<div class="share"><div>${esc(m.label)}</div><b>${tok(m.total_tokens)}</b><div class="bar"><span style="width:${m.total_tokens/maxM*100}%"></span></div><small>${reqs(m.requests)} · ${num(m.percent||0)}%</small></div>`).join('')||'<p class="empty">No usage in this range.</p>';
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
function renderAllowance(now){
 const lookback=Number($('lookback').value)*HOUR,future=Number($('future').value)*HOUR,provider=$('pool').value,pace=Number($('pace').value)/100;
 $('pace-value').textContent=`at ${pace}× the pace`;
 const {all,enabled}=poolAccounts(provider,kind,now);
 // No usable time in the chosen window (everything empty) widens it until there is.
 let rate=null,used=lookback;
 for(const h of [lookback,72*HOUR,168*HOUR,720*HOUR].filter(h=>h>=lookback)){rate=pooledRate(all,now,h,a=>a.scale);used=h;if(rate)break;}
 const usedLabel=used>=48*HOUR?`${Math.round(used/DAY)} days`:`${Math.round(used/HOUR)} hours`;
 const perHour=rate?rate.perHour*pace:0;
 const earliest=Math.min(...enabled.flatMap(a=>a.points.map(p=>p.t)),now-DAY);
 const start=range==='all'?earliest:Math.max(now-RANGES[range].ms,Math.min(earliest,now-HOUR)),end=now+future;
 const history=stackHistory(enabled,start,now),forecast=future>0?forecastStack(enabled,now,end,perHour,WINDOWS[kind]):[];
 const total=s=>s.values.reduce((n,v)=>n+(v??0),0),current=history.length?total(history.at(-1)):0;
 const unitNote=unit==='tokens'?'tokens, estimated from what 1% of each account bought in its latest cycle':'percent of one account; 100% = one full allowance';
 $('chart-note').textContent=`${providerName(provider)} · ${kind==='short'?'5-hour':'weekly'} allowance of every enabled account, stacked · ${unitNote}`;
 // Plain-language outlook: how long what is left lasts, and when the next refills come.
 const zero=current>0&&forecast.find(p=>!p.reset&&total(p)===0&&p.t>now),refills=[];
 for(let i=1;i<forecast.length;i++)if(forecast[i].reset)forecast[i].values.forEach((v,k)=>{const d=v-forecast[i-1].values[k];if(d>0)refills.push({t:forecast[i].t,a:enabled[k],d});});
 const nextRefills=refills.slice(0,3).map(r=>`${fmt(r.t)} +${amount(r.d)} (${esc(r.a.name)})`);
 $('outlook').innerHTML=`<strong>${amount(current)}</strong> left now${rate?` · pace ${amount(rate.perHour)}/hour over the last ${usedLabel}${used!==lookback?' (nothing could be used in the chosen window)':''}${pace!==1?` × ${pace}`:''}`:' · no measured pace yet'}${zero?` · runs out ${fmt(zero.t)}`:current>0&&rate&&future>0?' · lasts past the look-ahead':''}${nextRefills.length?`<br>Next refills: ${nextRefills.join(' · ')}`:''}`;
 $('legend').innerHTML=enabled.map(a=>`<span><i class="sw" style="background:${a.color}"></i>${esc(a.name)} <b class="${a.remaining===0?'warning':''}">${a.remaining===null||a.stale?'no reading':`${num(a.remaining)}%`}${unit==='tokens'&&a.remaining?` · ${tok(a.remaining*a.scale)}`:''}</b>${unit==='tokens'&&a.scaleSource!=='own'?' <small>(typical rate)</small>':''}</span>`).join('')+(all.filter(a=>!a.disabled&&!a.scale).length?`<span>${all.filter(a=>!a.disabled&&!a.scale).length} account(s) without a token rate yet</span>`:'')||'<span>No enabled accounts.</span>';
 const svg=$('chart');svg.replaceChildren();$('tooltip').hidden=true;
 const W=Math.max(300,svg.clientWidth||1100),H=W<600?280:360,L=W<600?46:58,R=12,T=24,B=30;svg.setAttribute('viewBox',`0 0 ${W} ${H}`);
 const max=niceMax(Math.max(...history.map(total),...forecast.map(total),1e-9)),x=t=>L+(t-start)/(end-start)*(W-L-R),y=v=>H-B-v/max*(H-T-B);
 for(let k=0;k<=4;k++){const v=max*k/4;svg.append(node('line',{x1:L,x2:W-R,y1:y(v),y2:y(v),stroke:'#2b3036'}),node('text',{x:L-8,y:y(v)+4,'text-anchor':'end'},amount(v)));}
 const span=end-start,ticks=W<600?3:6;
 for(let i=0;i<=ticks;i++){const t=start+span*i/ticks;svg.append(node('text',{x:x(t),y:H-10,'text-anchor':i===0?'start':i===ticks?'end':'middle'},span>3*DAY?fmtDay(t):fmt(t)));}
 if(future>0)svg.append(node('rect',{x:x(now),y:T,width:x(end)-x(now),height:H-T-B,fill:'#ffffff06'}));
 // Stacked areas, one band per account; the top edge is everything you can still spend.
 const bands=(series,opacity)=>{let lower=series.map(()=>0);enabled.forEach((a,k)=>{const upper=series.map((s,i)=>lower[i]+(s.values[k]??0));if(upper.some((u,i)=>u>lower[i])){const pts=series.map((s,i)=>`${x(s.t).toFixed(1)},${y(upper[i]).toFixed(1)}`).concat(series.map((s,i)=>`${x(s.t).toFixed(1)},${y(lower[i]).toFixed(1)}`).reverse());svg.append(node('polygon',{points:pts.join(' '),fill:a.color,opacity}));}lower=upper;});};
 const line=(series,attrs)=>svg.append(node('path',{d:series.map((s,i)=>`${i?'L':'M'}${x(s.t).toFixed(1)},${y(total(s)).toFixed(1)}`).join(' '),fill:'none','stroke-linejoin':'round',...attrs}));
 if(history.length){bands(history,.55);line(history,{stroke:'#eff4f6','stroke-width':2});}
 if(forecast.length>1){bands(forecast,.3);line(forecast,{stroke:'#eff4f6','stroke-width':2,'stroke-dasharray':'6 5'});}
 svg.append(node('line',{x1:x(now),x2:x(now),y1:T-6,y2:H-B,stroke:'#a4b1bc','stroke-dasharray':'3 5'}),node('text',{x:x(now)+5,y:T-10},'now'));
 if(!history.some(s=>total(s)>0)&&!forecast.some(s=>total(s)>0))svg.append(node('text',{x:L+8,y:T+40},'Nothing left and no reset in view.'));
 const series=[...history.map(s=>({...s,kind:'Observed'})),...forecast.map(s=>({...s,kind:'Expected'}))];
 const hover=node('line',{y1:T,y2:H-B,stroke:'#ffffff40',visibility:'hidden'});svg.append(hover);
 svg.onpointermove=e=>{
  const rect=svg.getBoundingClientRect(),t=start+((e.clientX-rect.left)/rect.width*W-L)/(W-L-R)*span;
  const s=series.reduce((b,p)=>!b||Math.abs(p.t-t)<Math.abs(b.t-t)?p:b,null);if(!s)return;
  hover.setAttribute('x1',x(s.t));hover.setAttribute('x2',x(s.t));hover.setAttribute('visibility','visible');
  $('tooltip').hidden=false;$('tooltip').textContent=`${s.kind} · ${fmt(s.t)}\n${amount(total(s))} left in total\n${enabled.map((a,k)=>`${a.name}: ${s.values[k]===null?'no reading':amount(s.values[k])}`).join('\n')}`;
  $('tooltip').style.left=Math.min(Math.max(0,e.clientX-rect.left+12),Math.max(0,rect.width-260))+'px';
 };svg.onpointerleave=()=>{hover.setAttribute('visibility','hidden');$('tooltip').hidden=true;};
}
function renderCycles(now){
 const start=range==='all'?0:now-RANGES[range].ms;
 const rows=data.flatMap(a=>cycleSummaries(a.histories?.weekly).filter(c=>c.end===null||c.end>=start).map(c=>({a,...c}))).sort((x,y)=>y.start-x.start||x.a.name.localeCompare(y.a.name));
 $('cycles').innerHTML=rows.length?`<div class="table"><table><thead><tr><th>Account</th><th>Week</th><th>Used</th><th>Tokens</th><th>Tokens per 1%</th></tr></thead><tbody>${rows.map(r=>`<tr><td><span class="provider ${r.a.provider}">${providerName(r.a.provider)}</span>${esc(r.a.name)}${r.a.disabled?' <span class="subtle">· disabled</span>':''}</td><td data-l="Week">${fmt(r.start)} → ${fmt(r.end)}${r.status==='current'?' <span class="badge">current</span>':''}</td><td data-l="Used"><div class="used"><div class="bar"><span style="width:${Math.min(100,r.used)}%"></span></div>${r.used}%${r.status==='current'&&r.remaining!==null?` <span class="subtle">· ${num(r.remaining)}% left</span>`:''}</div></td><td data-l="Tokens">${tok(r.tokens)}</td><td data-l="Tokens per 1%">${r.perPoint?tok(r.perPoint):'—'}</td></tr>`).join('')}</tbody></table></div>`:'<p class="empty">No weekly cycles in this range yet.</p>';
}
function render(){
 const now=Date.now(),view=spendView();
 document.querySelectorAll('[data-range]').forEach(b=>b.classList.toggle('active',b.dataset.range===range));
 renderKpis(view,now);renderSpend(view);renderAllowance(now);renderCycles(now);renderAccounts();
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
for(const id of ['pool','future','lookback'])$(id).onchange=render;
$('pace').oninput=render;$('refresh').onclick=()=>load(true);
const setRange=r=>{if(!RANGES[r]||r===range)return;range=r;localStorage.setItem('runway-range',r);history.replaceState(null,'','#'+r);render();loadSpend().then(render);};
for(const b of document.querySelectorAll('[data-range]'))b.onclick=()=>setRange(b.dataset.range);
window.addEventListener('hashchange',()=>setRange(location.hash.slice(1)));
for(const b of document.querySelectorAll('[data-mode]'))b.onclick=()=>{mode=b.dataset.mode;document.querySelectorAll('[data-mode]').forEach(x=>x.classList.toggle('active',x===b));render();};
for(const b of document.querySelectorAll('[data-unit]'))b.onclick=()=>{unit=b.dataset.unit;document.querySelectorAll('[data-unit]').forEach(x=>x.classList.toggle('active',x===b));render();};
for(const b of document.querySelectorAll('[data-kind]'))b.onclick=()=>{kind=b.dataset.kind;$('future').value=kind==='short'?'12':'168';document.querySelectorAll('[data-kind]').forEach(x=>x.classList.toggle('active',x===b));render();};
let resizeTimer;window.addEventListener('resize',()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(render,100);});
window.addEventListener('online',()=>load());document.addEventListener('visibilitychange',()=>{if(!document.hidden)load();});
render();load();
