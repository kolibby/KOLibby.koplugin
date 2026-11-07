-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
return function(test,eq,fails,contains)
local U=require('kolibby/updater')
local I=require('kolibby/updateinstall')
local H=require('kolibby/updatehttp')
local J=require('kolibby/json')
local Copy=require('kolibby/util').copy
local function release(number)
 number=number or '0.6.0'
 return {draft=false,prerelease=false,tag_name='v'..number,body='Release notes\n\n- An improvement',assets={{
  name='KOLibby-'..number..'.zip',state='uploaded',size=1234,digest='sha256:'..string.rep('a',64),
  browser_download_url='https://github.com/kolibby/KOLibby.koplugin/releases/download/v'..number..'/KOLibby-'..number..'.zip'}}}
end
local function manifest()
 local entries,files={},{ }
 for _,name in ipairs({'main.lua','_meta.lua','README.md','LICENSE','NOTICE','VERSION','kolibby/updater.lua','kolibby/updatehttp.lua','kolibby/updateinstall.lua'}) do
  entries[name]={size=10};files[name]={bytes=10,sha256=string.rep('a',64)}
 end
 entries['release.json']={size=1000}
 return {version='0.6.0',files=files},entries
end
local function fs()
 local root='/plugins/KOLibby.koplugin';local stage=root..'.update-stage';local backup=root..'.update-backup'
 local nodes={[root]='directory',[stage]='directory',[root..'/VERSION']='file'}
 local operations={}
 local filesystem={mode=function(path) return nodes[path] end,remove=function(path) nodes[path]=nil end}
 filesystem.rename=function(from,to)
  operations[#operations+1]={from,to}
  if not nodes[from] or nodes[to] then return nil end
  nodes[to]=nodes[from];nodes[from]=nil;return true
 end
 return filesystem,root,stage,backup,nodes,operations
end

test('Update versions use numeric stable ordering and cannot downgrade',function()
 assert(U.newer('v0.10.0','0.9.99'));assert(U.newer('1.0.0','0.99.99'))
 eq(U.newer('0.5.0','0.5.0'),false);eq(U.newer('0.4.99','0.5.0'),false)
 for _,v in ipairs({'0.06.0','0.6','0.6.0-beta','v1.2.3;command','999999999.0.0'}) do fails(function() U.newer(v,'0.5.0') end,'version') end
end)
test('Latest release metadata selects the exact runtime asset and displays notes',function()
 local r=U.release(release(),'0.5.0');eq(r.status,'available');eq(r.version,'0.6.0');eq(r.bytes,1234)
 contains(r.notes,'An improvement');contains(r.url,'KOLibby-0.6.0.zip')
 eq(U.release(release('0.4.0'),'0.5.0').status,'current')
end)
test('Drafts prereleases source archives and missing uploaded packages cannot install',function()
 local r=release();r.draft=true;fails(function() U.release(r,'0.5.0') end,'stable')
 r=release();r.prerelease=true;fails(function() U.release(r,'0.5.0') end,'stable')
 r=release();r.assets[1].name='Source code.zip';fails(function() U.release(r,'0.5.0') end,'ZIP')
 r=release();r.assets[1].state='new';fails(function() U.release(r,'0.5.0') end,'ZIP')
end)
test('Release downloads require the intended repository bounded size and SHA256',function()
 local r=release();r.assets[1].browser_download_url='https://github.com/other/project/update.zip';fails(function() U.release(r,'0.5.0') end,'ZIP')
 r=release();r.assets[1].size=U.max_zip+1;fails(function() U.release(r,'0.5.0') end,'ZIP')
 r=release();r.assets[1].digest=false;fails(function() U.release(r,'0.5.0') end,'SHA-256')
 r=release();r.assets[1].digest='sha256:'..string.rep('g',64);fails(function() U.release(r,'0.5.0') end,'SHA-256')
 r=release();r.assets[2]=Copy(r.assets[1]);fails(function() U.release(r,'0.5.0') end,'duplicate')
end)
test('No published release is handled without attempting an asset download',function()
 local calls=0;local r=U.check(function(q) calls=calls+1;eq(q.url,U.api);return {status=404} end,'0.5.0')
 eq(r.status,'unpublished');eq(calls,1)
end)
test('Update check handles rate limits and invalid metadata without raw response leakage',function()
 for _,status in ipairs({403,429}) do fails(function() U.check(function() return {status=status,body='private response'} end,'0.5.0') end,'limiting') end
 fails(function() U.check(function() return {status=200,body='not JSON'} end,'0.5.0') end,'invalid release')
 eq(U.check(function() return {status=200,body=J.encode(release())} end,'0.5.0').status,'available')
end)
test('GitHub HTTP requests carry no Libby authorization cookies or request profile',function()
 local calls={};local client=H.new('0.5.0',{driver=function(q)
  calls[#calls+1]=q
  if #calls==1 then return {status=302,headers={location='https://release-assets.githubusercontent.com/example/file?sig=synthetic'}} end
  return {status=200,body='package'}
 end})
 local r=client:request{url='https://github.com/kolibby/KOLibby.koplugin/releases/download/v0.6.0/KOLibby-0.6.0.zip',headers={Authorization='Bearer fixture',Cookie='fixture'}}
 eq(r.status,200);eq(#calls,2)
 for _,q in ipairs(calls) do
  eq(q.headers.Authorization,nil);eq(q.headers.Cookie,nil);eq(q.headers.Origin,nil);eq(q.headers['X-Requested-With'],nil)
  contains(q.headers['User-Agent'],'KOLibby/0.5.0');eq(q.profile,'update');eq(q.headers['Accept-Encoding'],'identity')
 end
end)
test('Update redirects reject insecure unrelated and credential-bearing hosts',function()
 for _,url in ipairs({'http://github.com/a','https://github.com.evil.example/a','https://user@github.com/a','https://github.com:443/a','https://evil.example/a','https://github.com/a\r\nBad: header'}) do eq(H.allowed(url),false) end
 local calls=0;local client=H.new('0.5.0',{driver=function() calls=calls+1;return {status=302,headers={location='https://evil.example/package'}} end})
 fails(function() client:request{url=U.api} end,'host');eq(calls,1)
end)
test('GitHub redirects are bounded rather than retried indefinitely',function()
 local calls=0;local client=H.new('0.5.0',{driver=function() calls=calls+1;return {status=302,headers={location=U.api}} end})
 fails(function() client:request{url=U.api} end,'redirects');eq(calls,6)
end)
test('Update ZIP entries cannot write traversal private state hooks or links',function()
 for _,name in ipairs({'../main.lua','/main.lua','KOLibby.koplugin/../main.lua','KOLibby.koplugin/identity.json','KOLibby.koplugin/.git/config','KOLibby.koplugin/kolibby/../../settings.lua','KOLibby.koplugin/kolibby\\evil.lua','other.koplugin/main.lua'}) do
  fails(function() I.entry{path=name,mode='file',size=1} end,'unexpected')
 end
 fails(function() I.entry{path='KOLibby.koplugin/main.lua',mode='link',size=1} end,'link')
 fails(function() I.entry{path='KOLibby.koplugin/main.lua',mode='file',size=I.max_file+1} end,'size')
 eq(I.entry{path='KOLibby.koplugin/kolibby/updater.lua',mode='file',size=1},'kolibby/updater.lua')
end)
test('Update manifests require matching version file sizes hashes and complete inventory',function()
 local m,e=manifest();assert(I.manifest(m,e,'0.6.0'))
 fails(function() I.manifest(m,e,'0.7.0') end,'match')
 m.files['main.lua'].bytes=11;fails(function() I.manifest(m,e,'0.6.0') end,'invalid')
 m,e=manifest();m.files['main.lua']=nil;fails(function() I.manifest(m,e,'0.6.0') end,'missing')
 m,e=manifest();m.files['main.lua'].sha256=string.rep('Z',64);fails(function() I.manifest(m,e,'0.6.0') end,'invalid')
 m,e=manifest();e['kolibby/extra.lua']={size=1};fails(function() I.manifest(m,e,'0.6.0') end,'missing')
end)
test('Git checkouts and symlink installation folders cannot be overwritten',function()
 local f,r,_,_,nodes=fs();nodes[r..'/.git']='directory';fails(function() I.check_root(r,f) end,'Git checkout')
 nodes[r..'/.git']=nil;nodes[r]='link';fails(function() I.check_root(r,f) end,'installation folder')
end)
test('Update activation retains a backup and installs only the prepared sibling',function()
 local f,r,s,b,nodes=fs();eq(I.activate(r,s,f),b);eq(nodes[r],'directory');eq(nodes[b],'directory');eq(nodes[s],nil)
 f,r,s=fs();fails(function() I.activate(r,'/unrelated/stage',f) end,'staged')
end)
test('Failure to back up leaves the active plugin untouched',function()
 local f,r,s,b,nodes=fs();f.rename=function() return nil end
 fails(function() I.activate(r,s,f) end,'backed up');eq(nodes[r],'directory');eq(nodes[b],nil)
end)
test('Failure to install restores the previous plugin before reporting an error',function()
 local f,r,s,b,nodes=fs();local rename=f.rename
 f.rename=function(from,to) if from==s then return nil end;return rename(from,to) end
 fails(function() I.activate(r,s,f) end,'previous plugin was restored');eq(nodes[r],'directory');eq(nodes[b],nil);eq(nodes[s],'directory')
end)
test('Failure to restore keeps the backup and gives recovery instructions',function()
 local f,r,s,b,nodes=fs();local rename=f.rename
 f.rename=function(from,to) if from==s or from==b then return nil end;return rename(from,to) end
 fails(function() I.activate(r,s,f) end,'manually');eq(nodes[r],nil);eq(nodes[b],'directory')
end)
end
