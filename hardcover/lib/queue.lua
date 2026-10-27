-- Offline queue: remembers what happened while Hardcover could not be reached (a book was
-- started, how far you got, that you finished it) and sends it later, one book at a time.
--
-- Stored in its own file (hardcoversync_queue.lua in KOReader's settings folder), one entry per
-- book file, so it survives restarts and an interrupted sync simply carries on next time.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local util = require("util")

local NetworkManager = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local Api = require("hardcover/lib/hardcover_api")
local Book = require("hardcover/lib/book")
local User = require("hardcover/lib/user")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local SETTING = require("hardcover/lib/constants/settings")

local QUEUE_FILE = "hardcoversync_queue.lua"
local LOG_FILE = "hardcoversync_log.lua"
local LOG_DAYS = 7

local Queue = {}
Queue.__index = Queue

local function today()
  return os.date("%Y-%m-%d")
end

local function isFinished(read)
  return type(read.finished_at) == "string"
end

-- "A sync is in progress" is kept on the class itself, not on each copy of the plugin: the file
-- browser and the reader each have their own copy, and both must see the same flag, otherwise two
-- syncs run at once and send every book twice
Queue.running = false

function Queue:new(o)
  o = o or {}
  return setmetatable(o, self)
end

-- The file is re-read every time, so the file browser and the reader never disagree
function Queue:_open()
  return LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. QUEUE_FILE)
end

function Queue:entries()
  return self:_open():readSetting("entries") or {}
end

function Queue:count()
  local n = 0
  for _ in pairs(self:entries()) do
    n = n + 1
  end
  return n
end

function Queue:hasStarted(file)
  local entry = self:entries()[file]
  return entry ~= nil and entry.started_at ~= nil
end

-- A book whose queued update is thrown away may be offered "Currently Reading" again
function Queue:_forgetPrompted(file)
  if not (self.settings and self.settings.settings) then
    return
  end
  local store = self.settings.settings
  local books = store:readSetting("books")
  if books and books[file] and books[file].start_prompted then
    books[file].start_prompted = nil
    store:flush()
  end
end

function Queue:clear()
  for file in pairs(self:entries()) do
    pcall(self._forgetPrompted, self, file)
  end
  local store = self:_open()
  store:saveSetting("entries", {})
  store:flush()
end

-- ------------------------------------------------------------------------------------------
-- Sync log: what was sent to Hardcover (or refused) over the last 7 days (stored oldest first,
-- shown newest first).
-- One short row per book: { time sent, 1 sent / 0 refused, text }
-- ------------------------------------------------------------------------------------------

function Queue:addLog(ok, text)
  local store = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. LOG_FILE)
  local now = os.time()
  local cutoff = now - LOG_DAYS * 86400

  local rows = {}
  for _, row in ipairs(store:readSetting("rows") or {}) do
    if row[1] >= cutoff then
      table.insert(rows, row)
    end
  end
  table.insert(rows, { now, ok and 1 or 0, text })

  store:saveSetting("rows", rows)
  store:flush()
end

-- The log as text for display, or nil when there is nothing in it
function Queue:logText()
  local store = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. LOG_FILE)
  local cutoff = os.time() - LOG_DAYS * 86400
  local lines = {}
  local rows = store:readSetting("rows") or {}
  -- newest first
  for i = #rows, 1, -1 do
    local row = rows[i]
    if row[1] >= cutoff then
      local when = os.date("%Y-%m-%d %H:%M", row[1])
      if row[2] == 1 then
        table.insert(lines, when .. "  " .. row[3])
      else
        table.insert(lines, when .. "  NOT SENT: " .. row[3])
      end
    end
  end
  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n\n")
end

-- info: { file, book_id, edition_id, pages, doc_pages, title, local_title }
function Queue:_update(info, mutate)
  if not (info and info.file and (info.book_id or info.snapshot)) then
    return
  end

  local store = self:_open()
  local entries = store:readSetting("entries") or {}

  local entry = entries[info.file]
  if not entry then
    entry = { queued_at = os.time(), failures = 0 }
    entries[info.file] = entry
  end

  if info.book_id then
    entry.book_id = info.book_id
    entry.edition_id = info.edition_id
    entry.pages = info.pages
    entry.title = info.title
  elseif not entry.book_id then
    -- not linked to a Hardcover book yet: keep the details needed to find it once online
    entry.snapshot = info.snapshot
  end
  entry.doc_pages = info.doc_pages or entry.doc_pages
  entry.local_title = info.local_title or entry.local_title

  mutate(entry)

  store:saveSetting("entries", entries)
  store:flush()
