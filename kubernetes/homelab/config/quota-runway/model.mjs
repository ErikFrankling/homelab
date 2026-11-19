// Quota percentages are provider observations, not interchangeable token budgets.
export const HOUR = 3600000, DAY = 24 * HOUR;
// Limits are identified by window length, not by Keeper's primary/secondary slot:
// Codex Pro reports its weekly limit in the "primary" slot.
export const WINDOWS = {short: 18000, weekly: 604800};
export const time = value => { const n = Date.parse(value); return Number.isFinite(n) ? n : null; };
export const percent = value => typeof value === 'number' && Number.isFinite(value) ? Math.min(100, Math.max(0, value)) : null;
export function windowKind(seconds) { return Object.keys(WINDOWS).find(k => WINDOWS[k] === seconds) ?? null; }
export function observations(history) {
  return (history?.cycles || []).flatMap(c => {
    const points = [{t:time(c.first_observed_at),p:percent(c.first_remaining_percent)}];
    for (const x of c.transitions || []) {
      points.push({t:time(x.interval_started_at),p:percent(x.from_remaining_percent)});
      points.push({t:time(x.interval_ended_at),p:percent(x.to_remaining_percent)});
    }
    points.push({t:time(c.last_observed_at),p:percent(c.last_remaining_percent)});
    return points.filter(x=>x.t!==null&&x.p!==null).map(x=>({...x,cycle:c.id,reset:time(c.reset_at)}));
  }).sort((a,b)=>a.t-b.t);
}
export function burnRate(history, now, lookback=HOUR) {
  // Use only observed intervals inside a cycle. Ignore reset/replenishment gains,
  // large data gaps and time spent at zero (rate-limited, not genuinely idle).
  let loss=0, elapsed=0;
  for (const c of history?.cycles || []) {
    const points=observations({cycles:[c]});
    for(let i=1;i<points.length;i++) {
      const a=points[i-1],b=points[i],dt=b.t-a.t;
      if(dt<=0||dt>2*HOUR||b.p>a.p||a.p===0) continue;
      const span=Math.max(0,Math.min(b.t,now)-Math.max(a.t,now-lookback));
      loss+=(a.p-b.p)*span/dt;elapsed+=span;
    }
  }
  if(elapsed<5*60000) return null;
  return {perHour:loss/elapsed*HOUR,minutes:elapsed/60000,loss};
}
// The all-model limit row from the live cache. Claude also reports model-scoped
// (Fable) and oauth-app rows with the same window length; those never count.
export function limitRow(account, kind) {
  const rows=account.cache?.quota?.quota || [], seconds=WINDOWS[kind];
  if(account.provider==='claude') return rows.find(r=>r.key===(kind==='short'?'five_hour':'seven_day')) || null;
  return rows.find(r=>r.window?.seconds===seconds&&(!r.scope||r.scope==='window')) || null;
}
export function accountState(account, kind, now, lookback=HOUR) {
  const history=account.histories?.[kind];
  const row=limitRow(account,kind);
  const points=observations(history),last=points.at(-1);
  const cacheTime=time(account.cache?.refreshed_at);
  const cacheP=row ? percent(typeof row.usedPercent==='number'?100-row.usedPercent:
    typeof row.remainingFraction==='number'?row.remainingFraction*100:null) : null;
  const useCache=cacheP!==null && cacheTime!==null && (!last||cacheTime>=last.t);
  const remaining=useCache?cacheP:last?.p??null;
  const observed=useCache?cacheTime:last?.t??null;
  const reset=useCache?time(row.resetAt):last?.reset??null;
  const stale=observed===null || now-observed>15*60000 || (reset!==null&&reset<=now);
  const rate=stale?null:burnRate(history,now,lookback);
  const exhaustedAt=remaining===0?now:rate?.perHour>0?now+remaining/rate.perHour*HOUR:null;
  return {...account,history,points,remaining,observed,reset,stale,rate,exhaustedAt,
    beforeReset:exhaustedAt!==null&&reset!==null&&exhaustedAt<reset};
}
// One account's observed line, broken (null) only at a new quota cycle. Inside a
// cycle the reading only falls, so joining two readings never invents usage.
export function accountSeries(points, start, end) {
  const out=[];
  let before=null;
  for(const p of points) {
    if(p.t<start){before=p;continue;}
    if(p.t>end)break;
    const prev=out.length?out.at(-1):before;
    if(prev&&prev.value!==null&&prev.cycle!==p.cycle)out.push({t:p.t,value:null});
    else if(!out.length&&before&&before.cycle===p.cycle)out.push({t:start,value:before.p,p:before.p,cycle:before.cycle});
    out.push({t:p.t,value:p.p,p:p.p,cycle:p.cycle});
  }
  if(!out.length&&before&&(before.reset===null||before.reset>start))out.push({t:start,value:before.p,p:before.p,cycle:before.cycle});
  return out;
}
export function forecastAccount(a,now,end,multiplier=1) {
  if(a.stale||a.remaining===null)return [];
  let p=a.remaining,t=now;
  const points=[{t,value:p/100}];
  const rate=a.rate?.perHour;
  const reset=a.reset!==null&&a.reset>now&&a.reset<=end?a.reset:null;
  function consume(until) {
    if(rate===undefined||rate===null) { points.push({t:until,value:p/100,uncertain:true});t=until;return; }
    const zero=rate>0?t+p/(rate*multiplier)*HOUR:Infinity;
    if(zero>t&&zero<until)points.push({t:zero,value:0});
    p=Math.max(0,p-rate*multiplier*(until-t)/HOUR);t=until;points.push({t,value:p/100});
  }
  consume(reset??end);
  if(reset!==null) {
    p=100;points.push({t:reset,value:1,reset:true});
    // Only the provider's next scheduled reset is known. No invented later cycles.
    consume(end);
  }
  return points;
}
// Each quota cycle as "how much of one allowance went, and how many tokens it took".
export function cycleSummaries(history) {
  return (history?.cycles || []).map(c=>{
    const used=(c.transitions||[]).reduce((n,x)=>n+(typeof x.percentage_points==='number'?x.percentage_points:0),0);
    const tokens=c.usage?.total_tokens??null;
    let dp=0,dt=0;for(const x of c.transitions||[])if(x.is_direct&&x.percentage_points>0&&x.usage?.total_tokens>0){dp+=x.percentage_points;dt+=x.usage.total_tokens;}
    return {id:c.id,status:c.status,start:time(c.effective_started_at)??time(c.first_observed_at),
      end:time(c.effective_ended_at)??time(c.reset_at),firstSeen:time(c.first_observed_at),lastSeen:time(c.last_observed_at),
      remaining:percent(c.last_remaining_percent),used,tokens,requests:c.usage?.requests??null,
      perPoint:dp>0?dt/dp:used>0&&tokens?tokens/used:null};
  }).filter(c=>c.start!==null).sort((a,b)=>b.start-a.start);
}
// Keeper masks credential keys as the first 3 and last 6 characters.
export const maskedMatch = (masked, id) => typeof masked==='string'&&typeof id==='string'&&masked.length>9&&id.startsWith(masked.slice(0,3))&&id.endsWith(masked.slice(-6));
// Stack the busiest models; everything else is "Other".
export function modelStacks(modelUsage, top=5) {
  const series=(modelUsage?.series||[]).map(s=>({model:s.model,values:(s.total_tokens||[]).map(v=>v||0)}));
  series.forEach(s=>{s.total=s.values.reduce((a,b)=>a+b,0);});
  series.sort((a,b)=>b.total-a.total);
  const kept=series.filter(s=>s.total>0).slice(0,top),rest=series.slice(kept.length).filter(s=>s.total>0);
  if(rest.length)kept.push({model:'Other',values:(modelUsage.buckets||[]).map((_,i)=>rest.reduce((n,s)=>n+(s.values[i]||0),0)),total:rest.reduce((n,s)=>n+s.total,0)});
  return kept;
}
// Drop empty leading buckets so "All time" starts at the first recorded day.
export function firstUsedIndex(tokenUsage) {
  const i=(tokenUsage||[]).findIndex(b=>(b.total_tokens||0)>0||(b.requests||0)>0);
  return i<0?0:i;
}
// Remaining percent of one account at time t, from Keeper's observations.
// Inside a cycle readings are joined; a reset switches to the next cycle's
// first reading; after a reset with no later reading the value is unknown (null).
export function remainingAt(points, t) {
  let lo=0,hi=points.length-1,i=-1;
  while(lo<=hi){const m=(lo+hi)>>1;if(points[m].t<=t){i=m;lo=m+1;}else hi=m-1;}
  if(i<0)return null;
  const a=points[i],b=points[i+1];
  if(b&&b.cycle===a.cycle)return a.p+(b.p-a.p)*(t-a.t)/(b.t-a.t||1);
  const resetPassed=a.reset!==null&&t>=a.reset;
  if(b&&b.t-a.t<=2*HOUR)return t>=(a.reset??b.t)?b.p:a.p;
  return resetPassed?null:a.p;
}
// Tokens one percentage point of this account's allowance bought in its most
// recent cycle with at least 20 points measured. Only direct one-point drops
// count: a cycle's total also holds tokens that never moved the reading.
export function tokensPerPoint(history) {
  const cycles=[...(history?.cycles||[])].sort((a,b)=>(time(b.effective_started_at)??0)-(time(a.effective_started_at)??0));
  for(const c of cycles){
    let points=0,tokens=0;
    for(const x of c.transitions||[])if(x.is_direct&&x.percentage_points>0&&x.usage?.total_tokens>0){points+=x.percentage_points;tokens+=x.usage.total_tokens;}
    if(points>=20)return tokens/points;
  }
  return null;
}
const median=v=>{const s=[...v].sort((a,b)=>a-b);return s.length?s[s.length>>1]:null;};
// Per-account scale: tokens per point, falling back to the median of the same
// provider and plan, then of the same provider.
export function pointScales(accounts, kind) {
  const own=new Map(accounts.map(a=>[a.id,tokensPerPoint(a.histories?.[kind])]));
  const pick=f=>median(accounts.filter(f).map(a=>own.get(a.id)).filter(v=>v>0));
  return new Map(accounts.map(a=>{const v=own.get(a.id);
    if(v>0)return [a.id,{value:v,source:'own'}];
    const plan=pick(b=>b.provider===a.provider&&b.plan===a.plan);if(plan)return [a.id,{value:plan,source:'plan'}];
    const prov=pick(b=>b.provider===a.provider);return [a.id,prov?{value:prov,source:'provider'}:null];}));
}
// Pooled pace: allowance used across all of a provider's accounts per hour of
// time when at least one of them still had allowance (blocked time is excluded,
// since nothing could be used then). Units follow scale(account).
export function pooledRate(accounts, now, lookback, scale) {
  const start=now-lookback;let lost=0;
  for(const a of accounts){const s=scale(a);if(!s)continue;const pts=a.points||[];
    for(let i=1;i<pts.length;i++){const x=pts[i-1],y=pts[i];
      if(x.cycle!==y.cycle||y.p>=x.p||y.t<=start||x.t>=now)continue;
      const overlap=Math.min(y.t,now)-Math.max(x.t,start);lost+=(x.p-y.p)*overlap/(y.t-x.t||1)*s;}}
  let able=0;const step=5*60000;
  for(let t=start;t<now;t+=step)if(accounts.some(a=>(remainingAt(a.points||[],t)??0)>0))able+=step;
  if(able<30*60000)return null;
  return {perHour:lost/able*HOUR,ableHours:able/HOUR,lost};
}
// Stacked history: each account's remaining allowance in units, summed.
export function stackHistory(accounts, start, now, samples=240) {
  const times=new Set([start,now]);
  for(let k=1;k<samples;k++)times.add(start+(now-start)*k/samples);
  for(const a of accounts)for(const p of a.points){if(p.t>start&&p.t<now)times.add(p.t);if(p.reset>start&&p.reset<now){times.add(p.reset-1);times.add(p.reset);}}
  return [...times].sort((x,y)=>x-y).map(t=>({t,values:accounts.map(a=>{
    const v=t===now&&a.remaining!==null&&!a.stale?a.remaining:remainingAt(a.points,t);
    return v===null?null:v*a.scale;})}));
}
// Expected stack from now: one pooled demand drains the account that resets
// first (its allowance would be lost at the reset anyway), then the next. Each
// reset refills that account and repeats every window length.
export function forecastStack(accounts, now, end, perHour, period) {
  const r=accounts.map(a=>a.remaining===null||a.stale?0:a.remaining*a.scale);
  const reset=accounts.map(a=>a.reset!==null&&a.reset>now?a.reset:null);
  const rate=perHour>0?perHour/HOUR:0,out=[{t:now,values:[...r]}];
  let t=now;
  for(let guard=0;guard<1000&&t<end;guard++){
    const nextReset=Math.min(...reset.map(x=>x??Infinity));
    let active=-1;
    r.forEach((v,i)=>{if(v>0&&(active<0||(reset[i]??Infinity)<(reset[active]??Infinity)))active=i;});
    const empty=active>=0&&rate>0?t+r[active]/rate:Infinity;
    const tn=Math.min(nextReset,empty,end);
    if(active>=0&&rate>0)r[active]=tn===empty?0:Math.max(0,r[active]-rate*(tn-t));
    t=tn;out.push({t,values:[...r]});
    let jumped=false;
    reset.forEach((x,i)=>{if(x===t){r[i]=100*accounts[i].scale;reset[i]=period?x+period*1000:null;jumped=true;}});
    if(jumped)out.push({t,values:[...r],reset:true});
  }
  return out;
}
