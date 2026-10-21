local DataStorage = require("datastorage")
local _ = require("gettext")
local math = require("math")
local os = require("os")
local logger = require("logger")

local T = require("ffi/util").template

local Font = require("ui/font")
local UIManager = require("ui/uimanager")

local UpdateDoubleSpinWidget = require("hardcover/lib/ui/update_double_spin_widget")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local SpinWidget = require("ui/widget/spinwidget")

local Api = require("hardcover/lib/hardcover_api")
local Github = require("hardcover/lib/github")
local User = require("hardcover/lib/user")
local _t = require("hardcover/lib/table_util")

local HARDCOVER = require("hardcover/lib/constants/hardcover")
local ICON = require("hardcover/lib/constants/icons")
local SETTING = require("hardcover/lib/constants/settings")
local VERSION = require("hardcover_version")

local HardcoverMenu = {}
HardcoverMenu.__index = HardcoverMenu

function HardcoverMenu:new(o)
  return setmetatable(o or {
    enabled = true
  }, self)
end

local privacy_labels = {
  [HARDCOVER.PRIVACY.PUBLIC] = "Public",
  [HARDCOVER.PRIVACY.FOLLOWS] = "Follows",
  [HARDCOVER.PRIVACY.PRIVATE] = "Private"
}

function HardcoverMenu:mainMenu()
  return {
    enabled_func = function()
      return self.enabled
    end,
    text_func = function()
      return self.settings:bookLinked() and _("Hardcover: " .. ICON.LINK) or _("Hardcover")
    end,
    sub_item_table_func = function()
      local has_book = self.ui.document and true or false
      return self:getSubMenuItems(has_book)
    end,
  }
end

