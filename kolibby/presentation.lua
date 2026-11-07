-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local U=require('kolibby/util')
local Model=require('kolibby/model')
local M={}
function M.wait_label(days)
    if days<=0 then return 'Expected soon' end
    local n,unit
    if days<14 then n,unit=math.ceil(days),'day'
    elseif days<60 then n,unit=math.ceil(days/7),'week'
    elseif days<365 then n,unit=math.ceil(days/30),'month'
    else return 'Over a year to wait' end
    return string.format('About %d %s%s to wait',n,unit,n==1 and '' or 's')
end
function M.duration(value)
    if type(value)~='string' then return nil end
    local h,m=value:match('^(%d+):(%d%d):%d%d$')
    if not h then return nil end
    h,m=tonumber(h),tonumber(m)
    if m>=60 then return nil end
    return h>0 and string.format('%d hr %d min',h,m) or string.format('%d min',m)
end
function M.summary(item,shelf,download)
    local metadata={item.media_label}
    local duration=M.duration(item.duration)
    if duration then metadata[#metadata+1]=duration end
    if item.series then metadata[#metadata+1]=item.series..(item.series_order and ' #'..item.series_order or '') end
    local status,detail,highlight
    if item.kind=='loans' then
        status=U.due_label(item.expires)
        if Model.same_checkout(download,item) then detail='Downloaded' end
    elseif item.suspended then
        status='Suspended';detail=item.suspended_until and 'Until '..os.date('%b %d',item.suspended_until)
    elseif item.available then
        status=item.expires and item.expires<=os.time() and 'Offer expired' or 'Ready to borrow'
        highlight=Model.can_borrow(item)
        detail=item.expires and 'Borrow by '..os.date('%b %d, %H:%M',item.expires)
    else
        status=item.position and 'Position '..item.position or 'On hold'
        detail=item.wait_days and M.wait_label(item.wait_days) or nil
    end
    if item.stale then detail='Cached · refresh needed';highlight=false end
    local card=Model.card_for(shelf,item.card_id)
    local library=card and (card.library.." · "..Model.card_name(card)) or Model.card_label(shelf,item.card_id)
    return {metadata=table.concat(metadata,' · '),library=library,attribution=Model.card_attribution(shelf,item.card_id),
        status=status,detail=detail,highlight=highlight}
end
function M.progress(value)
    if value.stage=='batch_preparing' or value.stage=='batch_complete' then
        return {stage=value.stage=='batch_complete' and 'Downloads finished' or 'Checking your loans',
            percentage=value.stage=='batch_complete' and 1 or 0,count=value.stage=='batch_complete' and 'Updating your shelf…' or 'Synchronizing with your library…'}
    end
    local stages={authorizing='Preparing your book',downloading='Downloading files',packaging='Finishing EPUB',complete='Ready to read'}
    local audio=value.kind=='mp3'
    if audio then stages={authorizing='Preparing your audiobook',downloading='Downloading audio',checking='Checking audio',joining='Joining MP3',complete='Ready to listen'} end
    local total=tonumber(value.total) or 0
    local done=math.max(0,math.min(tonumber(value.done) or 0,total))
    return {stage=stages[value.stage] or stages.authorizing,
        percentage=total>0 and done/total or 0,
        count=total>0 and (audio and ((value.detail and value.detail..' · ' or '')..M.bytes(done)..' of '..M.bytes(total)) or string.format('%d of %d files',done,total)) or 'Connecting to your library…',
        bytes=not audio and value.bytes and M.bytes(value.bytes) or nil}
end
function M.bytes(value)
    if value>=1024*1024 then return string.format('%.1f MB',value/(1024*1024)) end
    return string.format('%d KB',math.ceil(value/1024))
end
return M
