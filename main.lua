-- Copyright (C) 2026 KOLibby contributors
-- SPDX-License-Identifier: AGPL-3.0-only
local WidgetContainer=require("ui/widget/container/widgetcontainer")
local UIManager=require("ui/uimanager")
local Menu=require("ui/widget/menu")
local ButtonDialog=require("ui/widget/buttondialog")
local InfoMessage=require("ui/widget/infomessage")
local ConfirmBox=require("ui/widget/confirmbox")
local Trapper=require("ui/trapper")
local NetworkMgr=require("ui/network/manager")
local DataStorage=require("datastorage")
local Device=require("device")
local Store=require("kolibby/store")
local Model=require("kolibby/model")
local Client=require("kolibby/client")
local Http=require("kolibby/http")
local J=require("kolibby/json")
local U=require("kolibby/util")
local Coordinator=require("kolibby/coordinator")
local Covers=require("kolibby/covers")
local Present=require("kolibby/presentation")
local Borrowing=require("kolibby/borrowing")
local Batch=require("kolibby/batch")

local KOLibby=WidgetContainer:extend{is_doc_only=false}
function KOLibby:init()
    self.version=U.trim(Store.read_file(self.path..'/VERSION'))
    self.store=Store.new(DataStorage:getSettingsDir().."/kolibby")
    self.config=self.store:read("config.json",{interval_minutes=30,download_dir=DataStorage:getDataDir().."/KOLibby"})
    self.shelf=self.store:read("shelf.json",Model.empty())
    if Model.sanitize(self.shelf) then self.store:write("shelf.json",self.shelf) end
    Coordinator.last_sync=math.max(Coordinator.last_sync,self.shelf.last_sync or 0)
    self.downloads=self.store:read("downloads.json",{})
    self.status=self.store:read("status.json",{})
    self.cache_dir=DataStorage:getDataDir().."/cache/kolibby"
    self.cover_dir=self.cache_dir.."/covers"
    self.ui.menu:registerToMainMenu(self)
    self._tick=function() self:maybeSync();self:scheduleTick() end
    self._pair_poll=function() self:pollPairing() end
    UIManager:scheduleIn(4,self._tick)
end
function KOLibby:addToMainMenu(items)
    -- KOReader appends sorting_hint entries after the built-in tools. Its
    -- shared order tables provide explicit placement in both main menus.
    for _,context in ipairs({"filemanager","reader"}) do
        local tools=require("ui/elements/"..context.."_menu_order").tools
        for i=#tools,1,-1 do if tools[i]=="kolibby" then table.remove(tools,i) end end
        table.insert(tools,1,"kolibby")
    end
    items.kolibby={text="KOLibby",sorting_hint="tools",sub_item_table_func=function()
        self:reloadShelf();return self:rootItems()
    end}
end
function KOLibby:client()
    local http=Http.new()
    return Client.new{auth=self.store:auth(),save_auth=function(auth) self.store:save_auth(auth) end,
        transport=function(req) return http:request(req) end}
end
function KOLibby:message(text) UIManager:show(InfoMessage:new{text=text}) end
function KOLibby:closeWindow()
    if self.window then UIManager:close(self.window);self.window=nil end
end
function KOLibby:showMenu(title,rows,options)
    self:closeWindow()
    local menu=Menu:new{title=title,item_table=rows,items_max_lines=options and options.items_max_lines,covers_fullscreen=true,is_borderless=true,is_popout=false,
        title_bar_fm_style=true,onMenuSelect=function(menu_self,item)
            if item.callback then UIManager:close(menu_self);if self.window==menu_self then self.window=nil end;item.callback() end
        end}
    self.window=menu;UIManager:show(menu)
end
function KOLibby:syncLabel()
    if not self.shelf.last_sync or self.shelf.last_sync==0 then return "Not synchronized yet" end
    return "Last sync: "..os.date("%Y-%m-%d %H:%M",self.shelf.last_sync)..(self.shelf.partial and " · Some libraries need attention" or "")
end
function KOLibby:reloadShelf()
    self.shelf=self.store:read("shelf.json",Model.empty())
    self.downloads=self.store:read("downloads.json",{})
    if Model.sanitize(self.shelf) then self.store:write("shelf.json",self.shelf) end