function HardcoverMenu:getSubMenuItems(book_view)
  local menu_items = {
    book_view and {
      text_func = function()
        if self.settings:bookLinked() then
          -- need to show link information somehow. Maybe store title
          local title = self.settings:getLinkedTitle()
          if not title then
            title = self.settings:getLinkedBookId()
          end
          return _("Linked book: " .. title)
        else
          return _("Link book")
        end
      end,
      enabled_func = function()
        -- leave button enabled to allow clearing local link when api disabled
        return self.enabled or self.settings:bookLinked()
      end,
      hold_callback = function(menu_instance)
        if self.settings:bookLinked() then
          self.settings:updateBookSetting(
            self.ui.document.file,
            {
              _delete = { 'book_id', 'edition_id', 'edition_format', 'pages', 'title' }
            }
          )

          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        if not self.enabled then
          return
        end

        local force_search = self.settings:bookLinked()

        self.hardcover:showLinkBookDialog(force_search, function()
          menu_instance:updateItems()
        end)
      end,
    },
    book_view and {
      text_func = function()
        local edition_format = self.settings:getLinkedEditionFormat()
        local title = "Change edition"

        if edition_format then
          title = title .. ": " .. edition_format
        elseif self.settings:getLinkedEditionId() then
          return title .. ": physical book"
        end

        return _(title)
      end,
      enabled_func = function()
        return self.enabled and self.settings:bookLinked()
      end,
      callback = function(menu_instance)
        local editions = Api:findEditions(self.settings:getLinkedBookId(), User:getId())
        -- need to show "active" here, and prioritize current edition if available
        self.dialog_manager:buildSearchDialog(
          "Select edition",
          editions,
          {
            edition_id = self.settings:getLinkedEditionId()
          },
          function(book)
            self.hardcover:linkBook(book)
            menu_instance:updateItems()
          end
        )
      end,
      keep_menu_open = true,
      separator = true
    },
    book_view and {
      text = _("Always sync this book"),
      mandatory_func = function()
        return self:ruleSummary("always")
      end,
      sub_item_table_func = function()
        return self:getAlwaysSyncItems()
      end,
    },
    book_view and {
      text = _("Never sync this book"),
      mandatory_func = function()
        return self:ruleSummary("never")
      end,
      sub_item_table_func = function()
        return self:getNeverSyncItems()
      end,
    },
    book_view and {
      text = _("Update status"),
      enabled_func = function()
        return self.settings:bookLinked()
      end,
      sub_item_table_func = function()
        self.cache:cacheUserBook()

        return self:getStatusSubMenuItems()
      end,
      separator = true
    },
    {
      text_func = function()
        local waiting = self.queue and self.queue:count() or 0
        if waiting == 0 then
          return _("Offline queue: nothing waiting")
        end
        return T(_("Sync %1 queued update(s) now"), waiting)
      end,
      enabled_func = function()
        return self.queue ~= nil and self.queue:count() > 0
      end,
      callback = function()
        self.sync_queue()
      end,
      keep_menu_open = true
    },
    {
      text_func = function()
        local waiting = self.queue and self.queue:count() or 0
        if waiting == 0 then
          return _("Pending updates: none")
        end
        return T(_("Pending updates (%1)"), waiting)
      end,
      enabled_func = function()
        return self.queue ~= nil and self.queue:count() > 0
      end,
      sub_item_table_func = function()
        return self:getPendingItems()
      end,
    },
    {
      text = _("Clear queued updates"),
      enabled_func = function()
        return self.queue ~= nil and self.queue:count() > 0
      end,
      callback = function(menu_instance)
        self.dialog_manager:confirm({
          text = T(_("Delete %1 queued update(s) without sending them to Hardcover?"), self.queue:count()),
          ok_text = _("Delete"),
          ok_callback = function()
            self.queue:clear()
            menu_instance:updateItems()
          end,
        })
      end,
      keep_menu_open = true
    },
    {
      text_func = function()
        local limit = self.queue and self.queue:retryLimit() or 3
        if limit == 0 then
          return _("Ask about failed updates: never")
        end
        return T(_("Ask about failed updates after %1 tries"), limit)
      end,
      callback = function(menu_instance)
        UIManager:show(SpinWidget:new {
          value = self.queue:retryLimit(),
          value_min = 0,
          value_max = 20,
          value_step = 1,
          value_hold_step = 5,
          ok_always_enabled = true,
          ok_text = _("Save"),
          title_text = _("Tries before asking (0 = never ask)"),
          callback = function(spin)
            self.settings:updateSetting(self.queue.RETRY_KEY, spin.value)
            menu_instance:updateItems()
          end
        })
      end,
      keep_menu_open = true
    },
    {
      text = _("Sync Log"),
      callback = function()
        local text = self.queue and self.queue:logText()
        if not text then
          UIManager:show(InfoMessage:new {
            text = _("Nothing has been sent from the offline queue in the last 7 days"),
          })
          return
        end
        UIManager:show(TextViewer:new {
          title = _("Sync Log (last 7 days)"),
          text = text,
        })
      end,
      keep_menu_open = true,
      separator = true
    },
    {
      text = _("Suggest a book"),
      callback = function()
        self.hardcover:showRandomBookDialog()
      end,
      separator = true,
      keep_menu_open = true
    },
    {
      text = _("Settings"),
      sub_item_table_func = function()
        return self:getSettingsSubMenuItems()
      end,
    },
    {
      text = _("About"),
      callback = function()
        local new_release = Github:newestRelease()
        local version = table.concat(VERSION, ".")
        local new_release_str = ""
        if new_release then
          new_release_str = " (latest v" .. new_release .. ")"
        end
        local settings_file = DataStorage:getSettingsDir() .. "/" .. "hardcoversync_settings.lua"

        UIManager:show(InfoMessage:new {
          text = [[
Hardcover plugin
v]] .. version .. new_release_str .. [[


Updates book progress and status on Hardcover.app

Project:
github.com/billiam/hardcoverapp.koplugin

Settings:
]] .. settings_file,
          face = Font:getFace("cfont", 18),
          show_icon = false,
        })
      end,
      keep_menu_open = true
    }
  }
  return _t.filter(menu_items, function(v)
    return v
  end)
end

