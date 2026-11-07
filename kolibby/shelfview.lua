-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- A local Menu subclass: KOReader's menus and CoverBrowser remain untouched.
local BB=require('ffi/blitbuffer')
local Buttons=require('ui/widget/buttontable')
local TitleBar=require('ui/widget/titlebar')
local Center=require('ui/widget/container/centercontainer')
local Device=require('device')
local Frame=require('ui/widget/container/framecontainer')
local Geom=require('ui/geometry')
local Gesture=require('ui/gesturerange')
local HGroup=require('ui/widget/horizontalgroup')
local HSpan=require('ui/widget/horizontalspan')
local Input=require('ui/widget/container/inputcontainer')
local Menu=require('ui/widget/menu')
local Underline=require('ui/widget/container/underlinecontainer')
local VGroup=require('ui/widget/verticalgroup')
local VSpan=require('ui/widget/verticalspan')
local UI=require('ui/uimanager')
local Book=require('kolibby/bookwidgets')
local Present=require('kolibby/presentation')
local Screen=Device.screen
-- A title and a visible shelf action share the header's measured height and
-- keyboard focus layout; the action never becomes a fake book/list row.
local Header=Input:extend{}
function Header:init()
    local action_height=self.actions:getSize().h
    self[1]=VGroup:new{align='left',self.bar,
        Center:new{dimen=Geom:new{w=self.width,h=action_height},self.actions},
        VSpan:new{width=Screen:scaleBySize(8)}}
    self.dimen=Geom:new{w=self.width,h=self[1]:getSize().h}
end
function Header:getHeight() return self[1]:getSize().h end
function Header:setTitle(...) self.bar:setTitle(...) end
function Header:setSubTitle(...) self.bar:setSubTitle(...) end
function Header:setLeftIcon(...) self.bar:setLeftIcon(...) end
function Header:generateVerticalLayout()
    local layout=self.bar:generateVerticalLayout()
    for _,row in ipairs(self.actions.buttons_layout or {}) do layout[#layout+1]=row end
    return layout
end
local Row=Input:extend{}
function Row:init()
    local pad=Screen:scaleBySize(16)
    local height=self.dimen.h-Screen:scaleBySize(12)
    local cover_h=math.min(height-Screen:scaleBySize(10),Screen:scaleBySize(114))
    local cover_w=math.floor(cover_h*2/3)
    local width=self.dimen.w-2*pad-cover_w-Screen:scaleBySize(18)
    local summary=Present.summary(self.entry.item,self.menu.shelf,self.entry.download)
    local texts=VGroup:new{align='left',
        Book.adaptive_text(self.entry.item.title,20,width,2,true),
        VSpan:new{width=Screen:scaleBySize(4)},
        Book.text(self.entry.item.author,16,width,1),
        Book.text(summary.metadata,14,width,1,false,BB.COLOR_DARK_GRAY),
        Book.text(summary.library,13,width,1,false,BB.COLOR_DARK_GRAY),
    }
    if summary.attribution then texts[#texts+1]=Book.text(summary.attribution,13,width,1,false,BB.COLOR_DARK_GRAY) end
    texts[#texts+1]=VSpan:new{width=Screen:scaleBySize(3)}
    texts[#texts+1]=Book.text(summary.status..(summary.detail and ' · '..summary.detail or ''),14,width,1,true)
    local body=HGroup:new{align='center',
        Book.cover(self.entry.item,self.menu.cover_dir,cover_w,cover_h),
        HSpan:new{width=Screen:scaleBySize(18)},texts}
    self.line=Underline:new{linesize=Screen:scaleBySize(1),padding=0,color=BB.COLOR_LIGHT_GRAY,
        Center:new{dimen=Geom:new{w=self.dimen.w,h=self.dimen.h-Screen:scaleBySize(1)},
            Frame:new{bordersize=0,padding=0,padding_left=pad,padding_right=pad,body}}}
    self[1]=self.line
    self.ges_events={TapSelect={Gesture:new{ges='tap',range=self.dimen}},HoldSelect={Gesture:new{ges='hold',range=self.dimen}}}
end
function Row:onTapSelect() self.menu:onMenuSelect(self.entry);return true end
function Row:onHoldSelect() return self:onTapSelect() end
function Row:onFocus() self.line.color=BB.COLOR_BLACK;return true end
function Row:onUnfocus() self.line.color=BB.COLOR_LIGHT_GRAY;return true end
local Shelf=Menu:extend{covers_fullscreen=true,is_borderless=true,is_popout=false,title_bar_fm_style=true,with_bottom_line=true}
function Shelf:init()
    local reserved=Screen:scaleBySize(120)
    if self.download_all_callback then
        local width=self.width or Screen:getWidth()
        local actions=Buttons:new{width=width-Screen:scaleBySize(32),show_parent=self,
            buttons={{{text=self.download_all_label or "Download all",callback=self.download_all_callback}}}}
        if actions.layout then actions:disableFocusManagement(self) end
        actions.key_events={} -- The parent Menu owns keyboard focus.
        local bar=TitleBar:new{width=width,fullscreen=true,align='center',title=self.title,subtitle=self.subtitle,
            with_bottom_line=true,title_top_padding=Screen:scaleBySize(6),button_padding=Screen:scaleBySize(5),
            left_icon=self.title_bar_left_icon,left_icon_size_ratio=1,right_icon_size_ratio=1,
            left_icon_tap_callback=function() self:onLeftButtonTap() end,
            left_icon_hold_callback=function() self:onLeftButtonHold() end,
            close_callback=function() self:onClose() end,show_parent=self}
        self.custom_title_bar=Header:new{width=width,bar=bar,actions=actions}
        reserved=reserved+actions:getSize().h+Screen:scaleBySize(8)
    end
    local row_height=156
    for _,entry in ipairs(self.item_table or {}) do
        if Present.summary(entry.item,self.shelf,entry.download).attribution then row_height=172;break end
    end
    self.items_per_page=math.max(2,math.min(8,math.floor((Screen:getHeight()-reserved)/Screen:scaleBySize(row_height))))
    self.items_font_size=20
    Menu.init(self)
end
function Shelf:updateItems(select_number,no_recalculate)
    local old=self.dimen and self.dimen:copy()
    self.layout={};self.item_group:clear()
    self.page_info:resetLayout();self.return_button:resetLayout();self.content_group:resetLayout()
    self:_recalculateDimen(no_recalculate)
    for index=1,self.perpage do
        local n=(self.page-1)*self.perpage+index
        local entry=self.item_table[n];if not entry then break end
        entry.idx=n
        local row=Row:new{entry=entry,menu=self,dimen=self.item_dimen:copy()}
        self.item_group[#self.item_group+1]=row;self.layout[#self.layout+1]={row}
    end
    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()
    self.dithered=true
    UI:setDirty(self.show_parent,function() return 'ui',old and old:combine(self.dimen) or self.dimen,true end)
end
return Shelf
