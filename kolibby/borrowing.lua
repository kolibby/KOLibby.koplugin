-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Circulation is never retried after an ambiguous POST failure. Reconcile first.
local Model=require('kolibby/model')
local U=require('kolibby/util')
local M={}
local function period_key(p)
    if type(p)~='table' or type(p[1])~='number' or p[1]<=0 or p[1]~=math.floor(p[1]) or
        (p[2]~='days' and p[2]~='hours' and p[2]~='minutes') then return nil end
    return tostring(p[1])..':'..p[2]
end
function M.periods(raw)
    if type(raw)~='table' or type(raw.options)~='table' then return nil end
    local options,seen={},{}
    for _,p in ipairs(raw.options) do
        local key=period_key(p)
        if key and not seen[key] then seen[key]=true;options[#options+1]={p[1],p[2]} end
    end
    if #options==0 then return nil end
    local preferred=period_key(raw.preference)
    for i,p in ipairs(options) do
        if period_key(p)==preferred then table.remove(options,i);table.insert(options,1,p);break end
    end
    return options,preferred and seen[preferred] and preferred or nil
end
function M.period_label(period) return tostring(period[1])..' '..(period[1]==1 and period[2]:gsub('s$','') or period[2]) end
function M.find_loan(shelf,hold)
    local card=Model.card_for(shelf,hold.card_id)
    for _,loan in pairs(shelf.loans) do
        local other=Model.card_for(shelf,loan.card_id)
        if loan.id==hold.id and card and other and card.id==other.id then return loan end
    end
end
local function ready(shelf,original)
    local hold=shelf.holds[original.key]
    local card=hold and Model.card_for(shelf,hold.card_id)
    if not hold or not Model.can_borrow(hold) or not card or card.needs_verification or card.stale then
        error('This hold is not ready to borrow on this card. Synchronize and check its status.',0)
    end
    if original.reserve_id and hold.reserve_id~=original.reserve_id then error('This hold changed. Select it again from Holds.',0) end
    return hold,card
end
function M.prepare(client,previous,original,persist)
    local shelf=Model.merge(previous,client:sync(),os.time())
    persist(shelf)
    local existing=M.find_loan(shelf,original)
    if existing then return {shelf=shelf,existing=existing.key} end
    local hold,card=ready(shelf,original)
    local ok,raw=pcall(client.loan_periods,client,hold)
    local options,preferred
    if ok then options,preferred=M.periods(raw) end
    if not options then
        local media=hold.media_type=='ebook' and 'book' or hold.media_type
        options,preferred=M.periods((card.lending_periods or {})[media])
    end
    if not options then error('Loan periods could not be loaded. Synchronize and try again.',0) end
    return {shelf=shelf,hold=hold,options=options,preferred=preferred}
end
function M.commit(client,previous,original,period,callbacks)
    assert(period_key(period),'Invalid lending period')
    local shelf=Model.merge(previous,client:sync(),os.time())
    callbacks.persist(shelf)
    local existing=M.find_loan(shelf,original)
    if existing then return {shelf=shelf,loan_key=existing.key,message='This title is already on your loans.'} end
    local hold=ready(shelf,original)
    callbacks.pending({key=hold.key,started=os.time()})
    local posted,response=pcall(client.borrow,client,hold,period)
    local confirmed,loan
    if posted then
        local ok,result,value=pcall(Model.import_borrowed,shelf,response,hold,os.time())
        if ok then shelf=result;loan=value;confirmed=true;callbacks.persist(shelf) end
    end
    local synced,latest=pcall(function() return Model.merge(shelf,client:sync(),os.time()) end)
    if synced then
        local found=M.find_loan(latest,hold)
        if found then
            callbacks.persist(latest);callbacks.pending({})
            return {shelf=latest,loan_key=found.key,message='Borrowed successfully.'}
        elseif confirmed then
            latest,loan=Model.import_borrowed(latest,response,hold,os.time())
            callbacks.persist(latest);callbacks.pending({})
            return {shelf=latest,loan_key=loan.key,message='Borrowed. The library shelf is still updating.'}
        end
        shelf=latest;callbacks.persist(shelf)
    end
    if confirmed then
        callbacks.pending({})
        return {shelf=shelf,loan_key=loan.key,message='Borrowed. Shelf synchronization failed; synchronize again when connected.'}
    end
    local message=not posted and U.error_message(response) or 'Libby did not confirm the new loan.'
    return {shelf=shelf,uncertain=true,message=message..'\n\nCheck Loans and synchronize before trying Borrow again.'}
end
return M