function HardcoverMenu:getVisibilitySubMenuItems()
  return {
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.PUBLIC]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.PUBLIC
      end,
      callback = function()
        self.hardcover:changeBookVisibility(HARDCOVER.PRIVACY.PUBLIC)
      end,
      radio = true,
    },
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.FOLLOWS]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.FOLLOWS
      end,
      callback = function()
        self.hardcover:changeBookVisibility(HARDCOVER.PRIVACY.FOLLOWS)
      end,
      radio = true
    },
    {
      text = _(privacy_labels[HARDCOVER.PRIVACY.PRIVATE]),
      checked_func = function()
        return self.state.book_status.privacy_setting_id == HARDCOVER.PRIVACY.PRIVATE
      end,
      callback = function()
        self.hardcover:changeBookVisibility(HARDCOVER.PRIVACY.PRIVATE)
      end,
      radio = true
    },
  }
end

function HardcoverMenu:getStatusSubMenuItems()
  return {
    {
      text = _(ICON.BOOKMARK .. " Want To Read"),
      enabled_func = function()
        return self.enabled
      end,
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.TO_READ
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Want To Read?",
          ok_callback = function()
            self.cache:updateBookStatus(self.ui.document.file, HARDCOVER.STATUS.TO_READ)
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true
    },
    {
      text = _(ICON.OPEN_BOOK .. " Currently Reading"),
      enabled_func = function()
        return self.enabled
      end,
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.READING
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Currently Reading?",
          ok_callback = function()
            self.cache:updateBookStatus(self.ui.document.file, HARDCOVER.STATUS.READING)
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true
    },
    {
      text = _(ICON.CHECKMARK .. " Read"),
      enabled_func = function()
        return self.enabled
      end,
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.FINISHED
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Read?",
          ok_callback = function()
            self.cache:updateBookStatus(self.ui.document.file, HARDCOVER.STATUS.FINISHED)
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true
    },
    {
      text = _(ICON.STOP_CIRCLE .. " Did Not Finish"),
      enabled_func = function()
        return self.enabled
      end,
      checked_func = function()
        return self.state.book_status.status_id == HARDCOVER.STATUS.DNF
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Mark book as Did Not Finish?",
          ok_callback = function()
            self.cache:updateBookStatus(self.ui.document.file, HARDCOVER.STATUS.DNF)
          end,
          no_confirm_callback = function()
            menu_instance:updateItems()
          end
        })
      end,
      radio = true,
    },
    {
      text = _(ICON.TRASH .. " Remove"),
      enabled_func = function()
        return self.enabled and self.state.book_status.status_id ~= nil
      end,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = "Remove current book status?",
          ok_callback = function()
            local result = Api:removeRead(self.state.book_status.id)
            if result and result.id then
              self.state.book_status = {}
              menu_instance:updateItems()
            end
          end
        })
      end,
      keep_menu_open = true,
      separator = true
    },
    {
      text_func = function()
        local reads = self.state.book_status.user_book_reads
        local current_page = reads and reads[#reads] and reads[#reads].progress_pages or 0
        local max_pages = self.settings:pages()

        if not max_pages then
          max_pages = "???"
        end

        return T(_("Update page: %1 of %2"), current_page, max_pages)
      end,
      enabled_func = function()
        return self.enabled and self.state.book_status.status_id == HARDCOVER.STATUS.READING and self.settings:pages()
      end,
      callback = function(menu_instance)
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local last_hardcover_page = current_read and current_read.progress_pages or 0

        local document_page = self.ui:getCurrentPage()
        local document_pages = self.ui.document:getPageCount()

        local remote_pages = self.settings:pages()
        local mapped_page = self.page_mapper:getMappedPage(document_page, document_pages, remote_pages)

        local left_text = "Edition"
        if last_hardcover_page > 0 then
          left_text = left_text .. ": was " .. last_hardcover_page
        end

        local spinner = UpdateDoubleSpinWidget:new {
          ok_always_enabled = true,

          left_text = left_text,
          left_value = mapped_page,
          left_min = 0,
          left_max = remote_pages,
          left_step = 1,
          left_hold_step = 20,

          right_text = "Local page",
          right_value = document_page,
          right_min = 0,
          right_max = document_pages,
          right_step = 1,
          right_hold_step = 20,

          update_callback = function(new_edition_page, new_document_page, edition_page_changed)
            if edition_page_changed then
              local new_mapped_page = self.page_mapper:getUnmappedPage(new_edition_page, document_pages, remote_pages)
              return new_edition_page, new_mapped_page
            else
              local new_mapped_page = self.page_mapper:getMappedPage(new_document_page, document_pages, remote_pages)
              return new_mapped_page, new_document_page
            end
          end,
          ok_text = _("Set page"),
          title_text = _("Set current page"),

          callback = function(edition_page, _document_page)
            local result

            if current_read then
              result = Api:updatePage(current_read.id, current_read.edition_id, edition_page,
                current_read.started_at)
            else
              local start_date = os.date("%Y-%m-%d")
              result = Api:createRead(self.state.book_status.id, self.state.book_status.edition_id, edition_page,
                start_date)
            end

            if result then
              self.state.book_status = result
              menu_instance:updateItems()
            else

            end
          end
        }
        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = _("Add a note"),
      enabled_func = function()
        return self.enabled and self.state.book_status.id ~= nil
      end,
      callback = function()
        local reads = self.state.book_status.user_book_reads
        local current_read = reads and reads[#reads]
        local current_page = current_read and current_read.progress_pages or 0

        -- allow premapped page
        self.dialog_manager:journalEntryForm(
          "",
          self.ui.document,
          current_page,
          self.settings:pages(),
          current_page,
          "note"
        )
      end,
      keep_menu_open = true
    },
    {
      text_func = function()
        local text
        if self.state.book_status.rating then
          text = "Update rating"
          local whole_star = math.floor(self.state.book_status.rating)
          local star_string = string.rep(ICON.STAR, whole_star)
          if self.state.book_status.rating - whole_star > 0 then
            star_string = star_string .. ICON.HALF_STAR
          end
          text = text .. ": " .. star_string
        else
          text = "Set rating"
        end

        return _(text)
      end,
      enabled_func = function()
        return self.enabled and self.state.book_status.id ~= nil
      end,
      callback = function(menu_instance)
        local rating = self.state.book_status.rating

        local spinner = SpinWidget:new {
          ok_always_enabled = rating == nil,
          value = rating or 2.5,
          value_min = 0,
          value_max = 5,
          value_step = 0.5,
          value_hold_step = 2,
          precision = "%.1f",
          ok_text = _("Save"),
          title_text = _("Set Rating"),
          callback = function(spin)
            local result = Api:updateRating(self.state.book_status.id, spin.value)
            if result then
              self.state.book_status = result
              menu_instance:updateItems()
            else
              self.dialog_manager:showError("Rating could not be saved")
            end
          end
        }
        UIManager:show(spinner)
      end,
      hold_callback = function(menu_instance)
        local result = Api:updateRating(self.state.book_status.id, 0)
        if result then
          self.state.book_status = result
          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
      separator = true
    },
    {
      text = _("Set status visibility"),
      enabled_func = function()
        return self.enabled and self.state.book_status.id ~= nil
      end,
      sub_item_table_func = function()
        return self:getVisibilitySubMenuItems()
      end,
    },
  }
end

function HardcoverMenu:getTrackingSubMenuItems()
  return {
    {
      text = "Update periodically",
      radio = true,
      checked_func = function()
        return self.settings:trackByTime()
      end,
      callback = function()
        self.settings:setTrackMethod(SETTING.TRACK.FREQUENCY)
      end
    },
    {
      text_func = function()
        return "Every " .. self.settings:trackFrequency() .. " minutes"
      end,
      enabled_func = function()
        return self.settings:trackByTime()
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = self.settings:trackFrequency(),
          value_min = 1,
          value_max = 120,
          value_step = 1,
          value_hold_step = 6,
          ok_text = _("Save"),
          title_text = _("Set track frequency"),
          callback = function(spin)
            self.settings:updateSetting(SETTING.TRACK_FREQUENCY, spin.value)
            menu_instance:updateItems()
          end
        }

        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
    {
      text = "Update by progress",
      radio = true,
      checked_func = function()
        return self.settings:trackByProgress()
      end,
      callback = function()
        self.settings:setTrackMethod(SETTING.TRACK.PROGRESS)
      end
    },
    {
      text_func = function()
        return "Every " .. self.settings:trackPercentageInterval() .. " percent completed"
      end,
      enabled_func = function()
        return self.settings:trackByProgress()
      end,
      callback = function(menu_instance)
        local spinner = SpinWidget:new {
          value = self.settings:trackPercentageInterval(),
          value_min = 1,
          value_max = 50,
          value_step = 1,
          value_hold_step = 10,
          ok_text = _("Save"),
          title_text = _("Set track progress"),
          callback = function(spin)
            self.settings:changeTrackPercentageInterval(spin.value)
            menu_instance:updateItems()
          end
        }

        UIManager:show(spinner)
      end,
      keep_menu_open = true
    },
  }
end

-- Choose when a book counts as started: after a percentage of the book, or after minutes of reading
function HardcoverMenu:getReadingAfterSubMenuItems()
  local TYPE = SETTING.READING_AFTER_TYPE
  local function spinItem(label_func, type_name, value_func, min, max, step, hold, title, key)
    return {
      text_func = label_func,
      enabled_func = function()
        return (self.settings:readingAfterByMinutes() and TYPE.MINUTES or TYPE.PERCENT) == type_name
      end,
      callback = function(menu_instance)
        UIManager:show(SpinWidget:new {
          value = value_func(),
          value_min = min,
          value_max = max,
          value_step = step,
          value_hold_step = hold,
          ok_text = _("Save"),
          title_text = title,
          callback = function(spin)
            self.settings:updateSetting(key, spin.value)
            menu_instance:updateItems()
          end
        })
      end,
      keep_menu_open = true,
    }
  end

  return {
    {
      text = "After a percentage of the book",
      radio = true,
      checked_func = function()
        return not self.settings:readingAfterByMinutes()
      end,
      callback = function()
        self.settings:updateSetting(SETTING.READING_AFTER, TYPE.PERCENT)
      end,
      keep_menu_open = true,
    },
    spinItem(function()
      return "At " .. self.settings:readingAfterPercent() .. "% of the book"
    end, TYPE.PERCENT, function() return self.settings:readingAfterPercent() end,
      1, 50, 1, 5, _("Percent of the book"), SETTING.READING_AFTER_PERCENT),
    {
      text = "After minutes of reading",
      radio = true,
      checked_func = function()
        return self.settings:readingAfterByMinutes()
      end,
      callback = function()
        self.settings:updateSetting(SETTING.READING_AFTER, TYPE.MINUTES)
      end,
      keep_menu_open = true,
    },
    spinItem(function()
      return "After " .. self.settings:readingAfterMinutes() .. " minutes of reading"
    end, TYPE.MINUTES, function() return self.settings:readingAfterMinutes() end,
      1, 240, 1, 10, _("Minutes of reading"), SETTING.READING_AFTER_MINUTES),
  }
end

function HardcoverMenu:getAutoModeSubMenuItems(setting_key)
  local function option(label, mode)
    return {
      text = label,
      radio = true,
      checked_func = function()
        return (self.settings:readSetting(setting_key) or SETTING.AUTO_MODE.OFF) == mode
      end,
      callback = function()
        self.settings:updateSetting(setting_key, mode)
      end,
    }
  end

  return {
    option("Off", SETTING.AUTO_MODE.OFF),
    option("Ask first", SETTING.AUTO_MODE.ASK),
    option("Automatic", SETTING.AUTO_MODE.AUTO),
  }
end

function HardcoverMenu:getSettingsSubMenuItems()
  return {
    {
      text = "Automatically link by ISBN",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_ISBN) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_ISBN) == true
        self.settings:updateSetting(SETTING.LINK_BY_ISBN, not setting)
      end
    },
    {
      text = "Automatically link by Hardcover identifiers",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_HARDCOVER) == true
        self.settings:updateSetting(SETTING.LINK_BY_HARDCOVER, not setting)
      end
    },
    {
      text = "Automatically link by title and author",
      checked_func = function()
        return self.settings:readSetting(SETTING.LINK_BY_TITLE) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.LINK_BY_TITLE) == true
        self.settings:updateSetting(SETTING.LINK_BY_TITLE, not setting)
      end,
      separator = true
    },
    {
      text_func = function()
        local labels = { off = "Off", ask = "Ask first", auto = "Automatic" }
        return "'Currently Reading' updates by default: " .. (labels[self.settings:autoReadingMode()] or "Off")
      end,
      sub_item_table_func = function()
        return self:getAutoModeSubMenuItems(SETTING.AUTO_READING)
      end,
    },
    {
      text_func = function()
        if self.settings:readingAfterByMinutes() then
          return "Currently Reading after: " .. self.settings:readingAfterMinutes() .. " minutes of reading"
        end
        return "Currently Reading after: " .. self.settings:readingAfterPercent() .. "% of the book"
      end,
      sub_item_table_func = function()
        return self:getReadingAfterSubMenuItems()
      end,
    },
    {
      text = "Reading progress updates by default",
      checked_func = function()
        return self.settings:readSetting(SETTING.ALWAYS_SYNC) == true
      end,
      callback = function()
        local setting = self.settings:readSetting(SETTING.ALWAYS_SYNC) == true
        self.settings:updateSetting(SETTING.ALWAYS_SYNC, not setting)
      end,
    },
    {
      text_func = function()
        if self.settings:trackByProgress() then
          return "Progress updates after: Every " .. self.settings:trackPercentageInterval() .. "% completed"
        end
        return "Progress updates after: Every " .. self.settings:trackFrequency() .. " minutes"
      end,
      sub_item_table_func = function()
        return self:getTrackingSubMenuItems()
      end,
    },
    {
      text_func = function()
        local labels = { off = "Off", ask = "Ask first", auto = "Automatic" }
        return "'Read' status updates by default: " .. (labels[self.settings:autoFinishingMode()] or "Off")
      end,
      sub_item_table_func = function()
        return self:getAutoModeSubMenuItems(SETTING.AUTO_FINISHING)
      end,
    },
    {
      text = "Rating prompt when marked 'Read' by default",
      checked_func = function()
        return self.settings:askRating()
      end,
      callback = function()
        self.settings:updateSetting(SETTING.ASK_RATING, not self.settings:askRating())
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[After you answer Yes to "Mark this book as Read?", asks how many stars to give it. Works whether 'Read' status updates are set to "Ask first" or "Automatic".]]),
        })
      end,
    },
    {
      text = "Confirm changes to book read status",
      checked_func = function()
        return self.settings:menuConfirm()
      end,
      callback = function()
        local setting = self.settings:menuConfirm() == true
        self.settings:setMenuConfirm(not setting)
      end,
      separator = true,
    },
    {
      text = "Suppress all pop-up notifications",
      checked_func = function()
        return self.settings:suppressNotifications()
      end,
      callback = function()
        self.settings:updateSetting(SETTING.SUPPRESS_NOTIFICATIONS, not self.settings:suppressNotifications())
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = _("Hides the brief messages such as \"Marked as Currently Reading\", \"Synced to Hardcover\" and \"Saved. Will be sent when online\". Error messages and answers to menu actions still show."),
        })
      end,
    },
    {
      text = "Compatibility mode",
      checked_func = function()
        return self.settings:compatibilityMode()
      end,
      callback = function()
        local setting = self.settings:compatibilityMode()
        self.settings:updateSetting(SETTING.COMPATIBILITY_MODE, not setting)
      end,
      hold_callback = function()
        UIManager:show(InfoMessage:new {
          text = [[Disable fancy menu for book and edition search results.

May improve compatibility for some versions of KOReader]],
        })
      end
    }
  }
