-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Queue native downloads, saving every completed checkout before advancing.
local Model=require('kolibby/model')
local U=require('kolibby/util')
local M={}
local function eligible(shelf,loan,now)
    local card=Model.card_for(shelf,loan.card_id)
    return loan.downloadable and loan.checkout_id and loan.expires and loan.expires>now and not loan.stale and
        card and not card.stale and not card.needs_verification and
        (loan.media_type=='ebook' or loan.media_type=='book' or loan.media_type=='audiobook')
end
local function saved(record,loan,exists)
    return Model.same_checkout(record,loan) and type(record.path)=='string' and exists(record.path)
end
function M.plan(shelf,downloads,opts)
    local result={queue={},already_downloaded=0,unavailable=0}
    local now=opts.now or os.time()
    for _,loan in ipairs(Model.list(shelf,'loans',opts.card_id)) do
        if saved(downloads[loan.key],loan,opts.exists) then result.already_downloaded=result.already_downloaded+1
        elseif eligible(shelf,loan,now) then result.queue[#result.queue+1]=loan
        else result.unavailable=result.unavailable+1 end
    end
    return result
end
function M.run(client,shelf,downloads,opts)
    local exists=opts.exists or function(path)
        local Store=require('kolibby/store')
        return Store.exists(path) and (Store.size(path) or 0)>0
    end
    local plan=M.plan(shelf,downloads,{card_id=opts.card_id,exists=exists,now=opts.now})
    local result={downloaded=0,already_downloaded=plan.already_downloaded,unavailable=plan.unavailable,failures={}}
    local download=opts.download or function(c,loan,card,options)
        return require(loan.media_type=='audiobook' and 'kolibby/audiobook' or 'kolibby/download').run(c,loan,card,options)
    end
    local function progress(value,loan,index)
        if not opts.progress then return end
        local p=U.copy(value)
        p.batch=true;p.batch_index=index;p.batch_total=#plan.queue
        p.batch_downloaded=result.downloaded
        if loan then p.item={key=loan.key,title=loan.title,author=loan.author,media_type=loan.media_type,cover_url=loan.cover_url} end
        opts.progress(p)
    end
    for i,loan in ipairs(plan.queue) do
        -- Recheck time/file state immediately before starting each queued loan.
        if saved(downloads[loan.key],loan,exists) then result.already_downloaded=result.already_downloaded+1
        elseif not eligible(shelf,loan,opts.now or os.time()) then result.unavailable=result.unavailable+1
        else
            progress({stage='authorizing',kind=loan.media_type=='audiobook' and 'mp3' or 'epub'},loan,i)
            local options={directory=opts.directory,cache_dir=opts.cache_dir,cover_dir=opts.cover_dir,
                progress=function(value) progress(value,loan,i) end}
            local ok,record=pcall(function()
                local value=download(client,loan,Model.card_for(shelf,loan.card_id),options)
                assert(Model.same_checkout(value,loan) and type(value.path)=='string' and exists(value.path),'The download did not produce a completed file')
                return value
            end)
            if ok then
                local work=record.work;record.work=nil
                downloads[loan.key]=record
                -- Persistence errors stop the queue. Never advance with only an
                -- in-memory completion record that cancellation could discard.
                opts.persist(downloads)
                result.downloaded=result.downloaded+1
                if work then
                    if opts.cleanup then opts.cleanup(work)
                    else require('kolibby/store').remove_tree(work) end
                end
            else
                result.failures[#result.failures+1]={key=loan.key,title=loan.title,message=U.error_message(record)}
            end
        end
    end
    progress({stage='batch_complete'},nil,#plan.queue)
    return result
end
function M.summary(result)
    local lines={result.downloaded==0 and #result.failures==0 and 'No downloads needed.' or 'Download all finished.',
        'Downloaded: '..result.downloaded,'Already downloaded: '..result.already_downloaded}
    if result.unavailable>0 then lines[#lines+1]='Unsupported or unavailable: '..result.unavailable end
    if #result.failures>0 then
        lines[#lines+1]='Failed: '..#result.failures
        for i=1,math.min(3,#result.failures) do
            local f=result.failures[i];lines[#lines+1]='\n'..f.title..'\n'..f.message
        end
        lines[#lines+1]='\nRun Download all again to retry unfinished loans.'
    end
    return table.concat(lines,'\n')
end
return M
