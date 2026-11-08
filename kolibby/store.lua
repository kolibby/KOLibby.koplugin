-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local lfs_ok,lfs=pcall(require,"libs/libkoreader-lfs")
if not lfs_ok then lfs=require("lfs") end
local J=require("kolibby/json")
local U=require("kolibby/util")
local Store={lfs=lfs};Store.__index=Store
local ffi_ok,ffi=pcall(require,"ffi")
if ffi_ok then pcall(ffi.cdef,"int chmod(const char *path, unsigned int mode);") end
local function protect(path,mode) if ffi_ok then pcall(function() ffi.C.chmod(path,mode) end) end end
function Store.mkdir(path)
    if lfs.attributes(path,"mode")=="directory" then return end
    local parent=path:match("^(.*)/[^/]+$")
    if parent and parent~="" and parent~=path then Store.mkdir(parent) end
    local ok=lfs.mkdir(path)
    if not ok and lfs.attributes(path,"mode")~="directory" then error("Could not create the KOLibby storage folder",0) end
    protect(path,448)
end
function Store.new(root)
    Store.mkdir(root)
    return setmetatable({root=root},Store)
end
function Store:read(name,default)
    local f=io.open(self.root.."/"..name,"rb");if not f then return U.copy(default) end
    local raw=f:read("*a");f:close()
    local ok,value=pcall(J.decode,raw)
    return ok and type(value)=="table" and value or U.copy(default)
end
function Store:write(name,value)
    local path=self.root.."/"..name;local tmp=path..".tmp"
    local file=io.open(tmp,"wb");if not file then error("Could not save KOLibby data. Check available storage.",0) end
    protect(tmp,384)
    local ok=file:write(J.encode(value));local closed=file:close()
    if not ok or not closed or not os.rename(tmp,path) then os.remove(tmp);error("Could not save KOLibby data",0) end
    protect(path,384)
end
function Store:auth() return self:read("identity.json",{}) end
function Store:save_auth(value) return self:write("identity.json",value) end
function Store:forget()
    for _,name in ipairs({"identity.json","identity.json.tmp","identity.json.old","shelf.json","shelf.json.tmp","status.json","borrow.json","borrow.json.tmp"}) do os.remove(self.root.."/"..name) end
end
function Store.exists(path) return lfs.attributes(path,"mode")=="file" end
function Store.size(path) return lfs.attributes(path,"size") end
function Store.read_file(path)
    local f=assert(io.open(path,"rb"));local s=f:read("*a");f:close();return s
end
function Store.write_file(path,bytes)
    Store.mkdir(path:match("^(.*)/[^/]+$"));local f=io.open(path,"wb")
    if not f then error("Could not write the downloaded book",0) end
    local ok=f:write(bytes);local closed=f:close()
    if not ok or not closed then error("The download could not be saved. Check available storage.",0) end
end
function Store.remove_tree(path)
    if lfs.attributes(path,"mode")~="directory" then return end
    for entry in lfs.dir(path) do
        if entry~="." and entry~=".." then
            local file=path.."/"..entry
            if lfs.symlinkattributes(file,"mode")=="directory" then Store.remove_tree(file) else os.remove(file) end
        end
    end
    lfs.rmdir(path)
end
return Store