end

-- ---------------------------------------------------------------------------------------
-- Per-book rules: "Always sync this book" / "Never sync this book"
-- ---------------------------------------------------------------------------------------

local RULE_ITEMS = {
  { key = "progress", label = "Progress" },
  { key = "reading", label = "Currently Reading" },
  { key = "read", label = "Read" },
  { key = "rating", label = "Rating" },
}

function HardcoverMenu:bookFile()
  return self.ui.document and self.ui.document.file
end

-- the book's rule for one item (nil: follows the global setting)
function HardcoverMenu:ruleValue(item)
  return self.settings:bookRule(self:bookFile(), item)
end

-- is this rule value one of the "always" kind (switched on for the book)?
local function isAlways(item, rule)
  if item == "progress" then
    return rule == "always"
  elseif item == "rating" then
    return rule == "ask"
  end
  return rule == "auto" or rule == "ask"
end

-- writes rules for several items at once: changes = { progress = "always", rating = false, ... }
-- (false removes a rule so the book follows the global setting again)
function HardcoverMenu:setRules(changes)
  local file = self:bookFile()
  if not file then
    return
  end

  local config = { _delete = {} }
  for item, value in pairs(changes) do
    local key = self.settings.RULE_KEYS[item]
    if value then
      config[key] = value
    else
      table.insert(config._delete, key)
    end
  end
  self.settings:updateBookSetting(file, config)
