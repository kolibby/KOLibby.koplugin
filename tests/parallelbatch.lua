-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
return function(test,eq,fails,contains)
local B=require('kolibby/batch')
local U=require('kolibby/util')
local P=require('kolibby/progress')
local function fixture(count,delays)
    local shelf={cards={A={id='A'}},loans={}}
    for i=1,count do
        local key='A:'..i
        shelf.loans[key]={key=key,id=tostring(i),card_id='A',checkout_id='checkout-'..i,title='Loan '..i,
            downloadable=true,media_type=i%2==0 and 'audiobook' or 'ebook',expires=2000}
    end
    local files,saved,events,clients={},{},{},{}
    local state={time=0,running=0,peak=0,started=0,stopped=0,credential_handoffs=0}
    local pending={}
    local pool={}
    function pool:start(index,task)
        if self.fail_at==index then error('Cannot fork',0) end
        state.running=state.running+1;state.started=state.started+1;state.peak=math.max(state.peak,state.running)
        events[#events+1]='start '..index
        local h={index=index,task=task,ready=state.time+(delays and delays[index] or 1)};pending[h]=true;return h
    end
    function pool:poll(h)
        if state.time<h.ready then return nil end
        state.running=state.running-1;pending[h]=nil;events[#events+1]='finish '..h.index
        local ok,value=pcall(h.task,function(p) h.progress=p end)
        if ok and value.auth then state.credential_handoffs=state.credential_handoffs+1
        elseif ok then eq(value.base_identity,nil);eq(value.base_chip,nil) end
        return ok and {ok=true,value=value} or {ok=false,message=U.error_message(value)}
    end
    function pool:progress(h) return h.progress or {stage='downloading',done=state.time,total=10} end
    function pool:wait() state.time=state.time+1;assert(state.time<50,'Pool failed to settle') end
    function pool:close(success)
        state.closed=success
        for _ in pairs(pending) do state.stopped=state.stopped+1 end
    end
    local client={auth={identity='original',chip='chip'}}
    function client:save() state.auth_saves=(state.auth_saves or 0)+1 end
    local opts={now=1000,concurrency=3,pool=pool,directory='/output',cache_dir='/cache',exists=function(path) return files[path]==true end,
        client_factory=function(auth)
            local c={auth=U.copy(auth)};clients[#clients+1]=c
            c.close=function() c.closed=true end
            return c
        end,
        download=function(c,loan,card,settings)
            assert(c~=client);eq(card.id,'A')
            settings.progress({stage='downloading',done=1,total=2})
            local path='/output/'..loan.id;files[path]=true
            return {key=loan.key,checkout_id=loan.checkout_id,path=path,work='/cache/'..loan.id}
        end,
        persist=function(records) saved[#saved+1]=U.copy(records) end,
        cleanup=function() end}
    return {shelf=shelf,files=files,saved=saved,events=events,clients=clients,state=state,pool=pool,client=client,opts=opts}
end
local function run(f,records) return B.run(f.client,f.shelf,records or {},f.opts) end

test('Three mixed-media loans start together and a free slot is replenished out of order',function()
    local f=fixture(6,{8,1,2,1,1,1});local seen={}
    local original=f.opts.download
    f.opts.download=function(c,loan,card,settings)
        seen[loan.media_type]=true
        return original(c,loan,card,settings)
    end
    local r=run(f)
    eq(r.downloaded,6);eq(f.state.peak,3);eq(f.state.closed,true)
    eq(table.concat({f.events[1],f.events[2],f.events[3]},','),'start 1,start 2,start 3')
    contains(table.concat(f.events,','),'finish 2,start 4')
    eq(f.events[#f.events],'finish 1');eq(#f.saved,6);eq(U.count(f.saved[6]),6)
    assert(seen.ebook and seen.audiobook);eq(#f.clients,6)
    for _,c in ipairs(f.clients) do assert(c.closed) end
    for i=1,6 do eq(U.count(f.saved[i]),i) end
    eq(f.state.credential_handoffs,0)
end)
test('A concurrency request cannot exceed three simultaneous loans',function()
    local f=fixture(5);f.opts.concurrency=100
    eq(run(f).downloaded,5);eq(f.state.peak,3)
end)
test('A failed parallel loan frees its slot while the other loans finish',function()
    local f=fixture(5,{1,4,4,1,1});local original=f.opts.download
    f.opts.download=function(c,loan,...)
        if loan.id=='1' then error({message='Synthetic offline failure'},0) end
        return original(c,loan,...)
    end
    local r=run(f);eq(r.downloaded,4);eq(#r.failures,1);eq(r.failures[1].key,'A:1')
    eq(U.count(f.saved[4]),4);eq(f.saved[4]['A:1'],nil);eq(f.state.closed,true)
end)
test('A persistence failure stops every remaining parallel worker before refilling',function()
    local f=fixture(6,{1,8,8});f.opts.persist=function() error('Storage full',0) end
    fails(function() run(f) end,'Storage full')
    eq(f.state.started,3);eq(f.state.stopped,2);eq(f.state.closed,false)
end)
test('A failed worker launch stops earlier workers in the same batch',function()
    local f=fixture(5);f.pool.fail_at=2
    fails(function() run(f) end,'Cannot fork')
    eq(f.state.started,1);eq(f.state.stopped,1);eq(f.state.closed,false);eq(#f.saved,0)
end)
test('Parallel completion recovery accepts only existing files for current eligible checkouts',function()
    local f=fixture(5);local function record(id,checkout,path)
        f.files[path]=true
        return {ok=true,value={record={key='A:'..id,checkout_id=checkout,path=path}}}
    end
    local recovered={record(1,'checkout-1','/recovered'),record(2,'old-checkout','/stale'),
        record(3,'checkout-3','/expired'),record(4,'checkout-4','/missing'),{ok=false,message='Old failure'}}
    f.files['/missing']=nil;f.shelf.loans['A:3'].expires=1000
    function f.pool:recover() return recovered end
    function f.pool:reset() f.state.reset=true end
    local r=run(f)
    eq(r.already_downloaded,1);eq(r.downloaded,3);eq(r.unavailable,1);eq(#r.failures,0)
    eq(f.saved[1]['A:1'].path,'/recovered');eq(f.state.started,3);assert(f.state.reset)
end)
test('A missing output from a worker is reported while other parallel loans complete',function()
    local f=fixture(3);local original=f.opts.download
    f.opts.download=function(c,loan,...)
        local r=original(c,loan,...);if loan.id=='2' then f.files[r.path]=nil end;return r
    end
    local r=run(f);eq(r.downloaded,2);eq(#r.failures,1);eq(r.failures[1].key,'A:2')
end)
test('Sibling identity refreshes are saved serially without replacing a newer identity',function()
    local f=fixture(3,{1,2,3});local original=f.opts.download
    f.opts.download=function(c,loan,...)
        c.auth.identity='refreshed-'..loan.id
        return original(c,loan,...)
    end
    eq(run(f).downloaded,3);eq(f.client.auth.identity,'refreshed-1');eq(f.state.auth_saves,1);eq(f.state.credential_handoffs,3)
end)
test('Parallel progress preserves all active loans and completed counts',function()
    local f=fixture(4,{1,4,4,1});local three,after_completion=false,false
    f.opts.progress=function(p)
        assert(p.batch);eq(p.batch_total,4)
        if p.stage~='batch_complete' then
            eq(p.batch_running,#p.active)
            for _,a in ipairs(p.active) do assert(a.item.title);assert(a.batch_index>=1) end
            if #p.active==3 then three=true end
            if p.batch_completed>0 and #p.active>0 then after_completion=true end
        else eq(p.batch_running,0);eq(p.batch_completed,4);eq(p.batch_downloaded,4) end
    end
    run(f);assert(three and after_completion)
end)
test('A secondary loan progress change repaints without changing the focused loan',function()
    local a={stage='downloading',done=1,total=10,batch_completed=0,batch_downloaded=0,batch_running=2,
        active={{item={key='A:1'},stage='downloading',done=1,total=10},{item={key='A:2'},stage='downloading',done=1,total=10}}}
    local signature=P.signature(a);a.active[2].done=2;assert(P.signature(a)~=signature)
    local now,writes=0,0;local writer=P.throttle(function() writes=writes+1 end,{interval=2,clock=function() return now end})
    writer(a);a.active[2].done=3;writer(a);eq(writes,1)
    a.active[2].stage='joining';writer(a);eq(writes,2)
    a.batch_completed=1;a.batch_downloaded=1;writer(a);eq(writes,3)
end)
end
