-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
return function(test,eq,fails,contains)
local B=require('kolibby/batch')
local U=require('kolibby/util')
local function loan(card,id,media)
 return {key=card..':'..id,card_id=card,id=id,checkout_id='checkout-'..id,title=id,author='Writer',
  downloadable=true,media_type=media or 'ebook',expires=2000}
end
local function fixture()
 local a,b,c=loan('A','Alpha'),loan('B','Alpha'),loan('A','Beta','audiobook')
 return {cards={A={id='A'},B={id='B'}},card_aliases={},loans={[a.key]=a,[b.key]=b,[c.key]=c},holds={}},a,b,c
end
local function opts(files)
 return {exists=function(path) return files[path]==true end,now=1000}
end
local function record(loan,path) return {key=loan.key,checkout_id=loan.checkout_id,path=path or loan.key..'.file'} end
local function runner(files,options)
 local calls,persisted,cleaned={},nil,{}
 options=options or opts(files)
 options.directory='/output';options.cache_dir='/cache'
 options.download=function(client,loan,card,settings)
  calls[#calls+1]={key=loan.key,card=card.id,media=loan.media_type}
  settings.progress({stage='downloading',done=1,total=1})
  local r=record(loan);files[r.path]=true;r.work='/cache/'..loan.key;return r
 end
 options.persist=function(records) persisted=U.copy(records) end
 options.cleanup=function(work) cleaned[#cleaned+1]=work end
 return options,calls,function() return persisted,cleaned end
end

test('Download all skips a completed file for the same checkout',function()
 local s,a=fixture();local files={saved=true};local plan=B.plan(s,{[a.key]=record(a,'saved')},opts(files))
 eq(#plan.queue,2);eq(plan.already_downloaded,1)
end)
test('Missing files and replacement checkouts remain queued',function()
 local s,a,b=fixture();local old=record(b,'saved');old.checkout_id='previous'
 local plan=B.plan(s,{[a.key]=record(a,'deleted'),[b.key]=old},opts({saved=true}))
 eq(#plan.queue,3);eq(plan.already_downloaded,0)
end)
test('Duplicate title loans on different cards are independent',function()
 local s,a,b=fixture();local plan=B.plan(s,{[a.key]=record(a,'saved')},opts({saved=true}))
 eq(plan.queue[1].key,b.key);eq(plan.queue[2].media_type,'audiobook')
end)
test('Card-specific download all includes only that card and replacement aliases',function()
 local s,a,b,c=fixture();s.cards.C={id='C'};s.cards.A=nil;s.card_aliases.A='C'
 local o=opts({});o.card_id='C';local p=B.plan(s,{},o);eq(#p.queue,2);eq(p.queue[1].key,a.key);eq(p.queue[2].key,c.key)
 o.card_id='B';p=B.plan(s,{},o);eq(#p.queue,1);eq(p.queue[1].key,b.key)
end)
test('Download all omits expired unsupported stale and unverified loans',function()
 local s,a,b,c=fixture();a.expires=1000;b.stale=true;c.downloadable=false
 local p=B.plan(s,{},opts({}));eq(#p.queue,0);eq(p.unavailable,3)
 s,a,b,c=fixture();s.cards.A.needs_verification=true;s.cards.B.stale=true
 p=B.plan(s,{},opts({}));eq(#p.queue,0);eq(p.unavailable,3)
end)
test('Holds never enter the download queue',function()
 local s=fixture();s.holds['A:held']=loan('A','held');eq(#B.plan(s,{},opts({})).queue,3)
end)
test('Mixed EPUB and MP3 queue saves each result before the next download',function()
 local s=fixture();local files={};local o,calls,state=runner(files);local records={};local saved_count=0
 local original=o.download
 o.download=function(...)
  eq(saved_count,#calls)
  return original(...)
 end
 o.persist=function(r) records=U.copy(r);saved_count=saved_count+1 end
 local r=B.run({},s,{},o);eq(r.downloaded,3);eq(#calls,3);eq(calls[3].media,'audiobook');eq(saved_count,3)
 eq(records['A:Beta'].work,nil);local _,cleaned=state();eq(#cleaned,3)
end)
test('A repeated Download all skips saved paths even after the folder changes',function()
 local s=fixture();local files={};local o,calls,state=runner(files)
 B.run({},s,{},o);local records=state();o.directory='/new-output-folder';local r=B.run({},s,records,o)
 eq(#calls,3);eq(r.downloaded,0);eq(r.already_downloaded,3)
end)
test('One failed title does not prevent other loans from completing',function()
 local s,a=fixture();local files={};local o,calls,state=runner(files);local original=o.download
 o.download=function(client,loan,card,settings)
  if loan.key==a.key then error({kind='network',message='Offline'},0) end
  return original(client,loan,card,settings)
 end
 local r=B.run({},s,{},o);eq(r.downloaded,2);eq(#r.failures,1);eq(r.failures[1].key,a.key)
 local records=state();eq(records[a.key],nil);assert(records['A:Beta'])
end)
test('After interruption completed queue items remain saved and are skipped on retry',function()
 local s,a=fixture();local files={};local o,calls=runner(files);local saved
 o.persist=function(records) saved=U.copy(records);error('Simulated worker interruption',0) end
 fails(function() B.run({},s,{},o) end,'interruption');eq(#calls,1);assert(saved[a.key])
 o.persist=function(records) saved=U.copy(records) end
 local r=B.run({},s,saved,o);eq(r.downloaded,2);eq(r.already_downloaded,1);eq(#calls,3)
end)
test('A persistence failure stops the queue before another transfer',function()
 local s=fixture();local o,calls=runner({});o.persist=function() error('Storage full',0) end
 fails(function() B.run({},s,{},o) end,'Storage full');eq(#calls,1)
end)
test('An incomplete download result is not saved and the next loan is attempted',function()
 local s,a=fixture();local o,calls,state=runner({});local original=o.download
 o.download=function(client,loan,card,settings)
  if loan.key==a.key then return record(loan,'missing') end
  return original(client,loan,card,settings)
 end
 local r=B.run({},s,{},o);eq(r.downloaded,2);eq(#r.failures,1)
 local records=state();eq(records[a.key],nil);eq(#calls,2)
end)
test('Cleanup happens only after a completed record is persisted',function()
 local s=fixture();local o=runner({});local saved=false
 o.persist=function() saved=true end;o.cleanup=function() assert(saved);saved=false end
 eq(B.run({},s,{},o).downloaded,3)
end)
test('Queue progress includes current cover metadata and stable mixed-media counters',function()
 local s=fixture();local o=runner({});local seen={}
 o.progress=function(p)
  assert(p.batch);eq(p.batch_total,3)
  if p.item then seen[p.item.key]=true;assert(p.item.title);assert(p.batch_index>=1) end
 end
 B.run({},s,{},o);eq(U.count(seen),3)
end)
test('A loan that expires while waiting is omitted before its transfer',function()
 local s,a,b,c=fixture();a.expires=os.time()+60;b.expires=os.time()+60;c.expires=os.time()+60
 local o,calls=runner({});o.now=nil;local original=o.download
 o.download=function(...)
  local value=original(...);c.expires=os.time()-1;return value
 end
 local r=B.run({},s,{},o);eq(r.downloaded,2);eq(r.unavailable,1);eq(#calls,2)
end)
test('Batch summary separates new saved failed and unavailable downloads',function()
 local message=B.summary({downloaded=1,already_downloaded=2,unavailable=1,failures={{title='Bad book',message='Unavailable'}}})
 contains(message,'Downloaded: 1');contains(message,'Already downloaded: 2');contains(message,'Failed: 1');contains(message,'Bad book')
 contains(B.summary({downloaded=0,already_downloaded=3,unavailable=0,failures={}}),'No downloads needed')
end)
end
