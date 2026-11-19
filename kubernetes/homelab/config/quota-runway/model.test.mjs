import test from 'node:test';
import assert from 'node:assert/strict';
import {HOUR,burnRate,observations,accountState,accountSeries,forecastAccount,cycleSummaries,maskedMatch,modelStacks,firstUsedIndex,limitRow,remainingAt,tokensPerPoint,pointScales,pooledRate,stackHistory,forecastStack} from './model.mjs';
const now=Date.parse('2026-11-07T12:00:00Z'),iso=t=>new Date(t).toISOString();
function history(start,end,from,to,reset=now+HOUR,id=1){return {cycles:[{id,first_observed_at:iso(start),last_observed_at:iso(end),first_remaining_percent:from,last_remaining_percent:to,reset_at:iso(reset),transitions:[{from_remaining_percent:from,to_remaining_percent:to,interval_started_at:iso(start),interval_ended_at:iso(end)}]}]};}
test('rate measures percentage points per hour and does not count reset gains',()=>{
 const h=history(now-HOUR,now,90,60);assert.equal(burnRate(h,now).perHour,30);
 const resetHistory={cycles:[...history(now-2*HOUR,now-HOUR,50,0,now-HOUR).cycles,...history(now-HOUR,now,100,75,now+HOUR,2).cycles]};
 assert.equal(burnRate(resetHistory,now,2*HOUR).perHour,37.5);
});
test('depleted time is censored and sparse histories cannot claim a rate',()=>{
 const h=history(now-HOUR,now-HOUR/2,30,0);h.cycles[0].last_observed_at=iso(now);
 assert.equal(burnRate(h,now).perHour,60);
 assert.equal(burnRate(history(now-60000,now,50,45),now),null);
 assert.equal(burnRate(history(now-3*HOUR,now,50,45),now,4*HOUR),null);
});
test('stale quota and passed reset are not presented as current',()=>{
 assert.equal(accountState({histories:{short:history(now-HOUR,now,90,60,now-1)}},'short',now).stale,true);
 assert.equal(accountState({histories:{short:history(now-HOUR,now-HOUR/2,90,60)}},'short',now).stale,true);
 assert.equal(accountState({histories:{}},'short',now).remaining,null);
});
test('cached quota uses usedPercent and a missing 5h limit stays unknown',()=>{
 const a={provider:'codex',cache:{refreshed_at:iso(now),quota:{quota:[{key:'rate_limit.secondary_window',usedPercent:16,window:{seconds:604800},resetAt:iso(now+HOUR)}]}},histories:{}};
 assert.equal(accountState(a,'weekly',now).remaining,84);
 assert.equal(accountState(a,'short',now).remaining,null);
});
test('Codex Pro weekly limit in the primary slot is found by window length',()=>{
 const a={provider:'codex',cache:{refreshed_at:iso(now),quota:{quota:[{key:'rate_limit.primary_window',usedPercent:100,window:{seconds:604800},resetAt:iso(now+HOUR)}]}},histories:{}};
 assert.equal(accountState(a,'weekly',now).remaining,0);
 assert.equal(limitRow(a,'short'),null);
});
test('model-specific weekly rows never masquerade as the all-model allowance',()=>{
 const a={provider:'claude',histories:{},cache:{refreshed_at:iso(now),quota:{quota:[
  {key:'limits.weekly_scoped.Fable',scope:'model',usedPercent:0,window:{seconds:604800}},
  {key:'seven_day_oauth_apps',scope:'window',usedPercent:20,window:{seconds:604800}},
  {key:'seven_day',scope:'window',usedPercent:100,window:{seconds:604800}}
 ]}}};
 assert.equal(accountState(a,'weekly',now).remaining,0);
 a.cache.quota.quota.pop();
 assert.equal(accountState(a,'weekly',now).remaining,null);
});
test('an account line breaks at a new cycle and keeps a flat plateau connected',()=>{
 const pts=[{t:now-10*HOUR,p:40,cycle:1,reset:now-5*HOUR},{t:now-6*HOUR,p:40,cycle:1,reset:now-5*HOUR},{t:now-5*HOUR,p:100,cycle:2,reset:now+HOUR},{t:now,p:80,cycle:2,reset:now+HOUR}];
 const s=accountSeries(pts,now-12*HOUR,now);
 assert.deepEqual(s.map(p=>p.value),[40,40,null,100,80]);
});
test('a line entering the window starts at the window edge from the earlier reading',()=>{
 const pts=[{t:now-10*HOUR,p:90,cycle:1,reset:now+HOUR},{t:now-HOUR,p:89,cycle:1,reset:now+HOUR}];
 const s=accountSeries(pts,now-2*HOUR,now);
 assert.deepEqual(s.map(p=>[p.t,p.value]),[[now-2*HOUR,90],[now-HOUR,89]]);
});
test('one account missing history never hides the other accounts',()=>{
 const a=accountSeries(observations(history(now-5*HOUR,now,90,60)),now-6*HOUR,now);
 assert.ok(a.some(p=>p.value!==null));
 assert.deepEqual(accountSeries([],now-6*HOUR,now),[]);
});
test('forecast refills at the next reset and changes with pace',()=>{
 const a={remaining:20,stale:false,rate:{perHour:20},reset:now+2*HOUR};
 const f=forecastAccount(a,now,now+3*HOUR);
 assert.equal(f.find(p=>p.reset).value,1);
 assert.ok(forecastAccount(a,now,now+3*HOUR,2).at(-1).value<f.at(-1).value);
 assert.deepEqual(forecastAccount({...a,stale:true},now,now+HOUR),[]);
});
test('weekly cycles report used points, tokens and tokens per point',()=>{
 const c=cycleSummaries({cycles:[{id:2,status:'current',effective_started_at:iso(now),effective_ended_at:iso(now+7*24*HOUR),last_remaining_percent:60,usage:{total_tokens:4000,requests:3},transitions:[{percentage_points:30},{percentage_points:10}]},
  {id:1,status:'completed',effective_started_at:iso(now-7*24*HOUR),effective_ended_at:iso(now),last_remaining_percent:0,usage:{total_tokens:0},transitions:[]}]});
 assert.equal(c[0].id,2);assert.equal(c[0].used,40);assert.equal(c[0].perPoint,100);
 assert.equal(c[1].perPoint,null);
});
test('masked credential keys match their identity',()=>{
 assert.ok(maskedMatch('fc2*********cbd22f','fc2d635577cbd22f'));
 assert.ok(!maskedMatch('fc2*********cbd22f','507648a22452c814'));
});
test('model stacks keep the busiest models and fold the rest into Other',()=>{
 const s=modelStacks({buckets:[1,2],series:[{model:'a',total_tokens:[5,5]},{model:'b',total_tokens:[1,0]},{model:'c',total_tokens:[0,2]},{model:'z',total_tokens:[0,0]}]},2);
 assert.deepEqual(s.map(x=>[x.model,x.total]),[['a',10],['c',2],['Other',1]]);
 assert.equal(firstUsedIndex([{total_tokens:0},{total_tokens:0},{total_tokens:3}]),2);
});
test('remaining is interpolated inside a cycle, switches at reset and is unknown after an unobserved reset',()=>{
 const pts=[{t:0,p:100,cycle:1,reset:10*HOUR},{t:2*HOUR,p:80,cycle:1,reset:10*HOUR},{t:10*HOUR+60000,p:100,cycle:2,reset:20*HOUR}];
 assert.equal(remainingAt(pts,HOUR),90);
 assert.equal(remainingAt(pts,5*HOUR),80);
 assert.equal(remainingAt(pts,-1),null);
 assert.equal(remainingAt([{t:0,p:40,cycle:1,reset:HOUR}],2*HOUR),null);
 assert.equal(remainingAt([{t:0,p:40,cycle:1,reset:HOUR}],HOUR/2),40);
});
test('tokens per point use the latest cycle with real use and fall back to the plan',()=>{
 const d=(p,t,direct=true)=>({percentage_points:p,is_direct:direct,usage:{total_tokens:t}});
 const h={cycles:[{id:2,effective_started_at:iso(now),transitions:[d(5,1)]},{id:1,effective_started_at:iso(now-HOUR),transitions:[d(30,3000),d(20,2000),d(10,99999,false)],usage:{total_tokens:999999}}]};
 assert.equal(tokensPerPoint(h),100);
 const s=pointScales([{id:'a',provider:'claude',plan:'max',histories:{weekly:h}},{id:'b',provider:'claude',plan:'max',histories:{}}],'weekly');
 assert.deepEqual(s.get('b'),{value:100,source:'plan'});
});
test('pooled pace counts use across accounts and leaves out time when everything was empty',()=>{
 const a={points:[{t:now-4*HOUR,p:0,cycle:1,reset:null},{t:now-2*HOUR,p:0,cycle:1,reset:null}]};
 const b={points:[{t:now-2*HOUR,p:100,cycle:1,reset:null},{t:now,p:50,cycle:1,reset:null}]};
 const r=pooledRate([a,b],now,4*HOUR,()=>1);
 assert.ok(Math.abs(r.perHour-25)<1);assert.ok(Math.abs(r.ableHours-2)<0.1);
});
test('the expected stack drains the first reset, refills at resets and repeats each window',()=>{
 const accounts=[{remaining:50,stale:false,reset:now+10*HOUR,scale:1},{remaining:0,stale:false,reset:now+2*HOUR,scale:1}];
 const f=forecastStack(accounts,now,now+30*HOUR,10,24*3600);
 const at=t=>f.filter(p=>p.t===t).at(-1).values;
 assert.deepEqual(at(now+2*HOUR),[30,100]);
 // the first account (earlier reset) empties at +5h, then the second drains until the first refills at +10h
 assert.deepEqual(at(now+5*HOUR),[0,100]);
 assert.deepEqual(at(now+10*HOUR),[100,50]);
 assert.ok(f.some(p=>p.reset&&p.t===now+26*HOUR));
});
test('the observed stack sums every account in its unit',()=>{
 const a={points:[{t:now-HOUR,p:50,cycle:1,reset:null}],remaining:40,stale:false,scale:2};
 const b={points:[{t:now-HOUR,p:10,cycle:1,reset:null}],remaining:null,stale:true,scale:10};
 const s=stackHistory([a,b],now-HOUR,now,4);
 assert.deepEqual(s[0].values,[100,100]);assert.deepEqual(s.at(-1).values,[80,100]);
});