end

function Queue:recordStarted(info)
  self:_update(info, function(entry)
    if not entry.started_at then
      entry.started_at = today()
    end
  end)
end

-- One progress value per book: the newest overwrites the older one
function Queue:recordProgress(info, percent)
  if not percent then
    return
  end
  self:_update(info, function(entry)
    if not entry.finished_at then
      entry.percent = math.max(0, math.min(1, percent))
    end
  end)
end

-- Which kinds of update are waiting for one book: { progress, reading, read, rating } (booleans)
function Queue:pendingParts(file)
  local entry = self:entries()[file]
  local parts = {}
  if not entry then
    return parts
  end
  parts.reading = entry.started_at ~= nil
  parts.read = entry.finished_at ~= nil
  parts.progress = entry.percent ~= nil and entry.finished_at == nil
  parts.rating = entry.rating ~= nil
  return parts
end

-- Throws away the waiting updates of the given kinds for one book ("all" empties its entry).
-- Used when a book is set to "Never sync".
function Queue:dropParts(file, which)
  local entry = self:entries()[file]
  if not entry then
    return
  end

  if which == "all" then
    self:_remove(file)
    if entry.started_at or entry.finished_at then
      pcall(self._forgetPrompted, self, file)
    end
    return
  end

  local store = self:_open()
  local entries = store:readSetting("entries") or {}
  local current = entries[file]
  if not current then
    return
  end

  if which == "progress" then
    if not current.finished_at then
      current.percent = nil
    end
  elseif which == "reading" then
    -- the start date is still needed to date a finish that is waiting too
    if not current.finished_at then
      current.started_at = nil
    end
  elseif which == "read" then
    current.finished_at = nil
    if current.percent == 1 then
      current.percent = nil
    end
  elseif which == "rating" then
    current.rating = nil
  end

  local anything_left = current.started_at or current.finished_at or current.percent or current.rating
  if anything_left then
    store:saveSetting("entries", entries)
    store:flush()
  else
    self:_remove(file)
  end
end

-- The star rating given when the book was marked Read (1 to 5, halves allowed)
function Queue:recordRating(info, rating)
  if type(rating) ~= "number" or rating <= 0 then
    return
  end
  self:_update(info, function(entry)
    entry.rating = math.min(5, rating)
  end)
end

function Queue:recordFinished(info)
  self:_update(info, function(entry)
    if not entry.finished_at then
      entry.finished_at = today()
    end
    entry.percent = 1
  end)
end

function Queue:_markFailed(file, message)
  local store = self:_open()
  local entries = store:readSetting("entries") or {}
  local entry = entries[file]
  if entry then
    entry.failures = (entry.failures or 0) + 1
    entry.last_error = message
    store:saveSetting("entries", entries)
    store:flush()
  end
end

-- how many failed attempts before asking what to do (0 = never ask)
Queue.RETRY_KEY = "queue_retry_limit"

function Queue:retryLimit()
  local value = self.settings and self.settings:readSetting(Queue.RETRY_KEY)
  if type(value) ~= "number" then
    return 3
  end
  return value
end

-- Takes an update out of the queue at the user's request
function Queue:discard(file, title, reason)
  self:_remove(file)
  pcall(self._forgetPrompted, self, file)
  pcall(self.addLog, self, false, tostring(title) .. ": removed from the queue (" .. tostring(reason) .. ")")
end

function Queue:_patch(file, fields, clear)
  local store = self:_open()
  local entries = store:readSetting("entries") or {}
  local entry = entries[file]
  if entry then
    for key, value in pairs(fields) do
      entry[key] = value
    end
    for _, key in ipairs(clear or {}) do
      entry[key] = nil
    end
    store:saveSetting("entries", entries)
    store:flush()
  end
end

function Queue:_remove(file)
  local store = self:_open()
  local entries = store:readSetting("entries") or {}
  entries[file] = nil
  store:saveSetting("entries", entries)
  store:flush()
