-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Which LuaSec settings each session uses, with socket and TLS replaced by stubs.
return function(test,eq,fails,contains)
local names={'socket.http','ssl.https','ssl','socket.url','ltn12','kolibby/transport'}
local function with_stubs(fn)
    local saved={};for _,name in ipairs(names) do saved[name]=package.loaded[name] end
    local seen={}
    package.loaded['ssl']={}
    package.loaded['ltn12']={source={string=function() end}}
    package.loaded['socket.url']={absolute=saved['socket.url'] and saved['socket.url'].absolute,parse=function(u)
        local host,port,path=u:match('^https://([^:/]+):?(%d*)(/[^?]*)')
        return {host=host,port=port~='' and port or nil,path=path}
    end}
    package.loaded['ssl.https']={tcp=function(params)
        seen[#seen+1]=params
        return function()
            return {connect=function() return 1 end,close=function() end,
                getpeercertificate=function() error('hostname checked',0) end}
        end
    end}
    -- Stop after the TLS connect, before any request bytes.
    package.loaded['socket.http']={open=function(host,port,create)
        local conn=create();conn:connect(host,port);error('stopped after connect',0)
    end}
    package.loaded['kolibby/transport']=nil
    local ok,err=pcall(fn,seen,require('kolibby/transport'))
    for _,name in ipairs(names) do package.loaded[name]=saved[name] end
    assert(ok,err)
end
local function detail(fn) local ok,err=pcall(fn);assert(not ok);return type(err)=='table' and err.detail or tostring(err) end
test('Libby requests use unverified TLS like KOReader; explicit verification still checks names',function()
    with_stubs(function(seen,Transport)
        local plain=Transport.new{verify=false}
        eq(detail(function() plain:request{url='https://sentry.libbyapp.com/chip',headers={}} end),'stopped after connect')
        eq(seen[1].verify,'none');eq(seen[1].cafile,nil)
        local checked=Transport.new{ca_file='/fixture/ca.crt'}
        eq(detail(function() checked:request{url='https://api.github.com/repos',headers={}} end),'hostname checked')
        eq(seen[2].verify,'peer');eq(seen[2].cafile,'/fixture/ca.crt')
    end)
end)
test('Libby sessions run unverified while the GitHub updater stays verified',function()
    with_stubs(function(seen,Transport)
        local Http=require('kolibby/http')
        local http=Http.new()
        pcall(http.request,http,{url='https://sentry.libbyapp.com/chip'})
        eq(http.transport.verify,false);eq(seen[1].verify,'none')
        local update=require('kolibby/updatehttp').new('0.0.0')
        pcall(update.request,update,{url='https://api.github.com/repos/kolibby/KOLibby.koplugin/releases/latest'})
        eq(update.transport.verify,true)
        eq(Transport.new().verify,true)
    end)
end)
end
