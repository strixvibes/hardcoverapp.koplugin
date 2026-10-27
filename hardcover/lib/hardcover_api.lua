local logger = require("logger")

-- The API key file is optional: without it the plugin uses the token from "Sign in to Hardcover"
-- (see oauth.lua)
local config_loaded, config = pcall(require, "hardcover_config")
local key_file_present = config_loaded and type(config) == "table"
local config_token = key_file_present and config.token or nil

-- Spaces around the key are ignored. A key may only contain the characters that are allowed in a
-- bearer token (letters, digits and - . _ ~ + / = :); anything else, including a blank key, is
-- refused here rather than sent to Hardcover. The file still counts as present (see
-- HardcoverApi:hasKeyFile), so the user is told the API key is invalid. The format of the key
-- itself (prefix, length) is deliberately not checked, so a change by Hardcover cannot break it.
if type(config_token) == "string" then
  config_token = config_token:match("^%s*(.-)%s*$")
  if not config_token:find("^[A-Za-z0-9%-%._~%+/=:]+$") then
    if config_token ~= "" then
      logger.warn("HARDCOVER: the API key in hardcover_config.lua contains characters a key cannot have")
    end
    config_token = nil
  end
else
  config_token = nil
end
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local _t = require("hardcover/lib/table_util")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local socketutil = require("socketutil")

local Book = require("hardcover/lib/book")
local Oauth = require("hardcover/lib/oauth")
local HARDCOVER = require("hardcover/lib/constants/hardcover")
local VERSION = require("hardcover_version")

local api_url = "https://api.hardcover.app/v1/graphql"

local user_agent = T("hardcoverapp.koplugin/%1 (https://github.com/strixvibes/hardcoverapp.koplugin)",
  table.concat(VERSION, "."))

-- Set once Hardcover has refused the API key. The key is then not used again until KOReader is
-- restarted (the user has to correct it), and the plugin treats it like having no key.
local key_rejected = false

-- The token for the next request: the signed-in token if there is one, else the API key
local function currentToken()
  return Oauth.accessToken() or (not key_rejected and config_token or nil)
end

local function requestHeaders()
  return {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = user_agent,
    Authorization = "Bearer " .. currentToken(),
  }
end

-- Whether Hardcover's answer means "your token is not valid (any more)"
local function isTokenError(err)
  return err == HARDCOVER.ERROR.TOKEN
    or _t.dig(err, "extensions", "code") == HARDCOVER.ERROR.JWT
    or (type(err) == "table" and err.message and string.find(err.message, "JWT") ~= nil)
end

local HardcoverApi = {
  enabled = true
}

-- Hardcover can answer a mutation with an "error" text instead of the object; turn that into
-- the same error shape that HardcoverApi:query() uses
local function mutationError(result, key, err)
  if err then
    return err
  end
  local payload = result and result[key]
  if payload and payload.error then
    return { errors = { { message = tostring(payload.error) } } }
  end
end

local book_fragment = [[
fragment BookParts on books {
  book_id: id
  title
  release_year
  users_read_count
  pages
  book_series {
    position
    series {
      name
    }
  }
  contributions: cached_contributors
  cached_image
  user_books(where: { user_id: { _eq: $userId }}) {
    id
  }
}]]

local edition_fragment = book_fragment .. [[
fragment EditionParts on editions {
  id
  book {
    ...BookParts
  }
  cached_image
  edition_format
  language {
    code2
    language
  }
  pages
  publisher {
    name
  }
  release_date
  reading_format_id
  title
  users_count
}]]

local user_book_fragment = [[
fragment UserBookParts on user_books {
  id
  book_id
  status_id
  edition_id
  privacy_setting_id
  rating
  user_book_reads(order_by: {id: asc}) {
    id
    started_at
    finished_at
    progress_pages
    edition_id
    edition {
      pages
    }
  }
}]]

