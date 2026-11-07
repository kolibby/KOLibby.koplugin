-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local M={}
-- The generic writer adds an mtime extra field, forbidden on EPUB's mimetype entry.
-- Use its archive handle for this one entry and leave all timestamps unset.
function M.add_mimetype(writer)
    local ffi=require("ffi")
    require("ffi/libarchive_h")
    local archive=ffi.loadlib("archive","13")
    local entry=ffi.gc(archive.archive_entry_new(),archive.archive_entry_free)
    local content="application/epub+zip"
    archive.archive_entry_set_pathname(entry,"mimetype")
    archive.archive_entry_set_filetype(entry,archive.AE_IFREG)
    archive.archive_entry_set_perm(entry,420)
    archive.archive_entry_set_size(entry,#content)
    if archive.archive_write_header(writer.archive,entry)~=archive.ARCHIVE_OK or
        archive.archive_write_data(writer.archive,content,#content)~=#content then
        error("Could not create the EPUB mimetype entry",0)
    end
end
function M.close(writer)
    if not writer.archive then return false end
    local ffi=require("ffi")
    local archive=ffi.loadlib("archive","13")
    local status=archive.archive_write_close(writer.archive)
    writer.archive=nil;writer.archive_read_disk=nil
    return status==archive.ARCHIVE_OK
end
return M
