-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Bounded ZIP staging and a directory swap. No archive path is executed.
local J=require('kolibby/json')
local M={max_file=4*1024*1024,max_total=64*1024*1024,max_files=512}
local root_files={['main.lua']=true,['_meta.lua']=true,['README.md']=true,LICENSE=true,NOTICE=true,VERSION=true,['release.json']=true}
local required={'main.lua','_meta.lua','README.md','LICENSE','NOTICE','VERSION','kolibby/updater.lua','kolibby/updatehttp.lua','kolibby/updateinstall.lua'}
function M.entry(entry)
    local name=entry.path
    if type(name)~='string' then error('Invalid update archive path.',0) end
    if entry.mode=='directory' and (name=='KOLibby.koplugin/' or name=='KOLibby.koplugin/kolibby/') then return nil end
    local relative=name:match('^KOLibby%.koplugin/(.+)$')
    if entry.mode~='file' or not relative or not (root_files[relative] or relative:match('^kolibby/[a-z][a-z0-9_]*%.lua$')) then
        error('The update archive contains an unexpected file or link.',0)
    end
    local size=tonumber(entry.size)
    if not size or size<0 or size>M.max_file or size~=math.floor(size) then error('An update file exceeds the supported size.',0) end
    return relative,size
end
function M.manifest(value,entries,version)
    if type(value)~='table' or value.version~=version or type(value.files)~='table' then error('The update manifest does not match the release.',0) end
    local count=0
    for name,file in pairs(value.files) do
        count=count+1
        local entry=entries[name]
        if name=='release.json' or not entry or type(file)~='table' or file.bytes~=tonumber(entry.size) or
            type(file.sha256)~='string' or #file.sha256~=64 or file.sha256:find('[^0-9a-f]') then
            error('The update manifest contains an invalid file or checksum.',0)
        end
    end
    if count>M.max_files then error('The update contains too many files.',0) end
    for name in pairs(entries) do
        if name~='release.json' and not value.files[name] then error('An update file is missing from the manifest.',0) end
    end
    for _,name in ipairs(required) do if not value.files[name] then error('The update package is missing required plugin files.',0) end end
    return value.files
end
function M.hash_file(path)
    local update=require('ffi/sha2').sha256()
    local file=io.open(path,'rb');if not file then error('The update package could not be read.',0) end
    while true do local data=file:read(32768);if not data then break end;update(data) end
    file:close();return update()
end
local function filesystem()
    local lfs=require('lfs');local Store=require('kolibby/store')
    local fs={mode=function(path) return lfs.symlinkattributes(path,'mode') end,rename=os.rename,mkdir=Store.mkdir}
    function fs.remove(path)
        local mode=fs.mode(path)
        if not mode then return end
        if mode~='directory' then assert(os.remove(path),'Could not remove an old update file');return end
        for name in lfs.dir(path) do if name~='.' and name~='..' then fs.remove(path..'/'..name) end end
        assert(lfs.rmdir(path),'Could not remove an old update folder')
    end
    return fs
end
function M.check_root(root,fs)
    fs=fs or filesystem()
    if type(root)~='string' or root:find('[%z\1-\31]') or not root:match('[^/]+%.koplugin$') or fs.mode(root)~='directory' then
        error('The plugin installation folder is not suitable for self-update.',0)
    end
    if fs.mode(root..'/.git') then error('Self-update is disabled for a Git checkout. Update that checkout with Git.',0) end
end
function M.unpack(archive,root,version)
    local Store=require('kolibby/store');local fs=filesystem()
    M.check_root(root,fs)
    local file=assert(io.open(archive,'rb'));local magic=file:read(4);file:close()
    if magic~='PK\3\4' then error('The update is not a ZIP package.',0) end
    local stage=root..'.update-stage'
    fs.remove(stage);fs.mkdir(stage)
    local reader=require('ffi/archiver').Reader:new()
    local ok,result=pcall(function()
        if not reader:open(archive) then error('The update ZIP could not be opened.',0) end
        local entries,ordered,total,count={},{},0,0
        for entry in reader:iterate() do
            count=count+1;if count>M.max_files+2 then error('The update contains too many entries.',0) end
            local name,size=M.entry(entry)
            if name then
                if entries[name] then error('The update contains duplicate filenames.',0) end
                total=total+size
                if total>M.max_total then error('The expanded update exceeds the supported size.',0) end
                entries[name]=entry
                ordered[#ordered+1]=name
            end
        end
        if reader.err then error('The update ZIP is incomplete.',0) end
        local descriptor=entries['release.json']
        if not descriptor or tonumber(descriptor.size)>1024*1024 then error('The update has no valid manifest.',0) end
        local raw=reader:extractToMemory(descriptor.index)
        if not raw then error('The update manifest could not be read.',0) end
        local decoded,value=pcall(J.decode,raw)
        if not decoded then error('The update manifest is invalid.',0) end
        local files=M.manifest(value,entries,version)
        -- File data is read by libarchive with CRC checks, bounded above, then
        -- written as regular files. Link extraction is never invoked.
        for _,name in ipairs(ordered) do if name~='release.json' then
            local info=files[name]
            local data=reader:extractToMemory(entries[name].index)
            if not data or #data~=info.bytes or require('ffi/sha2').sha256(data)~=info.sha256 then
                error('An update file failed checksum verification.',0)
            end
            if name=='VERSION' and data~=version..'\n' then error('The packaged version does not match the release.',0) end
            if name:match('%.lua$') and (data:byte(1)==27 or not loadstring(data,'@'..name)) then error('The update contains invalid Lua source.',0) end
            Store.write_file(stage..'/'..name,data)
        end end
        Store.write_file(stage..'/release.json',raw)
        return stage
    end)
    reader:close()
    if not ok then fs.remove(stage);error(result,0) end
    return result
end
function M.activate(root,stage,fs)
    fs=fs or filesystem()
    M.check_root(root,fs)
    if stage~=root..'.update-stage' or fs.mode(stage)~='directory' then error('The staged update is unavailable.',0) end
    local backup=root..'.update-backup'
    fs.remove(backup)
    if not fs.rename(root,backup) then error('The installed plugin could not be backed up. No update was installed.',0) end
    if not fs.rename(stage,root) then
        if not fs.rename(backup,root) then error('Update activation and restore failed. Restore the .update-backup folder manually.',0) end
        error('The update could not be installed. The previous plugin was restored.',0)
    end
    return backup
end
return M
