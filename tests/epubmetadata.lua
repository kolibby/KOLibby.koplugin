-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
return function(test,eq,fails,contains)
local Epub=require('kolibby/epub')
local function package(description)
    return Epub.package({title={main='Sample book'},language='en',description=description,
        creator={{name='Sample Author'}},spine={{path='chapter.xhtml'}}},
        {id='fixture',title='Sample book'},{{path='chapter.xhtml',media_type='application/xhtml+xml'}},0)
end
test('EPUB description prefers the full native reader synopsis',function()
    contains(package{full='The full publisher synopsis.',short='A shorter summary.'},
        '<dc:description>The full publisher synopsis.</dc:description>')
end)
test('EPUB description also accepts a string from the reader manifest',function()
    contains(package('A string synopsis.'),'<dc:description>A string synopsis.</dc:description>')
end)
test('Empty and nontext full descriptions fall back to the short synopsis',function()
    for _,full in ipairs({'  ','<p><br /></p>',false,{}}) do
        contains(package{full=full,short='Short synopsis.'},'<dc:description>Short synopsis.</dc:description>')
    end
end)
test('Publisher HTML becomes plain paragraphs with decoded Unicode entities',function()
    local value={full='<p><strong>Caf&eacute;</strong>&nbsp;&amp; tea.</p><p>Second<br>line &#x1F30D;.</p>'}
    eq(Epub.description{description=value},'Café & tea.\n\nSecond\nline 🌍.')
    contains(package(value),'<dc:description>Café &amp; tea.\n\nSecond\nline 🌍.</dc:description>')
end)
test('Description markup comments and executable content do not enter metadata',function()
    local value='<div>Visible<!-- hidden --><script>secret()</script><style>p{color:red}</style></div>'
    local opf=package(value)
    contains(opf,'<dc:description>Visible</dc:description>')
    eq(opf:find('secret',1,true),nil);eq(opf:find('color:red',1,true),nil)
end)
test('Description XML escapes literal markup and decodes entities only once',function()
    local value='3 < 5 &amp; &lt;story&gt; &amp;lt;quoted&amp;gt;'
    contains(package(value),'<dc:description>3 &lt; 5 &amp; &lt;story&gt; &amp;lt;quoted&amp;gt;</dc:description>')
end)
test('Plain descriptions preserve paragraphs and remove invalid XML controls',function()
    eq(Epub.description{description='First\r\n\r\nSecond\0\1\11\31.'},'First\n\nSecond.')
    contains(package('Safe'..string.char(239,191,190)..' text'),'<dc:description>Safe text</dc:description>')
end)
test('Malformed optional descriptions cannot break an otherwise valid EPUB',function()
    for _,value in ipairs({{full='<p title="broken>text',short='Safe fallback'},
        {full='Bad '..string.char(255),short='Safe fallback'},
        {full=string.rep('x',128*1024+1),short='Safe fallback'}}) do
        contains(package(value),'<dc:description>Safe fallback</dc:description>')
    end
    for _,value in ipairs({false,{},123,'  ','<script>hidden</script>'}) do
        eq(package(value):find('<dc:description>',1,true),nil)
    end
    eq(package(nil):find('<dc:description>',1,true),nil)
end)
end
