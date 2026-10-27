local http = require("socket.http")
local json = require("json")
local ltn12 = require("ltn12")

local VERSION = require("hardcover_version")

local RELEASE_API = "https://api.github.com/repos/strixvibes/hardcoverapp.koplugin/releases?per_page=1"

local Github = {}

-- Returns the newest release's version (for example "0.6.0") when it is newer than this plugin,
-- otherwise nil. A tag may start with "v".
function Github:newestRelease()
  local responseBody = {}
  local _res, code = http.request {
    url = RELEASE_API,
    sink = ltn12.sink.table(responseBody),
  }

  if code == 200 or code == 304 then
    local ok, data = pcall(json.decode, table.concat(responseBody), json.decode.simple)
    if ok and data and #data > 0 and data[1].tag_name then
      local tag = data[1].tag_name:gsub("^v", "")
      local index = 1
      for str in string.gmatch(tag, "([^.]+)") do
        local part = tonumber(str)
        if not part or not VERSION[index] then
          return nil
        end

        if part < VERSION[index] then
          return nil
        elseif part > VERSION[index] then
          return tag
        end
        index = index + 1
      end
    end
  end
end

return Github
