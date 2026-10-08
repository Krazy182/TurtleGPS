-- TurtleGPS setup: writes /fleet/config.lua and /startup.lua, then reboots.
-- Run again any time to change settings:  /fleet/bin/setup

package.path = "/fleet/?.lua;" .. package.path
local config = require("lib.config")
local P = require("lib.proto")

local function color(c) if term.isColor() then term.setTextColor(c) end end

local function ask(prompt, default)
  color(colors.yellow)
  write(prompt)
  if default ~= nil and default ~= "" then
    color(colors.lightGray)
    write(" [" .. tostring(default) .. "]")
  end
  color(colors.white)
  write(": ")
  local s = read()
  s = s and s:gsub("^%s+", ""):gsub("%s+$", "") or ""
  if s == "" then return default end
  return s
end

local function askNumber(prompt, default)
  while true do
    local s = ask(prompt, default)
    local n = tonumber(s)
    if n then return n end
    color(colors.red)
    print("Please enter a number.")
  end
end

local function genSecret()
  math.randomseed(os.epoch("utc") + os.getComputerID() * 7919)
  local chars = "abcdefghjkmnpqrstuvwxyz23456789"
  local out = {}
  for i = 1, 20 do
    local k = math.random(1, #chars)
    out[i] = chars:sub(k, k)
  end
  return table.concat(out)
end

term.clear()
term.setCursorPos(1, 1)
color(colors.lime)
print("TurtleGPS setup  -  this is computer #" .. os.getComputerID())
color(colors.white)

local old = config.load() or {}
local kind = turtle and "turtle" or (pocket and "pocket" or "computer")
local defaultRole = old.role or (kind == "turtle" and "turtle" or (kind == "pocket" and "pocket" or nil))
local role
repeat
  role = ask("Role (control, turtle, pocket, gpshost)", defaultRole)
until role == "control" or role == "turtle" or role == "pocket" or role == "gpshost"

local cfg = { role = role }

if role == "control" then
  local secret = ask("Shared secret (blank = generate)", old.secret)
  if not secret or #secret < 8 then
    secret = genSecret()
    color(colors.lime)
    print("Generated secret (type it on every fleet computer):")
    print("  " .. secret)
    color(colors.white)
  end
  cfg.secret = secret
else
  local secret
  repeat
    secret = ask("Shared secret (same as control)", old.secret)
    if not secret or #secret < 8 then color(colors.red); print("At least 8 characters.") end
  until secret and #secret >= 8
  cfg.secret = secret
  cfg.serverId = askNumber("Control computer ID", old.serverId)
end

if role == "control" or role == "gpshost" then
  local d
  repeat
    d = P.normDim(ask("Dimension of this computer (overworld, nether, end)", old.dim or "overworld"))
  until d
  cfg.dim = d
elseif role == "turtle" then
  local d = ask("Dimension (overworld, nether, end; blank = from GPS)", old.dim or "")
  cfg.dim = P.normDim(d)
end

if role == "gpshost" then
  print("Enter THIS computer's block coordinates (F3, look at it: 'Targeted Block').")
  cfg.x = askNumber("x", old.x)
  cfg.y = askNumber("y", old.y)
  cfg.z = askNumber("z", old.z)
end

if role == "control" then
  cfg.owner = ask("Your player name (for Chat Box alerts)", old.owner)
  local ids = ask("Pocket computer IDs allowed to command (comma separated)",
    old.commanders and table.concat(old.commanders, ",") or "")
  cfg.commanders = {}
  for n in tostring(ids or ""):gmatch("%d+") do cfg.commanders[#cfg.commanders + 1] = tonumber(n) end
  cfg.garages = old.garages
  cfg.monitor = old.monitor
end

if role == "pocket" then
  cfg.owner = ask("Your player name", old.owner)
end

if role == "turtle" or role == "pocket" then
  local label = ask("Label", os.getComputerLabel() or old.label or (role .. os.getComputerID()))
  if label then
    cfg.label = label
    os.setComputerLabel(label)
  end
end

local problems = config.problems(cfg)
if #problems > 0 then
  color(colors.red)
  for _, p in ipairs(problems) do print(p) end
  return
end

if not fs.exists("/fleet/data") then fs.makeDir("/fleet/data") end
config.save(cfg)
local startup = 'shell.run("/fleet/boot.lua")\n'
if fs.exists("/startup.lua") then
  local h = fs.open("/startup.lua", "r")
  local cur = h.readAll()
  h.close()
  if cur ~= startup then
    if fs.exists("/startup.lua.bak") then fs.delete("/startup.lua.bak") end
    fs.move("/startup.lua", "/startup.lua.bak")
    print("Old /startup.lua saved as /startup.lua.bak")
  end
end
local h = fs.open("/startup.lua", "w")
h.write(startup)
h.close()

color(colors.lime)
print("Saved /fleet/config.lua")
color(colors.white)
if role == "control" then
  print("Add garages and other options with: edit /fleet/config.lua")
end
local again = ask("Reboot now? (y/n)", "y")
if again == "y" or again == "Y" then os.reboot() end
