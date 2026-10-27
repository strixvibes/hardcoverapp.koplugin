local _ = require("gettext")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Dispatcher = require("dispatcher")
local logger = require("logger")
local math = require("math")

local Font = require("ui/font")
local NetworkManager = require("ui/network/manager")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local SpinWidget = require("ui/widget/spinwidget")

local WidgetContainer = require("ui/widget/container/widgetcontainer")

local _t = require("hardcover/lib/table_util")
local Api = require("hardcover/lib/hardcover_api")
local Oauth = require("hardcover/lib/oauth")
local AutoWifi = require("hardcover/lib/auto_wifi")
local Cache = require("hardcover/lib/cache")
local debounce = require("hardcover/lib/debounce")
local Hardcover = require("hardcover/lib/hardcover")
local HardcoverSettings = require("hardcover/lib/hardcover_settings")
local PageMapper = require("hardcover/lib/page_mapper")
local Queue = require("hardcover/lib/queue")
local Scheduler = require("hardcover/lib/scheduler")
local throttle = require("hardcover/lib/throttle")
local User = require("hardcover/lib/user")

local DialogManager = require("hardcover/lib/ui/dialog_manager")
local SignInDialog = require("hardcover/lib/ui/sign_in_dialog")
local HardcoverMenu = require("hardcover/lib/ui/hardcover_menu")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SETTING = require("hardcover/lib/constants/settings")

-- true while "Sending queued updates" has already been announced for the current batch, so it
-- is shown once however many screens are opened in between (reset when the batch is finished or
-- Hardcover becomes unreachable)
local sending_announced = false

local HardcoverApp = WidgetContainer:extend {
  name = "hardcoverappsync",
  is_doc_only = false,
  state = nil,
  settings = nil,
  width = nil,
  enabled = true
}

local HIGHLIGHT_MENU_NAME = "13_0_make_hardcover_highlight_item"
-- Longest gap between two page turns that still counts as reading time (seconds)
local MAX_READING_GAP = 300

