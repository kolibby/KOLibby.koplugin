-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local J=require("kolibby/json")
local U=require("kolibby/util")
local Profile=require("kolibby/profile")
local Client={};Client.__index=Client
Client.BASE="https://sentry.libbyapp.com/"
Client.PROFILE=Profile
function Client.new(opts)
    return setmetatable({transport=assert(opts.transport),auth=U.copy(opts.auth or {}),save_auth=opts.save_auth or function() end},Client)
end
function Client:save() self.save_auth(self.auth) end
function Client:acquire()
    local source=self.auth.identity or (self.auth.chip and "xxxxxx"..self.auth.chip) or "cudlkahllcnsjxhbmddl"
    local letters=source:gsub("[^a-z]",""):reverse()
    local q={c=self.PROFILE.client,s=self.PROFILE.shell,v=self.auth.chip and self.auth.chip:match("^[^-]+")}
    local resp=self.transport{url=self.BASE.."chip?"..U.query(q),method="POST",profile="api",headers={
        Accept="application/json",["Accept-Language"]=letters:sub(5,6),
        Authorization=self.auth.identity and "Bearer "..self.auth.identity or nil}}
    if resp.status~=200 then self:failure(resp) end
    local data=J.decode(resp.body)
    if type(data)~="table" or type(data.identity)~="string" or type(data.chip)~="string" then error("Libby did not issue a device identity",0) end
    self.auth.identity=data.identity;self.auth.chip=data.chip;self:save()
end
function Client:failure(resp,data)
    if not data then local ok,v=pcall(J.decode,resp.body or "");if ok then data=v end end
    local result=type(data)=="table" and data.result or nil
    local messages={card_suspended="This library card needs verification in Libby. Verify it on your other device, then synchronize again.",
        missing_chip="Libby did not accept this device identity. Try synchronizing again or reconnect the device.",
        invalid_code="The setup code expired or was not accepted. Request a new code.",
        invalid_blessing="The device link expired. Request a new setup code."}
    local message=messages[result]
    local upstream=type(data)=="table" and type(data.upstream)=="table" and data.upstream.errorCode
    local circulation={
        PatronExceededCheckoutLimit="This library card has reached its loan limit. Return a loan in Libby, then try again.",
        PatronExceededChurningLimit="This card has reached its borrowing frequency limit. Try again later.",
        PatronExceededCostPerCircCheckoutLimit="This card has reached its borrowing limit for this collection.",
        CostPerCircNoBudget="The library's budget for this collection is currently unavailable.",
        PatronTypeRestrictedFromTitle="This library card cannot borrow this title.",
        TitleNoLongerAvailable="This hold is no longer available to borrow. Synchronize to update its status.",
        CheckoutNotAllowedForVisitor="This title cannot be borrowed with this partner-library card.",
        PatronCardFailedAuthentication="Verify this library card in Libby, then synchronize here.",
    }
    message=circulation[upstream] or message
    if not message then
        if resp.status==429 then message="Libby is limiting requests. Wait a few minutes before trying again."
        elseif resp.status==401 or resp.status==403 then message="Libby did not authorize this operation. Synchronize, and verify the card in Libby if needed."
        else message="Libby request failed (HTTP "..tostring(resp.status).."). Try again when connected." end
    end
    error({message=message,status=resp.status,kind=result or "http"},0)
end
function Client:api(path,method,data,query,retried)
    if not self.auth.identity then self:acquire() end
    local body=data and J.encode(data) or nil
    local url=self.BASE..path;local q=U.query(query);if q~="" then url=url.."?"..q end
    local response=self.transport{url=url,method=method or "GET",body=body,profile="api",headers={
        Accept="application/json",["Accept-Language"]="en-US",Authorization="Bearer "..self.auth.identity,
        ["Content-Type"]=body and "application/json" or nil}}
    local ok,value=pcall(J.decode,response.body or "")
    if response.status==403 and ok and type(value)=="table" and value.result=="missing_chip" and not retried then
        self:acquire();return self:api(path,method,data,query,true)
    end
    if response.status<200 or response.status>=300 then self:failure(response,ok and value) end
    if response.status==204 and response.body=="" then return {} end
    if not ok or type(value)~="table" then error("Libby returned an unexpected response",0) end
    return value
end
function Client:code(previous)
    return self:api("chip/clone/code","GET",nil,{role="pointer",code=previous})
end
function Client:finish_pairing(blessing)
    if type(blessing)~="string" or blessing=="" then error("Libby did not approve this device",0) end
    self:api("chip/clone","POST",{blessing=blessing})
    self:acquire();self.auth.paired=true;self:save();return self:sync()
end
function Client:sync() return self:api("chip/sync") end
function Client:loan_periods(hold)
    return self:api("card/"..U.urlencode(hold.card_id).."/loan/"..U.urlencode(hold.id).."/periods")
end
function Client:borrow(hold,period)
    local media=hold.media_type=="book" and "ebook" or hold.media_type
    return self:api("card/"..U.urlencode(hold.card_id).."/loan/"..U.urlencode(hold.id),"POST",
        {period=period[1],units=period[2],lucky_day=J.null,title_format=media})
end
function Client:json_resource(url,profile)
    local response=self.transport{url=url,method="GET",profile=profile or "resource",max_bytes=12*1024*1024}
    if response.status<200 or response.status>=300 then self:failure(response) end
    return J.decode(response.body)
end
function Client:publication(loan,card)
    if not card or not card.website_id then error("Library information is missing. Synchronize first.",0) end
    local t=Profile.context(loan,card)
    local format=loan.media_type=="audiobook" and "audiobook" or "book"
    local passport=self:api("open/"..format.."/card/"..U.urlencode(loan.card_id).."/title/"..U.urlencode(loan.id),"GET",nil,
        {t=U.base64_encode(J.encode(t)),website_id=card.website_id})
    if type(passport.urls)~="table" or type(passport.urls.rosters)~="string" or type(passport.urls.openbook)~="string" then
        error("This loan does not provide a native download",0)
    end
    if type(passport.message)~="string" or passport.message=="" then error("Libby did not issue a publication grant",0) end
    local join=passport.urls.rosters:find("?",1,true) and "&" or "?"
    local rosters=self:json_resource(passport.urls.rosters..join..passport.message,"roster")
    local book=self:json_resource(passport.urls.openbook)
    if type(book)~="table" or type(book.spine)~="table" or #book.spine==0 then error("Libby returned an incomplete publication manifest",0) end
    return passport,rosters,book
end
return Client
