-- TurtleGPS setup: writes /fleet/config.lua and /startup.lua, then reboots.
-- Run again any time to change settings:  /fleet/bin/setup
--
-- Fast path (the installer passes its arguments through):
--   setup turtle TG-7-abcd...-1f2e                 -> asks only dimension and label
--   setup gpshost TG-7-... dim=nether x=1 y=90 z=1 -y   -> asks nothing, reboots
-- Arguments: a role, a join code (press J on the control computer), key=value answers
-- (dim, label, owner, x, y, z, commanders), and -y to accept defaults without asking.

package.path = "/fleet/?.lua;" .. package.path
local config = require("lib.config")
local P = require("lib.proto")
local J = require("lib.joincode")

local ROLES = { control = true, turtle = true, pocket = true, gpshost = true }

local args = { ... }
local preset, roleArg, joinArg, yes = {}, nil, nil, false
for _, a in ipairs(args) do
  local k, v = tostring(a):match("^(%w+)=(.*)$")
  if k then preset[k] = v
  elseif a == "-y" or a == "--yes" then yes = true
  elseif ROLES[a] then roleArg = a
  elseif J.looksLike(a) then joinArg = a
  else printError("ignoring unknown argument: " .. tostring(a)) end
end

local function color(c) if term.isColor() then term.setTextColor(c) end end

--- key: preset name that answers this question without asking.
local function ask(prompt, default, key)
  color(colors.yellow)
  write(prompt)
  if default ~= nil and default ~= "" then
    color(colors.lightGray)
    write(" [" .. tostring(default) .. "]")
  end
  color(colors.white)
  write(": ")
  if key and preset[key] ~= nil then
    print(preset[key])
    return preset[key] ~= "" and preset[key] or default
  end
  if yes and default ~= nil then
    print(tostring(default))
    return default
  end
  local s = read()
  s = s and s:gsub("^%s+", ""):gsub("%s+$", "") or ""
  if s == "" then return default end
  return s
end

local function askNumber(prompt, default, key)
  while true do
    local n = tonumber(ask(prompt, default, key))
    if n then return n end
    color(colors.red)
    print("Please enter a number.")
    if key then preset[key] = nil end
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
local defaultRole = roleArg or old.role or (kind == "turtle" and "turtle" or (kind == "pocket" and "pocket" or nil))
local role = roleArg
while not ROLES[role] do
  role = ask("Role (control, turtle, pocket, gpshost)", defaultRole)
  if not ROLES[role] then yes = false end
end
if roleArg then print("Role: " .. role) end

-- keep hand-edited settings when re-running setup for the same role
local cfg = { role = role }
if old.role == role then
  for k, v in pairs(old) do cfg[k] = v end
end

if role == "control" then
  local secret = ask("Shared secret (blank = generate)", old.secret, "secret")
  if not secret or #secret < 8 then
    secret = genSecret()
    color(colors.lime)
    print("Generated a new secret.")
    color(colors.white)
  end
  cfg.secret = secret
else
  local id, secret
  if joinArg then
    id, secret = J.parse(joinArg)
    if not id then
      color(colors.red)
      print(secret)
      secret = nil
    end
  end
  while not id do
    local s = ask("Join code (press J on the control computer), or Enter to type secret + ID", nil)
    if not s then break end
    local why
    id, why = J.parse(s)
    if id then
      secret = why
    else
      color(colors.red)
      print(why)
    end
  end
  if id then
    color(colors.lime)
    print("Joined control computer #" .. id)
    color(colors.white)
  else
    repeat
      secret = ask("Shared secret (same as control)", old.secret, "secret")
      if not secret or #secret < 8 then
        color(colors.red)
        print("At least 8 characters.")
        preset.secret = nil
      end
    until secret and #secret >= 8
    id = askNumber("Control computer ID", old.serverId, "server")
  end
  cfg.secret, cfg.serverId = secret, id
end

if role == "control" or role == "gpshost" then
  local d
  repeat
    d = P.normDim(ask("Dimension of this computer (overworld, nether, end)", old.dim or "overworld", "dim"))
    if not d then preset.dim = nil end
  until d
  cfg.dim = d
elseif role == "turtle" then
  local d = ask("Dimension (overworld, nether, end; blank = from GPS)", old.dim or "", "dim")
  cfg.dim = P.normDim(d)
end

if role == "gpshost" then
  print("This computer's block coordinates (F3, look at it: 'Targeted Block'):")
  cfg.x = askNumber("x", old.x, "x")
  cfg.y = askNumber("y", old.y, "y")
  cfg.z = askNumber("z", old.z, "z")
end

if role == "control" then
  cfg.owner = ask("Your player name (for Chat Box alerts)", old.owner, "owner")
  local ids = ask("Pocket computer IDs allowed to command (comma separated)",
    old.commanders and table.concat(old.commanders, ",") or "", "commanders")
  cfg.commanders = {}
  for n in tostring(ids or ""):gmatch("%d+") do cfg.commanders[#cfg.commanders + 1] = tonumber(n) end
end

if role == "pocket" then
  cfg.owner = ask("Your player name", old.owner, "owner")
end

if role == "turtle" or role == "pocket" then
  local label = ask("Label", preset.label or os.getComputerLabel() or old.label or (role .. os.getComputerID()), "label")
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
  print("Join code for every other fleet computer (keep it private; also: press J later):")
  color(colors.yellow)
  print(J.make(os.getComputerID(), cfg.secret))
  color(colors.white)
  print("Add garages etc. with: edit /fleet/config.lua")
else
  print("Check this computer any time with /fleet/bin/doctor")
end
local again = ask("Reboot now? (y/n)", "y")
if again == "y" or again == "Y" then os.reboot() end
