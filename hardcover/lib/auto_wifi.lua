local NetworkMgr = require("ui/network/manager")

-- Small helpers around KOReader's own wifi handling. The plugin never switches wifi on by itself:
-- when wifi is off, updates are kept in the offline queue (see queue.lua) and sent later.
local AutoWifi = {}
AutoWifi.__index = AutoWifi

function AutoWifi:new(o)
  return setmetatable(o, self)
end

-- Runs callback(false) straight away when wifi is on. When it is off nothing happens.
function AutoWifi:withWifi(callback)
  if NetworkMgr:isWifiOn() then
    callback(false)
  end
end

function AutoWifi:wifiDisableSilent()
  NetworkMgr:turnOffWifi(function()
    -- explicitly disable wifi was on
    NetworkMgr.wifi_was_on = false
    G_reader_settings:saveSetting("wifi_was_on", false)
  end)
end

-- Runs callback(wifi_was_turned_on) once wifi is on, asking KOReader to turn it on if needed
function AutoWifi:wifiPrompt(callback)
  if NetworkMgr:isWifiOn() then
    if callback then
      callback(false)
    end

    return
  end

  if G_reader_settings:isTrue("airplanemode") then
    return
  end

  NetworkMgr:promptWifiOn(callback and function() callback(true) end or nil)
end

function AutoWifi:wifiDisablePrompt()
  NetworkMgr:toggleWifiOff()
end

return AutoWifi
