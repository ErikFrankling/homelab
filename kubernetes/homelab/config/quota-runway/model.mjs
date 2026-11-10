// Quota percentages are provider observations, not interchangeable token budgets.
export const HOUR = 3600000;
export const time = value => { const n = Date.parse(value); return Number.isFinite(n) ? n : null; };
export const percent = value => typeof value === 'number' && Number.isFinite(value) ? Math.min(100, Math.max(0, value)) : null;
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
export function accountState(account, role, now, lookback=HOUR) {
  const history=account.histories?.[role];
  const seconds=role==='primary'?18000:604800;
  const rows=account.cache?.quota?.quota || [];
  const key=account.provider==='claude'?(role==='primary'?'five_hour':'seven_day'):(role==='primary'?'rate_limit.primary_window':'rate_limit.secondary_window');
  const row=rows.find(r=>r.key===key)||rows.find(r=>!r.key&&r.window?.seconds===seconds&&(!r.scope||r.scope==='window'));
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
export function valueAt(points,t) {
  let previous=null,next=null;
  for(const p of points) {if(p.t>t){next=p;break;}previous=p;}
  const plateau=previous&&next&&previous.cycle!==undefined&&previous.cycle===next.cycle&&previous.p===next.p;
  // Missing history is not zero. Do not bridge a cycle boundary or long gap.
  if(!previous||(t-previous.t>2*HOUR&&!plateau)||(previous.reset!==null&&t>=previous.reset))return null;
  return previous.p;
}
export function historicalPool(accounts,start,end) {
  if(!accounts.length)return [];
  const breaks=accounts.flatMap(a=>a.points.flatMap((p,i)=>{
    const next=a.points[i+1];
    if(!next)return [];
    if(p.cycle!==undefined&&p.cycle===next.cycle&&p.p===next.p)return [];
    const expiry=Math.min(p.t+2*HOUR,p.reset??Infinity);
    return next.t>expiry?[expiry+1]:[];
  }));
  const times=[...new Set([start,end,...breaks,...accounts.flatMap(a=>a.points.map(p=>p.t))].filter(t=>t>=start&&t<=end))].sort((a,b)=>a-b);
  return times.map(t=>{const values=accounts.map(a=>valueAt(a.points,t));return {t,value:values.every(v=>v!==null)?values.reduce((s,v)=>s+v,0)/100:null};});
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
export function forecastPool(accounts,now,end,multiplier=1) {
  if(accounts.some(a=>a.stale||a.remaining===null||!a.rate))return [];
  const series=accounts.map(a=>forecastAccount(a,now,end,multiplier));
  const times=[...new Set(series.flatMap(s=>s.map(p=>p.t)))].sort((a,b)=>a-b);
  function value(s,t,after) {
    const exact=s.filter(p=>p.t===t);if(exact.length)return (after?exact.at(-1):exact[0]).value;
    const i=s.findIndex(p=>p.t>t);if(i<0)return s.at(-1).value;
    const a=s[i-1],b=s[i];return a.value+(b.value-a.value)*(t-a.t)/(b.t-a.t);
  }
  return times.flatMap(t=>{
    const before=series.reduce((n,s)=>n+value(s,t,false),0),after=series.reduce((n,s)=>n+value(s,t,true),0);
    return before===after?[{t,value:before}]:[{t,value:before},{t,value:after,reset:true}];
  });
}
