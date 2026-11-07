-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
return function(test,eq,fails,contains)
local U=require('kolibby/util');local J=require('kolibby/json');local D=require('kolibby/decoder')
local P=require('kolibby/publication');local L=require('kolibby/layout');local Markup=require('kolibby/markup')
local function fixture(name)
    local f=assert(io.open('tests/fixtures/'..name..'.json','rb'));local value=J.decode(f:read('*a'));f:close();return value
end
local function wrapper(kind,payload)
    return '<html><head><title>fixture</title></head><body><script>parent.__bif_cfc'..kind..'(self,'..J.encode(payload)..');</script></body></html>'
end
test('Page-decoding regression vectors match expected bodies',function()
    for _,v in ipairs(fixture('decoder-vectors')) do eq(D.decode_body(v.kind,v.payload,v.key),v.body) end
end)
test('Page-key and body edge cases match expected outcomes',function()
    for _,v in ipairs(fixture('decoder-edge-vectors')) do
        local ok,result=pcall(function() return D.decode_body(v.kind,v.payload,D.native_key(v.native_key)) end)
        if v.setup_error or v.decoding_failure then eq(ok,false) else assert(ok,result);eq(result,v.assigned_body) end
    end
end)
test('Normalized body fragments match six browser DOM outcomes',function()
    local rows=fixture('decoder-edge-vectors');local expected=fixture('dom-edge-results')
    for _,v in ipairs(expected) do
        local source
        for _,row in ipairs(rows) do if row.label=='missing' and row.body_case==v.case then source=row;break end end
        local html=D.xhtml(wrapper(source.kind,source.payload))
        local body=html:match('(<body>.-</body>)')
        eq(Markup.decode(body),Markup.decode(v.body))
    end
end)
test('CFC payload quoted escapes are unescaped without evaluating JavaScript',function()
    for _,v in ipairs(fixture('decoder-vectors')) do
        local html=D.xhtml(wrapper(v.kind,v.payload),v.key)
        contains(html,'<body')
    end
    eq(D.decode_body('0','PGJvZHk+eDwvYm9keT4'),'<body>x</body>')
    local body='<body><p>escaped</p></body>';local payload=U.base64_encode(body)
    local script='parent.__bif_cfc0(self,"\\x'..string.format('%02x',payload:byte(1))..payload:sub(2,4)..'\\\n'..payload:sub(5)..'");'
    contains(D.xhtml('<html><body><script>'..script..'</script></body></html>'),'<p>escaped</p>')
end)
test('Inert decoder names do not execute and active unknown handlers fail',function()
    contains(D.xhtml('<html><body><script>var re = /"/;</script><p>kept</p></body></html>'),'<p>kept</p>')
    contains(D.xhtml('<html><body><script>var a="__bif_cfc7";/* __bif_cfc2 */</script><p>kept</p></body></html>'),'<p>kept</p>')
    fails(function() D.xhtml(wrapper('2','eA==')) end,'unsupported reader encoding')
    fails(function() D.xhtml('<html><body><script>parent["__bif_cfc4"](self,"x")</script></body></html>') end)
end)
test('HTML normalization repairs common optional tags and preserves semantic attributes',function()
    local out=D.xhtml('<html lang=en><body><p title="a > b">A & B&nbsp;<div data-x=one>next<br><p>last')
    contains(out,'A &amp; B&#160;</p><div data-x="one">');contains(out,'<br />');contains(out,'last</p></div></body></html>')
    contains(out,'xml:lang="en"');contains(out,'<title>Chapter</title>')
    contains(D.xhtml('<html><body><svg viewbox="0 0 1 1"><fegaussianblur stddeviation="2"/></svg></body></html>'),'feGaussianBlur stdDeviation="2"')
    fails(function() D.xhtml('<html><body>x\1</body></html>') end,'control character')
    local html,_,base=D.xhtml('<html><head><base href="../media/?cmpt=1&amp;x=2"></head><body onclick="bad()">ok</body></html>')
    eq(base,'../media/?cmpt=1&x=2');assert(not html:find('<base',1,true));assert(not html:find('onclick',1,true))
end)
test('URL resolution preserves native component queries and query-only references',function()
    eq(P.resolve('https://book.libbyshelf.com/a/b.xhtml?old=1','../c.xhtml?cmpt=2&x=3#t'),'https://book.libbyshelf.com/c.xhtml?cmpt=2&x=3#t')
    eq(P.resolve('https://book.libbyshelf.com/a/b.xhtml?old=1','?cmpt=2'),'https://book.libbyshelf.com/a/b.xhtml?cmpt=2')
    eq(P.resolve('https://book.libbyshelf.com/a/b.xhtml?old=1','#t'),'https://book.libbyshelf.com/a/b.xhtml?old=1#t')
end)
test('Srcset parser preserves data URL commas and candidate descriptors',function()
    local seen={};local out=P.srcset('data:image/png;base64,AAAA 1x, ../a.jpg 2x, b.jpg 300w, bad.jpg 1x 2x',function(ref) seen[#seen+1]=ref;return ref=='../a.jpg' and 'local.jpg' or ref end)
    eq(out,'data:image/png;base64,AAAA 1x, local.jpg 2x, b.jpg 300w');eq(#seen,3)
    eq(P.srcset('bad.jpg 0xFFx, good.jpg 1.5e1x',function(ref) return ref end),'good.jpg 1.5e1x')
    eq(P.srcset('a.jpg, b.jpg,',function(ref) return ref end),'a.jpg, b.jpg')
end)
test('The same traversal discovers and rewrites picture CSS SVG and object resources',function()
    local asset={url='https://book.libbyshelf.com/pages/one.xhtml',path='pages/one.xhtml',media_type='application/xhtml+xml',base_url='https://book.libbyshelf.com/media/'}
    local html='<html><head><style>/* url(fake.png) */ @import "style.css"; .x{background:URL("a(1).png");content:"url(no.png)"}</style></head><body><picture><source srcset="a.jpg 1x, b.jpg 2x"/><img src="a.jpg" style="background:url(c\\ d.png)"/></picture><svg><image href="a.jpg"/><use xlink:href="draw.svg#p"/></svg><object data="draw.svg"/><a href="https://example.org/catalog">catalog</a></body></html>'
    local refs=P.references(html,asset);local by={};local count=0
    for _,r in ipairs(refs) do if r.internal then local path=U.resource_path(r.url);by[P.canonical(r.url)]={path=path};count=count+1 end end
    eq(count,9)
    local out=P.rewrite(html,asset,by)
    contains(out,'srcset="../media/a.jpg 1x, ../media/b.jpg 2x"');contains(out,'../media/c%20d.png');contains(out,'../media/draw.svg#p');contains(out,'https://example.org/catalog')
    assert(not out:find('media/fake',1,true));assert(not out:find('media/no',1,true))
end)
test('External metadata and SVG hyperlinks remain links rather than downloads',function()
    local asset={url='https://book.libbyshelf.com/page.xhtml',path='page.xhtml',media_type='application/xhtml+xml'}
    local html='<html><head><link rel="canonical" href="https://publisher.example/book"/></head><body><svg><a xlink:href="https://publisher.example/author">Author</a></svg></body></html>'
    local refs=P.references(html,asset);eq(#refs,2);eq(refs[1].discover,false);eq(refs[2].required,false)
    contains(P.rewrite(html,asset,{}),'https://publisher.example/author')
end)
test('CSS escaped parentheses hex escapes comments strings and imports stay correct',function()
    local refs={}
    local out=P.css('/*url(no)*/ @IMPORT \'theme.css\'; a{a:url(a\\(b\\).png);b:url("c\\22 d.png");content:"url(no)";c:url(data:image/svg+xml,a,b)}',function(ref) refs[#refs+1]=ref;return ref end)
    eq(#refs,4);eq(refs[1],'theme.css');eq(refs[2],'a(b).png');eq(refs[3],'c"d.png');eq(refs[4],'data:image/svg+xml,a,b');contains(out,'/*url(no)*/')
end)
test('Native fixed layout uses viewport objects positions and RTL without guessing spreads',function()
    local info=L.entry({['rendition-layout']='pre-paginated',['rendition-viewport']={width=1200,height=800},['rendition-position']='left',['rendition-spread']='none'},'application/xhtml+xml')
    eq(info.viewport.width,1200);eq(info.layout,'pre-paginated')
    local html=L.document(D.xhtml('<html><body><p>page</p></body></html>'),info,'application/xhtml+xml')
    contains(html,'width=1200, height=800')
    eq(L.properties(info,{layout='reflowable'}),'rendition:layout-pre-paginated rendition:spread-none page-spread-left')
    eq(L.properties(L.entry({},'application/xhtml+xml'),{layout='reflowable'}),'')
end)
test('Fixed pages preserve valid viewport or use the native default when absent',function()
    local html=D.xhtml('<html><head><meta name="viewport" content="width=640,height=480"/></head><body>x</body></html>')
    contains(L.document(html,L.entry({['rendition-layout']='pre-paginated'}),'application/xhtml+xml'),'width=640, height=480')
    contains(L.document(D.xhtml('<html><body>x</body></html>'),L.entry({['rendition-layout']='pre-paginated'}),'application/xhtml+xml'),'width=768, height=1024')
    local svg=L.document('<svg xmlns="http://www.w3.org/2000/svg" viewBox="10 20 100 200"><path/></svg>',L.entry({},'image/svg+xml'),'image/svg+xml')
    contains(svg,'viewBox="10 20 100 200"');contains(svg,'width="100"')
    svg=L.document('<svg width="300px" height="400px"><svg viewBox="0 0 10 20"/></svg>',L.entry({},'image/svg+xml'),'image/svg+xml')
    contains(svg,'viewBox="0 0 300 400"');local count=0;for t in Markup.tokens(svg) do if t.kind=='start' and t.name=='svg' then count=count+1;if count==2 then eq(t.values.viewbox,'0 0 10 20');eq(t.values.width,nil) end end end;eq(count,2)
end)
test('Foreign images without an EPUB fallback fail explicitly',function()
    fails(function() require('kolibby/assets').validate('image/webp','RIFFxxxxWEBP') end,'EPUB fallback')
end)
test('Bitmap spine wrappers are fixed XHTML pages with local SVG image references',function()
    local html=L.image_page('_kolibby-pages/0001.xhtml','images/a b.png',{width=100,height=200},'Page & one')
    contains(html,'width=100, height=200');contains(html,'xlink:href="../images/a%20b.png"');contains(html,'Page &amp; one')
end)
end