function HardcoverApi:me()
  local result = self:query([[{
    me {
      id
      account_privacy_setting_id
    }
  }]])

  if result and result.me then
    return result.me[1]
  end
  return {}
end

function HardcoverApi:hasCredentials()
  return currentToken() ~= nil
end

-- The sign-in has stopped working and was removed. When a usable API key is there to take over,
-- on_signin_lost() lets the plugin say so.
function HardcoverApi:signInLost()
  if config_token and not key_rejected and self.on_signin_lost then
    self.on_signin_lost()
  end
end

-- true when hardcover_config.lua exists, whatever it contains: the user has chosen to use an API key
function HardcoverApi:hasKeyFile()
  return key_file_present
end

-- true when requests are meant to use the API key from hardcover_config.lua (not a signed-in token)
function HardcoverApi:usesApiKey()
  return key_file_present and not Oauth.isSignedIn()
end

function HardcoverApi:query(query, parameters, renewed)
  if not NetworkManager:isConnected() or not self.enabled then
    return
  end

  if not self:hasCredentials() then
    if self.on_error then
      self.on_error(HARDCOVER.ERROR.TOKEN)
    end
    return nil, { no_credentials = true }
  end

  -- a signed-in token is renewed before it runs out (an API key never needs this)
  if Oauth.isSignedIn() and not renewed then
    local _ok, why = Oauth.refreshIfNeeded()
    if why == "rejected" then
      self:signInLost()
      return self:query(query, parameters, true)
    end
  end

  local completed, success, content

  completed, content = Trapper:dismissableRunInSubprocess(function()
    return self:_query(query, parameters)
  end, true, true)

  if completed and content then
    local code, response = string.match(content, "^([^:]*):(.*)")
    if string.find(code, "^%d%d%d") then
      local decoded_ok, data = pcall(json.decode, response, json.decode.simple)
      if not decoded_ok or type(data) ~= "table" then
        data = {}
      end
      if data.data then
        return data.data
      elseif data.errors or data.error or code == "401" then
        -- a 401 always means the token was refused, whatever the answer says
        local err = data.errors or { data.error or HARDCOVER.ERROR.TOKEN }

        -- a signed-in token Hardcover no longer accepts: renew it and ask again, once
        if not renewed and Oauth.isSignedIn() and (code == "401" or isTokenError(err[1])) then
          local renewed_ok, why = Oauth.refresh()
          if renewed_ok or not Oauth.isSignedIn() then
            if not renewed_ok then
              self:signInLost()
            end
            return self:query(query, parameters, true)
          elseif why == "unreachable" then
            -- could not renew right now: treated like any other failed request, tried again later
            return nil, { completed = false }
          end
        end

        local token_refused = code == "401"
        for _, e in ipairs(err) do
          if isTokenError(e) then
            token_refused = true
          end
        end
        -- Hardcover refused the API key: it is not used again (see key_rejected)
        if token_refused and not Oauth.isSignedIn() then
          key_rejected = true
        end

        if self.on_error then
          for _, e in ipairs(err) do
            self.on_error(e)
          end
          if token_refused then
            self.on_error(HARDCOVER.ERROR.TOKEN)
          end
        end

        return nil, { errors = err }
      end
    else
      return nil, { completed = false }
    end
  else
    return nil, { completed = completed }
  end
end

function HardcoverApi:_query(query, parameters)
  local requestBody = {
    query = query,
    variables = parameters
  }

  local maxtime = 12
  local timeout = 6

  local sink = {}
  socketutil:set_timeout(timeout, maxtime or 30)
  local request = {
    url = api_url,
    method = "POST",
    headers = requestHeaders(),
    source = ltn12.source.string(json.encode(requestBody)),
    sink = socketutil.table_sink(sink),
  }

  local _, code, _headers, _status = http.request(request)
  socketutil:reset_timeout()

  local content = table.concat(sink) -- empty or content accumulated till now
  --logger.warn(requestBody)
  if code == socketutil.TIMEOUT_CODE or
    code == socketutil.SSL_HANDSHAKE_CODE or
    code == socketutil.SINK_TIMEOUT_CODE
  then
    logger.warn("request interrupted:", code)
    return code .. ':'
  end

  if type(code) == "string" then
    logger.dbg("Request error", code)
  end

  if type(code) == "number" and (code < 200 or code > 299) then
    logger.dbg("Request error", code, content)
  end

  return code .. ':' .. content
