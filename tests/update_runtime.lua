-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Stock KOReader test using local generated fixtures, without network or identity.
return function(fixtures,output,plugin)
 local Store=require('kolibby/store');local J=require('kolibby/json')
 local Install=require('kolibby/updateinstall');local Update=require('kolibby/updater')
 local index=J.decode(Store.read_file(fixtures..'/index.json'))
 local result={passed=0,failed=0,failures={}}
 local root=output..'/isolated.koplugin';Store.mkdir(root)
 Store.write_file(root..'/old.txt','old runtime')
 Store.write_file(output..'/identity.json','synthetic private state')
 Store.write_file(output..'/download.epub','synthetic download')
 local function test(name,fn)
  local ok,err=pcall(fn)
  if ok then result.passed=result.passed+1
  else result.failed=result.failed+1;result.failures[#result.failures+1]={name=name,message=require('kolibby/util').error_message(err)} end
 end
 local function release(name) return {version='0.5.1',url=name,bytes=index[name].bytes,sha256=index[name].sha256} end
 local function transport(request)
  Store.write_file(request.destination,Store.read_file(fixtures..'/'..request.url..'.zip'))
  return {status=200}
 end
 local options={install_dir=root,cache_dir=output..'/cache'}
 for name in pairs(index) do if name~='valid' then
  test('reject '..name,function()
   local ok=pcall(Update.prepare,transport,release(name),options)
   assert(not ok,'Unsafe package accepted')
   assert(Store.read_file(root..'/old.txt')=='old runtime')
   assert(not Store.exists(options.cache_dir..'/update.zip.part'))
  end)
 end end
 test('reject outer checksum mismatch',function()
  local r=release('valid');r.sha256=string.rep('0',64)
  assert(not pcall(Update.prepare,transport,r,options))
  assert(Store.read_file(root..'/old.txt')=='old runtime')
 end)
 test('reject incomplete download',function()
  local r=release('valid');r.bytes=r.bytes+1
  assert(not pcall(Update.prepare,transport,r,options))
  assert(Store.read_file(root..'/old.txt')=='old runtime')
 end)
 test('prepare and activate a verified package without changing private state',function()
  local prepared=Update.prepare(transport,release('valid'),options)
  assert(Store.read_file(root..'/old.txt')=='old runtime')
  assert(Store.read_file(prepared.stage..'/VERSION')=='0.5.1\n')
  local backup=Install.activate(root,prepared.stage)
  assert(Store.read_file(root..'/VERSION')=='0.5.1\n')
  assert(Store.read_file(backup..'/old.txt')=='old runtime')
  assert(Store.read_file(output..'/identity.json')=='synthetic private state')
  assert(Store.read_file(output..'/download.epub')=='synthetic download')
 end)
 if plugin and not require('device'):canRestart() then
  test('unsupported automatic restart requests manual close and reopen',function()
   local message
   plugin.promptRestart({installed_version='0.5.1',message=function(_,value) message=value end})
   assert(message and message:find('Close KOReader completely',1,true) and message:find('open it again',1,true))
  end)
 end
 return result
end
