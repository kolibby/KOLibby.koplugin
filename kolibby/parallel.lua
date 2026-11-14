-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Used only inside the download-all subprocess. Children inherit its process
-- group so Trapper's Cancel all kills the coordinator and every loan worker.
local Store=require('kolibby/store')
local Progress=require('kolibby/progress')
local U=require('kolibby/util')
local M={}
function M.new(root,options)
    options=options or {}
    local ffi=require('ffi')
    require('ffi/posix')
    local util=require('ffi/util')
    -- Linux also stops a worker if its coordinator dies unexpectedly. Check
    -- getppid after prctl to cover the parent dying just before the call.
    if ffi.os=='Linux' then pcall(ffi.cdef,'int prctl(int option, ...);') end
    local parent=ffi.C.getpid()
    local job=Store.new(root)
    local active={}
    local pool={}
    function pool:recover()
        local results={}
        for name in Store.lfs.dir(root) do
            if name:match('^result%-%d+%.json$') then results[#results+1]=job:read(name,{}) end
        end
        return results
    end
    function pool:reset()
        Store.remove_tree(root);job=Store.new(root)
    end
    function pool:start(index,task)
        local result_name='result-'..index..'.json'
        local progress_name='progress-'..index..'.json'
        local pid=ffi.C.fork()
        if pid<0 then error('Could not start a download worker. Try again.',0) end
        if pid==0 then
            local ok,value=pcall(function()
                if ffi.os=='Linux' then
                    assert(ffi.C.prctl(1,ffi.cast('unsigned long',9))==0,'Could not protect the download worker')
                    if ffi.C.getppid()~=parent then ffi.C._exit(1) end
                end
                return task(Progress.throttle(function(p) job:write(progress_name,p) end,{interval=options.interval}))
            end)
            -- File IPC avoids full pipes and inherited pipe descriptors between
            -- sibling workers. Store gives every worker its own atomic rename.
            pcall(job.write,job,result_name,ok and {ok=true,value=value} or {ok=false,message=U.error_message(value)})
            ffi.C._exit(0)
        end
        local handle={pid=tonumber(pid),result_name=result_name,progress_name=progress_name}
        active[handle]=true
        return handle
    end
    function pool:poll(handle)
        if not util.isSubProcessDone(handle.pid) then return nil end
        active[handle]=nil
        local result=job:read(handle.result_name,{})
        if type(result.ok)~='boolean' then return {ok=false,message='The download worker ended unexpectedly. Try again to resume.'} end
        return result
    end
    function pool:progress(handle) return job:read(handle.progress_name,{}) end
    function pool:wait() util.usleep(100000) end
    function pool:close(success)
        -- Persistence/startup errors stop all remaining transfers before the
        -- coordinator returns. Never use terminateSubProcess here: each loan
        -- intentionally belongs to the coordinator's group, rather than its own.
        for handle in pairs(active) do
            if not util.isSubProcessDone(handle.pid) then ffi.C.kill(handle.pid,9) end
        end
        for handle in pairs(active) do util.isSubProcessDone(handle.pid,true);active[handle]=nil end
        -- Keep completed results on interruption/storage failure for recovery.
        if success then Store.remove_tree(root) end
    end
    return pool
end
return M