end

function HardcoverApi:hydrateBooks(ids, user_id)
  if #ids == 0 then
    return {}
  end

  -- hydrate ids
  local bookQuery = [[
    query ($ids: [Int!], $userId: Int!) {
      books(where: { id: { _in: $ids }}) {
        ...BookParts
      }
    }
  ]] .. book_fragment

  local books = self:query(bookQuery, { ids = ids, userId = user_id })
  if books then
    local list = books.books

    if #list > 1 then
      local id_order = {}

      for i, v in ipairs(ids) do
        id_order[v] = i
      end

      -- sort books by original ID order
      table.sort(list, function(a, b)
        return id_order[a.book_id] < id_order[b.book_id]
      end)
    end

    return list
  end
end

function HardcoverApi:hydrateBookFromEdition(edition_id, user_id)
  local editionSearch = [[
    query ($id: Int!, $userId: Int!) {
      editions(where: { id: { _eq: $id }}) {
        ...EditionParts
      }
    }]] .. edition_fragment

  local editions = self:query(editionSearch, { id = edition_id, userId = user_id })
  if editions and editions.editions and #editions.editions > 0 then
    return self:normalizedEdition(editions.editions[1])
  end
end

function HardcoverApi:findBookBySlug(slug, user_id)
  local slugSearch = [[
    query ($slug: String!, $userId: Int!) {
      books(where: { slug: { _eq: $slug }}) {
        ...BookParts
      }
    }]] .. book_fragment

  local books = self:query(slugSearch, { slug = slug, userId = user_id })
  if books and books.books and #books.books > 0 then
    return books.books[1]
  end
end

function HardcoverApi:findEditions(book_id, user_id)
  local edition_search = [[
    query ($id: Int!, $userId: Int!) {
      editions(where: { book_id: { _eq: $id }, _or: [{reading_format_id: { _is_null: true }}, {reading_format_id: { _neq: 2 }} ]},
      order_by: { users_count: desc_nulls_last }) {
        ...EditionParts
      }
    }]] .. edition_fragment

  local editions = self:query(edition_search, { id = book_id, userId = user_id })
  if not editions or not editions.editions then
    return {}
  end
  local edition_list = editions.editions

  if #edition_list > 1 then
    -- prefer editions with user reads
    local edition_ids = _t.map(edition_list, function(edition)
      return edition.id
    end)

    local read_search = [[
      query ($ids: [Int!], $userId: Int!) {
        user_books(where: { edition_id: { _in: $ids }, user_id: { _eq: $userId }}) {
          edition_id
        }
      }
    ]]

    local read_editions = self:query(read_search, { ids = edition_ids, userId = user_id })
    if not read_editions then
      return nil
    end
    local read_index = {}
    for _, read in ipairs(read_editions) do
      read_index[read.edition_id] = true
    end

    table.sort(edition_list, function(a, b)
      -- sort by user reads
      local read_a = read_index[a.id]
      local read_b = read_index[b.id]

      if read_a ~= read_b then
        return read_a == true
      end

      if a.reading_format_id ~= b.reading_format_id then
        return a.reading_format_id == 4
      end

      if a.users_count ~= b.users_count then
        return a.users_count > b.users_count
      end
    end)
  end

  return _t.map(edition_list, function(edition)
    return self:normalizedEdition(edition)
  end)
end

