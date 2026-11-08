-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Download progress crosses from the worker to the parent through progress.json.
-- Each write is a create, chmod and rename, slow on the FAT storage of Kindle and
-- Kobo, and each change repaints the e-ink dialog. A new stage, MP3 part or queue
-- position is written at once; counts within one step at most once per interval.
local M={}
function M.eink(Device)
    if Device==nil then
        local ok,value=pcall(require,'device');Device=ok and value or nil
    end
    if type(Device)~='table' or type(Device.hasEinkScreen)~='function' then return false end
    local called,value=pcall(Device.hasEinkScreen,Device)
    return called and value and true or false
end
-- Seconds between progress writes, and between the parent's reads.
function M.write_interval(eink) return eink and 2 or .5 end
function M.poll_interval(eink) return eink and 1 or .5 end
local function default_clock()
    local ok,socket=pcall(require,'socket')
    if ok and type(socket)=='table' and type(socket.gettime)=='function' then return socket.gettime end
    return os.time
end
local function step(value)
    return table.concat({tostring(value.stage),tostring(value.detail),tostring(value.batch_index),
        type(value.item)=='table' and tostring(value.item.key) or ''},'\n')
end
function M.throttle(write,options)
    options=options or {}
    local interval=options.interval or M.write_interval(M.eink())
    local now=options.clock or default_clock()
    local last_step,last_time
    return function(value)
        local current,time=step(value),now()
        if current==last_step and time-last_time<interval then return false end
        last_step,last_time=current,time
        write(value)
        return true
    end
end
return M
