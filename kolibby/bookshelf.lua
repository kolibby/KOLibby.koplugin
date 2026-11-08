-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Optional Bookshelf source. Rendering reads the saved shelf; network work stays
-- in KOLibby's existing workers and never runs from a Bookshelf list callback.
local Model=require('kolibby/model')
local Covers=require('kolibby/covers')
local Present=require('kolibby/presentation')
local U=require('kolibby/util')
local M={};M.__index=M
local handles={}
local prefix='kolibby://'
local function active()
    for i=#handles,1,-1 do
        local h=handles[i]
        if not h.closed and not h.plugin.closed then return h end
    end
end
local function collection(source)
    local kind=source and source.collection or 'loans'
    return (kind=='loans' or kind=='holds') and kind or nil
end
local function title(kind) return kind=='holds' and 'Holds' or 'Loans' end
function M.new(plugin,options)
    return setmetatable({plugin=plugin,options=options or {}},M)
end
function M:state()
    self.plugin:reloadShelf()
    return self.plugin.shelf,self.plugin.downloads
end
function M:exists(path)
    return type(path)=='string' and (self.options.exists or require('kolibby/store').exists)(path)
end
function M:records(source)
    local kind=collection(source);if not kind then return {} end
    local shelf,downloads=self:state()
    local card_id=source and source.card_id
    if card_id~=nil then
        if type(card_id)~='string' then return {} end
        local card=Model.card_for(shelf,card_id);if not card then return {} end
        card_id=card.id
    end
    local records={}
    for _,item in ipairs(Model.list(shelf,kind,card_id)) do
        local saved=downloads[item.key]
        local downloaded=kind=='loans' and Model.same_checkout(saved,item) and self:exists(saved.path)
        local summary=Present.summary(item,shelf,downloaded and saved or nil)
        local cover=Covers.path(item,self.plugin.cover_dir)
        local virtual=prefix..kind..'/'..U.urlencode(item.key)..'/'..U.urlencode(item.checkout_id or '')
        local description={summary.metadata,summary.library,summary.status}
        if summary.detail then description[#description+1]=summary.detail end
        local record={
            filepath=downloaded and saved.kind~='mp3' and saved.path or virtual,
            title=item.title,display_title=item.title,author=item.author,authors={item.author},
            series_name=item.series,series_num=item.series_order,
            cover_image_path=cover and self:exists(cover) and cover or nil,
            format=item.download_kind=='mp3' and 'MP3' or item.download_kind=='epub' and 'EPUB' or item.media_label,
            description=table.concat(description,'\n'),added_time=item.placed,
            status=kind=='holds' and 'on_hold' or 'unread',read_status=kind=='holds' and 'on_hold' or 'unread',
            kolibby_key=item.key,kolibby_collection=kind,kolibby_checkout=item.checkout_id,
            kolibby_status=summary.status,kolibby_library=summary.library,
            kolibby_download=downloaded and 'Downloaded' or kind=='loans' and 'Not downloaded' or '',
        }
        records[#records+1]=record
    end
    return records
end
function M:resolve(record)
    local kind=collection{collection=record.kolibby_collection}
    if not kind or type(record.kolibby_key)~='string' then return nil end
    local shelf=self:state()
    local item=shelf[kind] and shelf[kind][record.kolibby_key]
    if not item then
        self.plugin:message('This title is no longer on your Libby shelf. Refresh the Bookshelf chip.')
        self:changed();return nil
    end
    if kind=='loans' and item.checkout_id~=record.kolibby_checkout then
        self.plugin:message('This checkout changed. Refresh the Bookshelf chip and select the loan again.')
        self:changed();return nil
    end
    return item
end
function M:show(record,context,opening)
    local item=self:resolve(record);if not item then return true end
    local p=self.plugin
    local saved=p.downloads[item.key]
    local open=context and context.open
    if opening and item.kind=='loans' and Model.same_checkout(saved,item) and self:exists(saved.path) then
        p:openLoan(item,open)
    else
        p:showItem(item,{open=open,back=function() end,borrowed=function() self:changed() end})
    end
    return true
end
function M:choose(draft,done)
    local shelf=self:state()
    local manager=self.options.manager or require('ui/uimanager')
    local Dialog=self.options.dialog or require('ui/widget/buttondialog')
    local Menu=self.options.menu or require('ui/widget/menu')
    local screen
    local function close()
        local previous=screen;screen=nil
        if previous then manager:close(previous) end
    end
    local function show(label,buttons)
        close()
        screen=Dialog:new{title=label,buttons=buttons,dismissable=false};manager:show(screen)
    end
    local function cancel()
        close()
        done(false)
    end
    local choose_collection
    local function choose_card(kind)
        local function select_card(card)
            close()
            draft.source={kind='kolibby',collection=kind,card_id=card and card.id or nil}
            draft.label='KOLibby · '..title(kind)..(card and ' · '..card.library or '')
            done()
        end
        local rows={{text='All library cards',callback=function() select_card() end}}
        for _,card in ipairs(Model.list(shelf,'cards')) do
            local selected=card
            rows[#rows+1]={text=Model.card_label(shelf,card.id),callback=function() select_card(selected) end}
        end
        rows[#rows+1]={text='Back',callback=function() choose_collection() end}
        rows[#rows+1]={text='Cancel',callback=cancel}
        close()
        local menu
        menu=Menu:new{title=title(kind)..' · Choose library card',item_table=rows,items_max_lines=3,
            onMenuSelect=function(_,item) if item.callback then item.callback() end end,
            close_callback=function() if screen==menu then screen=nil;done(false) end end}
        screen=menu;manager:show(menu)
    end
    choose_collection=function()
        show('KOLibby · Choose shelf',{
            {{text='Loans',callback=function() choose_card('loans') end}},
            {{text='Holds',callback=function() choose_card('holds') end}},
            {{text='Cancel',callback=cancel}},
        })
    end
    choose_collection()
end
function M:changed()
    local h=active()
    local host=h and h.plugin.ui and h.plugin.ui.bookshelf or self.host
    if host and type(host.sourceChanged)=='function' then pcall(host.sourceChanged,host,'kolibby') end
end
function M:register()
    if self.closed or self.plugin.closed then return false end
    local host=self.plugin.ui and self.plugin.ui.bookshelf
    if not (host and type(host.registerSource)=='function' and type(host.SOURCE_API)=='number' and host.SOURCE_API>=1) then return false end
    local spec={api=1,label=function() return 'KOLibby' end,remote_prefix=prefix,
        available=function()
            local h=active();return h~=nil and next(h.plugin.shelf.cards or {})~=nil
        end,
        list=function(source) local h=active();return h and h:records(source) or {} end,
        pick=function(draft,done) local h=active();if h then h:choose(draft,done) else done(false) end end,
        open=function(record,ctx) local h=active();return h and h:show(record,ctx,true) or true end,
        info=function(record,ctx) local h=active();if h then h:show(record,ctx,false) end end,
        owns=function(book) return type(book.filepath)=='string' and book.filepath:sub(1,#prefix)==prefix end,
        refresh=function(_,_,done)
            local h=active()
            if not h then done();return end
            h.plugin:syncNow(false,function() h:changed();done() end)
        end,
        sort_default={{key='title',reverse=false}},
    }
    local ok,accepted=pcall(host.registerSource,host,'kolibby',spec)
    if not ok or not accepted then return false end
    self.host=host
    for i=#handles,1,-1 do if handles[i]==self then table.remove(handles,i) end end
    handles[#handles+1]=self
    if type(host.registerTokens)=='function' and type(host.TOKENS_API)=='number' and host.TOKENS_API>=1 then
        local defs={}
        for _,name in ipairs({'status','library','download'}) do
            local field='kolibby_'..name
            defs[field]={description='KOLibby '..name,category='Book',expand=function(book) return book and book[field] or '' end}
        end
        pcall(host.registerTokens,host,'kolibby',defs)
    end
    self:changed();return true
end
function M:close()
    self.closed=true
    for i=#handles,1,-1 do if handles[i]==self then table.remove(handles,i) end end
    self:changed()
end
return M
