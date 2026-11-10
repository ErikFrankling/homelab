import test from 'node:test';
import assert from 'node:assert/strict';
import {HOUR,burnRate,observations,accountState,forecastPool,historicalPool} from './model.mjs';
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
test('stale quota and passed reset are not presented as current or forecast',()=>{
 const a={histories:{primary:history(now-HOUR,now,90,60,now-1)}};
 assert.equal(accountState(a,'primary',now).stale,true);
 assert.equal(accountState({histories:{primary:history(now-HOUR,now-HOUR/2,90,60)}},'primary',now).stale,true);
 assert.equal(accountState({histories:{}},'primary',now).remaining,null);
});
test('pool forecast jumps at staggered resets and changes with pace',()=>{
 const a={remaining:20,stale:false,rate:{perHour:20},reset:now+HOUR};
 const b={remaining:40,stale:false,rate:{perHour:10},reset:now+2*HOUR};
 const series=forecastPool([a,b],now,now+3*HOUR);
 assert.deepEqual(series.filter(p=>p.t===now+HOUR).map(p=>Number(p.value.toFixed(8))),[.3,1.3]);
 assert.ok(Math.abs(series.at(-1).value-1.5)<1e-8);
 assert.ok(forecastPool([a,b],now,now+3*HOUR,2).at(-1).value<series.at(-1).value);
 assert.deepEqual(forecastPool([a,{...b,rate:null}],now,now+3*HOUR),[]);
});
test('history has genuine gaps and account membership is never silently filled with zero',()=>{
 const h=history(now-HOUR,now,90,60);const a={points:observations(h)};
 assert.equal(historicalPool([a,{points:[]}],now-HOUR,now).every(p=>p.value===null),true);
 assert.equal(historicalPool([a],now-2*HOUR,now)[0].value,null);
});
test('cached quota uses usedPercent correctly and a missing 5h limit stays unknown',()=>{
 const a={cache:{refreshed_at:iso(now),quota:{quota:[{usedPercent:16,window:{seconds:604800},resetAt:iso(now+HOUR)}]}},histories:{}};
 assert.equal(accountState(a,'secondary',now).remaining,84);
 assert.equal(accountState(a,'primary',now).remaining,null);
});

test('a long gap between two valid observations breaks the drawn history line',()=>{
 const a={points:[{t:now-4*HOUR,p:90,reset:now+HOUR},{t:now,p:50,reset:now+HOUR}]};
 const values=historicalPool([a],now-4*HOUR,now);
 assert.ok(values.some(p=>p.value===null));
 assert.equal(values[0].value,.9);assert.equal(values.at(-1).value,.5);
});

test('unchanged observations in one reset cycle keep a known depleted plateau',()=>{
 const a={points:[{t:now-4*HOUR,p:0,reset:now+HOUR,cycle:1},{t:now,p:0,reset:now+HOUR,cycle:1}]};
 assert.ok(historicalPool([a],now-4*HOUR,now).every(p=>p.value===0));
});

test('model-specific weekly rows never masquerade as the all-model allowance',()=>{
 const a={provider:'claude',histories:{},cache:{refreshed_at:iso(now),quota:{quota:[
  {key:'limits.weekly_scoped.Fable',scope:'model',usedPercent:0,window:{seconds:604800}},
  {key:'seven_day_oauth_apps',scope:'window',usedPercent:20,window:{seconds:604800}},
  {key:'seven_day',scope:'window',usedPercent:100,window:{seconds:604800}}
 ]}}};
 assert.equal(accountState(a,'secondary',now).remaining,0);
 a.cache.quota.quota.pop();
 assert.equal(accountState(a,'secondary',now).remaining,null);
});
