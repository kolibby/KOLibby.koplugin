-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local ButtonDialog=require('ui/widget/buttondialog')
local Device=require('device')
local Font=require('ui/font')
local Progress=require('ui/widget/progresswidget')
local Text=require('ui/widget/textboxwidget')
local VGroup=require('ui/widget/verticalgroup')
local VSpan=require('ui/widget/verticalspan')
local UI=require('ui/uimanager')
local Book=require('kolibby/bookwidgets')
local Present=require('kolibby/presentation')
local Screen=Device.screen
local Center=require('ui/widget/container/centercontainer')
local Geom=require('ui/geometry')
local M={}
function M.new(item,cover_dir)
    local dialog
    local function cancel()
        if dialog.cancelled then return end
        dialog.cancelled=true
        if dialog.dismiss_callback then dialog.dismiss_callback() end
    end
    dialog=ButtonDialog:new{title=item.batch and 'Download all' or item.media_type=='audiobook' and 'Downloading MP3' or 'Downloading EPUB',use_info_style=false,dismissable=false,
        buttons={{{text=item.batch and 'Cancel all' or 'Cancel download',callback=cancel}}}}
    local width=dialog:getAddedWidgetAvailableWidth()
    local function line(size)
        return Text:new{text='',face=Font:getFace('cfont',size),width=width,height=Screen:scaleBySize(size*1.5)}
    end
    local stage,count=line(18),line(15)
    local header=Book.header(item,cover_dir,width)
    if item.batch then header=Center:new{dimen=Geom:new{w=width,h=Screen:scaleBySize(150)},header} end
    local queue=item.batch and line(16) or VSpan:new{width=0}
    local bar=Progress:new{width=width,height=Screen:scaleBySize(12),percentage=0}
    local group=VGroup:new{align='left',not_focusable=true,parent=dialog,
        queue,header,VSpan:new{width=Screen:scaleBySize(18)},
        stage,VSpan:new{width=Screen:scaleBySize(8)},bar,
        VSpan:new{width=Screen:scaleBySize(8)},count,
        VSpan:new{width=Screen:scaleBySize(10)},
    }
    dialog:addWidget(group)
    dialog.onClose=function() cancel();return true end
    dialog.key_events.Cancel={{Device.input.group.Back}}
    dialog.onCancel=function() cancel();return true end
    dialog.updateProgress=function(self,value)
        if item.batch then
            queue:setText(value.batch_total and value.batch_total>0 and string.format('Loan %d of %d · %d downloaded',value.batch_index,value.batch_total,value.batch_downloaded or 0) or 'Checking your loans…')
            if value.item and value.item.key~=self.current_key then
                header[1]:free();header[1]=Book.header(value.item,cover_dir,width);self.current_key=value.item.key
            end
        end
        local p=Present.progress(value)
        stage:setText(p.stage)
        bar:setPercentage(p.percentage)
        count:setText(p.count..(p.bytes and ' · '..p.bytes or '')..(value.stage=='downloading' and string.format(' · %d%%',math.floor(p.percentage*100)) or ''))
        UI:setDirty(self,'ui')
    end
    dialog:updateProgress({stage=item.batch and 'batch_preparing' or 'authorizing',kind=item.media_type=='audiobook' and 'mp3' or 'epub'})
    return dialog
end
return M