end

-- ------------------------------------------------------------------------------------------
-- Sending
-- ------------------------------------------------------------------------------------------

local function describe(entry)
  local parts = {}
  if entry.started_at then
    table.insert(parts, "started " .. entry.started_at)
  end
  if entry.finished_at then
    table.insert(parts, "finished " .. entry.finished_at)
  elseif entry.percent then
    table.insert(parts, string.format("%d%%", math.floor(entry.percent * 100 + 0.5)))
  end
  if entry.rating then
    table.insert(parts, string.format("rated %s", tostring(entry.rating)))
  end
  return table.concat(parts, ", ")
end

local function titleOf(entry, file)
  local _dir, name = util.splitFilePathName(file or "")
  local local_title = entry.local_title or name
  if entry.title and local_title and entry.title ~= local_title then
    return local_title .. " → " .. entry.title
  end
  return entry.title or local_title or "?"
end

-- What is waiting, for the pending-updates menu: one row per book, oldest first
function Queue:pendingList()
  local rows = {}
  for file, entry in pairs(self:entries()) do
    local what = describe(entry)
    if what == "" then
      what = "waiting to be sent"
    end
    table.insert(rows, {
      file = file,
      title = titleOf(entry, file),
      what = what,
      linked = entry.book_id ~= nil,
      failures = entry.failures or 0,
      last_error = entry.last_error,
      queued_at = entry.queued_at or 0,
    })
  end
  table.sort(rows, function(x, y)
    return x.queued_at < y.queued_at
  end)
  return rows
end

Queue.NEWER_PROGRESS = "Hardcover already has newer progress, nothing sent"

-- Works out whether a failed request is worth trying again later ("transient") or was refused
function Queue:_failure(err, requests)
  if not NetworkManager:isConnected() then
    return "transient", "no connection", requests
  end

  if type(err) == "table" then
    if err.errors then
      local first = err.errors[1]
      local message = type(first) == "table" and first.message or nil
      return "failed", message or "Hardcover refused the update", requests
    end
    -- request cancelled or timed out
    return "transient", "request interrupted", requests
  end

  return "failed", "Hardcover did not accept the update", requests
end

