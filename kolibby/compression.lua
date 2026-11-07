-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local M={}
local loaded,ffi,zlib,zstd,brotli
local function load()
    if loaded then return end
    loaded=true
    local ok;ok,ffi=pcall(require,'ffi');if not ok then ffi=nil;return end
    ffi.cdef[[
      typedef struct {
        const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
        unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
        char *msg; void *state; void *zalloc; void *zfree; void *opaque;
        int data_type; unsigned long adler; unsigned long reserved;
      } kolibby_z_stream;
      const char *zlibVersion(void);
      int inflateInit2_(kolibby_z_stream *, int, const char *, int);
      int inflate(kolibby_z_stream *, int);
      int inflateEnd(kolibby_z_stream *);
      int inflateReset2(kolibby_z_stream *, int);
      int BrotliDecoderDecompress(size_t, const unsigned char *, size_t *, unsigned char *);
    ]]
    for _,name in ipairs({'z','libz.so','libz.dylib','libz.so.1'}) do
        local yes,lib=pcall(ffi.load,name)
        if yes and pcall(function() return lib.inflate,lib.zlibVersion end) then zlib=lib;break end
    end
    local yes,lib=pcall(function()
        require('ffi/zstd_h');return ffi.loadlib('zstd','1')
    end)
    if yes and pcall(function() return lib.ZSTD_decompress,lib.ZSTD_isError end) then zstd=lib end
    for _,name in ipairs({'brotlidec','libbrotlidec.so','libbrotlidec.so.1'}) do
        local found,value=pcall(ffi.load,name)
        if found and pcall(function() return value.BrotliDecoderDecompress end) then brotli=value;break end
    end
end
function M.encodings()
    load()
    local web={}
    if zlib then web={'gzip','deflate'} end
    if brotli then web[#web+1]='br' end
    if zstd then web[#web+1]='zstd' end
    return {web=#web>0 and table.concat(web,', ') or 'identity',native=zlib and 'gzip' or 'identity'}
end
local function failure() error('A compressed response is invalid, incomplete, unsupported or exceeds the download limit',0) end
local function buffered(kind,emit,limit)
    local parts,size={},0
    return function(chunk)
        if chunk then size=size+#chunk;if size>limit then failure() end;parts[#parts+1]=chunk;return end
        local data=table.concat(parts)
        local capacity=math.min(65536,limit)
        while true do
            local out=ffi.new('unsigned char[?]',capacity)
            if kind=='zstd' then
                local n=zstd.ZSTD_decompress(out,capacity,data,#data)
                if zstd.ZSTD_isError(n)==0 then emit(ffi.string(out,tonumber(n)));return end
                local message=ffi.string(zstd.ZSTD_getErrorName(n))
                if not message:lower():find('destination buffer is too small',1,true) then failure() end
            else
                local n=ffi.new('size_t[1]',capacity)
                if brotli.BrotliDecoderDecompress(#data,data,n,out)==1 then emit(ffi.string(out,tonumber(n[0])));return end
            end
            if capacity==limit then failure() end
            capacity=math.min(capacity*2,limit)
        end
    end
end
function M.decoder(kind,emit,limit)
    kind=(kind or 'identity'):lower():gsub('^%s+',''):gsub('%s+$','')
    limit=limit or 16*1024*1024
    local emitted=0
    local function write(chunk)
        if chunk and #chunk>0 then emitted=emitted+#chunk;if emitted>limit then failure() end;emit(chunk) end
    end
    if kind=='' or kind=='identity' then return write,function() end end
    load()
    if kind=='zstd' and zstd or kind=='br' and brotli then
        local process=buffered(kind,write,limit);return process,function() process(nil) end
    end
    if not zlib or kind~='gzip' and kind~='deflate' then failure() end
    local stream=ffi.new('kolibby_z_stream[1]')
    local bits=kind=='gzip' and 31 or 15
    if zlib.inflateInit2_(stream,bits,zlib.zlibVersion(),ffi.sizeof('kolibby_z_stream'))~=0 then failure() end
    local closed,ended=false,false
    local guard=ffi.gc(ffi.new('char[1]'),function() if not closed then zlib.inflateEnd(stream) end end)
    local function close()
        if not closed then closed=true;zlib.inflateEnd(stream);ffi.gc(guard,nil) end
    end
    local function fail() close();failure() end
    local output=ffi.new('unsigned char[32768]')
    local function feed(chunk)
        if closed then failure() end
        if not chunk or #chunk==0 then return end
        stream[0].next_in=ffi.cast('const unsigned char *',chunk);stream[0].avail_in=#chunk
        repeat
            if ended then
                if kind~='gzip' or zlib.inflateReset2(stream,bits)~=0 then fail() end
                ended=false
            end
            stream[0].next_out=output;stream[0].avail_out=32768
            local before=stream[0].avail_in
            local status=zlib.inflate(stream,0)
            local produced=32768-stream[0].avail_out
            if produced>0 then write(ffi.string(output,produced)) end
            if status==1 then ended=true
            elseif status~=0 and status~=-5 then fail()
            elseif before==stream[0].avail_in and produced==0 then fail() end
        until stream[0].avail_in==0 and stream[0].avail_out>0 or ended and stream[0].avail_in==0
    end
    local function finish()
        if closed then failure() end
        if not ended then fail() end
        close()
    end
    return feed,finish
end
return M
