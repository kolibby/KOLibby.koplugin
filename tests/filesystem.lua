-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
return function(test,eq,fails,contains)
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
    function fs.currentdir() return '/mnt/us/koreader' end
    return fs
end
local function environment(options)
    options=options or {}
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
        elseif name=='datastorage' then return options.datastorage or {
            getSettingsDir=function() return '/__kolibby_test_missing_settings__' end,
            getDataDir=function() return '/__kolibby_test_missing_data__' end}
        elseif name=='ui/uimanager' then return options.uimanager or {scheduleIn=function() end}
        elseif name=='ui/trapper' and options.trapper then return options.trapper
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
test('Kindle and Kobo default folders are absolute although KOReader data is "."',function()
    local env=environment{bundled=true,datastorage={
        getSettingsDir=function() return '/__kolibby_test_missing_settings__' end,
        getDataDir=function() return '.' end,getFullDataDir=function() return '/mnt/us/koreader' end}}
    local instance=env.start()
    eq(instance.config.download_dir,'/mnt/us/koreader/KOLibby')
    eq(instance.cache_dir,'/mnt/us/koreader/cache/kolibby');eq(instance.cover_dir,'/mnt/us/koreader/cache/kolibby/covers')
    -- Older KOReader without getFullDataDir still gets absolute paths.
    env=environment{bundled=true,datastorage={
        getSettingsDir=function() return '/__kolibby_test_missing_settings__' end,getDataDir=function() return '.' end}}
    eq(env.start().config.download_dir,'/mnt/us/koreader/KOLibby')
end)
test('Relative download folders and records saved by earlier versions become absolute once',function()
    local env=environment{bundled=true}
    local Plugin=env.start()
    local writes={}
    local state={config={interval_minutes=30,download_dir='./KOLibby'},
        downloads={a={path='./KOLibby/a.epub'},b={path='/mnt/us/documents/b.epub'},c={kind='mp3'}},
        store={write=function(_,name,value) writes[#writes+1]=name end}}
    Plugin.migratePaths(state)
    eq(state.config.download_dir,'/mnt/us/koreader/KOLibby')
    eq(state.downloads.a.path,'/mnt/us/koreader/KOLibby/a.epub');eq(state.downloads.b.path,'/mnt/us/documents/b.epub')
    eq(table.concat(writes,','),'config.json,downloads.json')
    writes={};Plugin.migratePaths(state);eq(#writes,0)
end)
test('Bookshelf open callbacks retain KOLibby expiry and audiobook checks',function()
    local env=environment{bundled=true};local plugin=env.start()
    local opened,messages={},{}
    plugin.message=function(_,text) messages[#messages+1]=text end
    local loan={key='A:42',checkout_id='fixture',expires=os.time()+3600}
    local record={key=loan.key,checkout_id=loan.checkout_id,path='/fixture/download',expires=loan.expires}
    plugin.downloads[loan.key]=record
    local function open(path) opened[#opened+1]=path end
    plugin:openLoan(loan,open);eq(opened[1],record.path)
    record.expires=os.time()-1;plugin:openLoan(loan,open);eq(#opened,1);contains(messages[1],'loan period has ended')
    record.expires=loan.expires;record.kind='mp3';plugin:openLoan(loan,open);eq(#opened,1);contains(messages[2],'audio player')
end)
test('Input cannot cancel background sync; user actions and leaving the setup-code screen can',function()
    local Coordinator=require('kolibby/coordinator')
    local queue={}
    local ui={scheduleIn=function(_,_,f) queue[#queue+1]=f end,
        unschedule=function(_,f) for i=#queue,1,-1 do if queue[i]==f then table.remove(queue,i) end end end,
        close=function() end,show=function() error('background work must not show a widget',0) end}
    local function tick() local current=queue;queue={};for _,f in ipairs(current) do f() end end
    local children={}
    local util={}
    function util.runInSubProcess(func)
        if util.fail then return false,'fork failed' end
        local child={pid=#children+1,func=func};children[child.pid]=child;return child.pid,child
    end
    function util.writeToFD(fd,data) fd.output=data;fd.done=true;return true end
    function util.isSubProcessDone(pid) return children[pid].done==true end
    function util.getNonBlockingReadSize(fd) return fd.output and #fd.output or 0 end
    function util.readAllFromFD(fd) fd.closed=true;return fd.output or '' end
    function util.terminateSubProcess(pid) children[pid].killed=true;children[pid].done=true end
    local function finish(pid) local c=children[pid];c.func(pid,c) end
    local wrapped=0
    local saved_util=package.loaded['ffi/util'];package.loaded['ffi/util']=util
    local ok,err=pcall(function()
        local env=environment{bundled=true,uimanager=ui,trapper={wrap=function() wrapped=wrapped+1 end}}
        local plugin=env.start();queue={}
        local results={}
        local function done(value,message) results[#results+1]={value=value,message=message} end
        local function work() return {synced=true} end
        -- Automatic sync: no trap widget, and it completes on its own.
        plugin:runTask('Synchronizing',work,done,true)
        eq(Coordinator.owner,plugin);eq(Coordinator.background.owner,plugin)
        tick();tick();eq(#results,0)
        finish(1);tick()
        eq(#results,1);eq(results[1].value.synced,true);eq(Coordinator.owner,nil);eq(Coordinator.background,nil);assert(children[1].closed)
        -- A user action replaces a running sync.
        plugin:runTask('Synchronizing',work,done,true)
        plugin:preemptBackground()
        eq(results[2].message,'cancelled');assert(children[2].killed);eq(Coordinator.owner,nil);eq(Coordinator.background,nil)
        finish(2);tick();tick();eq(#results,2)
        plugin:runTask('Synchronizing',work,done,true)
        plugin:runTask('Downloading EPUB…',work,done,false)
        eq(results[3].message,'cancelled');assert(children[3].killed);eq(wrapped,1);eq(Coordinator.owner,plugin)
        plugin.busy=false;Coordinator.release(plugin)
        -- The setup-code poll survives other actions until its screen closes.
        plugin.pairing={};Coordinator.pair_owner=plugin
        plugin:runTask('Requesting a Libby setup code…',work,done,true)
        plugin:preemptBackground();eq(#results,3);assert(not children[4].killed)
        plugin:cancelPairing()
        eq(results[4].message,'cancelled');assert(children[4].killed);eq(Coordinator.pair_owner,nil);eq(Coordinator.owner,nil)
        -- A failed fork is reported as a failure, so automatic sync backs off.
        util.fail=true
        plugin:runTask('Synchronizing',work,done,true)
        contains(results[5].message,'ended unexpectedly');eq(Coordinator.owner,nil);eq(Coordinator.background,nil)
    end)
    package.loaded['ffi/util']=saved_util
    Coordinator.owner=nil;Coordinator.background=nil;Coordinator.pair_owner=nil
    assert(ok,err)
end)
end
