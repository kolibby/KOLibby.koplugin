-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
package.path="./?.lua;./?/init.lua;./tests/support/?.lua;"..package.path
local U=require("kolibby/util")
local J=require("kolibby/json")
local Model=require("kolibby/model")
local Decoder=require("kolibby/decoder")
local Epub=require("kolibby/epub")
local Publication=require("kolibby/publication")
local Client=require("kolibby/client")
local Http=require("kolibby/http")
local Assets=require("kolibby/assets")
local Coordinator=require("kolibby/coordinator")
local Profile=require("kolibby/profile")
local TLS=require("kolibby/tls")
local Borrowing=require("kolibby/borrowing")
local Present=require("kolibby/presentation")
local Covers=require("kolibby/covers")
package.preload['socket.url']=function() return {absolute=function(base,location)
    if location:match("^https?://") then return location end
    return assert(base:match("^(https://[^/]+)"))..location
end} end
local passed,failed=0,0
local function eq(a,b) assert(a==b,"expected "..tostring(b)..", got "..tostring(a)) end
local function contains(s,needle) assert(s:find(needle,1,true),"missing expected text: "..needle) end
local function fails(fn,needle)
    local ok,err=pcall(fn);assert(not ok,"expected failure")
    if needle then contains(U.error_message(err),needle) end
end
local function test(name,fn)
    local ok,err=pcall(fn)
    if ok then passed=passed+1;io.write("PASS ",name,"\n")
    else failed=failed+1;io.write("FAIL ",name,": ",tostring(err),"\n") end
end
local function card(id,name) return {cardId=id,cardName=name or id,library={name="Library "..id,websiteId=id}} end
local function loan(c,id,checkout,media)
    return {cardId=c,id=id,checkoutId=checkout or "first",title="Same title",firstCreatorName="Author",type={id=media or "ebook",name=media or "eBook"},
        formats={{id=media=="audiobook" and "audiobook-mp3" or "ebook-overdrive"}},expireDate="2030-01-01T00:00:00Z"}
end
local function shelf(cards,loans,holds,summary)
    return {result="synchronized",cards=cards or {},loans=loans or {},holds=holds or {},summary=summary or {}}
end
local function initial()
    return Model.merge(Model.empty(),shelf({card("A"),card("B")},{loan("A","42"),loan("B","42"),loan("A","audio","first","audiobook")},{loan("A","hold"),loan("B","hold")}),1)
end
test("FileManager and Reader share a single active operation",function()
    local fm,reader={},{}
    assert(Coordinator.acquire(fm));eq(Coordinator.acquire(reader),false)
    Coordinator.release(fm);assert(Coordinator.acquire(reader));Coordinator.release(reader)
end)
test("An inactive controller cannot release another controller's operation",function()
    local a,b={},{};assert(Coordinator.acquire(a));Coordinator.release(b)
    eq(Coordinator.acquire(b),false);Coordinator.release(a)
end)

