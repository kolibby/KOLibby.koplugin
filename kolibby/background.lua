-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Runs a task in a forked subprocess without trapping input, so taps and page
-- turns never cancel it. Trapper:dismissableRunInSubprocess() kills its child on
-- the first input event, which on e-ink means almost every automatic sync. The
-- read and reap steps mirror Trapper's, polled from UIManager instead of a
-- coroutine. The task returns a string; done(completed,output) runs once.
local M={}
local COLLECT_INTERVAL=5

function M.run(task,done,deps)
    deps=deps or {}
    local util=deps.util or require('ffi/util')
    local UIManager=deps.UIManager or require('ui/uimanager')
    local pid,fd=util.runInSubProcess(function(_,write_fd)
        local ok,output=pcall(task)
        util.writeToFD(write_fd,ok and type(output)=='string' and output or '',true)
    end,true)
    if not pid then return nil,fd end
    local handle={pid=pid}
    local interval,checks=.125,0
    local check
    local function finish(completed,output)
        if handle.finished then return end
        handle.finished=true
        done(completed,output)
    end
    check=function()
        if handle.finished then return end
        local exited=util.isSubProcessDone(pid)
        if exited or (fd and util.getNonBlockingReadSize(fd)~=0) then
            -- readAllFromFD blocks until the child closes its end, then closes ours.
            local output=fd and util.readAllFromFD(fd) or '';fd=nil
            if not exited then
                local function reap() if not util.isSubProcessDone(pid) then UIManager:scheduleIn(1,reap) end end
                UIManager:scheduleIn(1,reap)
            end
            return finish(true,output)
        end
        checks=checks+1
        if interval<1 and checks%10==0 then interval=math.min(interval*2,1) end
        UIManager:scheduleIn(interval,check)
    end
    -- Explicit cancellation only: a user action that replaces this task, or
    -- leaving the setup-code screen.
    function handle.cancel()
        if handle.finished then return end
        UIManager:unschedule(check)
        util.terminateSubProcess(pid)
        local collect
        collect=function()
            if util.isSubProcessDone(pid) then
                if fd then util.readAllFromFD(fd);fd=nil end
            else
                if fd and util.getNonBlockingReadSize(fd)~=0 then util.readAllFromFD(fd);fd=nil end
                UIManager:scheduleIn(COLLECT_INTERVAL,collect)
            end
        end
        UIManager:scheduleIn(COLLECT_INTERVAL,collect)
        finish(false)
    end
    UIManager:scheduleIn(interval,check)
    return handle
end
return M