end
function KOLibby:rootItems()
    if Coordinator.restart_required then return {{text="Restart KOReader to finish updating",callback=function() self:promptRestart() end}} end
    local auth=self.store:auth();local paired=auth.paired or U.count(self.shelf.cards)>0
    local rows={}
    if paired then
        rows={
            {text_func=function() return "Loans ("..U.count(self.shelf.loans)..")" end,callback=function() self:showShelf("loans") end},
            {text_func=function() return "Holds ("..U.count(self.shelf.holds)..")" end,callback=function() self:showShelf("holds") end},
            {text_func=function() return "Library cards ("..U.count(self.shelf.cards)..")" end,callback=function() self:showCards() end},
            {text="Sync now",keep_menu_open=true,callback=function(menu) self.main_menu=menu;self:syncNow(false) end},
            {text_func=function() return self:syncLabel() end,callback=function() self:message(self:syncLabel()..(self.status.error and "\n\n"..self.status.error or "")) end},
        }
    else rows[1]={text="Connect to Libby",callback=function() self:connectDevice() end} end
    rows[#rows+1]={text="Settings",callback=function() self:showSettings() end}
    return rows
end
function KOLibby:showRoot()
    self:closeWindow();self:reloadShelf();self.view=nil
    local controller=self.ui.menu
    controller:onShowMenu()
    local menu=controller.menu_container and controller.menu_container[1]
    if menu and menu.switchMenuTab then
        for index,tab in ipairs(menu.tab_item_table) do
            for _,entry in ipairs(tab) do
                if entry.text=="KOLibby" then
                    menu:switchMenuTab(index);menu.bar:switchToTab(index);menu:onMenuSelect(entry);return
                end
            end
        end
    elseif menu and menu.switchItemTable then
        menu:switchItemTable("KOLibby",self:rootItems())
    end
end
function KOLibby:showShelf(collection,card_id)
    self:reloadShelf()
    self.view=collection;self.card_filter=card_id
    local rows={}
    for _,item in ipairs(Model.list(self.shelf,collection,card_id)) do
        local saved=self.downloads[item.key]
        rows[#rows+1]={text=item.title,item=item,download=saved and Store.exists(saved.path) and saved or nil,
            callback=function() self:showItem(item) end}
    end
    if #rows==0 then
        local empty_rows={
            {text=collection=="loans" and "No loans yet" or "No holds yet",callback=function() self:message("This shelf is empty.\n\n"..self:syncLabel()) end},
            {text="Back to KOLibby",callback=function() self:showRoot() end},
        }
        if collection=="loans" then table.insert(empty_rows,1,{text=card_id and "Download all on this card" or "Download all",callback=function() self:downloadAll(card_id) end}) end
        self:showMenu(collection=="loans" and "Loans" or "Holds",empty_rows);return
    end
    self:closeWindow()
    local menu=require("kolibby/shelfview"):new{title=collection=="loans" and "Loans" or "Holds",
        subtitle=(card_id and Model.card_label(self.shelf,card_id) or "All library cards").." · "..self:syncLabel(),
        item_table=rows,shelf=self.shelf,cover_dir=self.cover_dir,title_bar_left_icon="chevron.left",
        download_all_callback=collection=="loans" and function() self:downloadAll(card_id) end or nil,
        download_all_label=card_id and "Download all on this card" or "Download all",
        onLeftButtonTap=function() self:showRoot() end,
        close_callback=function() self.window=nil;self.view=nil end,
        onMenuSelect=function(_,entry) if entry.callback then entry.callback() end end}
    self.window=menu;UIManager:show(menu)
end
function KOLibby:showCards()
    self.view="cards"
    local rows={}
    for _,card in ipairs(Model.list(self.shelf,"cards")) do
        local label=Model.card_label(self.shelf,card.id)
        rows[#rows+1]={text=label,mandatory=card.needs_verification and "Verify in Libby" or card.stale and "Refresh pending" or "",
            callback=function()
                self:showMenu(label,{
                    {text="Loans on this card",callback=function() self:showShelf("loans",card.id) end},
                    {text="Holds on this card",callback=function() self:showShelf("holds",card.id) end},
                    {text="Update cards in Libby, then synchronize here",callback=function() self:message("Add, update, verify or remove library cards in your existing Libby app. Then synchronize KOLibby.") end},
                    {text="Back to library cards",callback=function() self:showCards() end},
                })
            end}
    end
    rows[#rows+1]={text="Back to KOLibby",callback=function() self:showRoot() end}
    self:showMenu("Libby library cards",rows,{items_max_lines=3})
end
function KOLibby:showItem(item)
    local summary=Present.summary(item,self.shelf,self.downloads[item.key])
    local text=(item.subtitle and item.subtitle.."\n\n" or "")..summary.metadata.."\n"..summary.library..(summary.attribution and "\n"..summary.attribution or "").."\n\n"..
        summary.status..(summary.detail and "\n"..summary.detail or "")
    if item.stale then text=text.."\nCached information; this library did not finish refreshing." end
    local buttons={};local dialog
    if item.kind=="loans" then
        local saved=self.downloads[item.key]
        if Model.same_checkout(saved,item) and Store.exists(saved.path) then
            buttons[#buttons+1]={{text=saved.kind=='mp3' and "Show MP3 location" or "Open in KOReader",callback=function() UIManager:close(dialog);self:openLoan(item) end}}
        end
        if item.downloadable and item.expires and item.expires>os.time() then
            buttons[#buttons+1]={{text=saved and "Download again / resume" or item.download_kind=='mp3' and "Download MP3" or "Download EPUB",callback=function() UIManager:close(dialog);self:downloadLoan(item) end}}
        elseif not item.downloadable then text=text.."\n\nNative download is not available for this media type." end
    elseif Model.can_borrow(item) then
        buttons[#buttons+1]={{text="Borrow",callback=function() UIManager:close(dialog);self:borrowHold(item) end}}
    end
    buttons[#buttons+1]={{text="Back",callback=function() UIManager:close(dialog);if not self.window then self:showShelf(item.kind,self.card_filter) end end}}
    dialog=ButtonDialog:new{buttons=buttons}
    local Book=require("kolibby/bookwidgets")
    local width=dialog:getAddedWidgetAvailableWidth()
    local Group=require("ui/widget/verticalgroup")
    local Span=require("ui/widget/verticalspan")
    dialog:addWidget(Group:new{align="left",not_focusable=true,parent=dialog,
        Book.header(item,self.cover_dir,width),Span:new{width=Device.screen:scaleBySize(14)},
        Book.adaptive_text(text,16,width,10),
        Span:new{width=Device.screen:scaleBySize(10)}})
    UIManager:show(dialog)
end
function KOLibby:showSettings()
    self.view="settings"
    self:showMenu("KOLibby settings",{
        {text="Download folder",mandatory=self.config.download_dir,callback=function()
            local PathChooser=require("ui/widget/pathchooser")
            UIManager:show(PathChooser:new{select_directory=true,select_file=false,path=self.config.download_dir,
                height=Device.screen:getHeight(),onConfirm=function(path)
                    local ok=pcall(Store.mkdir,path)
                    if not ok then self:message("That folder is not writable.");return end
                    self.config.download_dir=path:gsub("/+$","");self.store:write("config.json",self.config);self:showSettings()
                end})
        end},
        {text="Sync interval",mandatory=tostring(self.config.interval_minutes).." minutes",callback=function()
            local rows={}
            for _,minutes in ipairs({5,15,30,60,120}) do rows[#rows+1]={text=minutes.." minutes",callback=function()
                self.config.interval_minutes=minutes;self.store:write("config.json",self.config);self:showSettings()
            end} end
            self:showMenu("Sync while KOReader is active",rows)
        end},
        {text="Check for updates",callback=function() self:checkForUpdates() end},
        {text="Reconnect / display setup code",callback=function() self:connectDevice() end},
        {text="Disconnect this plugin",callback=function()
            UIManager:show(ConfirmBox:new{text="Remove this plugin's saved Libby connection and shelf? Downloaded books will stay in the download folder.",ok_callback=function()
                self:cancelPairing();self.store:forget();self.shelf=Model.empty();self.status={};self:showRoot()
            end})
        end},
        {text="About KOLibby "..self.version,callback=function() self:message("KOLibby "..self.version.."\n\nA companion to the official Libby apps for native ebook and MP3 audiobook downloads.\n\nAGPL-3.0-only · KOLibby contributors\nhttps://github.com/kolibby/KOLibby.koplugin\n\nManage cards in any linked official Libby app. KOLibby synchronizes while KOReader is active and connected.") end},
        {text="Back to KOLibby",callback=function() self:showRoot() end},
    })
end

-- A worker owns its network session. Only raw JSON crosses the subprocess pipe.
function KOLibby:runTask(label,work,done,silent,show_progress)
    if Coordinator.restart_required then if not silent then self:promptRestart() end;return end
    if self.busy or not Coordinator.acquire(self) then if not silent then self:message("A KOLibby operation is already running.") end;return end
    self.busy=true
    return Trapper:wrap(function()
        local widget,poll
        if show_progress then
            widget=require("kolibby/downloaddialog").new(show_progress,self.cover_dir);UIManager:show(widget)
            local previous
            poll=function()
                if not self.busy then return end
                local p=self.store:read("progress.json",{})
                local current=table.concat({p.stage or "",p.done or 0,p.total or 0,p.bytes or 0,p.detail or '',p.batch_index or 0},":")
                if current~=previous then widget:updateProgress(p);previous=current end
                UIManager:scheduleIn(.5,poll)
            end
            UIManager:scheduleIn(1,poll)
        end
        local completed,raw=Trapper:dismissableRunInSubprocess(function()
            local ok,value=pcall(work)
            return J.encode(ok and {ok=true,value=value} or {ok=false,message=U.error_message(value)})
        end,widget or (silent and true or label),true)
        self.busy=false
        Coordinator.release(self)
        if poll then UIManager:unschedule(poll) end
        if widget then UIManager:close(widget) end
        if not completed then
            if show_progress then self:message(show_progress.batch and "Download all cancelled. Finished downloads are saved. Run Download all again to continue." or "Download cancelled. Completed resources are kept for the next attempt.") end
            if done then done(nil,"cancelled") end
            return
        end
        local ok,result=pcall(J.decode,raw or "")
        if not ok or not result.ok then
            local message=ok and result.message or "The operation ended unexpectedly. Try again."
            if not silent then self:message(message) end
            if done then done(nil,message) end
        elseif done then done(result.value) end
    end)
end
function KOLibby:checkForUpdates()
    return NetworkMgr:runWhenOnline(function()
        return self:runTask("Checking for KOLibby updates…",function()
            local http=require('kolibby/updatehttp').new(self.version)
            local ok,result=pcall(require('kolibby/updater').check,function(req) return http:request(req) end,self.version)
            http:close();if not ok then error(result,0) end;return result
        end,function(result)
            if not result then return end
            if result.status=='unpublished' then self:message("No published KOLibby release is available yet. Check again after the first release is published.")
            elseif result.status=='current' then self:message("KOLibby "..self.version.." is up to date.")
            else self:showUpdateNotes(result) end
        end)
    end)
end
function KOLibby:showUpdateNotes(release)
    local viewer
    viewer=require('ui/widget/textviewer'):new{title='KOLibby '..release.version,text='Installed: '..self.version..'\nAvailable: '..release.version..'\n\n'..release.notes,
        force_txt=true,buttons_table={{{text='Install update',callback=function() UIManager:close(viewer);self:installUpdate(release) end},
            {text='Later',callback=function() UIManager:close(viewer) end}}}}
    UIManager:show(viewer)
end
function KOLibby:installUpdate(release)
    return NetworkMgr:runWhenOnline(function()
        return self:runTask("Downloading and verifying KOLibby…",function()
            local http=require('kolibby/updatehttp').new(self.version)
            local ok,result=pcall(require('kolibby/updater').prepare,function(req) return http:request(req) end,release,
                {install_dir=self.path,cache_dir=self.cache_dir..'/updates'})
            http:close();if not ok then error(result,0) end;return result
        end,function(prepared)
            if not prepared then return end
            -- Activation runs in the parent without a cancellation/yield point
            -- between the backup rename and the replacement rename.
            local ok,err=pcall(require('kolibby/updateinstall').activate,self.path,prepared.stage)
            if not ok then self:message(U.error_message(err));return end
            Coordinator.restart_required=true;self.installed_version=prepared.version
            self:closeWindow();self:promptRestart()
        end)
    end)
end
function KOLibby:promptRestart()
    local text='The KOLibby update'..(self.installed_version and ' ('..self.installed_version..')' or '')..' is installed. '
    if Device:canRestart() then UIManager:askForRestart(text..'Restart KOReader to use the update.')
    else self:message(text..'Close KOReader completely and open it again to use the update.') end
end
function KOLibby:prepareShelf(client,response)
    local shelf=Model.merge(self.shelf,response or client:sync(),os.time())
    Covers.fetch(shelf,client.transport,self.cover_dir)
    return shelf
end
function KOLibby:saveShelf(shelf)
    self.shelf=shelf;self.store:write("shelf.json",shelf)
    Coordinator.last_sync=shelf.last_sync
    local pending=self.store:read("borrow.json",{})
    if pending.key and shelf.loans[pending.key] then self.store:write("borrow.json",{}) end
end
function KOLibby:syncNow(automatic)
    if Coordinator.owner or Coordinator.pair_owner then return end
    local start=function()
        self.status.last_attempt=os.time();self.store:write("status.json",self.status)
        return self:runTask("Synchronizing Libby…",function()
            local client=self:client();return self:prepareShelf(client)
        end,function(shelf,err)
            if shelf then
                self:saveShelf(shelf);self.status.error=nil;self.status.failures=0
            elseif err~="cancelled" then self.status.error=err;self.status.failures=(self.status.failures or 0)+1 end
            self.store:write("status.json",self.status)
            if shelf and self.window then self:refreshView() end
            if self.main_menu and self.ui.menu.menu_container and self.ui.menu.menu_container[1]==self.main_menu then self.main_menu:updateItems() end
        end,automatic)
    end
    if automatic then return start() end
    return NetworkMgr:runWhenOnline(start)
end
function KOLibby:refreshView()
    if self.view=="loans" or self.view=="holds" then self:showShelf(self.view,self.card_filter)
    elseif self.view=="cards" then self:showCards()
    elseif self.view=="root" then self:showRoot() end
end
function KOLibby:scheduleTick()
    UIManager:unschedule(self._tick)
    if not self.suspended and not self.closed then UIManager:scheduleIn(60,self._tick) end
end
function KOLibby:maybeSync()
    if self.closed or self.suspended or Coordinator.owner or Coordinator.pair_owner or not self.store:auth().paired or not NetworkMgr:isConnected() then return end
    self.status=self.store:read("status.json",self.status)
    local interval=(tonumber(self.config.interval_minutes) or 30)*60
    local backoff=math.min(1800,30*2^math.min(self.status.failures or 0,6))
    if os.time()-math.max(self.shelf.last_sync or 0,Coordinator.last_sync)>=interval and os.time()-(self.status.last_attempt or 0)>=backoff then self:syncNow(true) end
end

function KOLibby:connectDevice()
    if Coordinator.owner then self:message("Wait for the current operation to finish.");return end
    if Coordinator.pair_owner and Coordinator.pair_owner~=self then self:message("A Libby connection screen is already open.");return end
    self:cancelPairing();self:closeWindow();self.pairing={}
    Coordinator.pair_owner=self
    return NetworkMgr:runWhenOnline(function() self:pollPairing() end)
end
function KOLibby:pairTitle()
    local code=self.pairing.code or ""
    local spaced=code:gsub("(.)","%1 "):gsub("%s+$","")
    local seconds=math.max(0,math.ceil((self.pairing.expiry or os.time())-os.time()))
    return "Connect to Libby\n\n"..spaced.."\n\nOn your existing Libby device, open:\nMenu → Copy To Another Device\n\nEnter the code there.\n"..seconds.." seconds remaining."
end
function KOLibby:showPairCode()
    if self.pair_dialog then
        local title=self.pair_dialog.title_group
        if title and title[1] and title[1][1] then title[1][1]:setText(self:pairTitle());UIManager:setDirty(self.pair_dialog,"ui") end
        return
    end
    self.pair_dialog=ButtonDialog:new{title=self:pairTitle(),dismissable=false,buttons={{{text="Cancel",callback=function() self:cancelPairing();self:showRoot() end}}}}
    UIManager:show(self.pair_dialog)
end
function KOLibby:pollPairing()
    if not self.pairing or self.suspended then return end
    if self.busy then UIManager:scheduleIn(1,self._pair_poll);return end
    local pairing=self.pairing
    return self:runTask("Requesting a Libby setup code…",function()
        local client=self:client();local response=client:code(pairing.code)
        if response.result=="fulfilled" then return {linked=true,shelf=self:prepareShelf(client,client:finish_pairing(response.blessing))} end
        return response
    end,function(response,err)
        if self.pairing~=pairing then return end
        if response and response.linked then
            self:cancelPairing();self:saveShelf(response.shelf)
            self.status={};self.store:write("status.json",self.status);self:showShelf("loans")
            return
        elseif response and type(response.code)=="string" then
            pairing.errors=0;pairing.code=response.code;pairing.expiry=tonumber(response.expiry) or os.time()+60;self:showPairCode()
        elseif err and err~="cancelled" then
            pairing.errors=(pairing.errors or 0)+1
            if not self.pair_dialog or pairing.errors>=3 then self:cancelPairing();self:message(err);return end
        end
        if self.pairing and not self.suspended then UIManager:scheduleIn(3,self._pair_poll) end
    end,self.pair_dialog~=nil)
end
function KOLibby:cancelPairing()
    self.pairing=nil;UIManager:unschedule(self._pair_poll)
    if Coordinator.pair_owner==self then Coordinator.pair_owner=nil end
    if self.pair_dialog then UIManager:close(self.pair_dialog);self.pair_dialog=nil end
end
function KOLibby:downloadLoan(loan)
    return NetworkMgr:runWhenOnline(function()
        self.store:write("progress.json",{stage="authorizing",kind=loan.media_type=="audiobook" and "mp3" or "epub",done=0,total=0})
        return self:runTask(loan.media_type=='audiobook' and "Downloading MP3…" or "Downloading EPUB…",function()
            local client=self:client();local shelf=self:prepareShelf(client)
            local current=shelf.loans[loan.key]
            if not current or current.checkout_id~=loan.checkout_id then error("This checkout changed. Synchronize and select the loan again.",0) end
            local module=current.media_type=='audiobook' and 'kolibby/audiobook' or 'kolibby/download'
            local record=require(module).run(client,current,Model.card_for(shelf,current.card_id),{
                directory=self.config.download_dir,cache_dir=self.cache_dir,cover_dir=self.cover_dir,
                progress=function(value) self.store:write("progress.json",value) end})
            return {record=record,shelf=shelf}
        end,function(result)
            if result then
                self.shelf=result.shelf;self.store:write("shelf.json",self.shelf)
                Coordinator.last_sync=self.shelf.last_sync
                local work=result.record.work;result.record.work=nil
                self.downloads[loan.key]=result.record;self.store:write("downloads.json",self.downloads)
                if work then Store.remove_tree(work) end
                self:openLoan(self.shelf.loans[loan.key])
            end
        end,false,loan)
    end)
end
function KOLibby:downloadAll(card_id)
    return NetworkMgr:runWhenOnline(function()
        -- Keep progress initialization inside the acquired worker so a second
        -- tap cannot overwrite an operation already in progress.
        return self:runTask("Downloading your loans…",function()
            self.store:write("progress.json",{stage='batch_preparing',batch=true})
            local client=self:client();local shelf=self:prepareShelf(client)
            self.store:write("shelf.json",shelf)
            return Batch.run(client,shelf,self.store:read("downloads.json",{}),{
                card_id=card_id,directory=self.config.download_dir,cache_dir=self.cache_dir,cover_dir=self.cover_dir,
                persist=function(downloads) self.store:write("downloads.json",downloads) end,
                progress=function(value) self.store:write("progress.json",value) end})
        end,function(result)
            self:reloadShelf();Coordinator.last_sync=self.shelf.last_sync or 0
            if result then self:showShelf("loans",card_id);self:message(Batch.summary(result)) end
        end,false,{batch=true,title=card_id and 'Loans on this card' or 'All library loans',author='EPUBs and MP3 audiobooks'})
    end)
end
function KOLibby:borrowHold(item)
    return NetworkMgr:runWhenOnline(function()
        return self:runTask("Checking this hold…",function()
            return Borrowing.prepare(self:client(),self.shelf,item,function(shelf) self.store:write("shelf.json",shelf) end)
        end,function(result)
            self:reloadShelf()
            if not result then return end
            if result.existing then self.store:write("borrow.json",{});self:showShelf("loans");self:message("This title is already on your loans.");return end
            self:showBorrowConfirmation(result)
        end)
    end)
end
function KOLibby:showBorrowConfirmation(prepared)
    local item=prepared.hold
    local pending=self.store:read("borrow.json",{})
    local text="Borrow “"..item.title.."”?\n\n"..Model.card_label(self.shelf,item.card_id).."\nChoose a loan period."
    if item.media_type=="audiobook" then text=text.."\nDownload eligible MP3 loans here, or listen in Libby." end
    if pending.key==item.key then text=text.."\n\nAn earlier attempt was interrupted. The shelf has been refreshed; check Loans before retrying." end
    local buttons,dialog={}
    for _,period in ipairs(prepared.options) do
        local key=tostring(period[1])..":"..period[2]
        buttons[#buttons+1]={{text="Borrow for "..Borrowing.period_label(period)..(key==prepared.preferred and " (default)" or ""),callback=function()
            UIManager:close(dialog);self:commitBorrow(item,period)
        end}}
    end
    buttons[#buttons+1]={{text="Cancel",callback=function() UIManager:close(dialog) end}}
    dialog=ButtonDialog:new{title=text,buttons=buttons};UIManager:show(dialog)
end
function KOLibby:commitBorrow(item,period)
    return NetworkMgr:runWhenOnline(function()
        return self:runTask("Borrowing your book…",function()
            local client=self:client()
            local result=Borrowing.commit(client,self.shelf,item,period,{
                persist=function(shelf) self.store:write("shelf.json",shelf) end,
                pending=function(value) self.store:write("borrow.json",value) end})
            Covers.fetch(result.shelf,client.transport,self.cover_dir)
            return result
        end,function(result,err)
            self:reloadShelf()
            if result then
                self:saveShelf(result.shelf)
                self:showShelf(result.loan_key and "loans" or "holds")
                self:message(result.message)
            elseif err=="cancelled" and self.store:read("borrow.json",{}).key then
                self:message("Borrowing was interrupted. Synchronize to check whether the loan was created before trying again.")
            end
        end)
    end)
end
function KOLibby:openLoan(loan)
    local record=self.downloads[loan.key]
    if not Model.same_checkout(record,loan) or not Store.exists(record.path) then self:message("Download this checkout before opening it.");return end
    local expiry=math.min(loan.expires or 0,record.expires or 0)
    if expiry<=os.time() then self:message("This download's loan period has ended. Synchronize, then download again if the loan was renewed.");return end
    if record.kind=='mp3' then
        self:message("MP3 saved with "..tostring(record.chapters or 0).." chapters:\n\n"..record.path.."\n\nOpen or import this file in your audio player. Chapter navigation depends on the player's ID3 chapter support.")
        return
    end
    self:closeWindow()
    local function open() require("apps/reader/readerui"):showReader(record.path) end
    if record.fixed_layout then
        UIManager:show(require("ui/widget/confirmbox"):new{
            text="This EPUB contains fixed-layout pages. KOReader may reflow or misrender them. For the intended layout, use a reader with fixed-layout EPUB support.\n\nSaved at:\n"..record.path,
            ok_text="Open in KOReader",ok_callback=open,cancel_text="Close"})
    else open() end
end
function KOLibby:onSuspend()
    self.suspended=true;UIManager:unschedule(self._tick);UIManager:unschedule(self._pair_poll)
end
function KOLibby:onResume()
    self.suspended=false;self:scheduleTick()
    if self.pairing then UIManager:scheduleIn(.5,self._pair_poll) else UIManager:scheduleIn(2,function() self:maybeSync() end) end
end
function KOLibby:onNetworkConnected()
    if not self.pairing then UIManager:scheduleIn(2,function() self:maybeSync() end) end
end
function KOLibby:onCloseDocument() self.closed=true;self:cancelPairing();UIManager:unschedule(self._tick) end
function KOLibby:onCloseWidget() self.closed=true;self:cancelPairing();UIManager:unschedule(self._tick) end
function KOLibby:onExit() self:onCloseWidget() end
return KOLibby
