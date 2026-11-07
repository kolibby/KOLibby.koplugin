-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local U=require("kolibby/util")
local M={}
local function table_or_empty(v) return type(v)=="table" and v or {} end
local function scalar(v,default) return type(v)=="string" and v or type(v)=="number" and tostring(v) or default end
local function text(v) return type(v)=="string" and v~="" and v or nil end
local function cover(raw)
    local covers=table_or_empty(raw.covers)
    for _,key in ipairs({'cover300Wide','cover150Wide','cover510Wide','cover300','cover150'}) do
        local c=table_or_empty(covers[key])
        if text(c.href) and not c.isPlaceholderImage then return c.href end
    end
    local keys={};for key in pairs(covers) do keys[#keys+1]=key end;table.sort(keys)
    for _,key in ipairs(keys) do
        local c=table_or_empty(covers[key])
        if text(c.href) and not c.isPlaceholderImage then return c.href end
    end
end
function M.empty() return {cards={},loans={},holds={},card_aliases={},last_sync=0} end
function M.mask_name(name,username)
    name=scalar(name,"Library card")
    if username and username~="" and name:find(tostring(username),1,true) or name:match("^[%a]*%d%d%d%d%d%d[%w]*$") then
        return #name>4 and "Card ••••"..name:sub(-4) or "Library card"
    end
    return name
end
function M.sanitize(shelf)
    local changed=false
    for _,c in pairs(shelf.cards or {}) do
        local name=M.mask_name(c.name)
        if c.is_partner and (name=="Library card" or U.trim(name)=="") then name="Partner card" end
        if name~=c.name then c.name=name;changed=true end
    end
    return changed
end
function M.card_for(shelf,id)
    return shelf.cards[id] or shelf.card_aliases and shelf.cards[shelf.card_aliases[id]]
end

-- Resolve only the server's explicit patron link. Keep patron/account IDs
-- transient; the reduced shelf stores a relationship between its own card IDs.
local function partner_homes(rows)
    local by_patron,homes={},{}
    for _,raw in ipairs(table_or_empty(rows)) do
        if type(raw)=='table' and raw.isVisitingCard~=true and U.id(raw.cardId) and U.id(raw.puid) then
            local key=U.id(raw.puid)
            if by_patron[key]==nil then by_patron[key]=raw else by_patron[key]=false end
        end
    end
    for _,raw in ipairs(table_or_empty(rows)) do
        if type(raw)=='table' and raw.isVisitingCard==true and U.id(raw.cardId) and U.id(raw.homeLibraryPUID) then
            local home=by_patron[U.id(raw.homeLibraryPUID)]
            if home and U.id(home.cardId)~=U.id(raw.cardId) then
                local website=U.id(table_or_empty(home.library).websiteId or home.websiteId)
                if not U.id(raw.homeLibraryWebsiteId) or website==U.id(raw.homeLibraryWebsiteId) then homes[U.id(raw.cardId)]=U.id(home.cardId) end
            end
        end
    end
    return homes
end
local function card(raw,homes)
    if type(raw)~="table" or not U.id(raw.cardId) then return nil end
    local lib=table_or_empty(raw.library)
    local aliases={}
    for _,id in ipairs(table_or_empty(raw.mergedCardIds)) do if U.id(id) then aliases[#aliases+1]=U.id(id) end end
    local partner=raw.isVisitingCard==true
    local name=M.mask_name(raw.cardName,scalar(raw.username))
    if partner and (name=='Library card' or U.trim(name)=='') then name='Partner card' end
    return {id=U.id(raw.cardId),name=name,is_partner=partner,home_card_id=partner and homes and homes[U.id(raw.cardId)] or nil,library=scalar(lib.name,"Library"),merged_ids=aliases,
        website_id=U.id(lib.websiteId or raw.websiteId),advantage_key=scalar(raw.advantageKey),
        lending_periods=U.copy(table_or_empty(raw.lendingPeriods)),needs_verification=false,stale=false}
end
local function item(raw,kind,now)
    if type(raw)~="table" or not U.id(raw.cardId) or not U.id(raw.id) then return nil end
    local types=table_or_empty(raw.type)
    local formats={}
    for _,f in ipairs(table_or_empty(raw.formats)) do if type(f)=="table" and U.id(f.id) then formats[#formats+1]=f.id end end
    local od=table_or_empty(raw.overDriveFormat)
    if od.id then formats[#formats+1]=od.id end
    local duration
    for _,f in ipairs(table_or_empty(raw.formats)) do if type(f)=="table" and text(f.duration) then duration=f.duration;break end end
    local series=table_or_empty(raw.detailedSeries)
    local suspended_until=U.timestamp(raw.suspensionEnd)
    local suspension_flag=raw.suspensionFlag and raw.suspensionFlag~=0 and raw.suspensionFlag~="0"
    local v={key=U.key(raw.cardId,raw.id),card_id=U.id(raw.cardId),id=U.id(raw.id),
        title=scalar(raw.title,"Untitled"),author=scalar(raw.firstCreatorName,""),media_type=scalar(types.id,"unknown"),
        subtitle=text(raw.subtitle),series=text(series.seriesName) or text(raw.series),series_order=scalar(series.readingOrder or series.rank),
        cover_url=cover(raw),duration=duration,publisher=text(raw.publisher),
        placed=U.timestamp(raw.placedDate),suspended_until=suspended_until,
        media_label=scalar(types.name,scalar(types.id,"Unknown format")),formats=formats,
        checkout_id=U.id(raw.checkoutId),reserve_id=U.id(raw.reserveId),
        expires=U.timestamp(raw.expireDate or raw.expires),expiry_text=scalar(raw.expireDate or raw.expires),
        available=raw.isAvailable==true,position=tonumber(raw.holdListPosition or raw.waitListPosition or raw.holdPosition),
        wait_days=tonumber(raw.estimatedWaitDays),suspended=raw.isSuspended==true or raw.isHoldSuspended==true or
            (suspension_flag and suspended_until~=nil and suspended_until>=now) or false,
        stale=false,kind=kind}
    v.downloadable=false
    if v.media_type=="ebook" or v.media_type=="book" then
        for _,f in ipairs(formats) do if f=="ebook-overdrive" then v.downloadable=true;v.download_kind='epub' end end
    elseif v.media_type=='audiobook' then
        for _,f in ipairs(formats) do
            if f=='audiobook-mp3' or f=='audiobook-overdrive' then v.downloadable=true;v.download_kind='mp3' end
        end
    end
    return v
end
local function status(response,id,collection)
    local summaries=table_or_empty(response.summary)
    local summary=table_or_empty(summaries[id] or summaries[tonumber(id)])
    return summary[collection] or "done"
end

function M.merge(previous,response,now)
    if type(response)~="table" or response.result~="synchronized" then error("Libby did not return a synchronized shelf",0) end
    local out=U.copy(previous or M.empty());out.cards=out.cards or {};out.loans=out.loans or {};out.holds=out.holds or {}
    local partial=false;local seen={};local homes=partner_homes(response.cards)
    for _,collection in ipairs({"cards","loans","holds"}) do
        local rows=response[collection]
        if type(rows)~="table" then partial=true
        else
            local incoming,valid={},true
            for _,raw in ipairs(rows) do
                local v=collection=="cards" and card(raw,homes) or item(raw,collection,now or os.time())
                if v then incoming[collection=="cards" and v.id or v.key]=v else valid=false;partial=true end
            end
            seen[collection]=incoming
            for key,old in pairs(out[collection]) do
                local id=collection=="cards" and old.id or old.card_id
                local s=status(response,id,collection)
                if not incoming[key] then
                    if s=="done" and valid then out[collection][key]=nil
                    else old.stale=true;partial=true end
                end
                if collection=="cards" and s=="auth" then old.needs_verification=true end
            end
            for key,v in pairs(incoming) do
                local s=status(response,collection=="cards" and v.id or v.card_id,collection)
                v.stale=s~="done";if v.stale then partial=true end
                if collection=="cards" then v.needs_verification=s=="auth" end
                out[collection][key]=v
            end
        end
    end
    out.card_aliases={}
    for id,c in pairs(out.cards) do
        for _,alias in ipairs(c.merged_ids or {}) do
            if not out.cards[alias] then out.card_aliases[alias]=id end
        end
    end
    -- A confirmed card removal also removes its stale shelf rows.
    for _,collection in ipairs({"loans","holds"}) do
        for key,v in pairs(out[collection]) do
            if not M.card_for(out,v.card_id) and not (seen[collection] and seen[collection][key]) and
                status(response,v.card_id,"cards")=="done" and type(response.cards)=="table" then
                out[collection][key]=nil
            end
        end
    end
    out.last_sync=now or os.time();out.partial=partial
    return out
end
function M.list(shelf,collection,card_id)
    local rows={}
    for _,v in pairs((shelf or M.empty())[collection] or {}) do
        if not card_id or v.card_id==card_id or shelf.card_aliases and shelf.card_aliases[v.card_id]==card_id or
            v.id==card_id and collection=="cards" then rows[#rows+1]=v end
    end
    table.sort(rows,function(a,b)
        local at=(a.title or a.library or a.name or ""):lower();local bt=(b.title or b.library or b.name or ""):lower()
        if at==bt then return tostring(a.key or a.id)<tostring(b.key or b.id) end
        return at<bt
    end)
    return rows
end
function M.card_name(card)
    local name=card.name or "Library card"
    return card.is_partner and name~="Partner card" and ("Partner card · "..name) or name
end
function M.card_attribution(shelf,id)
    local c=M.card_for(shelf,id)
    if not c or not c.is_partner or not c.home_card_id then return nil end
    local home=M.card_for(shelf,c.home_card_id)
    if not home or home.id==c.id or home.is_partner then return nil end
    local label="Partner via "..home.library
    if home.name and home.name~="Library card" and home.name~="" then label=label.." · "..home.name end
    return label
end
function M.card_label(shelf,id)
    local c=M.card_for(shelf,id)
    if not c then return "Library card" end
    local attribution=M.card_attribution(shelf,id)
    return c.library.." · "..M.card_name(c)..(attribution and " · "..attribution or "")
end
function M.hold_label(v)
    if v.suspended then return "Suspended" end
    if v.available then return "Ready to borrow" end
    if v.position then return "Position "..v.position end
    if v.wait_days then return "About "..v.wait_days.." days" end
    return "On hold"
end
function M.can_borrow(v,now)
    return v.kind=="holds" and v.available==true and not v.suspended and not v.stale and
        (not v.expires or v.expires>(now or os.time())) and
        (v.media_type=="ebook" or v.media_type=="book" or v.media_type=="audiobook" or v.media_type=="magazine")
end
function M.import_borrowed(shelf,raw,hold,now)
    local loan=item(raw,'loans',now or os.time())
    local expected=M.card_for(shelf,hold.card_id)
    local actual=loan and M.card_for(shelf,loan.card_id)
    if not loan or loan.id~=hold.id or not expected or not actual or expected.id~=actual.id or
        not loan.checkout_id or not loan.expires then error('Libby returned an unexpected loan. Synchronize to check the result.',0) end
    local result=U.copy(shelf)
    result.loans[loan.key]=loan;result.holds[hold.key]=nil
    result.partial=true -- A single confirmed loan is not a complete shelf refresh.
    return result,loan
end
function M.same_checkout(record,loan)
    return record and record.key==loan.key and record.checkout_id==loan.checkout_id
end
return M
