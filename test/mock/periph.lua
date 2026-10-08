-- Mock peripherals: wireless/ender modem, monitor, Advanced Peripherals player
-- detector and chat box, speaker.

local Screen = require("mock.screen")

local Periph = {}

function Periph.modem(sim, c, side, ender)
  local p = { type = "modem", side = side, wireless = true, ender = ender ~= false, channels = {} }
  local m = {}
  local function check(ch)
    if type(ch) ~= "number" or ch < 0 or ch > 65535 then error("Expected number in range 0-65535", 3) end
  end
  function m.open(ch) check(ch); p.channels[ch] = true end
  function m.close(ch) check(ch); p.channels[ch] = nil end
  function m.isOpen(ch) check(ch); return p.channels[ch] == true end
  function m.closeAll() p.channels = {} end
  function m.isWireless() return true end
  function m.transmit(ch, reply, msg)
    check(ch); check(reply)
    sim:transmit(c, p, ch, reply, msg)
  end
  p.methods = m
  return p
end

function Periph.monitor(sim, c, side, bw, bh)
  local screen = Screen.monitor(bw or 8, bh or 6, true)
  local p = { type = "monitor", side = side, screen = screen }
  p.methods = screen:api()
  return p
end

--- Advanced Peripherals Player Detector. sim.detectorDisabled makes it return nothing.
function Periph.playerDetector(sim, c, side)
  local p = { type = "playerDetector", side = side }
  local m = {}
  function m.getOnlinePlayers()
    local out = {}
    for name, pl in pairs(sim.players) do if pl.online then out[#out + 1] = name end end
    table.sort(out)
    return out
  end
  function m.getPlayerPos(name)
    if sim.detectorDisabled then return nil end
    local pl = sim.players[name]
    if not pl or not pl.online then return nil end
    return {
      x = pl.x, y = pl.y, z = pl.z, dimension = "minecraft:" .. pl.dim,
      eyeHeight = 1.62, yaw = 0, pitch = 0, health = 20, maxHealth = 20,
    }
  end
  m.getPlayer = m.getPlayerPos
  function m.isPlayerInRange() return false end
  function m.getPlayersInRange() return {} end
  p.methods = m
  return p
end

function Periph.chatBox(sim, c, side)
  local p = { type = "chatBox", side = side, last = -1 }
  local m = {}
  local function send(kind, msg, to)
    if sim.t - p.last < 0.5 then return nil, "You are sending messages too often" end
    p.last = sim.t
    sim.chat[#sim.chat + 1] = { t = sim.t, kind = kind, to = to, msg = msg }
    return true
  end
  function m.sendMessage(msg) return send("all", msg) end
  function m.sendMessageToPlayer(msg, player) return send("player", msg, player) end
  function m.sendToastToPlayer(msg, title, player) return send("toast", title .. ": " .. msg, player) end
  p.methods = m
  return p
end

function Periph.speaker(sim, c, side)
  local p = { type = "speaker", side = side }
  local m = {}
  function m.playNote(inst, vol, pitch)
    sim.sounds[#sim.sounds + 1] = { t = sim.t, id = c.id, inst = inst }
    return true
  end
  function m.playSound(name)
    sim.sounds[#sim.sounds + 1] = { t = sim.t, id = c.id, inst = name }
    return true
  end
  p.methods = m
  return p
end

return Periph
