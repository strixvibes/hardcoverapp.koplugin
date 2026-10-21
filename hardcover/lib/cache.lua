local Api = require("hardcover/lib/hardcover_api")
local User = require("hardcover/lib/user")

local HARDCOVER = require("hardcover/lib/constants/hardcover")

local Cache = {}
Cache.__index = Cache

function Cache:new(o)
  return setmetatable(o, self)
end

-- Hardcover dates are sent as yyyy-mm-dd (Hardcover displays them in your own format)
local function today()
  return os.date("%Y-%m-%d")
end

-- A read counts as finished only if it carries a real finish date
local function isFinished(read)
  return type(read.finished_at) == "string"
end

function Cache:updateBookStatus(filename, status, privacy_setting_id)
  local settings = self.settings:readBookSettings(filename)
  local book_id = settings.book_id
  local edition_id = settings.edition_id
  local pages = settings.pages

  local user_book = Api:updateUserBook(book_id, status, privacy_setting_id, edition_id)
  if not user_book then
    self.state.book_status = {}
    return
  end

  self.state.book_status = user_book

  local reads = user_book.user_book_reads or {}
  local last_read = reads[#reads]

  if status == HARDCOVER.STATUS.READING then
    -- Start a new read if there is none, or if the latest one is already finished (a re-read).
    -- Older reads are never touched.
    if not last_read or isFinished(last_read) then
      local result = Api:createRead(user_book.id, edition_id or user_book.edition_id, 0, today())
      if result then
        self.state.book_status = result
      end
    end
  elseif status == HARDCOVER.STATUS.FINISHED then
    -- Finishing a book that has no read yet: create one first so it can carry dates
    if not last_read then
      local created = Api:createRead(user_book.id, edition_id or user_book.edition_id, pages, today())
      if created then
        self.state.book_status = created
        last_read = created.user_book_reads and created.user_book_reads[1]
      end
    end

    -- Stamp today's date as the finish date on the current (unfinished) read
    if last_read and not isFinished(last_read) then
      local result = Api:finishRead(
        last_read.id,
        last_read.edition_id or edition_id,
        pages or last_read.progress_pages,
        last_read.started_at,
        today()
      )
      if result then
        self.state.book_status = result
      end
    end
  end
end

function Cache:cacheUserBook()
  local status, errors = Api:findUserBook(self.settings:getLinkedBookId(), User:getId())
  self.state.book_status = status or {}

  return errors
end

return Cache
