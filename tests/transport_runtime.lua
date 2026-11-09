-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Run with stock KOReader/LuaJIT, not the portable Lua 5.1 test runner.
-- Requires tests/compression_fixtures.lua; no credentials or network access.
local C=require('kolibby/compression')
local U=require('kolibby/util')
local F=require('tests/compression_fixtures')
-- Run in a fresh LuaJIT process for each order: by default these declarations
-- come first; call compression.encodings() before requiring this module to put
-- KOLibby's declarations first. All four zlib functions share that C namespace.
local ffi=require('ffi')
ffi.cdef[[
  typedef struct kolibby_test_z_stream_s {
    const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
    unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
    const char *msg; void *state; void *zalloc; void *zfree; void *opaque;
    int data_type; unsigned long adler; unsigned long reserved;
  } kolibby_test_z_stream;
  typedef kolibby_test_z_stream *kolibby_test_z_streamp;
  const char *zlibVersion(void);
  int inflateInit2_(kolibby_test_z_streamp strm, int windowBits, const char *version, int stream_size);
  int inflate(kolibby_test_z_streamp strm, int flush);
  int inflateEnd(kolibby_test_z_streamp strm);
  int inflateReset2(kolibby_test_z_streamp strm, int windowBits);
]]
return function()
    local result={passed=0,failed=0,failures={},encodings=C.encodings()}
    local function test(name,fn)
        local ok,err=pcall(fn)
        if ok then result.passed=result.passed+1
        else result.failed=result.failed+1;result.failures[#result.failures+1]={name=name,message=tostring(err)} end
    end
    local function decode(kind,data,chunk,limit)
        local out={};local feed,finish=C.decoder(kind,function(s) out[#out+1]=s end,limit)
        for i=1,#data,chunk or #data do feed(data:sub(i,i+(chunk or #data)-1)) end
        finish();return table.concat(out)
    end
    local function reject(fn) assert(not pcall(fn),'Invalid data accepted') end
    local expected=string.rep('KOLibby compression fixture: café 🌍\n',2500)
    local small='Native metadata café 🌍'
    local gzip=U.base64_decode(F.gzip)
    test('gzip works beside another plugin\'s zlib declarations',function()
        assert(decode('gzip',gzip,4096)==expected)
        local z
        for _,name in ipairs({'z','libz.so','libz.dylib','libz.so.1'}) do
            local ok,lib=pcall(ffi.load,name);if ok then z=lib;break end
        end
        assert(z,'zlib is unavailable')
        local s=ffi.new('kolibby_test_z_stream[1]')
        assert(z.inflateInit2_(s,31,z.zlibVersion(),ffi.sizeof('kolibby_test_z_stream'))==0,'other plugin cannot use zlib')
        local ok,err=pcall(function()
            local out=ffi.new('unsigned char[?]',#expected+1)
            for pass=1,2 do
                s[0].next_in=ffi.cast('const unsigned char *',gzip);s[0].avail_in=#gzip
                s[0].next_out=out;s[0].avail_out=#expected+1
                assert(z.inflate(s,4)==1,'other plugin cannot inflate')
                assert(ffi.string(out,#expected+1-s[0].avail_out)==expected)
                if pass==1 then assert(z.inflateReset2(s,31)==0,'other plugin cannot reset zlib') end
            end
        end)
        z.inflateEnd(s)
        assert(ok,err)
    end)
    test('decoder retains its stream across garbage collection',function()
        local out={};local feed,finish=C.decoder('gzip',function(s) out[#out+1]=s end)
        feed(gzip:sub(1,17));collectgarbage('collect')
        feed(gzip:sub(18));feed=nil;collectgarbage('collect')
        finish();assert(table.concat(out)==expected)
    end)
    test('identity binary',function() assert(decode('identity','a\0b',1)=='a\0b') end)
    test('gzip large output',function() assert(decode('gzip',gzip)==expected) end)
    test('gzip single-byte chunks',function() assert(decode('gzip',gzip,1)==expected) end)
    test('gzip small chunks',function() assert(decode('gzip',gzip,17)==expected) end)
    test('gzip concatenated members',function() assert(decode('gzip',U.base64_decode(F.multi),3)==small..small) end)
    test('deflate',function() assert(decode('deflate',U.base64_decode(F.deflate),7)==expected) end)
    test('gzip truncation',function() reject(function() decode('gzip',gzip:sub(1,-2)) end) end)
    test('gzip checksum',function() reject(function() decode('gzip',gzip:sub(1,-9)..'\0\0\0\0'..gzip:sub(-4)) end) end)
    test('gzip output bound',function() reject(function() decode('gzip',gzip,13,1000) end) end)
    test('gzip trailing garbage',function() reject(function() decode('gzip',gzip..'junk') end) end)
    test('identity output bound',function() reject(function() decode('identity','1234',2,3) end) end)
    test('unsupported encoding',function() reject(function() decode('not-an-encoding','data') end) end)
    if F.zstd then
        local zstd=U.base64_decode(F.zstd)
        test('zstd bounded growth',function() assert(decode('zstd',zstd,3)==expected) end)
        test('zstd output bound',function() reject(function() decode('zstd',zstd,3,1000) end) end)
        test('zstd truncation',function() reject(function() decode('zstd',zstd:sub(1,-2)) end) end)
        test('zstd encoded bound',function() reject(function() decode('zstd',zstd,3,10) end) end)
    end
    return result
end