-- Finds the Hardcover book for a queued book that was never linked, using the details saved when
-- it was opened (the same three auto-link options, in the same order, as when online).
-- Returns: true | false, "transient" | "failed", detail text, number of requests made
function Queue:_resolveLink(entry)
  local requests = 0
  local file = entry.file

  -- it may have been linked since (by hand, or by the normal auto-link while online)
  local linked = self.settings and self.settings:readBookSettings(file) or nil
  if linked and linked.book_id then
    local fields = {
      book_id = linked.book_id,
      edition_id = linked.edition_id,
      pages = linked.pages,
      title = linked.title,
    }
    for key, value in pairs(fields) do
      entry[key] = value
    end
    self:_patch(file, fields, { "snapshot" })
    return true, nil, nil, requests
  end

  local snap = entry.snapshot
  if not (snap and self.settings) then
    return false, "failed", "no book details were saved to link it", requests
  end

  local user_id = User:getId()
  local ok, ids = pcall(Book.parseIdentifiers, Book, snap.identifiers)
  if not ok then
    ids = {}
  end

  local found
  local tried = false

  if not found and self.settings:readSetting(SETTING.LINK_BY_ISBN) and (ids.isbn_10 or ids.isbn_13) then
    tried = true
    requests = requests + 1
    found = Api:findBookByIdentifiers({ isbn_10 = ids.isbn_10, isbn_13 = ids.isbn_13 }, user_id)
  end

  if not found and self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) and (ids.book_slug or ids.edition_id) then
    tried = true
    requests = requests + 1
    found = Api:findBookByIdentifiers({ book_slug = ids.book_slug, edition_id = ids.edition_id }, user_id)
  end

  if not found and self.settings:readSetting(SETTING.LINK_BY_TITLE) and snap.title and snap.title ~= "" then
    tried = true
    requests = requests + 1
    local results = Api:findBooks(snap.title, snap.authors, user_id)
    if not results then
      return false, "transient", "could not reach Hardcover", requests
    end
    found = results[1]
  end

  if not found then
    if not NetworkManager:isConnected() then
      return false, "transient", "no connection", requests
    end
    if not tried then
      local names = {}
      if self.settings:readSetting(SETTING.LINK_BY_ISBN) then
        table.insert(names, "ISBN")
      end
      if self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) then
        table.insert(names, "Hardcover identifier")
      end
      if self.settings:readSetting(SETTING.LINK_BY_TITLE) then
        table.insert(names, "title")
      end
      if #names == 0 then
        return false, "failed", "not linked to a Hardcover book and auto-linking is switched off. "
          .. "Link it from the Hardcover menu and it will be sent", requests
      end
      return false, "failed", "not linked to a Hardcover book. This book has nothing the enabled auto-link "
        .. "option(s) (" .. table.concat(names, ", ") .. ") can look up. Link it from the Hardcover menu", requests
    end
    return false, "failed", "no matching book found on Hardcover. Link it from the Hardcover menu", requests
  end

  -- remember the link for the book, the same way a link made by hand from the menu is saved
  local saved, save_err = pcall(function()
    self.settings:updateBookSetting(file, {
      book_id = found.book_id,
      edition_id = found.edition_id,
      edition_format = Book:editionFormatName(found.edition_format, found.reading_format_id),
      pages = found.pages,
      title = found.title,
    })
  end)
  if not saved then
    logger.warn("HARDCOVER queue: link saved, but a listener failed afterwards: " .. tostring(save_err))
  end

  logger.info(("HARDCOVER queue: linked %s to Hardcover book %s '%s'"):format(
    tostring(file), tostring(found.book_id), tostring(found.title)))

  -- Bookshelf keeps its own in-memory copy of the links and only re-reads them when told
  -- to; ask any loaded Bookshelf Hardcover module to forget it so the book info page updates
  pcall(function()
    for name, mod in pairs(package.loaded) do
      if type(name) == "string" and name:find("bookshelf_hardcover", 1, true)
          and type(mod) == "table" and type(mod.invalidate) == "function"
          and type(mod.getLink) == "function" then
        mod.invalidate()
      end
    end
  end)

  local fields = {
    book_id = found.book_id,
    edition_id = found.edition_id,
    pages = found.pages,
    title = found.title,
  }
  for key, value in pairs(fields) do
    entry[key] = value
  end
  self:_patch(file, fields, { "snapshot" })

  return true, nil, nil, requests
end

