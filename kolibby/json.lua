-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local dkjson = require("dkjson")
local M = {null=dkjson.null}
function M.encode(value)
    return assert(dkjson.encode(value))
end
function M.decode(text)
    -- false keeps null array entries iterable and optional null fields falsy.
    local value, pos, err = dkjson.decode(text, 1, false)
    if err or not pos or text:sub(pos):match("%S") then
        error("Invalid JSON response or saved data", 0)
    end
    return value
end
return M