end

-- short text for the right-hand side of the two menu entries
function HardcoverMenu:ruleSummary(kind)
  local names = {}
  for _i, item in ipairs(RULE_ITEMS) do
    local rule = self:ruleValue(item.key)
    if (kind == "always" and isAlways(item.key, rule)) or (kind == "never" and rule == "never") then
      table.insert(names, item.label)
    end
  end
  if #names == 0 then
    return ""
  elseif #names == #RULE_ITEMS then
    return _("All")
  end
  return table.concat(names, ", ")
end

function HardcoverMenu:ruleModeLabel(rule)
  if rule == "auto" then
    return _("Automatic")
  elseif rule == "ask" then
    return _("Ask first")
  elseif rule == "never" then
    return _("Never (set under Never sync this book)")
  end
  return _("Follow global setting")
end

function HardcoverMenu:getAlwaysSyncItems()
  local function statusItem(item, label)
    local function option(text, value)
      return {
        text = text,
        radio = true,
        checked_func = function()
          return self:ruleValue(item) == value
        end,
        callback = function(menu_instance)
          self:setRules({ [item] = value or false })
          if menu_instance and menu_instance.updateItems then
            menu_instance:updateItems()
          end
        end,
        keep_menu_open = true,
      }
    end

    return {
      text_func = function()
        return label .. ": " .. self:ruleModeLabel(self:ruleValue(item))
      end,
      checked_func = function()
        return isAlways(item, self:ruleValue(item))
      end,
      sub_item_table = {
        option(_("Follow global setting"), nil),
        option(_("Automatic"), "auto"),
        option(_("Ask first"), "ask"),
      },
    }
  end

  return {
    {
      text = _("Enable all"),
      checked_func = function()
        for _i, item in ipairs(RULE_ITEMS) do
          if not isAlways(item.key, self:ruleValue(item.key)) then
            return false
          end
        end
        return true
      end,
      callback = function(menu_instance)
        local all_on = true
        for _i, item in ipairs(RULE_ITEMS) do
          if not isAlways(item.key, self:ruleValue(item.key)) then
            all_on = false
          end
        end

        if all_on then
          self:setRules({ progress = false, reading = false, read = false, rating = false })
        else
          local reading = self:ruleValue("reading")
          local read = self:ruleValue("read")
          self:setRules({
            progress = "always",
            reading = (reading == "ask") and "ask" or "auto",
            read = (read == "ask") and "ask" or "auto",
            rating = "ask",
          })
        end
        menu_instance:updateItems()
      end,
      keep_menu_open = true,
      separator = true,
    },
    {
      text = _("Progress"),
      checked_func = function()
        return self:ruleValue("progress") == "always"
      end,
      callback = function(menu_instance)
        local on = self:ruleValue("progress") == "always"
        self:setRules({ progress = (not on) and "always" or false })
        menu_instance:updateItems()
      end,
      keep_menu_open = true,
    },
    statusItem("reading", _("Currently Reading")),
    statusItem("read", _("Read")),
    {
      text = _("Rating (ask after marking Read)"),
      checked_func = function()
        return self:ruleValue("rating") == "ask"
      end,
      callback = function(menu_instance)
        local on = self:ruleValue("rating") == "ask"
        self:setRules({ rating = (not on) and "ask" or false })
        menu_instance:updateItems()
      end,
      keep_menu_open = true,
    },
  }