-- Brings one book on Hardcover up to date with what was recorded.
-- Returns: "done" | "transient" | "failed", detail text, number of requests made
function Queue:_syncEntry(entry)
  local requests = 0
  local FINISHED = HARDCOVER.STATUS.FINISHED
  local READING = HARDCOVER.STATUS.READING

  local user_id = User:getId()
  if not user_id then
    return "transient", "could not reach Hardcover", requests
  end

  if not entry.book_id then
    local linked, outcome, detail, used = self:_resolveLink(entry)
    requests = requests + (used or 0)
    if not linked then
      return outcome, detail, requests
    end
  end

  local total = entry.pages or entry.doc_pages
  local edition_id = entry.edition_id

  local function pagesFor(percent)
    if not (percent and total) then
      return nil
    end
    local pages = math.floor(percent * total + 0.5)
    pages = math.max(0, math.min(total, pages))
    -- while "Mark as Read at end of book" is on, the last page is only sent by marking it Read
    if not entry.finished_at and total > 1 and pages >= total
        and self.settings and self.settings:holdsLastPage(entry.file) then
      pages = total - 1
    end
    return pages
  end

  requests = requests + 1
  local user_book, find_err = Api:findUserBook(entry.book_id, user_id)
  if find_err then
    return self:_failure(find_err, requests)
  end

  local reads = user_book and user_book.user_book_reads or {}
  local last = reads[#reads]
  local privacy = user_book and user_book.privacy_setting_id

  local target_status
  if entry.finished_at then
    target_status = FINISHED
  elseif entry.started_at then
    target_status = READING
  end

  -- 1. the shelf status
  local status_changed = false
  if target_status and (not user_book or user_book.status_id ~= target_status) then
    status_changed = true
    requests = requests + (privacy and 1 or 2)
    local updated, err = Api:updateUserBook(entry.book_id, target_status, privacy, edition_id)
    if not updated then
      return self:_failure(err, requests)
    end
    user_book = updated
    reads = user_book.user_book_reads or {}
    last = reads[#reads]
  end

  local progress_sent = false

  if entry.finished_at then
    -- 2a. the finish, dated as it happened
    local started = entry.started_at

    if status_changed then
      -- moving a book to Read makes Hardcover finish (or create) a read by itself, and the answer
      -- to the update may not show that yet: look again before deciding, so no second read is made
      requests = requests + 1
      local fresh, fresh_err = Api:findUserBook(entry.book_id, user_id)
      if fresh_err then
        return self:_failure(fresh_err, requests)
      end
      if fresh and fresh.id then
        user_book = fresh
        reads = user_book.user_book_reads or {}
        last = reads[#reads]
      end
    end

    -- a read still in progress is finished; a read that Hardcover has just finished itself is
    -- corrected to the recorded dates. Only a book that was already Read before (a re-read) gets
    -- a new read.
    local reusable = last and (not isFinished(last)
      or (status_changed and (last.finished_at == entry.finished_at or last.finished_at == today())))
    if reusable then
      local start_date
      if isFinished(last) then
        start_date = started or last.started_at or entry.finished_at
      else
        start_date = last.started_at or started or entry.finished_at
      end
      if not isFinished(last) or last.finished_at ~= entry.finished_at or last.started_at ~= start_date then
        requests = requests + 1
        local result, err = Api:finishRead(last.id, last.edition_id or edition_id,
          (last.edition and last.edition.pages) or total or last.progress_pages, start_date, entry.finished_at)
        if not result then
          return self:_failure(err, requests)
        end
      end
    elseif (not last) or status_changed or (started and last.started_at ~= started) then
      requests = requests + 1
      local created, err = Api:createRead(user_book.id, edition_id or user_book.edition_id,
        total, started or entry.finished_at)
      if not created then
        return self:_failure(err, requests)
      end
      local new_read = created.user_book_reads and created.user_book_reads[1]
      if not new_read then
        return "failed", "Hardcover did not return the new read", requests
      end
      requests = requests + 1
      local result, finish_err = Api:finishRead(new_read.id, new_read.edition_id or edition_id,
        total, new_read.started_at, entry.finished_at)
      if not result then
        return self:_failure(finish_err, requests)
      end
    end
    -- otherwise the latest read is already finished with this start date: nothing to do
    progress_sent = true
  elseif entry.started_at then
    -- 2b. the start, dated as it happened
    if (not last) or isFinished(last) then
      requests = requests + 1
      local created, err = Api:createRead(user_book.id, edition_id or user_book.edition_id,
        pagesFor(entry.percent) or 0, entry.started_at)
      if not created then
        return self:_failure(err, requests)
      end
      last = created.user_book_reads and created.user_book_reads[1]
      progress_sent = true
    end
  end

  -- 2c. the star rating
  if entry.rating then
    if not (user_book and user_book.id) then
      return "failed", "the book is not on your Hardcover shelf, so the rating could not be set", requests
    end
    if user_book.rating ~= entry.rating then
      requests = requests + 1
      local rated, rate_err = Api:updateRating(user_book.id, entry.rating)
      if not rated then
        return self:_failure(rate_err, requests)
      end
      user_book = rated
    end
  end

  -- 3. progress on the read in progress
  if not progress_sent and entry.percent then
    if last and not isFinished(last) then
      local pages = pagesFor(entry.percent)
      -- pages are counted in the linked edition; this read is measured in its own edition
      pages = Api:scalePagesToRead(last, pages, total)
      -- a queued value is never allowed to move progress backwards: if Hardcover is already
      -- further on (read live, or on another device, after this was queued) it is left alone
      if pages and last.progress_pages and pages < last.progress_pages then
        return "skipped", Queue.NEWER_PROGRESS, requests
      end
      if pages then
        requests = requests + 1
        local result, err = Api:updatePage(last.id, last.edition_id or edition_id, pages, last.started_at)
        if not result then
          return self:_failure(err, requests)
        end
      end
    else
      -- progress alone is never allowed to start a read or change a book's shelf
      return "skipped", "not currently reading on Hardcover, nothing sent", requests
    end
  end

  return "done", describe(entry), requests
end

-- Sends everything waiting, one book at a time, spaced out to stay inside Hardcover's rate
-- limits (about one request a second). opts.on_done(summary) is called at the end.
-- summary = { done = { "line", ... }, failed = { "line", ... }, waiting = number }
function Queue:sync(opts)
  opts = opts or {}

  -- nothing can be sent until the user has signed in (or set an API key)
  if not Api:hasCredentials() then
    return false
  end

  if self.running then
    return false
  end

  local list = {}
  for file, entry in pairs(self:entries()) do
    entry.file = file
    table.insert(list, entry)
  end
  if #list == 0 then
    return false
  end
  table.sort(list, function(a, b)
    return (a.queued_at or 0) < (b.queued_at or 0)
  end)

  Queue.running = true

  local summary = { done = {}, failed = {}, skipped = {}, waiting = 0, prompts = {} }
  local index = 0
  local step

  local finish = function()
    Queue.running = false

    local store = self:_open()
    store:saveSetting("last_sync", {
      time = os.time(),
      done = #summary.done,
      failed = #summary.failed,
      waiting = summary.waiting,
    })
    store:flush()

    if opts.on_done then
      opts.on_done(summary)
    end
  end

  -- Each book is handled inside a Trapper wrapper, so the requests run in the background and the
  -- screen keeps responding while they are sent
  local attempts = {}

  step = function()
    Trapper:wrap(function()
      index = index + 1
      local entry = list[index]
      if not entry then
        return finish()
      end

      if not NetworkManager:isConnected() then
        summary.waiting = #list - index + 1
        return finish()
      end

      local ok, outcome, detail, requests = pcall(self._syncEntry, self, entry)
      if not ok then
        logger.warn("HARDCOVER queue: error while syncing " .. tostring(entry.file) .. ": " .. tostring(outcome))
        outcome, detail, requests = "failed", tostring(outcome), 1
      end
      logger.warn(("HARDCOVER queue: %s -> %s (%s)"):format(tostring(entry.file), tostring(outcome), tostring(detail)))

      if outcome == "transient" and NetworkManager:isConnected() and (attempts[index] or 0) < 3 then
        -- a tap on the screen cancels a request in the background, and a slow connection can time
        -- out: simply try the same book again shortly
        attempts[index] = (attempts[index] or 0) + 1
        index = index - 1
        UIManager:scheduleIn(3, step)
        return
      end

      if outcome == "skipped" then
        -- nothing to send for this book: drop it
        self:_remove(entry.file)
        if detail == Queue.NEWER_PROGRESS then
          table.insert(summary.skipped, titleOf(entry, entry.file))
          pcall(self.addLog, self, true, titleOf(entry, entry.file) .. ": " .. detail)
        end
      elseif outcome == "done" then
        self:_remove(entry.file)
        table.insert(summary.done, titleOf(entry, entry.file) .. ": " .. detail)
        pcall(self.addLog, self, true, titleOf(entry, entry.file) .. ": " .. detail)
      elseif outcome == "failed" then
        local failures = (entry.failures or 0) + 1
        local is_new_reason = entry.last_error ~= detail
        self:_markFailed(entry.file, detail)

        -- the same refusal on every sync is only reported (and logged) the first time
        if is_new_reason or opts.manual then
          table.insert(summary.failed, titleOf(entry, entry.file) .. ": " .. tostring(detail))
        end
        if is_new_reason then
          pcall(self.addLog, self, false, titleOf(entry, entry.file) .. ": " .. tostring(detail))
        end

        -- after every N real failures, ask whether to keep trying
        local limit = self:retryLimit()
        if limit > 0 and failures % limit == 0 then
          table.insert(summary.prompts, {
            file = entry.file,
            title = titleOf(entry, entry.file),
            reason = tostring(detail),
            failures = failures,
          })
        end
      else
        -- no connection or interrupted: keep this one and everything after it for next time
        summary.waiting = #list - index + 1
        return finish()
      end

      UIManager:scheduleIn(math.max(1.5, requests or 1), step)
    end)
  end

  UIManager:scheduleIn(1, step)
  return true
end

return Queue
