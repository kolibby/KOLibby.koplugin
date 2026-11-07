-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local M={}
function M.matches(host,pattern)
    if type(host)~="string" or type(pattern)~="string" then return false end
    host=host:lower():gsub("%.$","");pattern=pattern:lower():gsub("%.$","")
    if host:find("[%z\1-\32]") or pattern:find("[%z\1-\32]") then return false end
    if not pattern:find("*",1,true) then return host==pattern end
    local suffix=pattern:match("^%*%.([^*]+)$")
    if not suffix or not suffix:find("%.") then return false end
    local first,rest=host:match("^([^.]+)%.(.+)$")
    return first~=nil and rest==suffix
end
function M.verify_name(certificate,host)
    local extensions=certificate:extensions()
    local san=type(extensions)=="table" and extensions['2.5.29.17']
    if type(san)=="table" then
        local dns=san.dNSName
        if type(dns)=="table" then
            for _,name in ipairs(dns) do if M.matches(host,name) then return true end end
        end
    end
    -- Modern service certificates require a matching DNS SAN. No CN fallback.
    return false
end
return M