function HardcoverApi:search(title, author, userId, page)
  page = page or 1
  local query = [[
    query ($query: String!, $page: Int!) {
      search(query: $query, per_page: 25, page: $page, query_type: "Book") {
        ids
      }
    }]]
  local search = title .. " " .. (author or "")
  local results, error = self:query(query, { query = search, page = page })
  if error then
    return nil, error
  end

  if not results or not _t.dig(results, "search", "ids") then
    return {}
  end

  local ids = _t.map(results.search.ids, function(id) return tonumber(id) end)
  return self:hydrateBooks(ids, userId)
end

function HardcoverApi:findBookByIdentifiers(identifiers, user_id)
  local isbnKey

  if identifiers.edition_id then
    local book = self:hydrateBookFromEdition(identifiers.edition_id, user_id)
    if book then
      return book
    end
  end

  if identifiers.book_slug then
    local book = self:findBookBySlug(identifiers.book_slug, user_id)
    if book then
      return book
    end
  end

  if identifiers.isbn_13 then
    isbnKey = 'isbn_13'
  elseif identifiers.isbn_10 then
    isbnKey = 'isbn_10'
  end

  if isbnKey then
    local editionSearch = [[
      query ($isbn: String!, $userId: Int!) {
        editions(where: { ]] .. isbnKey .. [[: { _eq: $isbn }}) {
          ...EditionParts
        }
      }]] .. edition_fragment

    local editions = self:query(editionSearch, { isbn = tostring(identifiers[isbnKey]), userId = user_id })
    if editions and editions.editions and #editions.editions > 0 then
      return self:normalizedEdition(editions.editions[1])
    end
  end
end

function HardcoverApi:normalizedEdition(edition)
  local result = edition.book

  result.edition_id = edition.id
  result.edition_format = Book:editionFormatName(edition.edition_format, edition.reading_format_id)

  result.cached_image = edition.cached_image
  result.publisher = edition.publisher
  if edition.release_date then
    local year = edition.release_date:match("^(%d%d%d%d)-")
    result.release_year = year
  else
    result.release_year = nil
  end
  result.language = edition.language
  result.title = edition.title
  result.reads = edition.reads
  result.pages = edition.pages
  result.filetype = result.edition_format or "Physical Book"
  result.users_count = edition.users_count

  return result
end

function HardcoverApi:normalizeUserBookRead(user_book_read)
  local user_book = user_book_read.user_book
  user_book_read.user_book = nil
  user_book.user_book_reads = { user_book_read }
  return user_book
end

-- Progress is counted in pages of one particular edition. Hardcover shows a read's percentage
-- against the edition that read belongs to, which is not always the edition the book was linked
-- with here. This converts a page number counted in the linked edition (`base_pages` long) to
-- the same place in the read's own edition. Never reaches the last page unless the input did.
function HardcoverApi:scalePagesToRead(read, pages, base_pages)
  local read_pages = read and read.edition and tonumber(read.edition.pages)
  base_pages = tonumber(base_pages)
  if not (pages and read_pages and read_pages > 0 and base_pages and base_pages > 0) or read_pages == base_pages then
    return pages
  end

  local scaled = math.floor(pages / base_pages * read_pages + 0.5)
  scaled = math.max(0, math.min(read_pages, scaled))
  if pages < base_pages and scaled >= read_pages and read_pages > 1 then
    scaled = read_pages - 1
  end
  return scaled
end