function HardcoverApp:onDispatcherRegisterActions()
  Dispatcher:registerAction("hardcover_link", {
    category = "none",
    event = "HardcoverLink",
    title = _("Hardcover: Link book"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_track", {
    category = "none",
    event = "HardcoverTrack",
    title = _("Hardcover: Track progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_stop_track", {
    category = "none",
    event = "HardcoverStopTrack",
    title = _("Hardcover: Stop tracking progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_update_progress", {
    category = "none",
    event = "HardcoverUpdateProgress",
    title = _("Hardcover: Update progress"),
    general = true,
  })

  Dispatcher:registerAction("hardcover_random_books", {
    category = "none",
    event = "HardcoverSuggestBook",
    title = _("Hardcover: Suggest a book"),
    general = true,
  })
end

function HardcoverApp:init()
  self.state = {
    page = nil,
    pos = nil,
    search_results = {},
    book_status = {},
    page_update_pending = false
  }
  --logger.warn("HARDCOVER app init")
  self.settings = HardcoverSettings:new(
    ("%s/%s"):format(DataStorage:getSettingsDir(), "hardcoversync_settings.lua"),
    self.ui
  )
  self.settings:subscribe(function(field, change, original_value) self:onSettingsChanged(field, change, original_value) end)

  User.settings = self.settings
  Api.on_error = function(err)
    if not err or not self.enabled then
      return
    end

    if err == HARDCOVER.ERROR.TOKEN or _t.dig(err, "extensions", "code") == HARDCOVER.ERROR.JWT or (err.message and string.find(err.message, "JWT")) then
      self:disable()
      self:showSignInPrompt(Api:usesApiKey()
          and _("Hardcover API key invalid. Please validate it, or sign in using OAuth from the Hardcover menu.")
          or _("Your Hardcover sign-in has expired. Please sign in again."))
      -- from now on the plugin behaves as with no connection: updates are saved in the queue
      self.state.read_cache_started = false
      UIManager:nextTick(function()
        self:startReadCache()
      end)
    end
  end

  Api.on_signin_lost = function()
    if not self.settings:suppressNotifications() then
      UIManager:show(InfoMessage:new {
        text = _("Hardcover sign-in expired. Using your API key instead. Sign in again from the Hardcover menu."),
        timeout = 8,
      })
    end
  end

  self.cache = Cache:new {
    settings = self.settings,
    state = self.state
  }
  self.page_mapper = PageMapper:new {
    state = self.state,
    ui = self.ui,
  }
  self.wifi = AutoWifi:new {
    settings = self.settings
  }
  self.dialog_manager = DialogManager:new {
    page_mapper = self.page_mapper,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }
  self.hardcover = Hardcover:new {
    cache = self.cache,
    dialog_manager = self.dialog_manager,
    settings = self.settings,
    state = self.state,
    ui = self.ui,
    wifi = self.wifi
  }

  self.queue = Queue:new {
    settings = self.settings,
  }

  self._auto_queue_sync = function()
    self:syncQueueNow(false)
  end

  -- on a slow or missing network the Hardcover status may never load; after a while the
  -- plugin then carries on from the offline queue
  self._offline_watchdog = function()
    if self.ui.document and not self.state.status_loaded and not NetworkManager:isConnected() then
      self.state.status_unavailable = true
      self:announceOffline()
    end
  end

  self.menu = HardcoverMenu:new {
    enabled = true,
    auth_changed = function()
      self:onAuthChanged()
    end,

    cache = self.cache,
    dialog_manager = self.dialog_manager,
    hardcover = self.hardcover,
    page_mapper = self.page_mapper,
    queue = self.queue,
    settings = self.settings,
    state = self.state,
    sync_queue = function()
      self:syncQueueNow(true)
    end,
    ui = self.ui,
  }

  self:installResetHook()
  self:onDispatcherRegisterActions()
  self:initializePageUpdate()
  self.ui.menu:registerToMainMenu(self)

  if NetworkManager:isConnected() then
    self:scheduleQueueSync(10)
  end

  self:startLinkWatch()

  logger.info("HARDCOVER connection: signed in=" .. tostring(Oauth.isSignedIn())
    .. ", key file present=" .. tostring(Api:hasKeyFile())
    .. ", usable credentials=" .. tostring(Api:hasCredentials()))

  -- Neither signed in nor an API key: the plugin stays quiet (no requests, nothing queued) and
  -- says so once each time KOReader starts
  if not Api:hasCredentials() then
    self:disable()
    if not HardcoverApp._not_signed_in_shown then
      HardcoverApp._not_signed_in_shown = true
      UIManager:scheduleIn(3, function()
        self:remindNotSignedIn()
      end)
    end
  end
end

-- Shown at start-up and every time the device wakes while there is no sign-in or API key. It is
-- deliberately not hidden by "Suppress all pop-up notifications": without credentials the plugin
-- cannot do anything.
-- A box with "Sign in" and "Cancel", for when the plugin cannot connect. It is deliberately not
-- hidden by "Suppress all pop-up notifications": without a connection the plugin cannot do anything.
function HardcoverApp:showSignInPrompt(text)
  UIManager:show(ConfirmBox:new {
    text = text,
    face = Font:getFace("x_smallinfofont"),
    icon = "notice-info",
    ok_text = _("Sign in"),
    cancel_text = _("Cancel"),
    ok_callback = function()
      SignInDialog.start(function()
        self:onAuthChanged()
      end)
    end,
  })
end

-- What to tell the user when there is nothing to connect with: if hardcover_config.lua exists the
-- API key is what they meant to use, so the key is reported; otherwise they are offered a sign-in
local function noConnectionText()
  if Api:hasKeyFile() then
    return _("Hardcover API key invalid. Please validate it, or sign in using OAuth from the Hardcover menu.")
  end
  return _("Not signed in to Hardcover. Sign in from the Hardcover plugin menu or configure your API key.")
end

function HardcoverApp:remindNotSignedIn()
  if Api:hasCredentials() then
    return
  end
  -- the file browser's and the reader's copies of the plugin both hear about a wake-up
  local now = os.time()
  if HardcoverApp._reminded_at and now - HardcoverApp._reminded_at < 15 then
    return
  end
  HardcoverApp._reminded_at = now

  self:showSignInPrompt(noConnectionText())
end

function HardcoverApp:onResume()
  if not Api:hasCredentials() then
    UIManager:scheduleIn(3, function()
      self:remindNotSignedIn()
    end)
  end
end

-- A queued update that was waiting for its book to be linked is sent as soon as the link
-- appears, whether it was made from the reader menu, from Bookshelf, or by auto-link.
-- Once a minute this looks (locally, no network) for such a book. Only the newest plugin
-- instance keeps watching, so the file browser's copy stops when the reader's takes over.
function HardcoverApp:startLinkWatch()
  HardcoverApp._link_watch_owner = self

  local watch
  watch = function()
    if HardcoverApp._link_watch_owner ~= self then
      return
    end

    pcall(function()
      if self.queue.running or not NetworkManager:isConnected() then
        return
      end

      local waiting = {}
      for file, entry in pairs(self.queue:entries()) do
        if not entry.book_id then
          waiting[#waiting + 1] = file
        end
      end
      if #waiting == 0 then
        return
      end

      -- read the settings file itself, so a link made by another part of KOReader is seen too
      local fresh = LuaSettings:open(DataStorage:getSettingsDir() .. "/hardcoversync_settings.lua")
      local books = fresh:readSetting("books") or {}
      for _, file in ipairs(waiting) do
        if books[file] and books[file].book_id then
          logger.info("HARDCOVER queue: " .. tostring(file) .. " has been linked, sending its queued updates")
          self:scheduleQueueSync(3)
          return
        end
      end
    end)

    UIManager:scheduleIn(60, watch)
  end

  UIManager:scheduleIn(60, watch)
end

-- When "Currently Reading" becomes active for the open book (switched on for the book, or in the
-- global settings), the book is offered it again whatever the percentage already read, instead
-- of waiting for a threshold that has long been passed.
function HardcoverApp:refreshReadingOffer()
  if not self.ui.document then
    return
  end

  local file = self.ui.document.file
  local before = self.state.reading_mode_last
  local now = self.settings:readingModeFor(file)
  self.state.reading_mode_last = now

  if before == SETTING.AUTO_MODE.OFF and now ~= SETTING.AUTO_MODE.OFF then
    logger.info("HARDCOVER reading offer: Currently Reading is now " .. tostring(now) .. " for this book, offering it again")
    self.settings:updateBookSetting(file, { _delete = { "start_prompted", "start_sent" } })
    if self.state.status_loaded or self:offlineRecording() then
      UIManager:nextTick(function()
        self:maybeStartReading()
      end)
    end
  end
end

-- "Reset book data" in KOReader / Bookshelf wipes a book's own settings and progress. The
-- per-book Hardcover rules (Always / Never sync) go with it, so the book follows the global
-- settings again and may be offered Currently Reading afresh. The Hardcover link stays.
function HardcoverApp:resetBookRules(file)
  local books = self.settings.settings:readSetting("books")
  local book = books and books[file]
  if not book then
    return
  end

  local keys = { "rule_progress", "rule_reading", "rule_read", "rule_rating", "start_prompted", "start_sent", "read_seconds" }
  local found = false
  for _i, key in ipairs(keys) do
    if book[key] ~= nil then
      found = true
    end
  end
  if not found then
    return
  end

  logger.info("HARDCOVER reset: book data was reset, clearing per-book Hardcover rules for " .. tostring(file))
  self.settings:updateBookSetting(file, { _delete = keys })
end

-- Listens for KOReader wiping a book's data (once per KOReader run; the newest copy of the plugin
-- does the work)
function HardcoverApp:installResetHook()
  HardcoverApp._reset_target = self
  if HardcoverApp._reset_hook_installed then
    return
  end
  HardcoverApp._reset_hook_installed = true

  local run = function(file)
    pcall(function()
      local app = HardcoverApp._reset_target
      if app and type(file) == "string" then
        app:resetBookRules(file)
      end
    end)
  end

  -- KOReader's own reset tells the reading history that a book's settings are gone
  local ok, ReadHistory = pcall(require, "readhistory")
  if ok and type(ReadHistory) == "table" and type(ReadHistory.fileSettingsPurged) == "function" then
    local original = ReadHistory.fileSettingsPurged
    ReadHistory.fileSettingsPurged = function(history, file, ...)
      run(file)
      return original(history, file, ...)
    end
  end

  -- any other way of wiping the whole sidecar of a book (a reset made by another plugin)
  local ok_ds, DocSettings = pcall(require, "docsettings")
  if ok_ds and type(DocSettings) == "table" and type(DocSettings.purge) == "function" then
    local original_purge = DocSettings.purge
    DocSettings.purge = function(doc_settings, sidecar_to_keep, data_to_purge, ...)
      if sidecar_to_keep == nil and (data_to_purge == nil or data_to_purge.doc_settings) then
        run(type(doc_settings) == "table" and doc_settings.doc_path or nil)
      end
      return original_purge(doc_settings, sidecar_to_keep, data_to_purge, ...)
    end
  end
end

function HardcoverApp:_bookSettingChanged(setting, key)
  return setting[key] ~= nil or _t.contains(_t.dig(setting, "_delete"), key)
end

-- Open note dialog
--
-- UIManager:broadcastEvent(Event:new("HardcoverNote", note_params))
--
-- note_params can contain:
--   text: Value will prepopulate the note section
--   page_number: The local page number
--   remote_page (optional): The mapped page in the linked book edition
--   note_type: one of "quote" or "note"
function HardcoverApp:onHardcoverNote(note_params)
  -- open journal dialog
  self.dialog_manager:journalEntryForm(
    note_params.text,
    self.ui.document,
    note_params.page_number,
    self.settings:pages(),
    note_params.remote_page,
    note_params.note_type or "quote"
  )
end

-- Called after signing in or out: the plugin works again (or stops) with whatever sign-in is left
function HardcoverApp:onAuthChanged()
  -- it may be a different account now, so the stored user id is forgotten
  self.settings.settings:delSetting(SETTING.USER_ID)
  self.settings.settings:flush()

  local usable = Api:hasCredentials()
  self.enabled = usable
  if self.menu then
    self.menu.enabled = usable
  end
  self:registerHighlight()

  -- signed out with an API key that does not work: say so now, not only at the next wake-up
  if not usable and Api:hasKeyFile() then
    UIManager:scheduleIn(1, function()
      self:showSignInPrompt(noConnectionText())
    end)
  end

  if usable and self.ui.document and
      (self.settings:syncEnabled() or (not self.settings:bookLinked() and self.settings:autolinkEnabled())) then
    self.state.read_cache_started = false
    self.state.status_unavailable = false
    self.state.offline_announced = false
    UIManager:scheduleIn(1, self.startReadCache, self)
  end
  self:scheduleQueueSync(4)
end

function HardcoverApp:disable()
  self.enabled = false
  if self.menu then
    self.menu.enabled = false
  end
  self:registerHighlight()
end

function HardcoverApp:onHardcoverLink()
  self.hardcover:showLinkBookDialog(false, function(book)
    self:notify(_("Linked to: " .. book.title))
  end)
end

function HardcoverApp:onHardcoverTrack()
  self.settings:setSync(true)
  UIManager:nextTick(function()
    UIManager:show(Notification:new {
      text = _("Progress tracking enabled")
    })
  end)
end

function HardcoverApp:onHardcoverStopTrack()
  self.settings:setSync(false)
  UIManager:show(Notification:new {
    text = _("Progress tracking disabled")
  })
end

function HardcoverApp:onHardcoverUpdateProgress()
  if self.ui.document and self.settings:bookLinked() then
    self:updatePageNow(function(result)
      if result then
        UIManager:show(Notification:new {
          text = _("Progress updated")
        })
      else
        logger.warn("Unsuccessful updating page progress", self.ui.document.file)
      end
    end)
  else
    logger.warn(self.state.book_status)
    local error
    if not self.ui.document then
      error = "No book active"
    elseif not self.state.book_status.id then
      error = "Book has not been mapped"
    end

    local error_message = error and "Unable to update reading progress: " .. error or "Unable to update reading progress"
    UIManager:show(InfoMessage:new {
      text = error_message,
      icon = "notice-warning",
    })
  end
end

function HardcoverApp:onHardcoverSuggestBook()
  self.hardcover:showRandomBookDialog()
end

function HardcoverApp:onSettingsChanged(field, change, original_value)
  if field == SETTING.BOOKS then
    local book_settings = change.config
    if self:_bookSettingChanged(book_settings, "rule_progress")
        or self:_bookSettingChanged(book_settings, "rule_reading")
        or self:_bookSettingChanged(book_settings, "rule_read") then
      if self.ui.document and (not change.filename or change.filename == self.ui.document.file) then
        if self.settings:syncEnabled() and not self.state.book_status.id then
          -- the status may not have been loaded because the book was inactive when it was opened
          -- (or was not linked yet): start the load again from scratch
          self.state.status_loaded = false
          self.state.read_cache_started = false
          UIManager:scheduleIn(1, self.startReadCache, self)
        end
        if not self.settings:progressEnabled(self.ui.document.file) then
          self:cancelPendingUpdates()
        end
        self:refreshReadingOffer()
      end
    end

    if self:_bookSettingChanged(book_settings, "book_id") then
      -- a link that was removed by hand starts the book over: it can be offered Currently Reading again
      if _t.contains(_t.dig(book_settings, "_delete"), "book_id") and change.filename then
        self.settings:updateBookSetting(change.filename, { _delete = { "start_prompted", "start_sent" } })
      end

      self:registerHighlight()

      -- a book was linked (or relinked) while open: load its Hardcover status now
      if self.ui.document and self.settings:bookLinked() and self.settings:syncEnabled() then
        self.state.status_loaded = false
        self.state.read_cache_started = false
        UIManager:scheduleIn(1, self.startReadCache, self)
      end
    end
  elseif field == SETTING.AUTO_READING or field == SETTING.ALWAYS_SYNC then
    -- Currently Reading was switched on (or the book became tracked) for the book being read
    self:refreshReadingOffer()
  elseif field == SETTING.TRACK_METHOD then
    self:cancelPendingUpdates()
    self:initializePageUpdate()
  elseif field == SETTING.LINK_BY_HARDCOVER or field == SETTING.LINK_BY_ISBN or field == SETTING.LINK_BY_TITLE then
    if change then
      self.hardcover:tryAutolink()
    end
  end
end

function HardcoverApp:_handlePageUpdate(filename, mapped_page, immediate, callback)
  --logger.warn("HARDCOVER: Throttled page update", mapped_page)
  self.page_update_pending = false

  if not self:syncFileUpdates(filename) then
    return
  end

  if self.state.book_status.status_id ~= HARDCOVER.STATUS.READING then
    return
  end

  local reads = self.state.book_status.user_book_reads
  local current_read = reads and reads[#reads]
  if not current_read then
    return
  end

  -- Hardcover marks a book as Read by itself once progress reaches its final page. While the
  -- "Mark as Read at end of book" setting is on, that decision is left to the question (or to
  -- Automatic), so progress is held one page short of the end until the book is marked.
  if self.ui.document and self.settings:holdsLastPage(self.ui.document.file) and not self.state.end_marked then
    local total_pages = self.settings:pages() or (self.ui.document and self.ui.document:getPageCount())
    if total_pages and total_pages > 1 and mapped_page and mapped_page >= total_pages then
      mapped_page = total_pages - 1
    end
  end

  local immediate_update = function()
    self:sendOrQueue(function()
      local result
      -- pages are counted in the linked edition; Hardcover measures this read in its own edition
      local send_page = Api:scalePagesToRead(current_read, mapped_page, self.settings:pages())
      if type(current_read.finished_at) == "string" then
        -- latest read is already finished: start a new read instead of overwriting it
        result = Api:createRead(self.state.book_status.id, current_read.edition_id, mapped_page, os.date("%Y-%m-%d"))
      else
        result = Api:updatePage(current_read.id, current_read.edition_id, send_page, current_read.started_at)
      end
      if result then
        self.state.book_status = result
      elseif NetworkManager:isConnected() then
        -- the read may no longer exist on Hardcover (changed on the website): re-sync our copy
        local previous_status = self.state.book_status
        local sync_error = self.cache:cacheUserBook()
        if sync_error then
          self.state.book_status = previous_status
        end
      else
        -- the connection went away: keep the progress for later
        self:queueProgressPage(filename, mapped_page)
      end
      if callback then
        callback(result)
      end
    end, function()
      self:queueProgressPage(filename, mapped_page)
      if callback then
        callback(nil)
      end
    end)
  end

  local trapped_update = function()
    Trapper:wrap(immediate_update)
  end

  if immediate then
    immediate_update()
  else
    UIManager:scheduleIn(1, trapped_update)
  end
end

-- ---------------------------------------------------------------------------------------
-- Offline queue helpers
-- ---------------------------------------------------------------------------------------

-- True while the open book is being tracked from the queue because Hardcover cannot be reached
function HardcoverApp:offlineRecording()
  return self.ui.document ~= nil
      and self.state.status_unavailable == true
      and not self.state.status_loaded
      and self.settings:syncEnabled()
end

-- Runs send() when wifi is on; otherwise queue() runs instead, so nothing is lost.
function HardcoverApp:sendOrQueue(send, queue)
  if NetworkManager:isWifiOn() and Api:hasCredentials() then
    send()
  else
    queue()
  end
end

-- everything the queue needs to send an update for this book later
function HardcoverApp:queueBookInfo(file)
  local book = self.settings:readBookSettings(file) or {}
  if not book.book_id then
    -- not linked to Hardcover yet: keep the book's own details so it can be found once online
    if not (self.ui.document and self.ui.document.file == file) then
      return nil
    end

    local props = self.ui.document:getProps() or {}
    return {
      file = file,
      snapshot = {
        title = props.title,
        authors = props.authors,
        identifiers = props.identifiers,
      },
      doc_pages = self.ui.document:getPageCount(),
      local_title = props.title,
    }
  end

  local info = {
    file = file,
    book_id = book.book_id,
    edition_id = book.edition_id,
    pages = book.pages,
    title = book.title,
  }

  if self.ui.document and self.ui.document.file == file then
    info.doc_pages = self.ui.document:getPageCount()
    local props = self.ui.document:getProps()
    info.local_title = props and props.title
  end

  return info
end

-- where the reader is, as a fraction of the book
function HardcoverApp:currentPercent()
  if not (self.ui.document and self.state.page) then
    return nil
  end

  local percent = self.page_mapper:getRemotePagePercent(
    self.state.page,
    self.ui.document:getPageCount(),
    self.settings:pages()
  )
  return percent
end

-- the last Hardcover status seen for a book, so prompts still make sense offline
function HardcoverApp:rememberStatus(file, status_id)
  local value = status_id or 0
  if file and self.settings:readBookSetting(file, "last_status_id") ~= value then
    self.settings:updateBookSetting(file, { last_status_id = value })
  end
end

-- Brief automatic messages ("Marked as Currently Reading", "Synced", ...). They can all be switched
-- off with "Suppress all pop-up notifications". Errors and answers to menu actions always show.
function HardcoverApp:notify(text, timeout)
  if self.settings:suppressNotifications() then
    return
  end
  UIManager:show(Notification:new { text = text, timeout = timeout })
end

function HardcoverApp:notifyQueued()
  if Api:hasCredentials() then
    self:notify(_("Saved. Will be sent to Hardcover when online"))
  else
    self:notify(_("Saved. Will be sent once connected to Hardcover"))
  end
end

function HardcoverApp:queueStarted(file)
  local info = self:queueBookInfo(file)
  if not info then
    return
  end

  self.queue:recordStarted(info)
  if self.settings:progressEnabled(file) then
    self.queue:recordProgress(info, self:currentPercent())
  end
  self:rememberStatus(file, HARDCOVER.STATUS.READING)
  self:notifyQueued()
  if not info.book_id and NetworkManager:isConnected() then
    self:scheduleQueueSync(3)
  end
end

function HardcoverApp:queueFinished(file)
  local info = self:queueBookInfo(file)
  if not info then
    return
  end

  self.queue:recordFinished(info)
  self:rememberStatus(file, HARDCOVER.STATUS.FINISHED)
  self.state.end_marked = true
  self:notifyQueued()
  if not info.book_id and NetworkManager:isConnected() then
    self:scheduleQueueSync(3)
  end
end

function HardcoverApp:queueProgressPercent(file, percent)
  local info = self:queueBookInfo(file)
  if info and percent then
    self.queue:recordProgress(info, percent)
  end
end

function HardcoverApp:queueProgressPage(file, page)
  local info = self:queueBookInfo(file)
  if not info or not page then
    return
  end

  local total = info.pages or info.doc_pages
  if total and total > 0 then
    self.queue:recordProgress(info, page / total)
  end
end

-- Progress while Hardcover cannot be reached, following the same tracking settings as usual
function HardcoverApp:recordOfflineProgress(page)
  local file = self.ui.document.file

  if not self.settings:progressEnabled(file) then
    return
  end

  -- Offline, the book's real status on Hardcover is unknown (it may have changed since it was last
  -- seen), so progress is always kept. When it is sent, the queue only applies it to a read that
  -- is actually in progress on Hardcover and otherwise sends nothing.

  local document_pages = self.ui.document:getPageCount()
  local remote_pages = self.settings:pages()
  local percent = self.page_mapper:getRemotePagePercent(page, document_pages, remote_pages)

  if self.settings:trackByProgress() then
    if not self.state.last_page then
      return
    end

    local interval = self.settings:trackPercentageInterval()
    local previous = self.page_mapper:getRemotePagePercent(self.state.last_page, document_pages, remote_pages)
    if math.floor(previous * 100 / interval) ~= math.floor(percent * 100 / interval) then
      self:queueProgressPercent(file, percent)
    end
  else
    -- time based: keep the newest value and write it at most once per tracking period
    self.state.offline_pending = percent
    local every = math.max(self.settings:trackFrequency(), 1) * 60
    if not self.state.offline_written_at or os.time() - self.state.offline_written_at >= every then
      self:flushOfflineProgress()
    end
  end
end

-- Tells the reader once per opened book that progress is being kept for later
function HardcoverApp:announceOffline()
  if self.state.offline_announced or not self:offlineRecording() then
    return
  end

  self.state.offline_announced = true
  sending_announced = false

  local text = _("Hardcover not reachable. Progress will be saved and sent later")
  if not Api:hasCredentials() then
    text = Api:hasKeyFile() and _("API key invalid. Updates will be saved and sent later")
        or _("Not signed in. Updates will be saved and sent later")
  end
  if Api:hasCredentials() and not self.settings:bookLinked() and NetworkManager:isConnected() then
    text = _("This book is not linked to Hardcover. Progress will be saved and sent once it is linked")
  end
  self:notify(text)
end

function HardcoverApp:flushOfflineProgress()
  local percent = self.state.offline_pending
  if not percent or not self.ui.document then
    return
  end

  self.state.offline_pending = nil
  self.state.offline_written_at = os.time()
  self:queueProgressPercent(self.ui.document.file, percent)
end

function HardcoverApp:scheduleQueueSync(delay)
  if self.queue:count() == 0 or self.queue.running or not Api:hasCredentials() then
    return
  end

  UIManager:unschedule(self._auto_queue_sync)
  UIManager:scheduleIn(delay or 6, self._auto_queue_sync)
end

function HardcoverApp:showQueueSummary(summary, manual)
  local parts = {}
  if #summary.done > 0 then
    table.insert(parts, ("Synced to Hardcover: %d"):format(#summary.done))
  end
  if #summary.failed > 0 then
    table.insert(parts, ("%d could not be sent (see Sync Log)"):format(#summary.failed))
  end
  if summary.skipped and #summary.skipped > 0 then
    table.insert(parts, ("Hardcover already had newer progress: %d left unchanged"):format(#summary.skipped))
  end

  if #parts == 0 then
    if not manual then
      return
    end
    table.insert(parts, summary.waiting > 0 and _("Still waiting for a connection") or _("Nothing to send"))
  end

  self:notify(table.concat(parts, ". "), 4)
end

-- Asks, one book at a time, whether to keep trying updates that Hardcover keeps refusing
function HardcoverApp:askAboutFailedUpdates(prompts, index)
  index = index or 1
  local item = prompts and prompts[index]
  if not item then
    return
  end

  local continue = function()
    UIManager:nextTick(function()
      self:askAboutFailedUpdates(prompts, index + 1)
    end)
  end

  self.dialog_manager:confirm({
    text = T(_("%1\n\ncould not be sent to Hardcover after %2 tries:\n%3\n\nRemove it from the queued updates?"),
      item.title, item.failures, item.reason),
    ok_text = _("Remove"),
    cancel_text = _("Keep trying"),
    dismissable = false,
    ok_callback = function()
      self.queue:discard(item.file, item.title, item.reason)
      continue()
    end,
    cancel_callback = continue,
  })
end

-- A book that is open has an out of date Hardcover status once its queue entry was sent
function HardcoverApp:afterQueueSync(summary)
  if #summary.done == 0 or not self.ui.document or not self.settings:syncEnabled() then
    return
  end

  self.state.book_status = {}
  self.state.status_loaded = false
  self.state.read_cache_started = false
  if self.settings:bookLinked() then
    self:registerHighlight()
  end
  UIManager:scheduleIn(2, self.startReadCache, self)
end

-- Sends everything in the queue. manual: asked for from the menu (offers to switch wifi on, and always
-- reports back); otherwise only runs if a connection is already there and stays quiet unless
-- something was sent.
function HardcoverApp:syncQueueNow(manual)
  if not Api:hasCredentials() then
    if manual then
      UIManager:show(InfoMessage:new {
        text = _("Sign in to Hardcover, or configure your API key, to send the queued updates."),
      })
    end
    return
  end

  if self.queue:count() == 0 then
    if manual then
      UIManager:show(Notification:new { text = _("No queued updates") })
    end
    return
  end

  if self.queue.running then
    if manual then
      UIManager:show(Notification:new { text = _("Already sending queued updates") })
    end
    return
  end

  local wifi_started = false
  local run = function()
    if not sending_announced then
      sending_announced = true
      self:notify(_("Sending queued updates to Hardcover..."), 4)
    end
    self.queue:sync({
      manual = manual,
      on_done = function(summary)
        if summary.waiting == 0 then
          sending_announced = false
        end
        if wifi_started then
          self.wifi:wifiDisableSilent()
        end
        self:showQueueSummary(summary, manual)
        self:afterQueueSync(summary)
        self:askAboutFailedUpdates(summary.prompts)

        -- connected but Hardcover did not answer (e.g. the network is still settling after wifi
        -- came back): try again in a couple of minutes, a few times, instead of waiting for the
        -- next restart
        if #summary.done > 0 then
          self.state.queue_retries = 0
        elseif summary.waiting > 0 and NetworkManager:isConnected() then
          self.state.queue_retries = (self.state.queue_retries or 0) + 1
          if self.state.queue_retries <= 5 then
            logger.warn(("HARDCOVER queue: Hardcover did not answer, trying again in 2 minutes (%d of 5)"):format(
              self.state.queue_retries))
            self:scheduleQueueSync(120)
          end
        end
      end,
    })
  end

  if NetworkManager:isConnected() then
    run()
  elseif manual then
    self.wifi:wifiPrompt(function(enabled)
      wifi_started = enabled == true
      run()
    end)
  end
end

-- ---------------------------------------------------------------------------------------
-- Mark as Currently Reading
-- ---------------------------------------------------------------------------------------

function HardcoverApp:maybeStartReading()
  local mode = self.settings:readingModeFor(self.ui.document and self.ui.document.file)
  if mode == SETTING.AUTO_MODE.OFF then
    return
  end

  if not (self.ui.document and self.state.page) then
    return
  end

  local document_pages = self.ui.document:getPageCount()
  if not document_pages or document_pages < 1 then
    return
  end

  -- "current" and "previous" are percentages of the book, or minutes read, depending on the setting
  local threshold, current_percent, previous_percent
  if self.settings:readingAfterByMinutes() then
    threshold = self.settings:readingAfterMinutes()
    current_percent = (self.state.read_seconds or 0) / 60
    previous_percent = current_percent - (self.state.read_seconds_added or 0) / 60
  else
    threshold = self.settings:readingAfterPercent()
    current_percent = self.state.page * 100 / document_pages
    previous_percent = self.state.last_page and self.state.last_page * 100 / document_pages
  end
  local crossed = false
  if previous_percent then
    crossed = previous_percent < threshold and current_percent >= threshold
  end

  local file = self.ui.document.file
  local offline = self:offlineRecording()

  -- Hardcover status not known yet: remember a crossing so it is not lost
  -- A book that is not linked (and cannot be linked automatically) never gets a status from
  -- Hardcover, so waiting for one would mean never asking; it is handled like an offline book.
  local unlinked = self.settings:syncEnabled() and not self.settings:bookLinked()
    and (not self.settings:autolinkEnabled() or self.state.autolink_failed == true)

  if not self.state.status_loaded and not offline and not unlinked then
    if crossed then
      self.state.crossed_before_load = true
    elseif current_percent < threshold then
      self.state.crossed_before_load = false
    end
    return
  end

  -- status has now loaded: honour a crossing that happened while it was loading
  if self.state.crossed_before_load then
    if current_percent >= threshold then
      crossed = true
    end
    self.state.crossed_before_load = false
  end

  -- A book that was marked as Currently Reading earlier, and whose start has been sent, but which
  -- Hardcover now shows with no status (e.g. it was reset or removed there) is offered again.
  -- Only judged with a linked book and a real answer from Hardcover, never while offline.
  if not offline and self.state.status_loaded and self.settings:bookLinked()
      and (self.state.start_in_flight_until or 0) < os.time()
      and self.settings:readBookSetting(file, "start_prompted")
      and self.settings:readBookSetting(file, "start_sent")
      and not self.queue:hasStarted(file) then
    local known_status = self.state.book_status.status_id
    if known_status == nil or known_status == HARDCOVER.STATUS.TO_READ then
      logger.info("HARDCOVER prompt-check: Hardcover no longer shows this book as started, offering it again")
      self.settings:updateBookSetting(file, { _delete = { "start_prompted", "start_sent" } })
    end
  end

  -- a book that has never been offered "Currently Reading" is offered once as soon as it is
  -- seen at or past the threshold (e.g. it was opened offline and only linked on a later visit)
  if not crossed and current_percent >= threshold and not self.settings:readBookSetting(file, "start_prompted") then
    crossed = true
  end

  if not crossed then
    return
  end

  -- offline the status is unknown, so it is never assumed to be "reading" (sending the start later
  -- changes nothing for a book that is already being read)
  local status_id = self.state.book_status.status_id
  if offline then
    status_id = nil
  end

  -- already reading, or just finished in this session (e.g. flicking back through the last chapters)
  if self.state.finished_in_session or status_id == HARDCOVER.STATUS.READING then
    return
  end

  -- remember that this book has now been offered, whatever the answer
  self.settings:updateBookSetting(file, { start_prompted = true })

  if mode == SETTING.AUTO_MODE.ASK then
    self.dialog_manager:confirm({
      text = _("Mark this book as Currently Reading on Hardcover?"),
      dismissable = false, -- a stray tap outside the box no longer closes it
      ok_text = _("Yes"),
      cancel_text = _("No"),
      other_buttons = {
        {
          {
            text = _("Never for this book"),
            callback = function()
              UIManager:nextTick(function()
                self:confirmNeverSync(file)
              end)
            end,
          },
        },
      },
      ok_callback = function()
        self:startReading(file)
      end,
    })
  else
    -- scheduled so the page turn is not held up by the network request
    UIManager:scheduleIn(1, function()
      Trapper:wrap(function()
        self:startReading(file)
      end)
    end)
  end
end

-- "Never for this book": asks once more, then switches every kind of update off for the book and
-- throws away anything of it still waiting in the queue
function HardcoverApp:confirmNeverSync(file)
  self.dialog_manager:confirm({
    text = _("Are you sure you want to disable all updates to Hardcover for this book?\n\nThis will clear all Hardcover sync updates pending for this title."),
    ok_text = _("Yes"),
    cancel_text = _("No"),
    ok_callback = function()
      self.settings:updateBookSetting(file, {
        rule_progress = "never",
        rule_reading = "never",
        rule_read = "never",
        rule_rating = "never",
      })
      self.queue:dropParts(file, "all")
      UIManager:show(Notification:new {
        text = _("Hardcover updates are off for this book. Change this under Never sync this book"),
        timeout = 4,
      })
    end,
  })
end

function HardcoverApp:startReading(file)
  -- the book may have been closed while the prompt or timer was pending
  if not (self.ui.document and self.ui.document.file == file) then
    return
  end

  -- a second start while this one is still being sent would mark the book twice
  if (self.state.start_in_flight_until or 0) >= os.time() then
    return
  end
  self.state.start_in_flight_until = os.time() + 30

  -- remember that a start was really sent (or queued), so a later reset on Hardcover is noticed
  self.settings:updateBookSetting(file, { start_sent = true })

  -- not linked to a Hardcover book yet: it can only be kept for later
  if not self.settings:bookLinked() then
    self:queueStarted(file)
    return
  end

  self:sendOrQueue(function()
    local previous_status = self.state.book_status
    self.cache:updateBookStatus(file, HARDCOVER.STATUS.READING, previous_status.privacy_setting_id)

    if self.state.book_status.id then
      self:rememberStatus(file, HARDCOVER.STATUS.READING)
      self:notify(_("Marked as Currently Reading on Hardcover"))

      if self.ui.document and self.ui.document.file == file and self.settings:progressEnabled(file) then
        self:updatePageNow()
      end
    else
      -- the update failed: put the previous status back rather than leaving it empty
      self.state.book_status = previous_status
      if NetworkManager:isConnected() then
        UIManager:show(InfoMessage:new {
          text = _("Could not update book status on Hardcover. It will be tried again later"),
          icon = "notice-warning",
          timeout = 3,
        })
      end
      self:queueStarted(file)
    end
  end, function()
    self:queueStarted(file)
  end)
end

function HardcoverApp:initializePageUpdate()
  local track_frequency = math.max(math.min(self.settings:trackFrequency(), 120), 1) * 60

  HardcoverApp._throttledHandlePageUpdate, HardcoverApp._cancelPageUpdate = throttle(
    track_frequency,
    HardcoverApp._handlePageUpdate
  )

  HardcoverApp.onPageUpdate, HardcoverApp._cancelPageUpdateEvent = debounce(2, HardcoverApp.pageUpdateEvent)
end

-- Adds the time since the previous page turn to the reading time of this book
function HardcoverApp:countReadingTime()
  local now = os.time()
  local gap = self.state.last_turn_time and (now - self.state.last_turn_time) or 0
  gap = math.max(0, math.min(gap, MAX_READING_GAP))
  self.state.last_turn_time = now
  self.state.read_seconds = (self.state.read_seconds or 0) + gap
  self.state.read_seconds_added = gap
end

-- Reading time is kept per book so it survives closing the book
function HardcoverApp:saveReadingTime()
  local file = self.ui.document and self.ui.document.file
  if file and (self.state.read_seconds or 0) > 0 and self.settings:readingAfterByMinutes()
      and not self.settings:readBookSetting(file, "start_prompted") then
    self.settings:updateBookSetting(file, { read_seconds = self.state.read_seconds })
  end
end

function HardcoverApp:pageUpdateEvent(page)
  self.state.last_page = self.state.page
  self.state.page = page
  self:countReadingTime()

  self:maybeStartReading()

  if self:offlineRecording() then
    self:recordOfflineProgress(page)
    return
  end

  if not (self.state.book_status.id and self.settings:progressEnabled(self.ui.document.file)) then
    return
  end
  --logger.warn("HARDCOVER page update event pending")
  local document_pages = self.ui.document:getPageCount()
  local remote_pages = self.settings:pages()

  if self.settings:trackByTime() then
    local mapped_page = self.page_mapper:getMappedPage(page, document_pages, remote_pages)

    self:_throttledHandlePageUpdate(self.ui.document.file, mapped_page)
    self.page_update_pending = true
  elseif self.settings:trackByProgress() and self.state.last_page then
    local percent_interval = self.settings:trackPercentageInterval()

    local previous_percent = self.page_mapper:getRemotePagePercent(
      self.state.last_page,
      document_pages,
      remote_pages
    )

    local current_percent, mapped_page = self.page_mapper:getRemotePagePercent(
      self.state.page,
      document_pages,
      remote_pages
    )

    local last_compare = math.floor(previous_percent * 100 / percent_interval)
    local current_compare = math.floor(current_percent * 100 / percent_interval)

    if last_compare ~= current_compare then
      self:_handlePageUpdate(self.ui.document.file, mapped_page)
    end
  end
end

function HardcoverApp:onPosUpdate(_, page)
  if self.state.process_page_turns then
    self:pageUpdateEvent(page)
  end
end

function HardcoverApp:onUpdatePos()
  self.page_mapper:cachePageMap()
end

function HardcoverApp:onReaderReady()
  --logger.warn("HARDCOVER on ready")

  self.page_mapper:cachePageMap()
  self:registerHighlight()
  self.state.page = self.ui:getCurrentPage()
  self.state.read_seconds = self.ui.document
      and self.settings:readBookSetting(self.ui.document.file, "read_seconds") or 0
  self.state.read_seconds_added = 0
  self.state.last_turn_time = nil
  self:wrapEndOfBook()
  self.state.reading_mode_last = self.ui.document
      and self.settings:readingModeFor(self.ui.document.file) or nil

  if self.ui.document and (self.settings:syncEnabled() or (not self.settings:bookLinked() and self.settings:autolinkEnabled())) then
    UIManager:scheduleIn(2, self.startReadCache, self)
  end
end

function HardcoverApp:cancelPendingUpdates()
  if self._cancelPageUpdate then
    self:_cancelPageUpdate()
  end

  if self._cancelPageUpdateEvent then
    self:_cancelPageUpdateEvent()
  end

  self.page_update_pending = false
end

function HardcoverApp:onDocumentClose()
  self:saveReadingTime()
  UIManager:unschedule(self.startCacheRead)
  UIManager:unschedule(self._offline_watchdog)
  self:flushOfflineProgress()
  self.state.offline_pending = nil
  self.state.offline_written_at = nil
  self.state.status_unavailable = false
  self.state.offline_announced = false
  self.state.process_page_turns = false
  self.state.status_loaded = false
  self.state.finished_in_session = false
  self.state.crossed_before_load = false
  self.state.autolink_failed = false
  self.state.end_prompt_open = false
  self.state.end_marked = false

  self:cancelPendingUpdates()
  self.state.read_cache_started = false

  if not self.state.book_status.id and not self.settings:syncEnabled() then
    return
  end

  if self.page_update_pending then
    self:updatePageNow()
  end

  self.process_page_turns = false
  self.page_update_pending = false
  self.state.book_status = {}
  self.state.page_map = nil
end

function HardcoverApp:onSuspend()
  self:saveReadingTime()
  self.state.last_turn_time = nil
  self:flushOfflineProgress()
  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false
end

function HardcoverApp:updatePageNow(callback)
  local mapped_page = self.page_mapper:getMappedPage(
    self.state.page,
    self.ui.document:getPageCount(),
    self.settings:pages()
  )
  self:_handlePageUpdate(self.ui.document.file, mapped_page, true, callback)
end

function HardcoverApp:onNetworkDisconnecting()
  self:cancelPendingUpdates()

  Scheduler:clear()
  self.state.read_cache_started = false

  if self.page_update_pending and self.ui.document and self.state.book_status.id and self.settings:syncEnabled() and self.settings:trackByTime() then
    self:updatePageNow()
  end
  self.page_update_pending = false
end

function HardcoverApp:onNetworkConnected()
  self.state.status_unavailable = false

  if self.ui.document and self.settings:syncEnabled() and not self.state.read_cache_started then
    --logger.warn("HARDCOVER on connected", self.state.read_cache_started)

    self:startReadCache()
  end

  self:scheduleQueueSync(6)
end

-- KOReader tells every plugin when the end of a document is reached. Asking whether to mark the
-- book Read is done by endOfBookFlow() (reached through wrapEndOfBook()); here the book is only
-- remembered as finished, so flicking back through the last pages does not start a new read.
function HardcoverApp:onEndOfBook()
  self.state.finished_in_session = true
end

-- ---------------------------------------------------------------------------------------
-- Mark as Read at end of book (Off / Ask first / Automatic)
-- ---------------------------------------------------------------------------------------

-- True when the end-of-book question should be handled by this plugin for the open book
function HardcoverApp:endPromptEligible()
  if not self.ui.document then
    return false
  end

  if self.settings:finishingModeFor(self.ui.document.file) == SETTING.AUTO_MODE.OFF then
    return false
  end

  if not (self:syncFileUpdates(self.ui.document.file) or self:offlineRecording()) then
    return false
  end

  -- already marked as Read from here this session, or Hardcover already says Read
  if self.state.end_marked then
    return false
  end
  if self.state.status_loaded and self.state.book_status.status_id == HARDCOVER.STATUS.FINISHED then
    return false
  end
  return true
end

-- Put our question in front of KOReader's own end-of-book handling. KOReader's handling still
-- runs afterwards, exactly as you have configured it (pop-up, next file, file browser...).
function HardcoverApp:wrapEndOfBook()
  local status = self.ui.status
  if not status or status._hardcover_wrapped or type(status.onEndOfBook) ~= "function" then
    return
  end
  status._hardcover_wrapped = true

  local original = status.onEndOfBook
  local app = self
  status.onEndOfBook = function(status_self, ...)
    if not app:endPromptEligible() then
      return original(status_self, ...)
    end

    app.state.finished_in_session = true
    app:endOfBookFlow(function()
      original(status_self)
    end)
  end
end

function HardcoverApp:endOfBookFlow(proceed)
  if self.state.end_prompt_open then
    return
  end

  local file = self.ui.document.file
  local mode = self.settings:finishingModeFor(file)
  local proceeded = false

  -- a star rating is offered after the book is marked Read (after "Yes", or straight after an
  -- automatic Read) if it is switched on globally or for this book, unless this book is set to "never"
  local rating_rule = self.settings:bookRule(file, "rating")
  local wants_rating = rating_rule == "ask" or (rating_rule == nil and self.settings:askRating())

  -- hand over to KOReader's own end-of-book handling (once), after any dialog of ours has closed
  local continue = function()
    if proceeded then
      return
    end
    proceeded = true
    UIManager:nextTick(function()
      if self.ui.document and self.ui.document.file == file then
        proceed()
      end
    end)
  end

  local mark_and_continue = function()
    self:finishBook(file)
    continue()
  end

  if mode == SETTING.AUTO_MODE.AUTO then
    if wants_rating then
      UIManager:nextTick(function()
        self:finishBook(file)
        self:askRatingForBook(file, continue)
      end)
    else
      UIManager:nextTick(mark_and_continue)
    end
  else
    self.state.end_prompt_open = true
    self.dialog_manager:confirm({
      text = _("Mark this book as Read on Hardcover?"),
      dismissable = false,
      ok_text = _("Yes"),
      cancel_text = _("No"),
      ok_callback = function()
        self.state.end_prompt_open = false
        if wants_rating then
          self:finishBook(file)
          UIManager:nextTick(function()
            self:askRatingForBook(file, continue)
          end)
        else
          mark_and_continue()
        end
      end,
      cancel_callback = function()
        self.state.end_prompt_open = false
        continue()
      end,
    })
  end
end

-- Asks for a star rating just after a book was marked Read. continue() runs once it is closed
-- (saved or skipped). The rating follows the same rules as everything else: sent straight away
-- when the book is linked and online, otherwise kept in the queue until it can be.
function HardcoverApp:askRatingForBook(file, continue)
  local done = false
  local finish = function()
    if done then
      return
    end
    done = true
    continue()
  end

  UIManager:show(SpinWidget:new {
    title_text = _("Rate this book"),
    info_text = _("Stars (0 = no rating)"),
    value = 2.5,
    wrap = true,
    value_min = 0,
    value_max = 5,
    value_step = 0.5,
    value_hold_step = 1,
    precision = "%.1f",
    ok_always_enabled = true,
    ok_text = _("Save"),
    cancel_text = _("Skip"),
    callback = function(spin)
      local ok, err = pcall(self.saveRating, self, file, spin.value)
      if not ok then
        logger.warn("HARDCOVER rating: could not save: " .. tostring(err))
      end
      finish()
    end,
    cancel_callback = finish,
    close_callback = finish,
  })
end

function HardcoverApp:saveRating(file, rating)
  if type(rating) ~= "number" or rating <= 0 then
    return
  end

  local entry = self.queue:entries()[file]
  local linked = self.settings:readBookSetting(file, "book_id") ~= nil
  local sent = false

  -- a finish that is still waiting in the queue must go first, so the rating waits with it
  if linked and not (entry and entry.finished_at) and NetworkManager:isConnected()
      and self.state.book_status and self.state.book_status.id then
    local result = Api:updateRating(self.state.book_status.id, rating)
    if result then
      self.state.book_status = result
      sent = true
      self:notify(_("Rating saved on Hardcover"))
    end
  end

  if not sent then
    local info = self:queueBookInfo(file)
    if info then
      self.queue:recordRating(info, rating)
      self:notifyQueued()
      if NetworkManager:isConnected() then
        self:scheduleQueueSync(3)
      end
    end
  end
end

-- Marks the open book as finished in KOReader and as Read on Hardcover (dated today)
function HardcoverApp:finishBook(file)
  -- KOReader's own status, the same as its "Mark as finished" button
  local status = self.ui.status
  if status and self.ui.doc_settings then
    local summary = self.ui.doc_settings:readSetting("summary")
    if summary and summary.status ~= "complete" then
      local ok, err = pcall(status.markBook, status, true)
      if not ok then
        logger.warn("HARDCOVER end-of-book: could not mark book finished in KOReader: " .. tostring(err))
      end
    end
  end

  if not self.settings:readBookSetting(file, "book_id") then
    self:queueFinished(file)
    return
  end

  self:sendOrQueue(function()
    local previous_status = self.state.book_status
    local book_id = self.settings:readBookSetting(file, "book_id")
    local user_book = Api:findUserBook(book_id, User:getId()) or {}
    self.cache:updateBookStatus(file, HARDCOVER.STATUS.FINISHED, user_book.privacy_setting_id)

    if self.state.book_status.id then
      self.state.end_marked = true
      self:rememberStatus(file, HARDCOVER.STATUS.FINISHED)
      self:notify(_("Marked as Read on Hardcover"))
    else
      -- the update failed: put the previous status back rather than leaving it empty
      self.state.book_status = previous_status
      if NetworkManager:isConnected() then
        UIManager:show(InfoMessage:new {
          text = _("Could not mark book as Read on Hardcover. It will be tried again later"),
          icon = "notice-warning",
          timeout = 3,
        })
      end
      self:queueFinished(file)
    end
  end, function()
    self:queueFinished(file)
  end)
end

function HardcoverApp:syncFileUpdates(filename)
  return self.settings:readBookSetting(filename, "book_id") and self.settings:fileSyncEnabled(filename)
end

function HardcoverApp:startReadCache()
  --logger.warn("HARDCOVER start read cache")
  if self.state.read_cache_started then
    --logger.warn("HARDCOVER Cache already started")
    return
  end

  if not self.ui.document then
    --logger.warn("HARDCOVER read cache fired outside of document")
    return
  end

  -- Neither signed in nor an API key: treated like being offline. Progress, start and finish are
  -- kept in the queue, and sent once the user has signed in.
  if not Api:hasCredentials() then
    if self.settings:syncEnabled() then
      local first_time = not self.state.status_unavailable
      self.state.status_unavailable = true
      self:announceOffline()
      if first_time then
        UIManager:nextTick(function()
          self:maybeStartReading()
        end)
      end
    end
    return
  end

  self.state.read_cache_started = true
  local cancel

  local restart = function(delay)
    --logger.warn("HARDCOVER restart cache fetch")
    delay = delay or 60
    cancel()
    self.state.read_cache_started = false
    UIManager:scheduleIn(delay, self.startReadCache, self)
  end

  cancel = Scheduler:withRetries(6, 1, function(success, fail)
      Trapper:wrap(function()
        if not self.ui.document then
          -- fail, but cancel retries
          return success()
        end
        local book_settings = self.settings:readBookSettings(self.ui.document.file) or {}
        --logger.warn("HARDCOVER", book_settings)
        if book_settings.book_id then
          if self.state.book_status.id then
            return success()
          else
            if not NetworkManager:isWifiOn() then
              -- no network: carry on from the offline queue, and load the status as soon as a
              -- network appears
              self.state.status_unavailable = true
              self.state.read_cache_started = false
              logger.info("HARDCOVER read-cache: offline, recording to the queue until a network is available")
              self:announceOffline()
              return
            end
            UIManager:unschedule(self._offline_watchdog)
            UIManager:scheduleIn(75, self._offline_watchdog)

            -- Hardcover could not be reached: carry on from the offline queue right away (not
            -- after the watchdog) and try again a little later
            local goOffline = function(why)
              local first_time = not self.state.status_unavailable
              self.state.status_unavailable = true
              logger.info("HARDCOVER read-cache: Hardcover not reachable (" .. why .. "), recording to the queue")
              self:announceOffline()
              if first_time then
                UIManager:nextTick(function()
                  self:maybeStartReading()
                end)
              end
              return restart(60)
            end

            if not NetworkManager:isConnected() then
              return goOffline("not connected")
            end

            local err = self.cache:cacheUserBook()
            if err and err.errors then
              -- Hardcover answered but refused: a real error, not a missing network
              return fail(err)
            elseif err then
              -- the request never completed (no internet, cancelled or timed out)
              return goOffline("request failed")
            end

            success()
          end
        else
          -- Not linked yet. With no network, or with auto-linking switched off, the book's
          -- details and progress are kept in the queue; the update is sent once the book is
          -- linked (by auto-link when online, or by hand from the Hardcover menu)
          if self.settings:syncEnabled() then
            local offline_now = not NetworkManager:isConnected()
            if offline_now or not self.settings:autolinkEnabled() then
              self.state.status_unavailable = true
              logger.info("HARDCOVER read-cache: book not linked, details kept in the queue")
              self:announceOffline()
              if offline_now and NetworkManager:isWifiOn() then
                return restart(60)
              end
              self.state.read_cache_started = false
              return
            end
          end

          local transient = self.hardcover:tryAutolink()
          if not transient and not self.settings:bookLinked() and not self.state.autolink_failed then
            -- nothing could be linked: from now on this book is treated as unlinked, and the
            -- Currently Reading question is not held back waiting for a status
            self.state.autolink_failed = true
            if self.settings:autolinkEnabled() then
              self:notify(_("No suitable automatic link found; manual linking required"))
            end
            UIManager:nextTick(function()
              self:maybeStartReading()
            end)
          end
          if self.settings:bookLinked() and self.settings:syncEnabled() then 
		    return restart(2) 
		  end
          if transient then return fail({ completed = false })
          end
        end
      end)
    end,

    function()
      if self.settings:syncEnabled() then
        --logger.warn("HARDCOVER enabling page turns")

        self.state.process_page_turns = true
        self.state.status_loaded = true
        self.state.status_unavailable = false
        UIManager:unschedule(self._offline_watchdog)
        if self.ui.document then
          self:rememberStatus(self.ui.document.file, self.state.book_status.status_id)
        end
        self:maybeStartReading()
        self:scheduleQueueSync(4)
      end
    end,

    function()
      if NetworkManager:isConnected() then
        UIManager:show(Notification:new {
          text = _("Failed to fetch book information from Hardcover"),
        })
      end
    end)
end

function HardcoverApp:registerHighlight()
  -- the file browser has no highlight module
  if not self.ui or not self.ui.highlight then
    return
  end
  self.ui.highlight:removeFromHighlightDialog(HIGHLIGHT_MENU_NAME)

  if self.enabled and self.settings:bookLinked() then
    self.ui.highlight:addToHighlightDialog(HIGHLIGHT_MENU_NAME, function(this)
      return {
        text_func = function()
          return _("Hardcover quote")
        end,
        callback = function()
          local selected_text = this.selected_text
          local raw_page = selected_text.pos0.page
          if not raw_page then
            raw_page = self.view.document:getPageFromXPointer(selected_text.pos0)
          end
          -- open journal dialog
          self:onHardcoverNote({
            text = selected_text.text,
            page_number = raw_page,
            note_type = "quote"
          })

          this:onClose()
        end,
      }
    end)
  end
end

function HardcoverApp:addToMainMenu(menu_items)
  menu_items.hardcover = self.menu:mainMenu()
end

return HardcoverApp
