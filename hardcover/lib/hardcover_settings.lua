local KoreaderVersion = require("version")
local LuaSettings = require("luasettings")

local _t = require("hardcover/lib/table_util")
local SETTING = require("hardcover/lib/constants/settings")

local HardcoverSettings = {}
HardcoverSettings.__index = HardcoverSettings

function HardcoverSettings:new(path, ui)
  local o = {}
  setmetatable(o, self)

  self.settings = LuaSettings:open(path)
  self.ui = ui
  self.subscribers = {}

  self:migrateOldSettings()

  if KoreaderVersion:getNormalizedCurrentVersion() < 202403010000 then
    if self.settings:readSetting(SETTING.COMPATIBILITY_MODE) == nil then
      self:updateSetting(SETTING.COMPATIBILITY_MODE, true)
    end
  end

  return o
end

-- One-time upgrade of settings written by earlier versions of this plugin (safe to delete once
-- nobody is expected to upgrade from those versions):
--  * the per-book tick box "sync" became the per-book rules (rule_progress and friends). A book
--    that had it ticked now always tracks progress; one that had it unticked never syncs at all.
--  * "enable_wifi" belonged to the removed "Enable wifi on demand" option.
function HardcoverSettings:migrateOldSettings()
  local changed = false

  local books = self.settings:readSetting("books")
  if books then
    for _file, book in pairs(books) do
      if book.sync ~= nil then
        if book.rule_progress == nil then
          if book.sync == true then
            book.rule_progress = "always"
          else
            book.rule_progress = "never"
            book.rule_reading = book.rule_reading or "never"
            book.rule_read = book.rule_read or "never"
            book.rule_rating = book.rule_rating or "never"
          end
        end
        book.sync = nil
        changed = true
      end
    end
  end

  if self.settings:has("enable_wifi") then
    self.settings:delSetting("enable_wifi")
    changed = true
  end

  if changed then
    self.settings:flush()
  end
end

function HardcoverSettings:readSetting(key)
  return self.settings:readSetting(key)
end

function HardcoverSettings:readBookSettings(filename)
  local books = self.settings:readSetting("books")
  if not books then
    return {}
  end

  return books[filename]
end

function HardcoverSettings:readBookSetting(filename, key)
  if not filename then
    return
  end

  local settings = self:readBookSettings(filename)
  if settings then
    return settings[key]
  end
end

function HardcoverSettings:updateBookSetting(filename, config)
  local books = self.settings:readSetting("books", {})
  if not books[filename] then
    books[filename] = {}
  end
  local book_setting = books[filename]
  local original_value = { table.unpack(book_setting) }
  for k, v in pairs(config) do
    if k == "_delete" then
      for _, name in ipairs(v) do
        book_setting[name] = nil
      end
    else
      book_setting[k] = v
    end
  end

  self.settings:flush()

  self:notify(SETTING.BOOKS, { filename = filename, config = config }, original_value)
end

function HardcoverSettings:updateSetting(key, value)
  local original_value = self.settings:readSetting(key)
  self.settings:saveSetting(key, value)

  self.settings:flush()

  self:notify(key, value, original_value)
end

function HardcoverSettings:notify(key, value, original_value)
  for _, cb in ipairs(self.subscribers) do
    cb(key, value, original_value)
  end
end

function HardcoverSettings:subscribe(cb)
  table.insert(self.subscribers, cb)
end

function HardcoverSettings:unsubscribe(cb)
  local new_subscribers = {}
  for _, original_cb in ipairs(self.subscribers) do
    if original_cb ~= cb then
      table.insert(new_subscribers, original_cb)
    end
  end
  self.subscribers = new_subscribers
end

function HardcoverSettings:setSync(value)
  self:updateBookSetting(self.ui.document.file, { rule_progress = value == true and "always" or "never" })
end

function HardcoverSettings:setTrackMethod(method)
  self:updateSetting(SETTING.TRACK_METHOD, method)
end

function HardcoverSettings:editionLinked()
  return self:getLinkedEditionId() ~= nil
end

function HardcoverSettings:readLinked()
  return self:readBookSetting(self.ui.document.file, "read_id") ~= nil
end

function HardcoverSettings:bookLinked()
  return self:getLinkedBookId() ~= nil
end

function HardcoverSettings:getFilePath()
  return _t.dig(self, "ui", "document", "file")
end

function HardcoverSettings:getLinkedTitle()
  return self:readBookSetting(self:getFilePath(), "title")
end

function HardcoverSettings:getLinkedBookId()
  return self:readBookSetting(self:getFilePath(), "book_id")
end

function HardcoverSettings:getLinkedEditionFormat()
  return self:readBookSetting(self:getFilePath(), "edition_format")
end

function HardcoverSettings:getLinkedEditionId()
  return self:readBookSetting(self:getFilePath(), "edition_id")
end

-- ------------------------------------------------------------------------------------------
-- Per-book rules ("Always sync this book" / "Never sync this book")
--
-- Four things can be set for a single book, each stored under the book's own settings:
--   progress  rule_progress  "always" | "never"
--   reading   rule_reading   "auto" | "ask" | "never"     (Mark as Currently Reading)
--   read      rule_read      "auto" | "ask" | "never"     (Mark as Read at end of book)
--   rating    rule_rating    "ask" | "never"              (star rating after marking Read)
-- Nothing stored means "follow the global setting".
-- ------------------------------------------------------------------------------------------

HardcoverSettings.RULE_KEYS = {
  progress = "rule_progress",
  reading = "rule_reading",
  read = "rule_read",
  rating = "rule_rating",
}

