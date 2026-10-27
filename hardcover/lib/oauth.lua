local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local http = require("socket.http")
local socket_url = require("socket.url")
local socketutil = require("socketutil")

local VERSION = require("hardcover_version")

-- Sign in with Hardcover, using the "device authorization" flow: the e-reader shows a short code,
-- the user approves it on a phone or computer, and the plugin receives a token it can renew.
-- The API key in hardcover_config.lua is the alternative (see hardcover_api.lua).
-- Hardcover's guide: https://docs.hardcover.app/api/oauth/getting-started-device/

-- A public client: there is no secret, so the id is safe to ship with the plugin
local CLIENT_ID = "b9e5af53-fcc8-4f7e-a349-6cb219ab2475"

-- Only what the plugin uses: your profile, library (read and write), catalog search and lookups
local SCOPE = "read:me read:library write:library read:catalog offline_access"

local DEVICE_ENDPOINT = "https://api.hardcover.app/oauth2/device"
local TOKEN_ENDPOINT = "https://api.hardcover.app/oauth2/token"
local REVOKE_ENDPOINT = "https://api.hardcover.app/oauth2/revoke"

-- Renew the access token this many seconds before it runs out
local RENEW_MARGIN = 60

local Oauth = {}

local store

-- The tokens live in their own file in KOReader's settings folder, separate from the plugin's
-- ordinary settings, so the file can be kept private on its own.
local function tokens()
  if not store then
    store = LuaSettings:open(DataStorage:getSettingsDir() .. "/hardcoversync_auth.lua")
  end
  return store
end

local function saveTokens(body)
  local file = tokens()
  file:saveSetting("access_token", body.access_token)
  -- a renewal may hand back a new refresh token; keep the old one if it does not
  file:saveSetting("refresh_token", body.refresh_token or file:readSetting("refresh_token"))
  file:saveSetting("expires_at", os.time() + (tonumber(body.expires_in) or 3600))
  file:flush()
end

local function clearTokens()
  local file = tokens()
  file:delSetting("access_token")
  file:delSetting("refresh_token")
  file:delSetting("expires_at")
  file:flush()
end

-- Sends a form-encoded POST. Returns the HTTP status (a number, or text when the request itself
-- failed) and the decoded JSON answer (nil when there was none).
local function postForm(url, fields)
  local parts = {}
  for key, value in pairs(fields) do
    parts[#parts + 1] = socket_url.escape(key) .. "=" .. socket_url.escape(value)
  end
  local body = table.concat(parts, "&")

  local sink = {}
  socketutil:set_timeout(8, 15)
  local ok, code = pcall(function()
    local _, status = http.request {
      url = url,
      method = "POST",
      headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["Content-Length"] = tostring(#body),
        ["Accept"] = "application/json",
        ["User-Agent"] = "hardcoverapp.koplugin/" .. table.concat(VERSION, "."),
      },
      source = ltn12.source.string(body),
      sink = socketutil.table_sink(sink),
    }
    return status
  end)
  socketutil:reset_timeout()

  if not ok then
    logger.warn("HARDCOVER oauth: request failed: " .. tostring(code))
    return "error", nil
  end

  local decoded_ok, decoded = pcall(json.decode, table.concat(sink), json.decode.simple)
  return code, decoded_ok and type(decoded) == "table" and decoded or nil
end

function Oauth.accessToken()
  return tokens():readSetting("access_token")
end

function Oauth.isSignedIn()
  return Oauth.accessToken() ~= nil
end

-- Step 1 of signing in. Returns the device answer (device_code, user_code, verification_uri,
-- verification_uri_complete, expires_in, interval), or nil and a short reason.
function Oauth.requestDeviceCode()
  local code, body = postForm(DEVICE_ENDPOINT, { client_id = CLIENT_ID, scope = SCOPE })
  if code == 200 and body and body.device_code and body.user_code then
    return body
  end
  logger.warn("HARDCOVER oauth: device code request failed: " .. tostring(code))
  return nil, (body and (body.error_description or body.error)) or "could not reach Hardcover"
end

-- Step 2, repeated until the user has approved. Returns one of:
--   "signed_in"   the tokens are saved
--   "pending"     the user has not approved yet, ask again after the interval
--   "slow_down"   ask again, but wait longer between requests
--   "failed"      the flow is over (denied, expired...), with a reason as a second value
--   "unreachable" no answer from Hardcover, may be tried again
function Oauth.pollDeviceCode(device_code)
  local code, body = postForm(TOKEN_ENDPOINT, {
    grant_type = "urn:ietf:params:oauth:grant-type:device_code",
    device_code = device_code,
    client_id = CLIENT_ID,
  })

  if code == 200 and body and body.access_token then
    saveTokens(body)
    logger.info("HARDCOVER oauth: signed in, access token valid for " .. tostring(body.expires_in) .. " seconds")
    return "signed_in"
  end

  if type(code) ~= "number" or not body then
    return "unreachable"
  end

  local err = body.error
  if err == "authorization_pending" then
    return "pending"
  elseif err == "slow_down" then
    return "slow_down"
  end
  return "failed", err or ("status " .. tostring(code))
end

-- Gets a new access token with the refresh token. Returns true when it worked; false and a reason
-- otherwise: "rejected" (the sign-in is over and must be done again) or "unreachable" (try later).
function Oauth.refresh()
  local refresh_token = tokens():readSetting("refresh_token")
  if not refresh_token then
    return false, "rejected"
  end

  local code, body = postForm(TOKEN_ENDPOINT, {
    grant_type = "refresh_token",
    refresh_token = refresh_token,
    client_id = CLIENT_ID,
  })

  if code == 200 and body and body.access_token then
    saveTokens(body)
    logger.info("HARDCOVER oauth: renewed, access token valid for " .. tostring(body.expires_in) .. " seconds")
    return true
  end

  if code == 400 or code == 401 or code == 403 then
    logger.warn("HARDCOVER oauth: renewal refused (" .. tostring(code) .. " " .. tostring(body and body.error) .. ")")
    clearTokens()
    return false, "rejected"
  end

  return false, "unreachable"
end

-- Renews the access token shortly before it runs out. Does nothing when not signed in this way.
function Oauth.refreshIfNeeded()
  local expires_at = tokens():readSetting("expires_at")
  if Oauth.isSignedIn() and expires_at and os.time() >= expires_at - RENEW_MARGIN then
    return Oauth.refresh()
  end
  return true
end

-- Tells Hardcover to forget this sign-in (so it no longer shows as an active app), then forgets
-- it here. The local tokens are removed even when Hardcover cannot be reached.
function Oauth.signOut()
  local refresh_token = tokens():readSetting("refresh_token")
  if refresh_token then
    postForm(REVOKE_ENDPOINT, {
      token = refresh_token,
      token_type_hint = "refresh_token",
      client_id = CLIENT_ID,
    })
  end
  clearTokens()
end

return Oauth
