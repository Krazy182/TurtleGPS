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

--- Run in its own coroutine.
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
      if ok and res then
        table.remove(self.queue, 1)
      elseif not ok then
        if self.log then self.log:warn("chat box: %s", tostring(res)) end
        table.remove(self.queue, 1)
      end
      -- res == nil/false means cooldown: retry after the sleep
      if not ok or res then sleep(1) else sleep(1.5) end
    else
      if #self.queue > 0 and not self.chat then self.queue = {} end
      sleep(0.5)
    end
  end
end

return N