end

function HardcoverMenu:getNeverSyncItems()
  local file = self:bookFile()

  local function neverItem(item, label, menu_text)
    return {
      text = menu_text or label,
      checked_func = function()
        return self:ruleValue(item) == "never"
      end,
      callback = function(menu_instance)
        local current = self:ruleValue(item)
        if current == "never" then
          self:setRules({ [item] = false })
          menu_instance:updateItems()
          return
        end

        local apply = function()
          self:setRules({ [item] = "never" })
          self.queue:dropParts(self:bookFile(), item)
          menu_instance:updateItems()
        end

        if self.queue:pendingParts(self:bookFile())[item] then
          self.dialog_manager:confirm({
            text = T(_("Stop syncing %1 for this book?\n\nThis will clear any %1 updates pending for this title."), label),
            ok_text = _("Yes"),
            ok_callback = apply,
          })
        else
          apply()
        end
      end,
      keep_menu_open = true,
    }
  end

  return {
    {
      text = _("Enable all"),
      checked_func = function()
        for _i, item in ipairs(RULE_ITEMS) do
          if self:ruleValue(item.key) ~= "never" then
            return false
          end
        end
        return true
      end,
      callback = function(menu_instance)
        local all_never = true
        for _i, item in ipairs(RULE_ITEMS) do
          if self:ruleValue(item.key) ~= "never" then
            all_never = false
          end
        end

        if all_never then
          self:setRules({ progress = false, reading = false, read = false, rating = false })
          menu_instance:updateItems()
          return
        end

        self.dialog_manager:confirm({
          text = _("Are you sure you want to disable all updates to Hardcover for this book?\n\nThis will clear all Hardcover sync updates pending for this title."),
          ok_text = _("Yes"),
          ok_callback = function()
            self:setRules({ progress = "never", reading = "never", read = "never", rating = "never" })
            self.queue:dropParts(self:bookFile(), "all")
            menu_instance:updateItems()
          end,
        })
      end,
      keep_menu_open = true,
      separator = true,
    },
    neverItem("progress", _("Progress")),
    neverItem("reading", _("Currently Reading")),
    neverItem("read", _("Read")),
    neverItem("rating", _("Rating")),
  }
