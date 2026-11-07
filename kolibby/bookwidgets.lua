-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local BB=require('ffi/blitbuffer')
local Center=require('ui/widget/container/centercontainer')
local Frame=require('ui/widget/container/framecontainer')
local Font=require('ui/font')
local Geom=require('ui/geometry')
local HGroup=require('ui/widget/horizontalgroup')
local HSpan=require('ui/widget/horizontalspan')
local Image=require('ui/widget/imagewidget')
local RenderImage=require('ui/renderimage')
local Text=require('ui/widget/textwidget')
local TextBox=require('ui/widget/textboxwidget')
local VGroup=require('ui/widget/verticalgroup')
local VSpan=require('ui/widget/verticalspan')
local Screen=require('device').screen
local Covers=require('kolibby/covers')
local M={}
function M.text(text,size,width,lines,bold,color)
    return TextBox:new{text=text or '',face=Font:getFace('cfont',size),width=width,
        height=Screen:scaleBySize(size*1.25*(lines or 1)),line_height=0.15,
        height_overflow_show_ellipsis=true,bold=bold,fgcolor=color or BB.COLOR_BLACK}
end
function M.adaptive_text(text,size,width,lines,bold,color)
    local widget=TextBox:new{text=text or '',face=Font:getFace('cfont',size),width=width,
        line_height=0.15,bold=bold,fgcolor=color or BB.COLOR_BLACK}
    if widget:getSize().h<=Screen:scaleBySize(size*1.25*lines) then return widget end
    widget:free()
    return M.text(text,size,width,lines,bold,color)
end
function M.cover(item,directory,width,height)
    local path=Covers.cached(item,directory)
    local content
    if path then
        local ok,buffer=pcall(RenderImage.renderImageFile,RenderImage,path,false,width,height)
        if ok and buffer then content=Image:new{image=buffer,width=width,height=height,scale_factor=0}
        else os.remove(path) end
    end
    if not content then
        local label=item.media_type=='audiobook' and 'AUDIO' or 'BOOK'
        content=VGroup:new{align='center',
            Text:new{text='LIBBY',face=Font:getFace('cfont',11),bold=true,fgcolor=BB.COLOR_DARK_GRAY},
            VSpan:new{width=Screen:scaleBySize(12)},
            Text:new{text=label,face=Font:getFace('cfont',12),bold=true},
        }
    end
    return Frame:new{bordersize=Screen:scaleBySize(1),padding=0,margin=0,color=BB.COLOR_LIGHT_GRAY,
        background=BB.COLOR_WHITE,Center:new{dimen=Geom:new{w=width,h=height},content}}
end
function M.header(item,directory,width)
    local cover_w=Screen:scaleBySize(66)
    local details=VGroup:new{align='left',
        M.adaptive_text(item.title,21,width-cover_w-Screen:scaleBySize(16),3,true),
        VSpan:new{width=Screen:scaleBySize(6)},
        M.adaptive_text(item.author,16,width-cover_w-Screen:scaleBySize(16),2,false,BB.COLOR_DARK_GRAY),
    }
    return HGroup:new{align='center',M.cover(item,directory,cover_w,Screen:scaleBySize(99)),
        HSpan:new{width=Screen:scaleBySize(14)},details}
end
return M
