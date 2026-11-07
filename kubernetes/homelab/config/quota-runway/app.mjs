import {HOUR,accountState,historicalPool,forecastPool,time} from './model.mjs';
const $=id=>document.getElementById(id),NS='http://www.w3.org/2000/svg';
let data=[],role='secondary',loading=false,chartPoints=[];
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=(t,full=false)=>t?new Intl.DateTimeFormat(undefined,{weekday:full?'short':undefined,month:full?'short':undefined,day:full?'numeric':undefined,hour:'2-digit',minute:'2-digit'}).format(t):'Not reported';
const duration=ms=>ms<=0?'now':ms<HOUR?`${Math.ceil(ms/60000)} min`:ms<48*HOUR?`${(ms/HOUR).toFixed(1)} hours`:`${(ms/(24*HOUR)).toFixed(1)} days`;
const number=n=>Number(n.toFixed(2)).toLocaleString();
async function api(path,body) {
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20000);
 try {const r=await fetch('/api/v1/'+path,{method:body?'POST':'GET',headers:{'x-cpa-usage-keeper-request':'fetch',...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined,signal:controller.signal});if(!r.ok)throw new Error(`Keeper returned ${r.status}`);return await r.json();}finally{clearTimeout(timer);}
}
async function load() {
 if(loading)return;loading=true;$('refresh').disabled=true;
 try {
  const identities=(await api('usage/identities')).identities.filter(a=>!a.disabled&&!a.is_deleted&&['claude','codex'].includes(a.provider||a.type));
  if(!identities.length)throw new Error('No enabled Claude or Codex accounts found.');
  const cached=await api('quota/cache',{auth_indexes:identities.map(a=>a.identity)});
  data=await Promise.all(identities.map(async(a,index)=>{
   const cache=cached.items.find(c=>c.auth_index===a.identity);
   const account={id:a.identity,name:a.alias||a.displayName||a.name||`${a.provider} ${index+1}`,provider:a.provider||a.type,plan:cache?.quota?.subscription?.plan||'Unknown plan',cache,histories:{},errors:[]};
   try {
    const initial=await api('quota/history/'+encodeURIComponent(a.identity));
    if(initial.selected_window)account.histories[initial.selected_window.window_role]=initial;
    for(const w of initial.windows||[])if(!account.histories[w.window_role])account.histories[w.window_role]=await api('quota/history/'+encodeURIComponent(a.identity)+'?window_role='+encodeURIComponent(w.window_role));
   } catch(e){account.errors.push(e.message);}
   return account;
  }));
  const selected=$('pool').value,groups=[...new Set(data.map(a=>a.provider+'|'+a.plan))];
  $('pool').replaceChildren(...groups.map(g=>{const o=document.createElement('option');o.value=g;const [provider,plan]=g.split('|');o.textContent=`${provider==='claude'?'Claude':'Codex'} · ${plan} · ${data.filter(a=>a.provider+'|'+a.plan===g).length} account(s)`;return o;}));
  if(groups.includes(selected))$('pool').value=selected;
  $('updated').textContent='Checked '+fmt(Date.now());$('error').hidden=true;
  try{const s=await api('quota/auto-refresh/settings');$('sampling').textContent=s.enabled?` Keeper samples every ${s.schedule?.value} ${s.schedule?.unit}(s).`:' Keeper background quota refresh is off.';}catch{}
  render();
 } catch(e){$('error').textContent='Could not refresh quota data. '+e.message+' Previous data, if present, is marked by its observation time.';$('error').hidden=false;render();}
 finally{loading=false;$('refresh').disabled=false;}
}
function render() {
 const now=Date.now(),pace=Number($('pace').value)/100,lookback=Number($('lookback').value)*HOUR;
 $('pace-value').textContent=pace===1?'at the same pace':`at ${pace}× the pace`;
 const pool=data.filter(a=>a.provider+'|'+a.plan===$('pool').value),accounts=pool.map(a=>accountState(a,role,now,lookback));
 const known=accounts.filter(a=>a.remaining!==null&&!a.stale),complete=known.length===accounts.length&&accounts.length>0;
 const total=known.reduce((s,a)=>s+a.remaining/100,0),rates=known.filter(a=>a.rate),rate=rates.reduce((s,a)=>s+a.rate.perHour/100,0)*pace;
 const resets=known.filter(a=>a.reset>now).sort((a,b)=>a.reset-b.reset);
 const end=now+Number($('future').value)*HOUR,start=now-Number($('past').value)*HOUR;
 const projection=complete?forecastPool(accounts,now,end,pace):[];
 const empty=projection.find(p=>p.value<=0.000001);
 const stat=(label,value,note,warn=false)=>`<article class="stat"><small>${label}</small><strong class="${warn?'warning':''}">${esc(value)}</strong><p>${esc(note)}</p></article>`;
 $('stats').innerHTML=stat('Remaining in this pool',known.length?`${number(total)} / ${known.length}`:'Unknown',`Full account allowances · ${role==='primary'?'5-hour':'weekly'}${complete?'':' · partial coverage'}`,known.length>0&&total===0)+
 stat('Consumption / hour',complete&&rates.length===known.length?number(rate):'Not enough data',complete&&rates.length===known.length?`Account allowances at ${pace}× recent pace`:'Needs ≥5 min of observed, unblocked usage')+
 stat('Pool runs out',complete&&total===0?'Already depleted':empty?fmt(empty.t,true):projection.length?'Beyond this view':'No reliable estimate',complete&&total===0?'Waiting for a reset':empty?'If this pace continues, including known resets':projection.length?'No zero crossing in the selected horizon':'Missing, stale or insufficient rate history',complete&&total===0||!!empty)+
 stat('Next refill',resets.length?fmt(resets[0].reset,true):'Not reported',resets.length?`${duration(resets[0].reset-now)} · ${resets[0].name}`:'Provider reset time unavailable');
 $('chart-note').textContent=`${role==='primary'?'5-hour':'Weekly'} allowance · one unit = one full account limit · ${known.length}/${accounts.length} current readings`;
 $('method').textContent=projection.length?`Projection assumes each account keeps its measured last-${$('lookback').value}-hour pace (${pace}×). Reset jumps are scheduled, not yet observed. Other quota windows can still block access.`:'No descending forecast is drawn without usable rate history for every account. Scheduled reset markers still show when allowance returns. Missing history stays blank.';
 draw(accounts,start,now,end,projection);
 $('coverage').textContent=complete?'All readings current':`${accounts.length-known.length} missing or stale reading(s)`;
 $('accounts').innerHTML=accounts.map(a=>{
  const other=accountState(a,role==='primary'?'secondary':'primary',now,lookback);
  const exhaustion=a.remaining===0?now:a.rate?.perHour>0?now+a.remaining/(a.rate.perHour*pace)*HOUR:null;
  const outlook=a.stale?'Reading stale':a.remaining===null?'Quota not reported':a.remaining===0?'Depleted':exhaustion&&a.reset&&exhaustion<a.reset?`Empty in ${duration(exhaustion-now)}`:a.rate?.perHour===0?'No measured burn':exhaustion&&a.reset?'Reset arrives first':'Not enough rate history';
  const otherLabel=role==='primary'?'weekly':'5-hour';
  return `<article class="account"><div><h3>${esc(a.name)}</h3><p>${esc(a.plan)}</p><span class="badge ${other.remaining===0&&!other.stale?'warning':''}">${otherLabel}: ${other.remaining===null?'not reported':`${number(other.remaining)}% left${other.stale?' · stale':''}`}</span></div><div><strong class="${a.remaining===0?'warning':''}">${a.remaining===null?'—':number(a.remaining)+'%'}</strong><p>remaining${a.stale?' · stale':''}</p><div class="bar"><span style="width:${a.remaining??0}%"></span></div><span class="subtle">Observed ${a.observed?fmt(a.observed,true):'never'}</span></div><div><strong style="font-size:16px" class="${a.beforeReset?'warning':''}">${esc(outlook)}</strong><p>${a.rate?`${number(a.rate.perHour*pace)} percentage points/hour · ${Math.round(a.rate.minutes)} min observed`:'Waiting for enough observations'}</p>${a.errors.length?'<p class="warning">History could not be loaded</p>':''}</div><div><span class="subtle">Next reset</span><p style="color:var(--text)">${esc(fmt(a.reset,true))}</p><p>${a.reset&&a.reset>now?'in '+duration(a.reset-now):'Waiting for provider update'}</p></div></article>`;
 }).join('')||'<p class="empty">Waiting for account data.</p>';
}
function svgNode(tag,attrs,text) {const el=document.createElementNS(NS,tag);for(const [k,v]of Object.entries(attrs))el.setAttribute(k,v);if(text!==undefined)el.textContent=text;return el;}
function draw(accounts,start,now,end,projection) {
 const svg=$('chart');svg.replaceChildren();const W=1100,H=350,left=54,right=24,top=30,bottom=45,max=Math.max(1,accounts.length);
 const x=t=>left+(t-start)/(end-start)*(W-left-right),y=v=>H-bottom-v/max*(H-top-bottom);
 svg.append(svgNode('title',{},'Remaining allowance: observed history and projected consumption with provider reset times'));
 for(let i=0;i<=4;i++){const v=max*i/4;svg.append(svgNode('line',{x1:left,x2:W-right,y1:y(v),y2:y(v),stroke:'#30383f'}),svgNode('text',{x:left-10,y:y(v)+4,'text-anchor':'end'},number(v)));}
 for(let i=0;i<=6;i++){const t=start+(end-start)*i/6;svg.append(svgNode('text',{x:x(t),y:H-15,'text-anchor':i===0?'start':i===6?'end':'middle'},new Intl.DateTimeFormat(undefined,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}).format(t)));}
 svg.append(svgNode('rect',{x:x(now),y:top,width:x(end)-x(now),height:H-top-bottom,fill:'#8de4bb',opacity:'.025'}),svgNode('line',{x1:x(now),x2:x(now),y1:top,y2:H-bottom,stroke:'#a4b1bc','stroke-dasharray':'3 5'}),svgNode('text',{x:x(now)+6,y:18},'NOW'));
 const history=historicalPool(accounts,start,now);chartPoints=[...history.filter(p=>p.value!==null).map(p=>({...p,kind:'Observed'})),...projection.map(p=>({...p,kind:'Estimated'}))];
 function path(points,dashed) {let d='',active=false;for(const p of points){if(p.value===null){active=false;continue;}d+=`${active?'L':'M'}${x(p.t).toFixed(2)},${y(p.value).toFixed(2)} `;active=true;}if(d)svg.append(svgNode('path',{d,fill:'none',stroke:'#8de4bb','stroke-width':2.5,...(dashed?{'stroke-dasharray':'7 5'}:{})}));}
 path(history,false);path(projection,true);
 const current=accounts.every(a=>a.remaining!==null&&!a.stale)?accounts.reduce((n,a)=>n+a.remaining/100,0):null;
 if(current!==null)svg.append(svgNode('circle',{cx:x(now),cy:y(current),r:4,fill:'#8de4bb'}));
 accounts.filter(a=>a.reset>now&&a.reset<=end).forEach((a,i)=>{svg.append(svgNode('line',{x1:x(a.reset),x2:x(a.reset),y1:top+16,y2:H-bottom,stroke:'#697de3','stroke-dasharray':'2 6',opacity:'.7'}),svgNode('text',{x:x(a.reset)+5,y:top+12+(i%3)*15,fill:'#9aaaff'},`↥ ${a.name.split('@')[0].slice(0,20)} reset`));});
 if(!history.some(p=>p.value!==null))svg.append(svgNode('text',{x:left+12,y:top+65},'No overlapping history yet — observations will build this curve.'));
 svg.onpointermove=event=>{const rect=svg.getBoundingClientRect(),t=start+((event.clientX-rect.left)/rect.width*W-left)/(W-left-right)*(end-start);let closest=null;for(const p of chartPoints)if(!closest||Math.abs(p.t-t)<Math.abs(closest.t-t))closest=p;if(!closest)return;$('tooltip').hidden=false;$('tooltip').textContent=`${closest.kind} · ${fmt(closest.t,true)}\n${number(closest.value)} full account allowances left`;$('tooltip').style.left=Math.min(Math.max(0,event.clientX-rect.left),Math.max(0,rect.width-260))+'px';};
 svg.onpointerleave=()=>$('tooltip').hidden=true;
}
for(const id of ['pool','past','future','lookback'])$(id).onchange=render;
$('pace').oninput=render;$('refresh').onclick=load;
for(const button of document.querySelectorAll('[data-role]'))button.onclick=()=>{role=button.dataset.role;document.querySelectorAll('[data-role]').forEach(b=>b.classList.toggle('active',b===button));render();};
load();setInterval(load,60000);
