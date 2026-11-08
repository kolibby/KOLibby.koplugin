-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- CA bundle discovery and user-facing explanations for failed connections.
-- Messages name the host and the library's reason only: never paths, queries,
-- headers, credentials or response bodies.
local M={}
M.OPTIONS={'all','no_sslv2','no_sslv3','no_tlsv1','no_tlsv1_1'}

local function readable(path)
    if type(path)~='string' or path=='' then return false end
    local f=io.open(path,'rb');if not f then return false end
    f:close();return true
end
local function currentdir()
    for _,name in ipairs({'libs/libkoreader-lfs','lfs'}) do
        local ok,lfs=pcall(require,name)
        if ok and type(lfs)=='table' and type(lfs.currentdir)=='function' then
            local dir=lfs.currentdir();if type(dir)=='string' and dir~='' then return dir end
        end
    end
end

-- KOReader ships data/ca-bundle.crt relative to its install directory, which is
-- the working directory on Kindle, Kobo and Android. LuaSec 1.3.2 (KOReader
-- 2026.07.x) has no ssl.get_system_ca(), so resolve an absolute path ourselves.
-- KOReader's bundle wins over a possibly stale firmware bundle.
function M.candidates(ssl,env)
    env=env or {}
    local list={}
    local cwd=env.cwd or currentdir()
    if cwd then list[#list+1]=cwd..'/data/ca-bundle.crt' end
    local home=env.koreader_dir or os.getenv('KOREADER_DIR')
    if home and home~='' then list[#list+1]=home..'/data/ca-bundle.crt' end
    list[#list+1]='data/ca-bundle.crt'
    if ssl and type(ssl.get_system_ca)=='function' then
        local ok,path=pcall(ssl.get_system_ca)
        if ok and type(path)=='string' then list[#list+1]=path end
    end
    for _,path in ipairs({'/etc/ssl/certs/ca-certificates.crt','/etc/pki/tls/certs/ca-bundle.crt','/etc/ssl/cert.pem','/etc/ssl/ca-bundle.pem'}) do
        list[#list+1]=path
    end
    return list
end
local cached
function M.ca_bundle(ssl,exists)
    if cached and not exists then return cached end
    for _,path in ipairs(M.candidates(ssl)) do
        if (exists or readable)(path) then
            if not exists then cached=path end
            return path
        end
    end
end
function M.reset() cached=nil end

-- LuaSocket's try() raises {message}; our own code raises strings or tables.
function M.text(err)
    if type(err)=='table' then err=err.detail or err.message or err[1] end
    if type(err)~='string' then return 'unknown error' end
    err=err:gsub('^.-:%d+: ','')
    -- Never echo an address or filesystem path from an error string.
    err=err:gsub('https?://%S+','<address>'):gsub('/[%w%._%-/]+','<path>')
    return #err>120 and err:sub(1,117)..'...' or err
end

local patterns={
    {'error loading CA locations','ca'},
    {'certificate verify failed','certificate'},
    {'TLS hostname validation failed','hostname'},{'hostname does not match','hostname'},
    {'host or service not provided','dns'},{'not known','dns'},{'name resolution','dns'},{'No address associated','dns'},
    {'connection refused','refused'},{'Network is unreachable','unreachable'},{'No route to host','unreachable'},
    {'timeout','timeout'},{'wantread','timeout'},{'wantwrite','timeout'},
    {'compressed response','decode'},{'exceeds size limit','size'},
    {'Could not create the download file','storage'},{'No space left','storage'},{'Read%-only file system','storage'},{'Permission denied','storage'},
    {'closed','closed'},{'Connection reset','closed'},{'Broken pipe','closed'},
}
function M.classify(err)
    local text=M.text(err)
    local raw=type(err)=='table' and (err.detail or err.message or err[1]) or err
    raw=type(raw)=='string' and raw or ''
    for _,p in ipairs(patterns) do
        if raw:lower():find(p[1]:lower()) then return p[2],text end
    end
    return 'other',text
end

-- After "certificate verify failed", repeat only the TLS handshake, accepting
-- the result just long enough to read why verification failed. No request
-- bytes are ever written on this connection.
function M.certificate_reasons(host,port,cafile,timeout)
    local ok,reasons=pcall(function()
        local socket,ssl=require('socket'),require('ssl')
        local tcp=socket.tcp();tcp:settimeout(timeout or 15)
        local connected,err=tcp:connect(host,port)
        if not connected then tcp:close();error(err,0) end
        local conn,werr=ssl.wrap(tcp,{mode='client',protocol='any',verify='peer',verifyext={'lsec_continue'},cafile=cafile,options=M.OPTIONS})
        if not conn then tcp:close();error(werr,0) end
        conn:sni(host);conn:settimeout(timeout or 15)
        local shaken,herr=conn:dohandshake()
        local verified,errors
        if shaken then verified,errors=conn:getpeerverification() end
        conn:close()
        if not shaken then error(herr,0) end
        local out,seen={},{}
        for _,list in pairs(type(errors)=='table' and errors or {}) do
            for _,e in ipairs(type(list)=='table' and list or {list}) do
                if type(e)=='string' and not seen[e] then seen[e]=true;out[#out+1]=e end
            end
        end
        table.sort(out)
        return out
    end)
    return ok and reasons or {}
end

local function clock() return os.date('!%Y-%m-%d %H:%M UTC') end
-- Returns a table suitable for error(): {kind='network',stage=,detail=,message=}.
function M.describe(err,context)
    context=context or {}
    local host=context.host or 'the server'
    local stage,detail=M.classify(err)
    local message
    if stage=='ca' or context.no_ca then
        stage='ca'
        message="KOReader's certificate bundle (data/ca-bundle.crt) could not be loaded, so "..host.." cannot be verified. Reinstall or update KOReader, then try again."
    elseif stage=='certificate' then
        local reasons=context.reasons or {}
        local joined=table.concat(reasons,'; ')
        detail=joined~='' and joined or detail
        if joined:find('not yet valid',1,true) or joined:find('expired',1,true) or (context.now or os.time())<1767225600 then
            stage='clock'
            message='The secure connection to '..host..' was rejected because its certificate is not valid at this device\'s date and time ('..clock()..'). Set the correct date, time and time zone, then try again.'
        else
            message='The certificate of '..host..' could not be verified ('..detail..'). A Wi-Fi login page, a filtering DNS or a network that inspects HTTPS can cause this. Try another network or update KOReader.'
        end
    elseif stage=='hostname' then
        message='The certificate presented for '..host..' belongs to a different site. A Wi-Fi login page or filtering network may be intercepting the connection.'
    elseif stage=='dns' then
        message='Could not look up '..host..'. Check that Wi-Fi is connected and has internet access, wait a few seconds, then try again.'
    elseif stage=='refused' or stage=='unreachable' then
        message='Could not connect to '..host..' ('..detail..'). Check the Wi-Fi connection, then try again.'
    elseif stage=='timeout' then
        message='The connection to '..host..' timed out. Check the Wi-Fi signal, then try again.'
    elseif stage=='storage' then
        message='The download could not be written ('..detail..'). Check available storage and the download folder, then try again.'
    elseif stage=='decode' or stage=='size' then
        message='The response from '..host..' could not be read ('..detail..'). Try again later.'
    elseif stage=='closed' then
        message='The connection to '..host..' was interrupted ('..detail..'). Try again.'
    else
        message='Network request to '..host..' failed ('..detail..'). Check your connection, device clock and available storage, then try again.'
    end
    return {kind='network',stage=stage,detail=detail,message=message..' ['..stage..']'}
end
function M.log(description,context)
    local ok,logger=pcall(require,'logger')
    if not ok or type(logger)~='table' or type(logger.warn)~='function' then return end
    pcall(logger.warn,'KOLibby network failure:',context and context.method or '?',context and context.host or '?',
        'stage='..tostring(description.stage),'detail='..tostring(description.detail),
        'verify='..tostring(context and context.verify~=false),'ca='..tostring(context and context.ca))
end
return M