function HardcoverApi:findBooks(title, author, userId)
  if not title or string.match(title, "^%s*$") then
    return {}
  end

  title = title:gsub(":.+", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return self:search(title, author, userId)
end

function HardcoverApi:getRandomToRead(user_id, limit)
  limit = limit or 10

  local read_query = [[
    query ($userId: Int!) {
      user_books(where: { status_id: { _eq:1 }, user_id: { _eq: $userId }}) {
        book_id
      }
    }
  ]]
  local results, err = self:query(read_query, { userId = user_id })
  if not results or not results.user_books then
    return {}, err
  end

  if not results or not results.user_books then
    return {}
  end

  local ids = _t.map(results.user_books, function(result) return tonumber(result.book_id) end)
  _t.shuffle(ids)

  return self:hydrateBooks(_t.slice(ids, 1, limit), user_id)
end

function HardcoverApi:findUserBook(book_id, user_id)
  -- this may not be adequate, as (it's possible) there could be more than one read in progress? Maybe?
  local read_query = [[
    query ($id: Int!, $userId: Int!) {
      user_books(where: { book_id: { _eq: $id }, user_id: { _eq: $userId }}) {
        ...UserBookParts
      }
    }
  ]] .. user_book_fragment

  local results, err = self:query(read_query, { id = book_id, userId = user_id })
  if not results or not results.user_books then
    return {}, err
  end

  return results.user_books[1]
end

function HardcoverApi:findDefaultEdition(book_id, user_id)
  -- prefer:
  -- 1. most recent matching user read
  -- 2. a user book
  -- 3. default ebook edition
  -- 4. default physical edition
  -- 5. most read book edition
  local user_edition_fragment = [[
    fragment UserEditionParts on editions {
      id
      edition_format
      reading_format_id
      pages
    }
  ]]
  local user_book_query = [[
    query ($bookId: Int!, $userId: Int!) {
      user_books(limit: 1, where: { book_id: { _eq: $bookId}, user_id: { _eq: $userId }}) {
        edition {
          ...UserEditionParts
        }
        user_book_reads(limit: 1, order_by: {id: asc}) {
          edition {
            ...UserEditionParts
          }
        }
      }
    }
  ]] .. user_edition_fragment

  local user_book_results = self:query(user_book_query, { bookId = book_id, userId = user_id })
  if user_book_results then
    local user_book = _t.dig(user_book_results, "user_books", 1)
    if user_book then
      local read_edition = _t.dig(user_book, "user_book_reads", 1, "edition")
      if read_edition then
        return read_edition
      end
      return user_book.edition
    end
  end

  local default_edition_query = [[
    query ($bookId: Int!) {
     books_by_pk(id: $bookId) {
        default_physical_edition {
          ...UserEditionParts
        }
        default_ebook_edition {
          ...UserEditionParts
        }
      }
    }
  ]] .. user_edition_fragment
  local default_edition_results = self:query(default_edition_query, { bookId = book_id })
  if default_edition_results then
    if default_edition_results.books_by_pk.default_ebook_edition then
      return default_edition_results.books_by_pk.default_ebook_edition
    end

    if default_edition_results.books_by_pk.default_physical_edition then
      return default_edition_results.books_by_pk.default_physical_edition
    end
  end

  local edition_query = [[
    query ($bookId: Int!) {
      editions(
        limit: 1
        where: {book_id: {_eq: $bookId}}
        order_by: {users_count: desc_nulls_last}
      ) {
        ...UserEditionParts
      }
    }
  ]] .. user_edition_fragment
  local edition_results = self:query(edition_query, { bookId = book_id })
  if edition_results then
    return _t.dig(edition_results, "editions", 1)
  end
end

function HardcoverApi:createRead(user_book_id, edition_id, page, started_at)
  local query = [[
    mutation InsertUserBookRead($id: Int!, $pages: Int, $editionId: Int, $startedAt: date) {
      insert_user_book_read(user_book_id: $id, user_book_read: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
      }) {
        error
        user_book_read {
          id
          started_at
          finished_at
          edition_id
          progress_pages
          edition {
            pages
          }
          user_book {
            id
            book_id
            status_id
            edition_id
            privacy_setting_id
            rating
          }
        }
      }
    }
  ]]

  local result, err = self:query(query, { id = user_book_id, pages = page, editionId = edition_id, startedAt = started_at })
  if result and result.insert_user_book_read and result.insert_user_book_read.user_book_read then
    return self:normalizeUserBookRead(result.insert_user_book_read.user_book_read)
  end
  return nil, mutationError(result, "insert_user_book_read", err)
end

function HardcoverApi:updatePage(user_read_id, edition_id, page, started_at)
  local query = [[
    mutation UpdateBookProgress($id: Int!, $pages: Int, $editionId: Int, $startedAt: date) {
      update_user_book_read(id: $id, object: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
      }) {
        error
        user_book_read {
          id
          started_at
          finished_at
          edition_id
          progress_pages
          edition {
            pages
          }
          user_book {
            id
            book_id
            status_id
            edition_id
            privacy_setting_id
            rating
          }
        }
      }
    }
  ]]

  local result, err = self:query(query, { id = user_read_id, pages = page, editionId = edition_id, startedAt = started_at })
  if result and result.update_user_book_read and result.update_user_book_read.user_book_read then
    return self:normalizeUserBookRead(result.update_user_book_read.user_book_read)
  end
  return nil, mutationError(result, "update_user_book_read", err)
