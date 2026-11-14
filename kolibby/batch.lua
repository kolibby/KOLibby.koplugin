-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Queue native downloads; only the coordinator persists shared completion state.
local Model=require('kolibby/model')
local U=require('kolibby/util')
local M={CONCURRENCY=3}
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
    local download=opts.download or function(c,loan,card,options)
        return require(loan.media_type=='audiobook' and 'kolibby/audiobook' or 'kolibby/download').run(c,loan,card,options)
    end
    local function valid(record,loan)
        assert(Model.same_checkout(record,loan) and type(record.path)=='string' and exists(record.path),'The download did not produce a completed file')
        return record
    end
    local function save(record,loan)
        local work=record.work;record.work=nil
        downloads[loan.key]=record
        -- One writer owns downloads.json and identity.json. A storage failure
        -- stops the entire pool; workers never race these shared atomic files.
        opts.persist(downloads)
        if work then
            if opts.cleanup then opts.cleanup(work)
            else require('kolibby/store').remove_tree(work) end
        end
    end
    local concurrency=math.max(1,math.min(M.CONCURRENCY,math.floor(opts.concurrency or 1)))
    local pool=concurrency>1 and (opts.pool or require('kolibby/parallel').new(opts.cache_dir..'/batch',{interval=opts.progress_interval})) or nil
    local function run()
        -- Cancel all can stop the coordinator after a worker publishes its file
        -- but before it is collected. Recover only complete, current checkouts.
        if pool and pool.recover then
            for _,outcome in ipairs(pool:recover()) do
                local record=outcome.ok and type(outcome.value)=='table' and outcome.value.record
                local loan=type(record)=='table' and shelf.loans[record.key]
                if loan and eligible(shelf,loan,opts.now or os.time()) and saved(record,loan,exists) and not saved(downloads[loan.key],loan,exists) then
                    save(record,loan)
                end
            end
            pool:reset()
        end
        local plan=M.plan(shelf,downloads,{card_id=opts.card_id,exists=exists,now=opts.now})
        local result={downloaded=0,already_downloaded=plan.already_downloaded,unavailable=plan.unavailable,failures={}}
        local active,finished={},0
        local function metadata(loan)
            return {key=loan.key,title=loan.title,author=loan.author,media_type=loan.media_type,cover_url=loan.cover_url}
        end
        local function initial(loan)
            return {stage='authorizing',kind=loan.media_type=='audiobook' and 'mp3' or 'epub'}
        end
        local function progress(value,loan,index)
            if not opts.progress then return end
            local p=U.copy(value)
            p.batch=true;p.batch_index=index;p.batch_total=#plan.queue
            p.batch_downloaded=result.downloaded;p.batch_completed=finished
            if loan then p.item=metadata(loan) end
            if pool then
                p.active={}
                for _,entry in ipairs(active) do
                    local current=U.copy(entry.progress);current.item=metadata(entry.loan);current.batch_index=entry.index
                    p.active[#p.active+1]=current
                end
                p.batch_running=#active
            end
            opts.progress(p)
        end
        local function options(loan,index,report)
            return {directory=opts.directory,cache_dir=opts.cache_dir,cover_dir=opts.cover_dir,
                progress=report or function(value) progress(value,loan,index) end}
        end
        local function complete(outcome,loan)
            local record=outcome.ok and type(outcome.value)=='table' and outcome.value.record
            local ok,value=pcall(valid,record,loan)
            if outcome.ok and ok then
                save(value,loan)
                result.downloaded=result.downloaded+1
                local v=outcome.value
                -- Do not overwrite a newer identity refreshed by a sibling.
                if v.auth and client.auth and client.auth.identity==v.base_identity and client.auth.chip==v.base_chip and
                    (v.auth.identity~=v.base_identity or v.auth.chip~=v.base_chip) then
                    client.auth=v.auth;client:save()
                end
            else
                result.failures[#result.failures+1]={key=loan.key,title=loan.title,message=outcome.ok and U.error_message(value) or outcome.message}
            end
            finished=finished+1
        end
        local next_index=1
        while next_index<=#plan.queue or #active>0 do
            while next_index<=#plan.queue and #active<concurrency do
                local index=next_index;local loan=plan.queue[index];next_index=next_index+1
                -- Recheck time/file state immediately before starting each loan.
                if saved(downloads[loan.key],loan,exists) then result.already_downloaded=result.already_downloaded+1;finished=finished+1
                elseif not eligible(shelf,loan,opts.now or os.time()) then result.unavailable=result.unavailable+1;finished=finished+1
                elseif pool then
                    local auth=U.copy(client.auth)
                    local handle=pool:start(index,function(report)
                        -- Construct the network session after fork. Inherited
                        -- keep-alive sockets and cookie jars must not be shared.
                        local worker=assert(opts.client_factory,'A parallel download needs a client factory')(auth)
                        local ok,record=pcall(download,worker,loan,Model.card_for(shelf,loan.card_id),options(loan,index,report))
                        if worker.close then worker:close() end
                        if not ok then error(record,0) end
                        local changed=worker.auth and (worker.auth.identity~=(auth and auth.identity) or worker.auth.chip~=(auth and auth.chip))
                        return {record=valid(record,loan),auth=changed and worker.auth or nil,
                            base_identity=changed and auth and auth.identity or nil,base_chip=changed and auth and auth.chip or nil}
                    end)
                    active[#active+1]={handle=handle,loan=loan,index=index,progress=initial(loan)}
                else
                    progress(initial(loan),loan,index)
                    local ok,record=pcall(download,client,loan,Model.card_for(shelf,loan.card_id),options(loan,index))
                    complete(ok and {ok=true,value={record=record}} or {ok=false,message=U.error_message(record)},loan)
                end
            end
            if pool and #active>0 then
                -- Collect every completion before replenishing any worker slot.
                for i=#active,1,-1 do
                    local entry=active[i];local outcome=pool:poll(entry.handle)
                    if outcome then complete(outcome,entry.loan);table.remove(active,i)
                    else
                        local p=pool:progress(entry.handle)
                        if p.stage then entry.progress=p end
                    end
                end
                local first=active[1]
                if first then progress(first.progress,first.loan,first.index) end
                if #active>=concurrency or next_index>#plan.queue then pool:wait() end
            end
        end
        progress({stage='batch_complete'},nil,#plan.queue)
        return result
    end
    local ok,result=pcall(run)
    if pool then pool:close(ok) end
    if not ok then error(result,0) end
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
