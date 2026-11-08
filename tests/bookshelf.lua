-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
return function(test,eq,fails,contains)
local Bridge=require('kolibby/bookshelf')
local Model=require('kolibby/model')
local U=require('kolibby/util')
local J=require('kolibby/json')
local function fixture()
    local shelf=Model.empty()
    shelf.cards={A={id='A',library='Harbor Library',name='Family'},B={id='B',library='Hill Library',name='Family'}}
    shelf.card_aliases={oldA='A'}
    local function item(card,id,kind,media)
        return {key=card..':'..id,card_id=card,id=id,kind=kind,title='Book '..id,author='Author',
            media_type=media or 'ebook',media_label=media=='audiobook' and 'Audiobook' or 'eBook',
            download_kind=media=='audiobook' and 'mp3' or 'epub',downloadable=true,
            checkout_id=kind=='loans' and 'checkout-'..card..'-'..id or nil,
            expires=os.time()+3600,cover_url='https://img1.od-cdn.com/'..id..'.jpg',placed=100,
            available=kind=='holds',series='Series',series_order='2'}
    end
    for _,row in ipairs({item('A','42','loans'),item('B','42','loans'),item('A','77','loans','audiobook')}) do shelf.loans[row.key]=row end
    for _,row in ipairs({item('A','42','holds'),item('B','88','holds')}) do shelf.holds[row.key]=row end
    local p={shelf=shelf,downloads={},cover_dir='/fixture/covers',ui={},calls={},messages={}}
    function p:reloadShelf() self.reads=(self.reads or 0)+1 end
    function p:message(text) self.messages[#self.messages+1]=text end
    function p:showItem(item,options) self.calls[#self.calls+1]={action='info',item=item,options=options} end
    function p:openLoan(item,open) self.calls[#self.calls+1]={action='open',item=item,open=open} end
    function p:syncNow(automatic,done) self.calls[#self.calls+1]={action='sync',automatic=automatic};self.sync_done=done end
    local host={SOURCE_API=1,TOKENS_API=1,changed=0,registered=0}
    function host:registerSource(id,spec) self.id=id;self.spec=spec;self.registered=self.registered+1;return true end
    function host:registerTokens(id,defs) self.tokens=defs;return true end
    function host:sourceChanged(id) eq(id,'kolibby');self.changed=self.changed+1 end
    p.ui.bookshelf=host
    local files={};local shown
    local options={exists=function(path) return files[path]==true end,
        manager={show=function(_,dialog) shown=dialog end,close=function() shown=nil end},
        dialog={new=function(_,value) return value end},menu={new=function(_,value) return value end}}
    local h=Bridge.new(p,options)
    return {p=p,host=host,h=h,files=files,dialog=function() return shown end}
end
local function with_fixture(fn)
    local f=fixture();local ok,err=pcall(fn,f);f.h:close();assert(ok,err)
end
local function row(records,key)
    for _,value in ipairs(records) do if value.kolibby_key==key then return value end end
    error('Missing fixture record '..key)
end
test('Bookshelf absence or an old interface leaves KOLibby independent',function()
    with_fixture(function(f)
        f.p.ui.bookshelf=nil;eq(f.h:register(),false)
        f.p.ui.bookshelf={SOURCE_API=0,registerSource=function() error('must not register') end};eq(f.h:register(),false)
        f.p.ui.bookshelf={SOURCE_API=1,registerSource=function() return false,'unsupported' end};eq(f.h:register(),false)
    end)
end)
test('KOLibby registers a list source with the documented Bookshelf hooks',function()
    with_fixture(function(f)
        assert(f.h:register());eq(f.host.id,'kolibby');eq(f.host.spec.api,1);eq(f.host.spec.label(),'KOLibby')
        eq(f.host.spec.remote_prefix,'kolibby://');eq(type(f.host.spec.list),'function');eq(f.host.spec.fetch,nil)
        assert(f.host.spec.available());assert(f.host.spec.owns{filepath='kolibby://loans/test'})
        eq(f.host.spec.owns{filepath='/fixture/ordinary.epub'},false)
    end)
end)
test('Loans include undownloaded books and keep different cards distinct',function()
    with_fixture(function(f)
        assert(f.h:register());local records=f.host.spec.list{collection='loans'}
        eq(#records,3);assert(row(records,'A:42').filepath~=row(records,'B:42').filepath)
        local a=row(records,'A:42');eq(a.title,'Book 42');eq(a.author,'Author');eq(a.series_num,'2')
        eq(a.format,'EPUB');contains(a.description,'Harbor Library');eq(a.kolibby_download,'Not downloaded')
        local encoded=J.encode(records);eq(encoded:find('Bearer',1,true),nil);eq(encoded:find('cover_url',1,true),nil)
        eq(#f.p.calls,0)
    end)
end)
test('Single-card and merged-card selections filter both loans and holds',function()
    with_fixture(function(f)
        f.h:register();local spec=f.host.spec
        eq(#spec.list{collection='loans',card_id='A'},2);eq(#spec.list{collection='loans',card_id='B'},1)
        eq(#spec.list{collection='loans',card_id='oldA'},2)
        eq(#spec.list{collection='holds',card_id='B'},1)
        eq(#spec.list{collection='loans',card_id='removed'},0)
        eq(#spec.list{collection='loans',card_id={}},0);eq(#spec.list{collection='unknown'},0)
    end)
end)
test('Holds never resolve to an existing download of the same title',function()
    with_fixture(function(f)
        f.h:register();local loan=f.p.shelf.loans['A:42']
        f.p.downloads[loan.key]={key=loan.key,checkout_id=loan.checkout_id,path='/fixture/book.epub'};f.files['/fixture/book.epub']=true
        local hold=row(f.host.spec.list{collection='holds'},'A:42')
        contains(hold.filepath,'kolibby://holds/');eq(hold.status,'on_hold');eq(hold.kolibby_status,'Ready to borrow')
        assert(f.host.spec.open(hold,{}));eq(f.p.calls[1].action,'info');eq(f.p.calls[1].item.kind,'holds')
        assert(type(f.p.calls[1].options.borrowed)=='function')
    end)
end)
test('Existing EPUBs use local paths only when their checkout and file match',function()
    with_fixture(function(f)
        f.h:register();local loan=f.p.shelf.loans['A:42']
        f.p.downloads[loan.key]={key=loan.key,checkout_id='old-checkout',path='/fixture/book.epub'};f.files['/fixture/book.epub']=true
        contains(row(f.host.spec.list{},loan.key).filepath,'kolibby://')
        f.p.downloads[loan.key].checkout_id=loan.checkout_id
        local record=row(f.host.spec.list{},loan.key);eq(record.filepath,'/fixture/book.epub');eq(record.kolibby_download,'Downloaded')
        f.files['/fixture/book.epub']=nil;contains(row(f.host.spec.list{},loan.key).filepath,'kolibby://')
    end)
end)
test('Cached cover paths are handed to Bookshelf without fetching images',function()
    with_fixture(function(f)
        f.h:register();local records=f.host.spec.list{}
        eq(row(records,'A:42').cover_image_path,nil)
        local path='/fixture/covers/'..U.hash(f.p.shelf.loans['A:42'].cover_url)..'.img';f.files[path]=true
        eq(row(f.host.spec.list{},'A:42').cover_image_path,path);eq(#f.p.calls,0)
    end)
end)
test('A downloaded publisher synopsis is also shown in the Bookshelf record',function()
    with_fixture(function(f)
        f.h:register();local loan=f.p.shelf.loans['A:42']
        f.p.downloads[loan.key]={key=loan.key,checkout_id=loan.checkout_id,path='/fixture/book.epub',description='The publisher synopsis.'}
        eq(row(f.host.spec.list{},loan.key).description,'The publisher synopsis.')
        f.p.downloads[loan.key].checkout_id='old-checkout'
        assert(row(f.host.spec.list{},loan.key).description~='The publisher synopsis.')
        assert(row(f.host.spec.list{collection='holds'},loan.key).description~='The publisher synopsis.')
    end)
end)
test('Opening a downloaded EPUB preserves the Bookshelf opener callback',function()
    with_fixture(function(f)
        f.h:register();local loan=f.p.shelf.loans['A:42']
        f.p.downloads[loan.key]={key=loan.key,checkout_id=loan.checkout_id,path='/fixture/book.epub'};f.files['/fixture/book.epub']=true
        local open=function() end;assert(f.host.spec.open(row(f.host.spec.list{},loan.key),{open=open}))
        eq(f.p.calls[1].action,'open');eq(f.p.calls[1].item,loan);eq(f.p.calls[1].open,open)
    end)
end)
test('Remote book details retain native download and return-to-Bookshelf controls',function()
    with_fixture(function(f)
        f.h:register();local open=function() end
        assert(f.host.spec.open(row(f.host.spec.list{},'A:42'),{open=open}))
        local call=f.p.calls[1];eq(call.action,'info');eq(call.options.open,open);eq(type(call.options.back),'function')
        local count=f.host.changed;call.options.borrowed();assert(f.host.changed>count)
    end)
end)
test('Downloaded audiobooks use KOLibby rather than launching the EPUB reader',function()
    with_fixture(function(f)
        f.h:register();local loan=f.p.shelf.loans['A:77']
        f.p.downloads[loan.key]={key=loan.key,checkout_id=loan.checkout_id,kind='mp3',path='/fixture/book.mp3'};f.files['/fixture/book.mp3']=true
        local record=row(f.host.spec.list{},loan.key);eq(record.format,'MP3');contains(record.filepath,'kolibby://')
        assert(f.host.spec.open(record,{}));eq(f.p.calls[1].action,'open');eq(f.p.calls[1].item.media_type,'audiobook')
    end)
end)
test('A stale Bookshelf checkout cannot open or download a replacement checkout',function()
    with_fixture(function(f)
        f.h:register();local record=row(f.host.spec.list{},'A:42')
        f.p.shelf.loans['A:42'].checkout_id='replacement';assert(f.host.spec.open(record,{}))
        eq(#f.p.calls,0);contains(f.p.messages[1],'checkout changed')
    end)
end)
test('Returned loans and removed holds produce a message instead of opening stale records',function()
    with_fixture(function(f)
        f.h:register()
        for _,kind in ipairs({'loans','holds'}) do
            local record=row(f.host.spec.list{collection=kind},'A:42');f.p.shelf[kind]['A:42']=nil
            assert(f.host.spec.open(record,{}))
        end
        eq(#f.p.calls,0);eq(#f.p.messages,2);contains(f.p.messages[1],'no longer')
    end)
end)
test('Pull-to-refresh redraws after success or an unsuccessful sync',function()
    with_fixture(function(f)
        f.h:register();local done=0
        for _,error in ipairs({'success','cancelled','busy'}) do
            f.host.spec.refresh({},nil,function() done=done+1 end)
            eq(f.p.calls[#f.p.calls].action,'sync');eq(f.p.calls[#f.p.calls].automatic,false)
            f.p.sync_done(nil,error)
        end
        eq(done,3)
    end)
end)
test('The chip picker saves collection and a single selected card',function()
    with_fixture(function(f)
        f.h:register();local draft={source={kind='kolibby'}};local calls=0
        f.host.spec.pick(draft,function(ok) assert(ok~=false);calls=calls+1 end)
        eq(f.dialog().title,'KOLibby · Choose shelf');f.dialog().buttons[2][1].callback()
        contains(f.dialog().title,'Holds');f.dialog().item_table[3].callback()
        eq(draft.source.collection,'holds');eq(draft.source.card_id,'B');contains(draft.label,'Hill Library');eq(calls,1)
    end)
end)
test('All-card chips omit the card filter, and picker cancellation preserves the draft',function()
    with_fixture(function(f)
        f.h:register();local draft={source={kind='kolibby',collection='holds',card_id='B'},label='Personal shelf'}
        local before=J.encode(draft);local cancelled=0
        f.host.spec.pick(draft,function(ok) if ok==false then cancelled=cancelled+1 end end)
        f.dialog().buttons[3][1].callback();eq(J.encode(draft),before)
        f.host.spec.pick(draft,function(ok) if ok==false then cancelled=cancelled+1 end end)
        f.dialog().buttons[1][1].callback();local buttons=f.dialog().item_table
        buttons[#buttons].callback();eq(cancelled,2);eq(J.encode(draft),before)
        f.host.spec.pick(draft,function() end);f.dialog().buttons[1][1].callback();f.dialog().item_table[1].callback()
        eq(draft.source.collection,'loans');eq(draft.source.card_id,nil)
    end)
end)
test('The card picker uses a scrolling menu and closing it cancels the selection',function()
    with_fixture(function(f)
        for i=1,40 do local id='card-'..i;f.p.shelf.cards[id]={id=id,library='Sample Library '..i,name='Family'} end
        f.h:register();local draft={source={kind='kolibby'}};local result
        f.host.spec.pick(draft,function(ok) result=ok end)
        f.dialog().buttons[1][1].callback()
        eq(#f.dialog().item_table,45);eq(f.dialog().items_max_lines,3)
        f.dialog().close_callback();eq(result,false);eq(draft.source.collection,nil)
    end)
end)
test('Bookshelf copies may change records without modifying KOLibby shelf metadata',function()
    with_fixture(function(f)
        f.h:register();local record=row(f.host.spec.list{},'A:42');record.title='Changed by host'
        eq(f.p.shelf.loans['A:42'].title,'Book 42');eq(row(f.host.spec.list{},'A:42').title,'Book 42')
    end)
end)
test('Disconnecting hides the source and empties existing chips',function()
    with_fixture(function(f)
        f.h:register();assert(f.host.spec.available());f.p.shelf=Model.empty();f.h:changed()
        eq(f.host.spec.available(),false);eq(#f.host.spec.list{},0)
    end)
end)
test('Source callbacks survive reader closure by using a remaining live instance',function()
    with_fixture(function(f)
        f.h:register();local second=fixture()
        local ok,err=pcall(function()
            second.h:register();second.p.shelf.loans={}
            eq(#f.host.spec.list{},0)
            second.p.closed=true;second.h:close();eq(#f.host.spec.list{},3)
            f.p.closed=true;eq(f.host.spec.available(),false);eq(#f.host.spec.list{},0)
        end)
        second.h:close();assert(ok,err)
    end)
end)
test('Optional Bookshelf tokens show KOLibby status without affecting ordinary books',function()
    with_fixture(function(f)
        f.h:register();local record=row(f.host.spec.list{},'A:42')
        eq(f.host.tokens.kolibby_status.expand(record),record.kolibby_status)
        contains(f.host.tokens.kolibby_library.expand(record),'Harbor Library')
        eq(f.host.tokens.kolibby_download.expand(record),'Not downloaded')
        eq(f.host.tokens.kolibby_status.expand({}),'')
    end)
end)
end