function HardcoverSettings:bookRule(file, item)
  if not file then
    return nil
  end
  local value = self:readBookSetting(file, HardcoverSettings.RULE_KEYS[item])
  return value
end

-- Whether progress is sent for this book
function HardcoverSettings:progressEnabled(file)
  if not file then
    return false
  end

  local rule = self:bookRule(file, "progress")
  if rule == "always" then
    return true
  elseif rule == "never" then
    return false
  end

  return self.settings:readSetting(SETTING.ALWAYS_SYNC) == true
end

-- Whether the global Currently Reading / Read settings apply to this book: they only do for books
-- that are tracked (by default, or by choice). "Never" for progress alone does not switch the
-- other settings off; the book then simply follows the universal default.
function HardcoverSettings:baseSynced(file)
  if not file then
    return false
  end

  if self:bookRule(file, "progress") == "never" then
    return self.settings:readSetting(SETTING.ALWAYS_SYNC) == true
  end
  return self:progressEnabled(file)
end

local function modeFromRule(rule)
  if rule == "auto" then
    return SETTING.AUTO_MODE.AUTO
  elseif rule == "ask" then
    return SETTING.AUTO_MODE.ASK
  elseif rule == "never" then
    return SETTING.AUTO_MODE.OFF
  end
  return nil
end

-- Currently Reading mode for one book: its own rule, else the global setting for tracked books
function HardcoverSettings:readingModeFor(file)
  local mode = modeFromRule(self:bookRule(file, "reading"))
  if mode then
    return mode
  end
  if self:baseSynced(file) then
    return self:autoReadingMode()
  end
  return SETTING.AUTO_MODE.OFF
end

-- Mark as Read mode for one book
function HardcoverSettings:finishingModeFor(file)
  local mode = modeFromRule(self:bookRule(file, "read"))
  if mode then
    return mode
  end
  if self:baseSynced(file) then
    return self:autoFinishingMode()
  end
  return SETTING.AUTO_MODE.OFF
end

-- True when the last page must never be sent as progress (Hardcover would mark the book Read by
-- itself): either marking Read is handled by the plugin, or it is switched off for the book
function HardcoverSettings:holdsLastPage(file)
  return self:finishingModeFor(file) ~= SETTING.AUTO_MODE.OFF or self:bookRule(file, "read") == "never"
end

-- Whether the plugin does anything at all for this book (loads its Hardcover status, watches
-- the end of the book, ...). Progress alone is a separate question: see progressEnabled().
function HardcoverSettings:fileSyncEnabled(file)
  if not file then
    return false
  end

  if self:baseSynced(file) then
    return true
  end

  local reading = self:bookRule(file, "reading")
  local read = self:bookRule(file, "read")
  return reading == "auto" or reading == "ask" or read == "auto" or read == "ask"
end

function HardcoverSettings:syncEnabled()
  return self:fileSyncEnabled(self:getFilePath())
end

function HardcoverSettings:autolinkEnabled()
  for _, setting in ipairs(SETTING.AUTOLINK_OPTIONS) do
    if self.settings:readSetting(setting) then
      return true
    end
  end

  return false
end

function HardcoverSettings:pages()
  return self:readBookSetting(self:getFilePath(), "pages")
end

function HardcoverSettings:trackFrequency()
  return self.settings:readSetting(SETTING.TRACK_FREQUENCY) or 5
end

function HardcoverSettings:trackPercentageInterval()
  return self.settings:readSetting(SETTING.TRACK_PERCENTAGE) or 10
end

function HardcoverSettings:trackByTime()
  local setting = self.settings:readSetting(SETTING.TRACK_METHOD)
  return setting == nil or setting == SETTING.TRACK.FREQUENCY
end

function HardcoverSettings:trackByProgress()
  return self.settings:readSetting(SETTING.TRACK_METHOD) == SETTING.TRACK.PROGRESS
end

function HardcoverSettings:changeTrackPercentageInterval(percent)
  self:updateSetting(SETTING.TRACK_PERCENTAGE, percent)
end

function HardcoverSettings:compatibilityMode()
  return self.settings:readSetting(SETTING.COMPATIBILITY_MODE) == true
end

function HardcoverSettings:setMenuConfirm(status)
  self:updateSetting(SETTING.MENU_CONFIRMATION, status)
end

function HardcoverSettings:menuConfirm()
  return self.settings:readSetting(SETTING.MENU_CONFIRMATION) == true
end

function HardcoverSettings:autoReadingMode()
  return self.settings:readSetting(SETTING.AUTO_READING) or SETTING.AUTO_MODE.OFF
end

-- Hides the brief automatic messages (errors and answers to menu actions still show)
function HardcoverSettings:suppressNotifications()
  return self.settings:readSetting(SETTING.SUPPRESS_NOTIFICATIONS) == true
end

-- When a book counts as "started": after a percentage of the book, or a number of minutes read
function HardcoverSettings:readingAfterByMinutes()
  return self.settings:readSetting(SETTING.READING_AFTER) == SETTING.READING_AFTER_TYPE.MINUTES
end

function HardcoverSettings:readingAfterPercent()
  return self.settings:readSetting(SETTING.READING_AFTER_PERCENT) or 5
end

function HardcoverSettings:readingAfterMinutes()
  return self.settings:readSetting(SETTING.READING_AFTER_MINUTES) or 10
end

-- Whether to offer a star rating after "Mark this book as Read?" is answered Yes
function HardcoverSettings:askRating()
  return self.settings:readSetting(SETTING.ASK_RATING) == true
end

function HardcoverSettings:autoFinishingMode()
  return self.settings:readSetting(SETTING.AUTO_FINISHING) or SETTING.AUTO_MODE.OFF
end

return HardcoverSettings
