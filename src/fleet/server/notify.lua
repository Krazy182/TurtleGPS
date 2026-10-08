-- Alert delivery: Advanced Peripherals Chat Box (private message to the owner) and a
-- speaker chime, both optional. Chat Box calls are queued because the peripheral has
-- a cooldown between messages.

local N = {}
N.__index = N

function N.new(cfg, log)
  local self = setmetatable({ cfg = cfg, log = log, queue = {} }, N)
  self:attach()
  return self
end

function N:attach()
  self.chat = peripheral.find("chatBox")
  self.speaker = peripheral.find("speaker")
  if self.chat and not self.cfg.owner and self.log then
    self.log:warn("Chat Box found but no owner in config: chat alerts disabled")
  end
end

function N:alert(a)
  if self.chat and self.cfg.owner then
    self.queue[#self.queue + 1] = { text = a.text, toast = a.sev >= 3 }
  end
  if self.speaker then
    pcall(self.speaker.playNote, "bell", 1, a.sev >= 3 and 18 or 12)
  end
end

function N:resolved(a, note)
  if self.chat and self.cfg.owner then
    self.queue[#self.queue + 1] = { text = "OK: " .. a.text .. (note and (" (" .. note .. ")") or "") }
  end
end

--- Run in its own coroutine. Chat Box returns nil + reason when on cooldown (retry) or
--- when the owner is offline / misspelled (drop: retrying would block later alerts).
function N:pump()
  while true do
    local item = self.queue[1]
    if item and self.chat then
      local ok, res, err = pcall(function()
        if item.toast and self.chat.sendToastToPlayer then
          return self.chat.sendToastToPlayer(item.text, "TurtleGPS alert", self.cfg.owner, "TurtleGPS")
        end
        return self.chat.sendMessageToPlayer(item.text, self.cfg.owner, "TurtleGPS")
      end)
      item.tries = (item.tries or 0) + 1
      local retry = ok and not res and tostring(err):lower():find("cooldown") and item.tries < 10
      if not retry then
        table.remove(self.queue, 1)
        if not ok or not res then
          self.lastError = tostring(ok and err or res)
          if self.log then self.log:warn("chat alert not delivered: %s", self.lastError) end
        else
          self.lastError = nil
        end
      end
      sleep(retry and 1.5 or 1)
    else
      if #self.queue > 0 and not self.chat then self.queue = {} end
      sleep(0.5)
    end
  end
end

return N
