-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Synthetic full downloader/archiver fixtures; no network or identity required.
return function(root)
local Store=require('kolibby/store');local U=require('kolibby/util');local J=require('kolibby/json')
local Download=require('kolibby/download')
Store.remove_tree(root);Store.mkdir(root)
local host='https://fixture.libbyshelf.com'
local function html(body,head) return '<html><head><title>Fixture</title>'..(head or '')..'</head><body>'..body..'</body></html>' end
local function encoded(body,head) return html('<script>parent.__bif_cfc0(self,"'..U.base64_encode('<body>'..body..'</body>')..'");</script>',head) end
local png=U.base64_decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jF1sAAAAASUVORK5CYII=')
local sources={
 ['/pages/one.xhtml']=encoded('<h1>Fixed page one</h1><p>Positioned at the top</p><picture><source srcset="../media/box.svg 1x, ../media/box2.svg 2x" type="image/svg+xml"/><img src="../media/box.svg" alt="Blue box"/></picture><p class="footer">Footer at the bottom</p>','<link rel="stylesheet" href="../css/main.css?cmpt=9&amp;x=1"/>'),
 ['/pages/two.svg']='<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 600 800"><title>Fixed page two</title><rect width="600" height="800" fill="#fff0b0"/><text x="40" y="70" font-size="30">Fixed page two</text><image x="40" y="120" width="300" height="300" xlink:href="../media/box.svg"/></svg>',
 ['/pages/chapter.xhtml']=html('<h1>Reflowing chapter</h1><p>A reflowing page follows the fixed page.</p>'),
 ['/css/main.css']='@import "extra.css";html,body{width:600px;height:800px;margin:0;}h1{position:absolute;top:30px;left:40px;}p{position:absolute;top:100px;left:40px;}img{position:absolute;top:180px;left:40px;width:300px;height:300px;}.footer{top:730px;}',
 ['/css/extra.css']='@import url(main.css?cmpt=9&x=1); body{background:url("../media/box.svg");background-size:600px 800px;}',
 ['/media/box.svg']='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800"><title>Box</title><rect width="600" height="800" fill="#d0e8ff"/><rect x="20" y="20" width="560" height="760" fill="none" stroke="#205080" stroke-width="4"/></svg>',
 ['/media/box2.svg']='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800"><title>Box alternate</title><rect width="600" height="800" fill="#d0e8ff"/></svg>',
 ['/media/pixel.png']=png,
}
local function run(name,spine,roster,extra,interrupt)
 local book={title={main=name},language='en',creator={{name='Synthetic Author'}},spine=spine}
 for k,v in pairs(extra or {}) do book[k]=v end
 local requests={};local client={}
 function client:publication() return {expires=os.time()+3600},{{group='title-content',id='synthetic-'..name,version=1,entries=roster}},book end
 function client.transport(req)
    assert(req.profile=='resource');assert(req.method=='GET');assert(not (req.headers or {}).Authorization)
    requests[#requests+1]=req.url
    local path=assert(req.url:match('^https://fixture.libbyshelf.com([^?#]*)'));local data=assert(sources[path],'Unexpected synthetic request')
    Store.write_file(req.destination,data);return {status=200,headers={}}
 end
 local loan={key='synthetic:'..name,id=name,checkout_id='synthetic',title=name,downloadable=true,expires=os.time()+3600}
 local opts={directory=root..'/books',cache_dir=root..'/cache-'..name}
 if interrupt then opts.progress=function(v) if v.stage=='downloading' and v.done==2 then error('Synthetic interruption',0) end end;assert(not pcall(Download.run,client,loan,{},opts));opts.progress=nil end
 local before=#requests
 local record=Download.run(client,loan,{},opts)
 return {path=record.path,resources=record.resources,spine=record.spine,fixed_layout=record.fixed_layout,mixed_layout=record.mixed_layout,requests=requests,resume_requests=#requests-before}
end
local function entry(path,position)
 return {path=path,['rendition-layout']='pre-paginated',['rendition-viewport']={width=600,height=800},['rendition-position']=position}
end
local reports={}
reports.fixed=run('Synthetic fixed layout',{entry('pages/one.xhtml','left'),entry('pages/two.svg','right')},{{url=host..'/pages/one.xhtml'},{url=host..'/pages/two.svg'}},{['i18n-page-progression-direction']='rtl',['rendition-spread']='both'},true)
local got=false;for _,url in ipairs(reports.fixed.requests) do if url==host..'/css/main.css?cmpt=9&x=1' then got=true end end;assert(got,'Component query was lost')
assert(reports.fixed.resources==6);assert(reports.fixed.resume_requests==4)
reports.mixed=run('Synthetic mixed layout',{entry('pages/one.xhtml','center'),{path='pages/chapter.xhtml'}},{{url=host..'/pages/one.xhtml'},{url=host..'/pages/chapter.xhtml'}})
assert(reports.mixed.mixed_layout)
reports.bitmap=run('Synthetic bitmap spine',{{path='media/pixel.png'}},{{url=host..'/media/pixel.png'}})
assert(reports.bitmap.fixed_layout)
-- Failed external embeds never result in a successful EPUB or a foreign request.
sources['/pages/external.xhtml']=html('<img src="https://example.org/private.png" alt="external"/>')
local ok=pcall(run,'Synthetic external resource',{{path='pages/external.xhtml'}},{{url=host..'/pages/external.xhtml'}})
assert(not ok)
reports.external_rejected=true
Store.new(root):write('result.json',{ok=true,value=reports})
return reports
end