test("Base64 round trips binary and Unicode",function()
    for _,s in ipairs({"","f","fo","foo","café 🌍","\0\1\254\255"}) do eq(U.base64_decode(U.base64_encode(s)),s) end
end)
test("Base64 rejects truncation and invalid padding",function()
    for _,s in ipairs({"abc","=abc","AA=A","AA==AA==","!!!="}) do fails(function() U.base64_decode(s) end) end
end)
test("UTC parsing is independent of local timezone",function()
    eq(U.timestamp("1970-01-01T00:00:00Z"),0)
    eq(U.timestamp("2026-11-06T12:00:00-08:00"),U.timestamp("2026-11-06T20:00:00+00:00"))
    eq(U.timestamp("2024-03-01T00:00:00Z")-U.timestamp("2024-02-28T00:00:00Z"),172800)
end)
test("Resource paths reject traversal and embedded separators",function()
    for _,s in ipairs({"https://a/../x","https://a/%2e%2e/x","https://a/a%5cb","https://a/a%00b"}) do fails(function() U.resource_path(s) end) end
    eq(U.resource_path("https://a/space%20name.xhtml?cmpt=private"),"space name.xhtml")
end)
test("Multiple cards borrowing the same title stay distinct",function()
    local s=initial();eq(U.count(s.cards),2);eq(U.count(s.loans),3)
    eq(s.loans['A:42'].card_id,"A");eq(s.loans['B:42'].card_id,"B")
    assert(U.filename("Same",'A:42:first')~=U.filename("Same",'B:42:first'))
end)
test("All loan media remain visible",function()
    local s=initial();assert(s.loans['A:audio']);eq(s.loans['A:audio'].downloadable,true);eq(s.loans['A:audio'].download_kind,'mp3');eq(s.loans['A:42'].downloadable,true)
end)
test("All holds remain distinct across cards",function()
    local s=initial();eq(#Model.list(s,"holds"),2);eq(#Model.list(s,"holds","B"),1)
end)
test("Partial library failure preserves missing rows only for that library",function()
    local s=Model.merge(initial(),shelf({card("A"),card("B")},{},{},{A={cards="done",loans="error",holds="error"},B={cards="done",loans="done",holds="done"}}),2)
    assert(s.loans['A:42']);assert(s.loans['A:audio']);eq(s.loans['B:42'],nil);eq(s.holds['B:hold'],nil);eq(s.partial,true)
end)
test("A card needing verification is retained with its cached shelf",function()
    local s=Model.merge(initial(),shelf({card("B")},{loan("B","42")},{},{A={cards="auth",loans="auth",holds="auth"}}),2)
    assert(s.cards.A.needs_verification);assert(s.loans['A:42'].stale);eq(s.partial,true)
end)
test("Authoritative card removal clears that card's rows",function()
    local s=Model.merge(initial(),shelf({card("B")},{loan("B","42")},{}),2)
    eq(s.cards.A,nil);eq(s.loans['A:42'],nil);assert(s.loans['B:42']);eq(s.holds['A:hold'],nil)
end)
test("Missing collection is not interpreted as an empty list",function()
    local r=shelf({card("A"),card("B")});r.loans=nil
    local s=Model.merge(initial(),r,2);eq(U.count(s.loans),3);eq(s.partial,true)
end)
test("Invalid rows prevent destructive collection replacement",function()
    local s=Model.merge(initial(),shelf({card("A"),card("B")},{false},{}),2)
    eq(U.count(s.loans),3);eq(s.partial,true)
end)
test("Replacement checkouts invalidate old downloads",function()
    local s=initial();local old={key='A:42',checkout_id='first'}
    assert(Model.same_checkout(old,s.loans['A:42']))
    s=Model.merge(s,shelf({card("A"),card("B")},{loan("A","42","replacement"),loan("B","42")},{}),2)
    eq(Model.same_checkout(old,s.loans['A:42']),false)
end)
test("Card labels are resolved per card",function()
    local s=initial();contains(Model.card_label(s,"A"),"Library A");contains(Model.card_label(s,"B"),"Library B")
end)
test("Default card-number labels are masked without discarding custom names",function()
    local c=card('A','A123456789');c.username='A123456789'
    local s=Model.merge(Model.empty(),shelf({c}),1)
    eq(s.cards.A.name,'Card ••••6789');assert(not J.encode(s):find('A123456789',1,true))
    eq(Model.mask_name('Family card'),'Family card')
end)
test("Existing cached numeric card labels are sanitized",function()
    local s={cards={A={name='1234567890'}}};assert(Model.sanitize(s));eq(s.cards.A.name,'Card ••••7890')
end)
test("Replaced card aliases retain active loans and work in card filters",function()
    local c=card('new');c.mergedCardIds={'old'}
    local s=Model.merge(Model.empty(),shelf({c},{loan('old','42')}),1)
    eq(Model.card_for(s,'old').id,'new');eq(#Model.list(s,'loans','new'),1);contains(Model.card_label(s,'old'),'Library new')
end)
test("A merged alias cannot override a separately returned card",function()
    local c=card('new');c.mergedCardIds={'other'}
    local s=Model.merge(Model.empty(),shelf({c,card('other')},{loan('other','42')}),1)
    eq(Model.card_for(s,'other').id,'other');eq(s.card_aliases.other,nil)
end)
test("Returned active loans remain visible while card metadata is absent",function()
    local s=Model.merge(Model.empty(),shelf({},{loan('pending','42')}),1)
    assert(s.loans['pending:42']);eq(Model.card_label(s,'pending'),'Library card')
end)
test("Hold labels do not invent queue data",function()
    eq(Model.hold_label({}),"On hold");eq(Model.hold_label({available=true}),"Ready to borrow")
    eq(Model.hold_label({position=4}),"Position 4")
end)
test("Shelf persistence excludes card numbers and account secrets",function()
    local c=card("A");c.username="not-for-storage";c.accounts={{secret="private"}}
    local s=Model.merge(Model.empty(),shelf({c},{loan("A","42")}),1)
    local encoded=J.encode(s);assert(not encoded:find("not-for-storage",1,true));assert(not encoded:find("private",1,true))
end)

local function cfc1(s) return U.base64_encode(s):gsub("(.)(.)(.)(.)","%4%2%3%1") end
test("Native cfc1 decodes Unicode and preserves the original head",function()
    local body='<body><p>café 🌍</p><img src="cover.jpg"></body>'
    local raw='<html><head><title>Chapter</title><link href="style.css" rel="stylesheet"></head><body><script>parent.__bif_cfc1(self,"'..cfc1(body)..'")</script></body></html>'
    local out=Decoder.xhtml(raw);contains(out,"café 🌍");contains(out,'href="style.css"');contains(out,'<img src="cover.jpg" />');assert(not out:find('__bif_cfc',1,true))
end)
test("Native cfc0 uses UTF8 bytes without double encoding",function()
    eq(Decoder.decode_body("0",U.base64_encode('<body>café 🌍</body>')),'<body>café 🌍</body>')
end)
test("Keyed page decoding handles zero-based character positions",function()
    eq(Decoder.decode_body("3","OGDjUHayP28Yj6YO'Js1UT]V@myGHTps",{"1049"}),'<body>café 🌍</body>')
end)
test("Unsupported or incomplete page wrappers fail closed",function()
    fails(function() Decoder.decode_body("2","") end)
    fails(function() Decoder.decode_body("1",cfc1('not a body')) end)
    fails(function() Decoder.xhtml('<html><body><script>parent.__bif_cfc2(self,"x")</script></body></html>') end)
end)
test("XHTML restores namespaces and named entities",function()
    local s=Decoder.xhtml('<html><head><title>A</title><base href="/"></head><body><p>A&nbsp;&eacute;&amp;B</p><br></body></html>')
    contains(s,'xmlns:epub=');contains(s,'&#160;&#233;&amp;B');contains(s,'<br />');assert(not s:find('<base ',1,true))
end)
test("Tag scanning preserves greater-than inside attributes",function()
    local s=Decoder.xhtml('<html><head><title>A</title></head><body><p title="a > b">Text</p></body></html>')
    eq(Decoder.attributes(s:match('<p(.-)>')).title,'a > b')
end)
test("NCX rewrite preserves other self-closing metadata",function()
    local s=Epub.ncx('<ncx><head><meta name="dtb:uid" content="old"/><meta name="dtb:depth" content="2"/></head></ncx>',{id="42"})
    contains(s,'urn:kolibby:42');contains(s,'<meta name="dtb:depth" content="2"/>')
end)
test("EPUB manifest retains native spine order and NCX reference",function()
    local s=Epub.package({title={main="A & B"},language="en",spine={{path="b.xhtml"},{path="a.xhtml"}},creator={}},
        {id="42",title="A"},{{path="a.xhtml",media_type="application/xhtml+xml"},{path="b.xhtml",media_type="application/xhtml+xml"},{path="toc.ncx",media_type="application/x-dtbncx+xml"}},0)
    contains(s,"A &amp; B");contains(s,'<spine toc="r3"><itemref idref="r2"/><itemref idref="r1"/>')
end)
test("EPUB packaging rejects a missing spine resource",function()
    fails(function() Epub.package({spine={{path='missing.xhtml'}}},{id='42'},{},0) end,"required chapter")
end)
test("Missing source TOC falls back to the complete native spine",function()
    local s=Epub.navigation({spine={{path='a.xhtml'},{path='b.xhtml'}}})
    contains(s,'href="a.xhtml">Section 1');contains(s,'href="b.xhtml">Section 2')
end)
test("WOFF font bytes are packaged with their real type and extension",function()
    local media,path=Assets.classify('fonts/publisher.ttf','application/font-woff','wOFF')
    eq(media,'font/woff');eq(path,'fonts/publisher.woff')
    local out=Publication.rewrite('@font-face{src:url(publisher.ttf)}',{url='https://book.read.libbyshelf.com/fonts/style.css',path='fonts/style.css',media_type='text/css'},
        {['book.read.libbyshelf.com/fonts/publisher.ttf']={path=path}})
    contains(out,'publisher.woff')
end)
test("Binary asset signatures reject sign-in HTML with a media filename",function()
    fails(function() Assets.validate('image/jpeg','<!DOCTYPE html><html>') end,'unexpected format')
    fails(function() Assets.validate('font/woff','<html>Login</html>') end,'unexpected format')
    Assets.validate('image/png','\137PNG\r\n\26\n')
    Assets.validate('font/woff','wOFFfixture')
end)
test("Already-normalized font references survive a resumed packaging pass",function()
    local asset={path='fonts/style.css',url='https://book.read.libbyshelf.com/fonts/style.css',media_type='text/css'}
    local font={path='fonts/publisher.woff'}
    local out=Publication.rewrite('@font-face{src:url(publisher.woff)}',asset,
        {['book.read.libbyshelf.com/fonts/publisher.ttf']=font,['book.read.libbyshelf.com/fonts/publisher.woff']=font})
    contains(out,'publisher.woff')
end)
test("Sign-in or interactive forms are rejected as chapters",function()
    fails(function() Decoder.xhtml('<html><head><title>Sign in</title></head><body><form action="login"></form></body></html>') end,'sign-in page')
end)
test("EPUB declares inline SVG and MathML properties",function()
    local s=Epub.package({spine={{path='a.xhtml'}}},{id='42'},{{path='a.xhtml',media_type='application/xhtml+xml',properties={svg=true,mathml=true}}},0)
    contains(s,'properties="svg mathml"')
end)
test("Publication URLs become local, safe, encoded references",function()
    local page={url='https://book.read.libbyshelf.com/chapters/a.xhtml',path='chapters/a.xhtml',media_type='application/xhtml+xml'}
    local img={path='images/space name.jpg'}
    local out=Publication.rewrite('<html><body><img src="../images/space%20name.jpg"><a href="https://example.org/">Site</a></body></html>',page,
        {['book.read.libbyshelf.com/images/space name.jpg']=img})
    contains(out,'src="../images/space%20name.jpg"');contains(out,'href="https://example.org/"')
end)
test("Missing embedded assets prevent successful completion",function()
    fails(function() Publication.rewrite('<html><body><img src="missing.jpg"></body></html>',{url='https://book.read.libbyshelf.com/a.xhtml',path='a.xhtml'}, {}) end,"missing a linked")
end)
test("External hyperlinks without a trailing slash remain ordinary links",function()
    local s=Publication.rewrite('<html><body><a href="http://example.org">Site</a></body></html>',{url='https://book.read.libbyshelf.com/a.xhtml',path='a.xhtml'}, {})
    contains(s,'href="http://example.org"')
end)
test("CSS references are validated and kept local",function()
    local out=Publication.rewrite('p{background:url("../cover.jpg")}',{url='https://book.read.libbyshelf.com/css/style.css',path='css/style.css',media_type='text/css'},
        {['book.read.libbyshelf.com/cover.jpg']={path='cover.jpg'}})
    eq(out,'p{background:url("../cover.jpg")}')
end)
test("Styles embedded in XHTML are checked for missing assets",function()
    fails(function() Publication.rewrite('<html><head><style>p{background:url(missing.jpg)}</style></head><body></body></html>',
        {url='https://book.read.libbyshelf.com/a.xhtml',path='a.xhtml'}, {}) end,'missing a linked')
end)

local function fake_client(responses,auth)
    local calls={};local index=0;local saved
    local client=Client.new{auth=auth or {identity='abcdefghijklmnopqrstuvwxyz',chip='chip-version'},save_auth=function(a) saved=U.copy(a) end,
        transport=function(req)
            calls[#calls+1]=U.copy(req);index=index+1
            local response=assert(responses[index],"unexpected request")
            if response.error then error(response.error,0) end
            return {status=response.status or 200,body=J.encode(response.data or {}),headers={}}
        end}
    return client,calls,function() return saved end
end
test("Identity acquisition applies the current client header and persists identity",function()
    local c,calls,saved=fake_client({{data={identity='newidentity',chip='new-chip'}}},{})
    c:acquire();eq(calls[1].method,'POST');eq(calls[1].headers['Accept-Language'],'bh');eq(saved().identity,'newidentity')
end)
test("Missing-chip response refreshes once and retries the original request",function()
    local c,calls=fake_client({{status=403,data={result='missing_chip'}},{data={identity='refreshed',chip='chip-version'}},{data=shelf()}})
    eq(c:sync().result,'synchronized');eq(#calls,3);eq(calls[3].headers.Authorization,'Bearer refreshed')
end)
test("Repeated authorization failure does not loop",function()
    local c,calls=fake_client({{status=403,data={result='missing_chip'}},{data={identity='refreshed',chip='chip-version'}},{status=403,data={result='missing_chip'}}})
    fails(function() c:sync() end);eq(#calls,3)
end)
test("Displayed setup code uses the pointer role",function()
    local c,calls=fake_client({{data={code='12345678',expiry=123}}})
    c:code('87654321');contains(calls[1].url,'role=pointer');contains(calls[1].url,'code=87654321')
end)
test("Pairing completes the blessing exchange and reacquires identity",function()
    local c,calls,saved=fake_client({{data={}},{data={identity='linked',chip='chip-version'}},{data=shelf({card('A')})}})
    c:finish_pairing('fixture-blessing');eq(J.decode(calls[1].body).blessing,'fixture-blessing');eq(saved().paired,true);eq(#calls,3)
end)
test("Native publication requests use the selected card and never leak identity to content hosts",function()
    local c,calls=fake_client({{data={message='d=fixture',urls={rosters='https://book.read.libbyshelf.com/_d/roster.json',openbook='https://book.read.libbyshelf.com/_d/openbook.json'}}},
        {data={{group='title-content',entries={}}}},{data={spine={{path='a.xhtml'}}}}})
    c:publication({card_id='B',id='42',key='B:42'},{website_id='library-B',advantage_key='library',library='Library B'})
    contains(calls[1].url,'/card/B/title/42');contains(calls[1].url,'website_id=library-B')
    eq((calls[2].headers or {}).Authorization,nil);eq((calls[3].headers or {}).Authorization,nil);contains(calls[2].url,'?d=fixture')
    eq(calls[1].profile,'api');eq(calls[2].profile,'roster');eq(calls[3].profile,'resource')
    local t=J.decode(U.base64_decode(calls[1].url:match('[?&]t=([^&]+)'):gsub('%%(%x%x)',function(h) return string.char(tonumber(h,16)) end)))
    eq(t.spec,'V32');eq(t.codex.loan.slug,'B-42')
end)
test("Audiobook publication uses the selected card and the native audio passport",function()
    local c,calls=fake_client({{data={message='d=fixture',urls={rosters='https://a.listen.libbyshelf.com/roster',openbook='https://a.listen.libbyshelf.com/map'}}},
        {data={{group='title-content',entries={}}}},{data={spine={{path='a.mp3'}}}}})
    c:publication({card_id='B',id='42',key='B:42',media_type='audiobook'},{website_id='library-B'})
    contains(calls[1].url,'/open/audiobook/card/B/title/42');eq(calls[2].profile,'roster');eq(calls[3].profile,'resource')
    eq((calls[2].headers or {}).Authorization,nil);eq((calls[3].headers or {}).Authorization,nil)
end)
test("API requests use the configured defaults",function()
    local h=Profile.headers('api',{Authorization='Bearer fixture'},{web='gzip, deflate, zstd',native='gzip'})
    eq(h['User-Agent'],Profile.webview_user_agent)
    eq(h.Origin,'https://libbyapp.com');eq(h['X-Requested-With'],'com.overdrive.mobile.android.libby')
    eq(h['sec-ch-ua-platform'],'"Android"');eq(h['sec-ch-ua-mobile'],'?1')
    eq(h['Sec-Fetch-Mode'],'cors');eq(h['Sec-Fetch-Dest'],'empty');eq(h['Sec-Fetch-Site'],'same-site')
    eq(h['Accept-Encoding'],'gzip, deflate, zstd');eq(h.Connection,'keep-alive');eq(h.TE,nil)
end)
test("Content requests use the configured defaults",function()
    local h=Profile.headers('resource',nil,{web='gzip, deflate, zstd',native='gzip'})
    eq(h['User-Agent'],Profile.native_user_agent);eq(h['Accept-Encoding'],'gzip');eq(h.Connection,'Keep-Alive')
    eq(h['Access-Control-Allow-Origin'],'*');eq(h.Accept,nil);eq(h['Accept-Language'],nil)
    eq(h.Origin,nil);eq(h['sec-ch-ua'],nil);eq(h['X-Requested-With'],nil)
end)
test("Native roster requests omit the resource-only header",function()
    local h=Profile.headers('roster',nil,{web='gzip, deflate',native='gzip'})
    eq(h['Access-Control-Allow-Origin'],nil);eq(h.Accept,nil);eq(h['User-Agent'],Profile.native_user_agent)
end)
test("Identity-derived language header overrides only its case-insensitive default",function()
    local h=Profile.headers('api',{['accept-language']='xy'},{web='gzip',native='gzip'})
    eq(h['Accept-Language'],'xy');eq(h['accept-language'],nil);eq(h['User-Agent'],Profile.webview_user_agent)
end)
test("Resource-supplied headers are retained without introducing browser headers",function()
    local h=Profile.headers('resource',{['content-type']='application/x-www-form-urlencoded',['X-Publication-Mode']='fixture'},{native='gzip'})
    eq(h['Content-Type'],'application/x-www-form-urlencoded');eq(h['x-publication-mode'],'fixture');eq(h.Origin,nil)
end)
test("Certificate hostname wildcards match exactly one label",function()
    assert(TLS.matches('sentry.libbyapp.com','*.libbyapp.com'))
    eq(TLS.matches('evil.libbyapp.com.example.org','*.libbyapp.com'),false)
    eq(TLS.matches('deep.sentry.libbyapp.com','*.libbyapp.com'),false)
    eq(TLS.matches('libbyapp.com','*.libbyapp.com'),false)
    eq(TLS.matches('libbyapp.com','*com'),false)
    assert(TLS.matches('SENTRY.LIBBYAPP.COM.','sentry.libbyapp.com'))
end)
test("TLS requires a matching DNS subject alternative name",function()
    local cert={extensions=function() return {['2.5.29.17']={dNSName={'*.libbyapp.com','libbyapp.com'}}} end}
    assert(TLS.verify_name(cert,'sentry.libbyapp.com'));eq(TLS.verify_name(cert,'other.example.org'),false)
    eq(TLS.verify_name({extensions=function() return {} end},'sentry.libbyapp.com'),false)
end)
test("CA bundle prefers KOReader's absolute data path over firmware bundles",function()
    local Diag=require("kolibby/netdiag")
    local list=Diag.candidates({get_system_ca=function() return "/etc/ssl/cert.pem" end},{cwd="/mnt/us/koreader",koreader_dir="/mnt/us/koreader"})
    eq(list[1],"/mnt/us/koreader/data/ca-bundle.crt");eq(list[3],"data/ca-bundle.crt");eq(list[4],"/etc/ssl/cert.pem")
    eq(Diag.ca_bundle({},function(path) return path=="data/ca-bundle.crt" end),"data/ca-bundle.crt")
    eq(Diag.ca_bundle({},function() return false end),nil)
    -- LuaSec 1.3.2 has no get_system_ca; a raising one is ignored.
    assert(#Diag.candidates({get_system_ca=function() error("boom") end},{cwd="/x"})>=3)
end)
test("Network failures name their cause without addresses, paths or tokens",function()
    local Diag=require("kolibby/netdiag")
    local cases={
        {{"certificate verify failed"},"certificate",{reasons={"unable to get local issuer certificate"}}},
        {{"certificate verify failed"},"clock",{reasons={"certificate is not yet valid"}}},
        {{"certificate verify failed"},"clock",{reasons={},now=1600000000}},
        {"TLS hostname validation failed","hostname",{}},
        {{"host or service not provided, or not known"},"dns",{}},
        {{"connection refused"},"refused",{}},
        {{"wantread"},"timeout",{}},
        {{"error loading CA locations ((null))"},"ca",{}},
        {"kolibby/transport.lua:70: /mnt/us/koreader/KOLibby/x.part: No space left on device","storage",{}},
        {"Could not create the download file: /mnt/us/koreader/cache/a:b.part: Invalid argument","storage",{}},
        {{"closed"},"closed",{}},
        {"something odd https://sentry.libbyapp.com/chip?token=secret","other",{}},
    }
    for _,c in ipairs(cases) do
        local context=c[3];context.host="sentry.libbyapp.com"
        local d=Diag.describe(c[1],context)
        eq(d.kind,"network");eq(d.stage,c[2]);contains(d.message,"["..c[2].."]")
        assert(not d.message:find("secret",1,true) and not d.message:find("/mnt/us",1,true) and not d.message:find("?token",1,true),d.message)
    end
    contains(Diag.describe({"certificate verify failed"},{host="h",reasons={"certificate has expired"}}).message,"date and time")
    eq(Diag.describe(nil,{host="h",no_ca=true}).stage,"ca")
end)
test("Cookie jar respects host, domain and path boundaries",function()
    local h=Http.new{clock=function() return 100 end}
    h:store_cookies('https://a.read.libbyshelf.com/book/page',{['set-cookie']='host=one; Path=/book; Secure, shared=two; Domain=.read.libbyshelf.com; Path=/; Secure'})
    contains(h:cookie_header('https://a.read.libbyshelf.com/book/next'),'host=one')
    eq(h:cookie_header('https://b.read.libbyshelf.com/'),'shared=two')
    eq(h:cookie_header('https://other.example/'),nil)
    eq(h:cookie_header('https://a.read.libbyshelf.com/bookish'),'shared=two')
end)
test("Cookie expiry and unrelated domain cookies are enforced",function()
    local h=Http.new{clock=function() return 100 end}
    h:store_cookies('https://a.libbyshelf.com/',{['set-cookie']='a=b; Path=/; Max-Age=30'})
    assert(h:cookie_header('https://a.libbyshelf.com/'))
    h:store_cookies('https://a.libbyshelf.com/',{['set-cookie']='a=gone; Path=/; Max-Age=0, evil=x; Domain=example.org'})
    eq(h:cookie_header('https://a.libbyshelf.com/'),nil)
end)
test("Redirects strip authorization and recompute cookies per destination",function()
    local calls={};local h=Http.new{driver=function(req)
        calls[#calls+1]=U.copy(req)
        if #calls==1 then return {status=302,headers={location='https://cdn.libbyshelf.com/a'}} end
        return {status=200,headers={},body='ok'}
    end}
    h:store_cookies('https://api.libbyshelf.com/',{['set-cookie']='private=fixture; Path=/'})
    h:request{url='https://api.libbyshelf.com/a',headers={Authorization='Bearer fixture'}}
    contains(calls[1].headers.Cookie,'private=fixture');eq(calls[2].headers.Authorization,nil);eq(calls[2].headers.Cookie,nil)
end)
test("Redirects reject HTTPS downgrades",function()
    local h=Http.new{driver=function() return {status=302,headers={location='http://cdn.libbyshelf.com/a'}} end}
    fails(function() h:request{url='https://api.libbyshelf.com/a'} end,'insecure')
end)
test("Error presentation redacts transport URLs",function()
    local message=U.error_message('transport https://example.org/?token=private failed')
    assert(not message:find('private',1,true));assert(not message:find('https://',1,true))
end)


local function ready_shelf()
    local hold=loan('A','42');hold.isAvailable=true;hold.reserveId='offer-A'
    local other=loan('B','42');other.isAvailable=true;other.reserveId='offer-B'
    return shelf({card('A'),card('B')},{loan('B','other')},{hold,other})
end
local function borrow_callbacks()
    local saved,pending
    return {persist=function(s) saved=U.copy(s) end,pending=function(p) pending=U.copy(p) end},function() return saved,pending end
end
local function ready_state()
    local raw=ready_shelf();local state=Model.merge(Model.empty(),raw,os.time())
    return raw,state,state.holds['A:42']
end

test('Shelf metadata selects a useful cover without requiring dimensions',function()
    local raw=loan('A','42');raw.covers={cover150Wide={href='https://img.od-cdn.com/small.jpg'},cover300Wide={href='https://img.od-cdn.com/medium.jpg'}}
    raw.subtitle='A subtitle';raw.detailedSeries={seriesName='A series',readingOrder=3};raw.formats[1].duration='12:34:56'
    local v=Model.merge(Model.empty(),shelf({card('A')},{raw}),1).loans['A:42']
    eq(v.cover_url,'https://img.od-cdn.com/medium.jpg');eq(v.series,'A series');eq(v.series_order,'3');eq(v.duration,'12:34:56');eq(v.subtitle,'A subtitle')
end)
test('Placeholder cover is skipped and optional metadata may be absent',function()
    local raw=loan('A','42');raw.covers={cover300Wide={href='https://img.od-cdn.com/placeholder.jpg',isPlaceholderImage=true},cover150Wide={href='https://img.od-cdn.com/small.jpg'}}
    eq(Model.merge(Model.empty(),shelf({card('A')},{raw}),1).loans['A:42'].cover_url,'https://img.od-cdn.com/small.jpg')
    eq(initial().loans['A:42'].subtitle,nil)
end)
test('Cover addresses require HTTPS and an actual allowed domain boundary',function()
    assert(Covers.allowed('https://img1.od-cdn.com/cover.jpg'))
    eq(Covers.allowed('http://img1.od-cdn.com/a.jpg'),false)
    eq(Covers.allowed('https://od-cdn.com.evil.example/a.jpg'),false)
    eq(Covers.allowed('https://user@od-cdn.com/a.jpg'),false)
    eq(Covers.allowed('https://127.0.0.1/a.jpg'),false)
    assert(Covers.path({cover_url='https://img1.od-cdn.com/a.jpg'},'/cache')~=Covers.path({cover_url='https://img1.od-cdn.com/b.jpg'},'/cache'))
end)
test('Native hold suspension expires at its specified time',function()
    local raw=ready_shelf();raw.holds[1].suspensionFlag=true;raw.holds[1].suspensionEnd='2026-11-07T00:00:00Z'
    local future=Model.merge(Model.empty(),raw,U.timestamp('2026-11-06T00:00:00Z')).holds['A:42']
    local past=Model.merge(Model.empty(),raw,U.timestamp('2026-11-08T00:00:00Z')).holds['A:42']
    assert(future.suspended);eq(past.suspended,false);eq(Model.can_borrow(future),false)
end)
test('Borrow readiness excludes expired stale suspended and catalogue-only states',function()
    local _,state,hold=ready_state();assert(Model.can_borrow(hold))
    for _,flag in ipairs({'stale','suspended'}) do local h=U.copy(hold);h[flag]=true;eq(Model.can_borrow(h),false) end
    local h=U.copy(hold);h.expires=1;eq(Model.can_borrow(h),false)
    h=U.copy(hold);h.available=false;h.availableCopies=20;eq(Model.can_borrow(h),false)
    eq(Model.can_borrow(state.loans['B:other']),false)
end)
test('Audiobook duration and progress labels handle missing and bounded values',function()
    eq(Present.duration('12:34:56'),'12 hr 34 min');eq(Present.duration('00:45:00'),'45 min');eq(Present.duration('bad'),nil)
    local p=Present.progress({stage='downloading',done=9,total=3,bytes=1024*1024});eq(p.percentage,1);eq(p.count,'3 of 3 files');eq(p.bytes,'1.0 MB')
    eq(Present.progress({stage='authorizing'}).percentage,0);eq(Present.progress({stage='packaging'}).stage,'Finishing EPUB')
end)
test('Hold summary shows queue position and waiting estimate together',function()
    local _,state,hold=ready_state();hold.available=false;hold.position=2;hold.wait_days=7
    local s=Present.summary(hold,state);eq(s.status,'Position 2');eq(s.detail,'About 7 days to wait')
end)
test('Loan periods use valid server options and the actual preference',function()
    local choices,preferred=Borrowing.periods({options={{7,'days'},{14,'days'},{14,'days'},{-1,'days'},{3,'invalid'}},preference={14,'days'}})
    eq(#choices,2);eq(choices[1][1],14);eq(preferred,'14:days');eq(Borrowing.period_label({1,'days'}),'1 day')
    eq(Borrowing.periods({options={}}),nil)
end)
test('Borrow preparation refreshes the selected hold and reads its own periods',function()
    local raw,state,hold=ready_state()
    local c,calls=fake_client({{data=raw},{data={options={{7,'days'},{14,'days'}},preference={14,'days'}}}})
    local result=Borrowing.prepare(c,state,hold,function() end)
    eq(calls[2].method,'GET');contains(calls[2].url,'card/A/loan/42/periods');eq(result.preferred,'14:days');eq(result.options[1][1],14)
end)
test('Borrow preparation can use the library card periods without inventing a default',function()
    local raw,state,hold=ready_state();raw.cards[1].lendingPeriods={book={options={{21,'days'}},preference={21,'days'}}}
    local c=fake_client({{data=raw},{status=503,data={}}})
    eq(Borrowing.prepare(c,state,hold,function() end).options[1][1],21)
    c=fake_client({{data=ready_shelf()},{data={options={}}}})
    fails(function() Borrowing.prepare(c,state,hold,function() end) end,'Loan periods')
end)
test('A card requiring verification cannot prepare a borrow',function()
    local raw,state,hold=ready_state();raw.summary={A={cards='auth',holds='auth'}}
    local c,calls=fake_client({{data=raw}})
    fails(function() Borrowing.prepare(c,state,hold,function() end) end,'not ready');eq(#calls,1)
end)
test('Borrow posts the selected card format period and JSON null then synchronizes',function()
    local raw,state,hold=ready_state();local final=ready_shelf();final.loans[#final.loans+1]=loan('A','42','new-checkout');table.remove(final.holds,1)
    local c,calls=fake_client({{data=raw},{status=201,data=loan('A','42','new-checkout')},{data=final}})
    local cb,saved=borrow_callbacks();local result=Borrowing.commit(c,state,hold,{14,'days'},cb)
    eq(calls[2].method,'POST');contains(calls[2].url,'card/A/loan/42');contains(calls[2].body,'"lucky_day":null')
    local body=J.decode(calls[2].body);eq(body.period,14);eq(body.units,'days');eq(body.title_format,'ebook')
    eq(result.loan_key,'A:42');eq(result.shelf.holds['A:42'],nil);assert(result.shelf.holds['B:42']);assert(result.shelf.loans['B:other'])
    local s,p=saved();eq(p.key,nil);eq(s.loans['A:42'].checkout_id,'new-checkout');eq(#calls,3)
end)
test('Confirmed borrowing survives a failed follow-up synchronization',function()
    local raw,state,hold=ready_state();local c=fake_client({{data=raw},{data=loan('A','42','confirmed')},{error={kind='network',message='offline'}}})
    local cb,saved=borrow_callbacks();local result=Borrowing.commit(c,state,hold,{7,'days'},cb)
    eq(result.loan_key,'A:42');assert(result.shelf.partial);eq(result.shelf.holds['A:42'],nil)
    local s=saved();eq(s.loans['A:42'].checkout_id,'confirmed');contains(result.message,'Borrowed')
end)
test('A timed-out borrow reconciles success without a second POST',function()
    local raw,state,hold=ready_state();local final=ready_shelf();final.loans[#final.loans+1]=loan('A','42','server-created');table.remove(final.holds,1)
    local c,calls=fake_client({{data=raw},{error={kind='network',message='timeout'}},{data=final}})
    local cb=borrow_callbacks();local result=Borrowing.commit(c,state,hold,{7,'days'},cb)
    eq(result.loan_key,'A:42');eq(#calls,3);eq(calls[3].method,'GET')
end)
test('Unknown borrow outcome keeps its pending marker and does not repost',function()
    local raw,state,hold=ready_state();local c,calls=fake_client({{data=raw},{error={kind='network',message='timeout'}},{error={kind='network',message='offline'}}})
    local cb,saved=borrow_callbacks();local result=Borrowing.commit(c,state,hold,{7,'days'},cb)
    assert(result.uncertain);eq(result.loan_key,nil);eq(#calls,3);assert(result.shelf.holds['A:42'])
    local _,p=saved();eq(p.key,'A:42')
end)
test('An existing loan on the same card prevents a repeated borrow',function()
    local raw,state,hold=ready_state();raw.loans[#raw.loans+1]=loan('A','42','already')
    local c,calls=fake_client({{data=raw}});local cb=borrow_callbacks()
    eq(Borrowing.commit(c,state,hold,{7,'days'},cb).loan_key,'A:42');eq(#calls,1)
end)
test('Loan result from a different real card is not imported',function()
    local _,state,hold=ready_state()
    fails(function() Model.import_borrowed(state,loan('B','42','wrong'),hold) end,'unexpected loan')
    assert(state.holds['A:42']);eq(state.loans['A:42'],nil)
end)
test('Borrowing errors explain circulation limits without raw response leakage',function()
    local raw,state,hold=ready_state();local c=fake_client({{data=raw},{status=400,data={result='upstream_failure',upstream={errorCode='PatronExceededCheckoutLimit'}}},{data=raw}})
    local cb=borrow_callbacks();local result=Borrowing.commit(c,state,hold,{7,'days'},cb)
    contains(result.message,'loan limit');eq(result.loan_key,nil);assert(result.shelf.holds['A:42'])
end)


test('Explicit missing-chip rejection may refresh and replay the borrow once',function()
    local raw,state,hold=ready_state();local final=ready_shelf();final.loans[#final.loans+1]=loan('A','42','new');table.remove(final.holds,1)
    local c,calls=fake_client({{data=raw},{status=403,data={result='missing_chip'}},{data={identity='refreshed',chip='new-chip'}},{data=loan('A','42','new')},{data=final}})
    local cb=borrow_callbacks();eq(Borrowing.commit(c,state,hold,{7,'days'},cb).loan_key,'A:42')
    eq(#calls,5);eq(calls[2].body,calls[4].body);eq(calls[4].headers.Authorization,'Bearer refreshed')
end)
test('Human hold estimates use weeks months and a bounded long-wait label',function()
    eq(Present.wait_label(0),'Expected soon');eq(Present.wait_label(14),'About 2 weeks to wait')
    eq(Present.wait_label(98),'About 4 months to wait');eq(Present.wait_label(3780),'Over a year to wait')
end)


test('A loan on another real card does not block this ready hold',function()
    local raw,state,hold=ready_state();raw.loans[#raw.loans+1]=loan('B','42','other-card')
    local periods={options={{7,'days'}},preference={7,'days'}}
    local c=fake_client({{data=raw},{data=periods}})
    local prepared=Borrowing.prepare(c,state,hold,function() end)
    eq(prepared.hold.card_id,'A');eq(prepared.existing,nil)
end)
test('Confirmed loan on an explicit replacement card resolves the old hold alias',function()
    local replacement=card('C');replacement.mergedCardIds={'A'}
    local held=loan('A','42');held.isAvailable=true
    local state=Model.merge(Model.empty(),shelf({replacement},{},{held}),os.time())
    local result,borrowed=Model.import_borrowed(state,loan('C','42','replacement-checkout'),state.holds['A:42'])
    eq(borrowed.card_id,'C');assert(result.loans['C:42']);eq(result.holds['A:42'],nil)
end)

test('MP3 progress labels use byte totals and identify download and remux stages',function()
    local p=Present.progress({kind='mp3',stage='downloading',done=1048576,total=2097152,detail='Part 1 of 2'})
    eq(p.percentage,.5);contains(p.count,'Part 1 of 2');contains(p.count,'1.0 MB of 2.0 MB');eq(p.bytes,nil)
    eq(Present.progress({kind='mp3',stage='joining'}).stage,'Joining MP3')
    eq(Present.progress({kind='mp3',stage='complete'}).stage,'Ready to listen')
end)
test('Progress writes once per step change and at most once per interval within a step',function()
    local Progress=require('kolibby/progress')
    local now,written=100,{}
    local write=Progress.throttle(function(v) written[#written+1]=v.done end,{interval=2,clock=function() return now end})
    write({stage='downloading',detail='Part 1 of 2',done=1})
    for i=2,20 do now=now+.25;write({stage='downloading',detail='Part 1 of 2',done=i}) end
    eq(table.concat(written,','),'1,9,17')
    write({stage='downloading',detail='Part 2 of 2',done=21});write({stage='joining',done=0})
    write({stage='complete',done=1});eq(table.concat(written,','),'1,9,17,21,0,1')
    eq(Progress.write_interval(true),2);eq(Progress.poll_interval(true),1);eq(Progress.poll_interval(false),.5)
    eq(Progress.eink({hasEinkScreen=function() return true end}),true);eq(Progress.eink({}),false)
    eq(Progress.eink({hasEinkScreen=function() error('unsupported') end}),false)
end)
require("tests/filesystem")(test,eq,fails,contains)
require("tests/fatstorage")(test,eq,fails,contains)
require("tests/tlsmode")(test,eq,fails,contains)
require("tests/partners")(test,eq,fails,contains)
require("tests/publication")(test,eq,fails,contains)
require("tests/audiobook")(test,eq,fails,contains)
require("tests/batch")(test,eq,fails,contains)
require("tests/updater")(test,eq,fails,contains)
test('Batch progress distinguishes shelf synchronization from completion',function()
    local p=Present.progress({stage='batch_preparing'});eq(p.stage,'Checking your loans');eq(p.percentage,0)
    p=Present.progress({stage='batch_complete'});eq(p.stage,'Downloads finished');eq(p.percentage,1)
end)

io.write(string.format("\n%d passed; %d failed\n",passed,failed))
os.exit(failed==0 and 0 or 1)
