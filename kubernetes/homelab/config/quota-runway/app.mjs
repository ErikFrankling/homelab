import {HOUR,accountState,historicalPool,forecastPool,time,percent} from './model.mjs';
const $=id=>document.getElementById(id), NS='http://www.w3.org/2000/svg';
const colors=['#edac87','#8faeff','#a5d8a6','#d7a4e9','#e7cf87'];
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=t=>t?new Intl.DateTimeFormat(undefined,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}).format(t):'Not reported';
const num=n=>Number(n.toFixed(1)).toLocaleString();
const groupId=a=>`${a.provider}|${a.plan}${a.plan==='Unknown plan'?'|'+a.id:''}`;
const groupName=g=>{const [p,plan]=g.split('|');return `${p==='claude'?'Claude':'Codex'} · ${plan}`;};
let data=[],loading=false,role='secondary',retryTimer,failures=0,resetBusy=false;
const attempts=new Map(),messages=new Map();
async function api(path,body){
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20000);
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
async function load(forceIds=null){
 if(loading||resetBusy)return;
 clearTimeout(retryTimer);loading=true;$('refresh').disabled=true;$('updated').textContent='Checking accounts…';
 try{
  const identities=(await api('usage/identities')).identities.filter(a=>!a.is_deleted&&['claude','codex'].includes(a.provider||a.type));
  const ids=identities.map(a=>a.identity);
  let cached=ids.length?await api('quota/cache',{auth_indexes:ids}):{items:[]};
  const existing=new Map(data.map(a=>[a.id,a]));
  data=identities.map((a,index)=>{
   const cache=cached.items?.find(c=>c.auth_index===a.identity),old=existing.get(a.identity);
   return {id:a.identity,name:a.alias||a.displayName||a.name||`${a.provider} ${index+1}`,provider:a.provider||a.type,disabled:a.disabled,plan:cache?.quota?.subscription?.plan||old?.plan||'Unknown plan',cache:cache?.quota?cache:old?.cache,histories:old?.histories||{},errors:[]};
  });renderAccounts();
  const refreshIds=forceIds===true?ids:forceIds||identities.filter(a=>!a.disabled&&needsRefresh(cached.items?.find(c=>c.auth_index===a.identity))&&Date.now()-(attempts.get(a.identity)||0)>60000).map(a=>a.identity);
  if(refreshIds.length){$('updated').textContent=`Fetching fresh limits for ${refreshIds.length} account(s)…`;try{await refreshAccounts(refreshIds);}catch{for(const id of refreshIds)messages.set(id,'Provider refresh failed. Will retry automatically.');}cached=await api('quota/cache',{auth_indexes:ids});}
  const previous=new Map(data.map(a=>[a.id,a]));
  data=await Promise.all(identities.map(async(a,index)=>{
   const old=previous.get(a.identity),cache=cached.items?.find(c=>c.auth_index===a.identity);
   const account={id:a.identity,name:a.alias||a.displayName||a.name||`${a.provider} ${index+1}`,provider:a.provider||a.type,disabled:a.disabled,plan:cache?.quota?.subscription?.plan||old?.plan||'Unknown plan',cache:cache?.quota?cache:old?.cache,histories:{...old?.histories},errors:[]};
   try{const initial=await api('quota/history/'+encodeURIComponent(a.identity));
    if(initial.selected_window)account.histories[initial.selected_window.window_role]=initial;
    await Promise.all((initial.windows||[]).filter(w=>w.window_role!==initial.selected_window?.window_role).map(async w=>{account.histories[w.window_role]=await api('quota/history/'+encodeURIComponent(a.identity)+'?window_role='+encodeURIComponent(w.window_role));}));
   }catch{account.errors.push('History unavailable; retrying automatically.');}
   return account;
  }));
  const selected=$('pool').value,groups=[...new Set(data.filter(a=>!a.disabled).map(groupId))];
  $('pool').innerHTML='<option value="all">Claude + Codex</option>'+groups.map(g=>`<option value="${esc(g)}">${esc(groupName(g))}</option>`).join('');
  $('pool').value=groups.includes(selected)?selected:'all';
  $('error').hidden=true;$('updated').textContent='Checked '+fmt(Date.now());failures=0;
 }catch(e){failures++;$('error').textContent=e.message+'. Retrying automatically. Previous readings keep their original timestamps.';$('error').hidden=false;$('updated').textContent='Connection interrupted';}
 finally{loading=false;$('refresh').disabled=false;render();retryTimer=setTimeout(()=>load(),failures?Math.min(60000,10000*2**failures):60000);}
}
function rowCard(row,observed){
 const remaining=percent(typeof row.usedPercent==='number'?100-row.usedPercent:typeof row.remainingFraction==='number'?row.remainingFraction*100:null);
 const reset=time(row.resetAt),stale=!observed||Date.now()-observed>15*60000||(reset!==null&&reset<=Date.now());
 const status=remaining===null?'Not reported':row.active===false?'Inactive':row.allowed===false?'Restricted':stale?'Stale reading':remaining===0?'Depleted':'Remaining';
 return `<div class="limit"><div class="limit-heading"><span>${esc(row.label||row.key)}</span><span class="subtle">${esc(status)}</span></div><strong class="${remaining===0?'warning':''}">${remaining===null?'Not reported':num(remaining)+'%'}${remaining!==null?'<small> left</small>':''}</strong><div class="bar"><span style="width:${remaining??0}%;${row.active===false?'background:var(--muted)':''}"></span></div><p>Resets ${fmt(reset)}</p></div>`;
}
function renderAccounts(){
 const now=Date.now();$('coverage').textContent=`${data.length} accounts · all reported limits`;
 $('accounts').innerHTML=data.map(a=>{
  const q=a.cache?.quota,rows=[...(q?.quota||[])],observed=time(a.cache?.refreshed_at);
  for(const [key,label] of (a.provider==='claude'?[['five_hour','5 hours'],['seven_day','7 days']]:[['rate_limit.primary_window','5 hours'],['rate_limit.secondary_window','7 days']]))if(!rows.some(r=>r.key===key))rows.unshift({key,label});
  const grants=q?.claudeResetGrants,credit=q?.rateLimitResetCreditsAvailableCount;
  return `<article class="account"><div class="account-heading"><div><h3><span class="provider ${a.provider}">${a.provider==='claude'?'Claude':'Codex'}</span>${esc(a.name)}</h3><p>${esc(a.plan)}${a.disabled?' · Disabled':''} · Updated ${fmt(observed)}${observed&&now-observed>15*60000?' · stale':''}</p></div><div class="account-actions"><button data-refresh="${esc(a.id)}" ${loading||resetBusy?'disabled':''}>Refresh limits</button><button data-reset="${esc(a.id)}" ${resetBusy||loading?'disabled':''}>Reset usage${a.provider==='claude'&&grants?' · '+grants.availableCount:a.provider==='codex'&&typeof credit==='number'?' · '+credit:''}</button></div></div><div class="limits">${rows.map(r=>rowCard(r,observed)).join('')}</div>${grants?.grants?.length?`<p class="grant-note">${grants.grants.map(g=>`${esc(g.label)}: ${g.resetsLeft}/${g.resetsTotal} left${g.usableNow?' · available now':' · unavailable now'}`).join('<br>')}</p>`:''}<p class="account-message" role="status">${esc(messages.get(a.id)||a.errors.join(' '))}</p></article>`;
 }).join('')||'<p class="empty">No accounts loaded yet. Retrying automatically.</p>';
}
function render(){
 const now=Date.now(),pace=Number($('pace').value)/100,lookback=Number($('lookback').value)*HOUR;
 $('pace-value').textContent=`at ${pace}× the pace`;
 const accounts=data.filter(a=>!a.disabled&&($('pool').value==='all'||groupId(a)===$('pool').value));
 const groups=[...new Set(accounts.map(groupId))].map((id,i)=>({id,name:groupName(id),color:colors[i%colors.length],accounts:accounts.filter(a=>groupId(a)===id).map(a=>accountState(a,role,now,lookback))}));
 $('stats').innerHTML=groups.map(g=>{
  const known=g.accounts.filter(a=>!a.stale&&a.remaining!==null),total=known.reduce((n,a)=>n+a.remaining,0),reset=known.map(a=>a.reset).filter(t=>t>now).sort((a,b)=>a-b)[0];
  return `<article class="stat" style="--series:${g.color}"><small>${esc(g.name)}</small><strong>${known.length?num(total/known.length)+'%':'—'}<span> remaining</span></strong><p>${known.length}/${g.accounts.length} current readings${known.length!==g.accounts.length?' · incomplete':''}</p><p>Next reset ${fmt(reset)}</p></article>`;
 }).join('');
 $('chart-note').textContent=`${role==='primary'?'5-hour':'7-day'} limits · percentage remaining per provider and plan`;
 $('method').textContent='Solid: observed. Dashed: estimated at the selected pace. Each line averages accounts on the same plan; Claude and Codex have different token budgets. Gaps mean missing data. Other limits can still block usage.';
 $('legend').innerHTML=groups.map(g=>`<span><i style="border-color:${g.color}"></i>${esc(g.name)}</span>`).join('');
 draw(groups,now-Number($('past').value)*HOUR,now,now+Number($('future').value)*HOUR,pace);
 renderAccounts();
}
function node(tag,attrs={},text){const el=document.createElementNS(NS,tag);for(const [k,v]of Object.entries(attrs))el.setAttribute(k,v);if(text!==undefined)el.textContent=text;return el;}
function draw(groups,start,now,end,pace){
 const svg=$('chart');svg.replaceChildren();$('tooltip').hidden=true;
 const W=Math.max(300,svg.clientWidth||1100),H=350,L=45,R=15,T=30,B=45,x=t=>L+(t-start)/(end-start)*(W-L-R),y=v=>H-B-v/100*(H-T-B);svg.setAttribute('viewBox',`0 0 ${W} ${H}`);
 svg.append(node('title',{},'Claude and Codex remaining quota, grouped by plan'));
 for(let v=0;v<=100;v+=25)svg.append(node('line',{x1:L,x2:W-R,y1:y(v),y2:y(v),stroke:'#30383f'}),node('text',{x:L-8,y:y(v)+4,'text-anchor':'end'},v+'%'));
 const ticks=W<550?2:4;for(let i=0;i<=ticks;i++)svg.append(node('text',{x:x(start+(end-start)*i/ticks),y:H-15,'text-anchor':i===0?'start':i===ticks?'end':'middle'},fmt(start+(end-start)*i/ticks)));
 svg.append(node('line',{x1:x(now),x2:x(now),y1:T,y2:H-B,stroke:'#a4b1bc','stroke-dasharray':'3 5'}),node('text',{x:x(now)+6,y:18},'NOW'));
 let points=[],hasHistory=false;
 for(const g of groups){
  const scale=100/g.accounts.length,history=historicalPool(g.accounts,start,now),projection=forecastPool(g.accounts,now,end,pace);
  for(const [series,dashed,kind] of [[history,false,'Observed'],[projection,true,'Estimate']]){
   let d='',active=false;
   for(const p of series){if(p.value===null){active=false;continue;}const value=p.value*scale;d+=`${active?'L':'M'}${x(p.t)},${y(value)} `;active=true;points.push({t:p.t,value,label:g.name,kind});}
   if(d){svg.append(node('path',{d,fill:'none',stroke:g.color,'stroke-width':2.5,...(dashed?{'stroke-dasharray':'6 5'}:{})}));if(!dashed)hasHistory=true;}
  }
  if(g.accounts.every(a=>!a.stale&&a.remaining!==null)){
   const value=g.accounts.reduce((n,a)=>n+a.remaining,0)/g.accounts.length;
   svg.append(node('circle',{cx:x(now),cy:y(value),r:4,fill:g.color}));points.push({t:now,value,label:g.name,kind:'Current'});
  }
  for(const a of g.accounts.filter(a=>!a.stale&&a.reset>now&&a.reset<end))svg.append(node('line',{x1:x(a.reset),x2:x(a.reset),y1:T,y2:H-B,stroke:g.color,opacity:'.35','stroke-dasharray':'2 6'},null),node('text',{x:x(a.reset)+3,y:T+12,fill:g.color},'↥'));
 }
 if(!hasHistory)svg.append(node('text',{x:L+8,y:T+55},'History will appear as readings arrive. Current readings are shown as dots.'));
 svg.onpointermove=e=>{
  const rect=svg.getBoundingClientRect(),t=start+((e.clientX-rect.left)/rect.width*W-L)/(W-L-R)*(end-start),value=(H-B-(e.clientY-rect.top)/rect.height*H)/(H-T-B)*100;
  const nearest=points.reduce((best,p)=>{const distance=Math.abs(p.t-t)/(end-start)+Math.abs(p.value-value)/500;return !best||distance<best.distance?{...p,distance}:best;},null);if(!nearest)return;
  $('tooltip').hidden=false;$('tooltip').textContent=`${nearest.label} · ${nearest.kind}\n${fmt(nearest.t)} · ${num(nearest.value)}% left`;$('tooltip').style.left=Math.min(Math.max(0,e.clientX-rect.left),Math.max(0,rect.width-260))+'px';
 };svg.onpointerleave=()=>$('tooltip').hidden=true;
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
for(const id of ['pool','past','future','lookback'])$(id).onchange=render;
$('pace').oninput=render;$('refresh').onclick=()=>load(true);
for(const b of document.querySelectorAll('[data-role]'))b.onclick=()=>{role=b.dataset.role;$('future').value=role==='primary'?'12':'168';document.querySelectorAll('[data-role]').forEach(x=>x.classList.toggle('active',x===b));render();};
window.addEventListener('resize',render);window.addEventListener('online',()=>load());document.addEventListener('visibilitychange',()=>{if(!document.hidden)load();});load();
