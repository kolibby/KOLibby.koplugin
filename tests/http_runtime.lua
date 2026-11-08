-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Integration checks against tools/transport-fixture.py on stock KOReader.
-- Pass the fixture's CA path; this affects this test instance only.
return function(ca_file,temporary_path)
    local T=require('kolibby/transport')
    local P=require('kolibby/profile')
    local C=require('kolibby/compression')
    local result={passed=0,failed=0,failures={}}
    local client=T.new{ca_file=ca_file}
    local expected=string.rep('Wire fixture café 🌍\n',3000)
    local function request(path,method,body,options)
        options=options or {}
        options.url='https://localhost:19443'..path
        options.method=method or 'GET';options.body=body
        options.headers=P.headers(options.profile or 'api',body and {['Content-Length']=tostring(#body),['Content-Type']='application/json'} or {},C.encodings())
        return client:request(options)
    end
    local function test(name,fn)
        local ok,err=pcall(fn)
        if ok then result.passed=result.passed+1
        else result.failed=result.failed+1;result.failures[#result.failures+1]={name=name,message=type(err)=='table' and err.message or tostring(err)} end
    end
    test('verified TLS and gzip',function() local r=request('/gzip');assert(r.status==200 and r.body==expected and r.encoded_bytes<r.bytes) end)
    test('persistent connection',function() local r=request('/identity');assert(r.body==expected and r.reused) end)
    test('deflate',function() assert(request('/deflate').body==expected) end)
    test('chunked gzip',function() assert(request('/chunked').body==expected) end)
    test('POST byte length',function() assert(request('/post','POST','{"text":"café 🌍"}').body==expected) end)
    test('native request profile',function() assert(request('/native',nil,nil,{profile='resource'}).body==expected) end)
    test('stale GET retry',function() request('/stale');assert(request('/identity').body==expected) end)
    test('stale POST is not retried',function() request('/stale');assert(not pcall(request,'/post','POST','{}')) end)
    test('truncated gzip removes partial destination',function()
        assert(not pcall(request,'/truncated',nil,nil,{destination=temporary_path}))
        local f=io.open(temporary_path,'rb');if f then f:close() end;assert(not f)
    end)
    test('decoded response bound',function() assert(not pcall(request,'/limit',nil,nil,{max_bytes=1000})) end)
    test('unsupported response encoding',function() assert(not pcall(request,'/unsupported')) end)
    test('wrong TLS hostname',function()
        assert(not pcall(client.request,client,{url='https://127.0.0.1:19443/wrong-host',headers={}}))
    end)
    test('untrusted TLS certificate',function()
        local untrusted=T.new()
        assert(not pcall(untrusted.request,untrusted,{url='https://localhost:19443/untrusted',headers={}}));untrusted:close()
    end)
    -- Libby sessions use KOReader's unverified mode (verify=false).
    test('unverified TLS accepts an untrusted certificate',function()
        local plain=T.new{verify=false}
        local r=plain:request{url='https://localhost:19443/identity',headers=P.headers('api',{},C.encodings())}
        plain:close();assert(r.status==200 and r.body==expected)
    end)
    test('unverified TLS skips the hostname check',function()
        local plain=T.new{verify=false}
        local r=plain:request{url='https://127.0.0.1:19443/identity',headers=P.headers('api',{},C.encodings())}
        plain:close();assert(r.status==200 and r.body==expected)
    end)
    test('recovery after failure',function() assert(request('/identity').body==expected) end)
    client:close()
    return result
end
