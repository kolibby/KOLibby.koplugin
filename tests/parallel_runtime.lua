-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Run with KOReader/LuaJIT. Uses real fork/process groups and synthetic files;
-- no Libby connection, credentials, shelf or installed plugin data is used.
return function(root)
    local ffi=require('ffi')
    require('ffi/posix')
    pcall(ffi.cdef,'int getpgid(int pid);')
    local util=require('ffi/util')
    local Store=require('kolibby/store')
    local Batch=require('kolibby/batch')
    local J=require('kolibby/json')
    local U=require('kolibby/util')
    local checks=0
    local function check(value,message) assert(value,message);checks=checks+1 end
    Store.remove_tree(root);Store.mkdir(root)
    local job=Store.new(root)
    local shelf={cards={A={id='A'}},loans={}}
    for i=1,6 do
        local key='A:'..i
        shelf.loans[key]={key=key,id=tostring(i),card_id='A',checkout_id='fixture-'..i,title='Synthetic loan '..i,
            media_type=i%2==0 and 'audiobook' or 'ebook',downloadable=true,expires=os.time()+3600}
    end
    local function wait_for(fn,message)
        for _=1,300 do if fn() then return end;util.usleep(10000) end
        error(message,0)
    end
    local function started()
        local n=0
        for i=1,6 do if job:read('start-'..i..'.json',{}).pid then n=n+1 end end
        return n
    end
    local mode='overlap'
    local parent_group=tonumber(ffi.C.getpgid(0))
    local function opts()
        return {concurrency=3,directory=root..'/output',cache_dir=root..'/cache',progress_interval=.01,
            persist=function(records)
                if mode=='cancel' then job:write('persist-blocked.json',{});util.usleep(5000000) end
                job:write('downloads.json',records)
            end,
            client_factory=function(auth)
                -- Every transport is constructed after fork, with a private jar.
                return {auth=U.copy(auth),close=function() end,transport={}}
            end,
            download=function(client,loan,card,options)
                local old=job:read('start-'..loan.id..'.json',{})
                local group=tonumber(ffi.C.getpgid(0))
                job:write('start-'..loan.id..'.json',{pid=tonumber(ffi.C.getpid()),group=group,attempt=(old.attempt or 0)+1})
                -- A barrier requires all three workers to be alive together.
                if mode=='overlap' then wait_for(function() return started()>=3 end,'Downloads ran serially') end
                if mode=='crash' and loan.id=='2' then ffi.C._exit(7) end
                Store.mkdir(options.directory)
                local part=options.directory..'/'..loan.id..'.part'
                Store.write_file(part,'resume fixture')
                if mode=='cancel' and loan.id~='1' then
                    while true do
                        job:write('heartbeat-'..loan.id..'.json',{time=util.getTimestamp()})
                        util.usleep(10000)
                    end
                end
                -- Keep first loan slow to exercise completion/replenishment order.
                util.usleep(loan.id=='1' and 300000 or 50000)
                options.progress({stage='downloading',done=1,total=2})
                Store.write_file(part,'complete synthetic publication')
                local path=options.directory..'/'..loan.id..'.file'
                assert(os.rename(part,path))
                return {key=loan.key,checkout_id=loan.checkout_id,path=path,group=group,expires=loan.expires}
            end}
    end
    local function client() return {auth={identity='synthetic'},save=function() end} end
    local result=Batch.run(client(),shelf,{},opts())
    check(result.downloaded==6 and #result.failures==0,'Concurrent batch did not finish')
    local records=job:read('downloads.json',{})
    check(U.count(records)==6,'Concurrent records were lost')
    local pids={}
    for i=1,6 do
        local start=job:read('start-'..i..'.json',{})
        check(start.group==parent_group,'Worker escaped the coordinator process group')
        pids[start.pid]=true
    end
    check(U.count(pids)==6,'Workers did not have independent processes')
    -- A process dying without publishing JSON fails one title, then frees its slot.
    mode='crash';job:write('downloads.json',{})
    result=Batch.run(client(),shelf,{},opts())
    check(result.downloaded==5 and #result.failures==1 and result.failures[1].key=='A:2','Crashed worker blocked other loans')
    -- Exercise the actual KOReader cancellation primitive on an outer worker.
    mode='cancel';job:write('downloads.json',{})
    for i=1,6 do os.remove(root..'/start-'..i..'.json') end
    local pid,fd=util.runInSubProcess(function(_,write_fd)
        Batch.run(client(),shelf,{},opts())
        util.writeToFD(write_fd,'unexpected completion',true)
    end,true)
    check(pid~=false and pid~=nil,'Could not start coordinator')
    wait_for(function() return Store.exists(root..'/persist-blocked.json') end,'Coordinator never collected a finished loan')
    local first=job:read('start-1.json',{})
    check(first.group==pid,'Loan did not inherit outer worker process group')
    util.terminateSubProcess(pid)
    wait_for(function() return util.isSubProcessDone(pid) end,'Cancelled coordinator did not exit')
    if fd then util.readAllFromFD(fd) end
    local heartbeat=Store.read_file(root..'/heartbeat-2.json')
    util.usleep(150000)
    check(Store.read_file(root..'/heartbeat-2.json')==heartbeat,'Cancelled worker is still running')
    check(Store.exists(root..'/output/2.part'),'Cancellation discarded resumable input')
    check(Store.exists(root..'/cache/batch/result-1.json'),'Cancellation discarded uncollected completion')
    -- Retry recovers that completion before clearing the old worker journal.
    mode='retry'
    result=Batch.run(client(),shelf,job:read('downloads.json',{}),opts())
    check(result.already_downloaded==1 and result.downloaded==5,'Retry failed to recover the completed loan')
    check(job:read('start-1.json',{}).attempt==1,'Retry transferred the completed loan again')
    check(U.count(job:read('downloads.json',{}))==6,'Retry lost download records')
    check(not Store.lfs.attributes(root..'/cache/batch'),'Successful batch left worker IPC files')
    Store.remove_tree(root)
    return {passed=checks,failed=0}
end