end

function HardcoverApi:finishRead(user_read_id, edition_id, page, started_at, finished_at)
  local query = [[
    mutation FinishBookRead($id: Int!, $pages: Int, $editionId: Int, $startedAt: date, $finishedAt: date) {
      update_user_book_read(id: $id, object: {
        progress_pages: $pages,
        edition_id: $editionId,
        started_at: $startedAt,
        finished_at: $finishedAt,
      }) {
        error
        user_book_read {
          id
          started_at
          finished_at
          edition_id
          progress_pages
          edition {
            pages
          }
          user_book {
            id
            book_id
            status_id
            edition_id
            privacy_setting_id
            rating
          }
        }
      }
    }
  ]]

  local result, err = self:query(query, {
    id = user_read_id,
    pages = page,
    editionId = edition_id,
    startedAt = started_at,
    finishedAt = finished_at
  })
  if result and result.update_user_book_read and result.update_user_book_read.user_book_read then
    return self:normalizeUserBookRead(result.update_user_book_read.user_book_read)
  end
  return nil, mutationError(result, "update_user_book_read", err)
end

function HardcoverApi:updateUserBook(book_id, status_id, privacy_setting_id, edition_id)
  if not privacy_setting_id then
    local me = self:me()
    privacy_setting_id = me.account_privacy_setting_id or 1
  end

  local query = [[
    mutation ($object: UserBookCreateInput!) {
      insert_user_book(object: $object) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  local update_args = {
    book_id = book_id,
    privacy_setting_id = privacy_setting_id,
    status_id = status_id,
    edition_id = edition_id
  }

  local result, err = self:query(query, { object = update_args })
  if result and result.insert_user_book and result.insert_user_book.user_book then
    return result.insert_user_book.user_book
  end
  return nil, mutationError(result, "insert_user_book", err)
end

function HardcoverApi:updateRating(user_book_id, rating)
  local query = [[
    mutation ($id: Int!, $rating: numeric) {
      update_user_book(id: $id, object: { rating: $rating }) {
        error
        user_book {
          ...UserBookParts
        }
      }
    }
  ]] .. user_book_fragment

  if rating == 0 or rating == nil then
    rating = json.util.null
  end

  local result, err = self:query(query, { id = user_book_id, rating = rating })
  if result and result.update_user_book and result.update_user_book.user_book then
    return result.update_user_book.user_book
  end
  return nil, mutationError(result, "update_user_book", err)
end

function HardcoverApi:removeRead(user_book_id)
  local query = [[
    mutation($id: Int!) {
      delete_user_book(id: $id) {
        id
      }
    }
  ]]
  local result = self:query(query, { id = user_book_id })
  if result then
    return result.delete_user_book
  end
end

function HardcoverApi:createJournalEntry(object)
  local query = [[
    mutation InsertReadingJournalEntry($object: ReadingJournalCreateType!) {
      insert_reading_journal(object: $object) {
        reading_journal {
          id
        }
      }
    }
  ]]

  local result = self:query(query, { object = object })
  if result then
    return result.insert_reading_journal.reading_journal
  end
end

return HardcoverApi
