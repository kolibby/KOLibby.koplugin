-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Release metadata is data, never code. Libby credentials are not used here.
local J=require('kolibby/json')
local M={repository='kolibby/KOLibby.koplugin',max_zip=16*1024*1024}
M.api='https://api.github.com/repos/'..M.repository..'/releases/latest'
local function version(text)
    if type(text)~='string' or #text>64 then return nil end
    local a,b,c=text:match('^v?(%d+)%.(%d+)%.(%d+)$')
    if not a then return nil end
    local result={}
    for _,n in ipairs({a,b,c}) do
        if #n>1 and n:sub(1,1)=='0' or #n>8 then return nil end
        result[#result+1]=tonumber(n)
    end
    return result,table.concat(result,'.')
end
function M.newer(candidate,current)
    local a,b=version(candidate),version(current)
    if not a or not b then error('Unsupported release version. Expected major.minor.patch.',0) end
    for i=1,3 do if a[i]~=b[i] then return a[i]>b[i] end end
    return false
end
function M.release(raw,current)
    if type(raw)~='table' or raw.draft~=false or raw.prerelease~=false then error('GitHub did not return a stable release.',0) end
    local _,number=version(raw.tag_name)
    if not number then error('Unsupported release tag. Expected vmajor.minor.patch.',0) end
    if not M.newer(number,current) then return {status='current',version=current} end
    local filename='KOLibby-'..number..'.zip'
    local expected='https://github.com/'..M.repository..'/releases/download/'..raw.tag_name..'/'..filename
    local selected
    for _,asset in ipairs(type(raw.assets)=='table' and raw.assets or {}) do
        if type(asset)=='table' and asset.name==filename then
            if selected then error('The release has duplicate plugin packages.',0) end
            selected=asset
        end
    end
    if not selected or selected.state~='uploaded' or selected.browser_download_url~=expected or
        type(selected.size)~='number' or selected.size<1 or selected.size>M.max_zip or selected.size~=math.floor(selected.size) then
        error('This release has no compatible KOLibby ZIP package ready to install.',0)
    end
    local digest=type(selected.digest)=='string' and selected.digest:match('^sha256:(%x+)$')
    if not digest or #digest~=64 then error('The release package has no SHA-256 digest. Try again when the upload is complete.',0) end
    local notes=type(raw.body)=='string' and raw.body or ''
    if #notes>128*1024 then error('Release notes exceed the supported size.',0) end
    return {status='available',version=number,tag=raw.tag_name,notes=notes~='' and notes or 'No release notes were provided.',
        url=expected,bytes=selected.size,sha256=digest:lower()}
end
function M.check(transport,current)
    local response=transport{url=M.api,max_bytes=2*1024*1024}
    if response.status==404 then return {status='unpublished'} end
    if response.status==403 or response.status==429 then error('GitHub is limiting update checks. Try again later.',0) end
    if response.status~=200 then error('GitHub could not provide release information. Try again later.',0) end
    local ok,value=pcall(J.decode,response.body or '')
    if not ok then error('GitHub returned invalid release information.',0) end
    return M.release(value,current)
end
function M.prepare(transport,release,options)
    local Install=require('kolibby/updateinstall')
    local Store=require('kolibby/store')
    Install.check_root(options.install_dir)
    Store.mkdir(options.cache_dir)
    local archive=options.cache_dir..'/update.zip.part'
    local ok,result=pcall(function()
        local response=transport{url=release.url,destination=archive,max_bytes=M.max_zip,accept='application/octet-stream'}
        if response.status~=200 or Store.size(archive)~=release.bytes then error('The update download was incomplete. Try again.',0) end
        if Install.hash_file(archive)~=release.sha256 then error('The update package checksum does not match. The installed plugin was not changed.',0) end
        return {stage=Install.unpack(archive,options.install_dir,release.version),version=release.version}
    end)
    os.remove(archive)
    if not ok then error(result,0) end
    return result
end
return M
