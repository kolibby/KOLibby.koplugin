-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
return function(test,eq,fails)
local function backend()
    local fs={mode_reads=0}
    function fs.attributes(path,field)
        if field=='size' then return 42 end
        return path:match('/download$') and 'file' or 'directory'
    end
    function fs.symlinkattributes(path,field)
        fs.mode_reads=fs.mode_reads+1
        if path:match('/%.git$') then return nil end
        return fs.attributes(path,field)
    end
    function fs.mkdir() return true end
    function fs.dir() return function() end end
    function fs.rmdir() return true end
    return fs
end
local function environment(options)
    local bundled,plain=backend(),backend()
    local modules,requests,registered={},{},{}
    local import
    local function load_source(path)
        local chunk=assert(loadfile(path))
        setfenv(chunk,setmetatable({require=function(name) return import(name) end},{__index=_G}))
        return chunk()
    end
    import=function(name)
        requests[name]=(requests[name] or 0)+1
        if name=='libs/libkoreader-lfs' then
            if options.bundled then return bundled end
            error("module 'libs/libkoreader-lfs' not found",0)
        elseif name=='lfs' then
            if options.plain then return plain end
            error("module 'lfs' not found",0)
        elseif name=='kolibby/store' or name=='kolibby/updateinstall' then
            if not modules[name] then modules[name]=load_source(name..'.lua') end
            return modules[name]
        elseif name=='ui/widget/container/widgetcontainer' then return {extend=function(_,value) return value end}
        elseif name=='datastorage' then return {
            getSettingsDir=function() return '/__kolibby_test_missing_settings__' end,
            getDataDir=function() return '/__kolibby_test_missing_data__' end}
        elseif name=='ui/uimanager' then return {scheduleIn=function() end}
        elseif name:match('^ui/elements/.-_menu_order$') then return {tools={'read_timer','more_tools'}}
        elseif name:match('^ui/') or name=='device' then return {}
        else return require(name) end
    end
    local function start()
        local Plugin=load_source('main.lua')
        local instance=setmetatable({path='.',ui={menu={registerToMainMenu=function(_,widget) registered[#registered+1]=widget end}}},{__index=Plugin})
        instance:init()
        eq(#registered,1)
        local items={};registered[1]:addToMainMenu(items)
        eq(items.kolibby.text,'KOLibby')
        eq(items.kolibby.sub_item_table_func()[1].text,'Connect to Libby')
        return instance
    end
    return {start=start,import=import,bundled=bundled,plain=plain,requests=requests,modules=modules}
end

test('Plugin startup registers Tools when only KOReader filesystem support exists',function()
    local env=environment{bundled=true}
    env.start()
    eq(env.modules['kolibby/store'].lfs,env.bundled)
    eq(env.requests.lfs,nil)
end)
test('Plugin startup still supports the legacy filesystem module',function()
    local env=environment{plain=true}
    env.start()
    assert(env.modules['kolibby/store'].exists('/fixture/download'))
end)
test('The bundled filesystem is preferred when both module names are available',function()
    local env=environment{bundled=true,plain=true}
    env.start()
    eq(env.modules['kolibby/store'].lfs,env.bundled)
    eq(env.requests.lfs,nil)
end)
test('The updater uses the same filesystem backend as normal plugin storage',function()
    local env=environment{bundled=true}
    local Store=env.import('kolibby/store')
    env.import('kolibby/updateinstall').check_root('/fixture/KOLibby.koplugin')
    eq(Store.lfs,env.bundled);eq(env.bundled.mode_reads,2);eq(env.requests.lfs,nil)
end)
test('The updater also shares the legacy fallback filesystem backend',function()
    local env=environment{plain=true}
    local Store=env.import('kolibby/store')
    env.import('kolibby/updateinstall').check_root('/fixture/KOLibby.koplugin')
    eq(Store.lfs,env.plain);eq(env.plain.mode_reads,2)
end)
test('Missing filesystem support remains an explicit startup error',function()
    local env=environment{}
    fails(env.start,"module 'lfs' not found")
end)
end