end

-- One row per book waiting in the offline queue; tapping a row offers to remove it
function HardcoverMenu:getPendingItems()
  local items = {}

  for _i, row in ipairs(self.queue:pendingList()) do
    table.insert(items, {
      text = row.title,
      mandatory = row.what,
      callback = function(menu_instance)
        local lines = { row.title, row.what }
        if not row.linked then
          table.insert(lines, _("Not linked to a Hardcover book yet"))
        end
        if row.failures > 0 then
          table.insert(lines, T(_("Failed tries: %1"), row.failures))
        end
        if row.last_error then
          table.insert(lines, T(_("Last problem: %1"), row.last_error))
        end
        table.insert(lines, "")
        table.insert(lines, _("Remove this update from the queue without sending it?"))

        self.dialog_manager:confirm({
          text = table.concat(lines, "\n"),
          ok_text = _("Remove"),
          ok_callback = function()
            self.queue:discard(row.file, row.title, "removed from the pending list")
            menu_instance.item_table = self:getPendingItems()
            menu_instance:updateItems()
          end,
        })
      end,
      keep_menu_open = true,
    })
  end

  if #items == 0 then
    table.insert(items, {
      text = _("Nothing is waiting"),
      enabled = false,
    })
  end

  return items
end

return HardcoverMenu
