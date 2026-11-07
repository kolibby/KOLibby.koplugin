-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
-- Shared across FileManager and Reader plugin instances in one KOReader process.
local M={owner=nil,pair_owner=nil,last_sync=0}
function M.acquire(owner)
    if M.owner then return false end
    M.owner=owner;return true
end
function M.release(owner)
    if M.owner==owner then M.owner=nil end
end
return M
