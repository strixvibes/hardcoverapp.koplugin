local UIManager = require("ui/uimanager")
local NetworkManager = require("ui/network/manager")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local Oauth = require("hardcover/lib/oauth")

-- The "Sign in to Hardcover" screen: shows a web address and a short code, then waits while the
-- user approves the sign-in on a phone or computer.
local SignInDialog = {}

local MAX_UNREACHABLE = 6

-- on_done() runs after a successful sign-in
function SignInDialog.start(on_done)
  NetworkManager:runWhenOnline(function()
    local device, reason = Oauth.requestDeviceCode()
    if not device then
      UIManager:show(InfoMessage:new {
        text = _("Could not start signing in: ") .. tostring(reason),
        icon = "notice-warning",
      })
      return
    end

    local dialog
    local cancelled = false
    local interval = tonumber(device.interval) or 5
    local deadline = os.time() + (tonumber(device.expires_in) or 900)
    local unreachable = 0

    local stop = function()
      cancelled = true
      if dialog then
        UIManager:close(dialog)
        dialog = nil
      end
    end

    local poll
    poll = function()
      if cancelled then
        return
      end
      if os.time() >= deadline then
        stop()
        UIManager:show(InfoMessage:new { text = _("Sign-in timed out. Please try again.") })
        return
      end

      local result, why = Oauth.pollDeviceCode(device.device_code)
      if result == "signed_in" then
        stop()
        UIManager:show(InfoMessage:new { text = _("Signed in to Hardcover"), timeout = 3 })
        if on_done then
          on_done()
        end
        return
      elseif result == "failed" then
        stop()
        UIManager:show(InfoMessage:new {
          text = _("Sign-in did not complete: ") .. tostring(why),
          icon = "notice-warning",
        })
        return
      elseif result == "unreachable" then
        unreachable = unreachable + 1
        if unreachable >= MAX_UNREACHABLE then
          stop()
          UIManager:show(InfoMessage:new {
            text = _("Could not reach Hardcover. Check your connection and try again."),
            icon = "notice-warning",
          })
          return
        end
      else
        unreachable = 0
        if result == "slow_down" then
          interval = interval + 5
        end
      end

      UIManager:scheduleIn(interval, poll)
    end

    local text = _("Sign in to Hardcover") .. "\n\n"
        .. _("1. On your phone or computer, go to:") .. "\n"
        .. tostring(device.verification_uri) .. "\n\n"
        .. _("2. Enter this code:") .. "\n"
        .. tostring(device.user_code) .. "\n\n"
        .. _("Waiting for you to approve...")

    dialog = ButtonDialog:new {
      title = text,
      title_align = "center",
      buttons = { {
        {
          text = _("Cancel"),
          callback = stop,
        },
      } },
    }
    UIManager:show(dialog)
    UIManager:scheduleIn(interval, poll)
  end)
end

return SignInDialog
