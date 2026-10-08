-- report: bundles everything needed to debug this computer into one text and uploads
-- it to pastebin as UNLISTED (not public) with a one-week expiry. The secret is removed.
--   /fleet/bin/report            upload and print the link
--   /fleet/bin/report --file     only write /fleet/data/report.txt
package.path = "/fleet/?.lua;" .. package.path
local D = require("lib.doctor")
local config = require("lib.config")
local store = require("lib.store")
local Up = require("lib.update")

local args = { ... }
local fileOnly = args[1] == "--file"
local out = {}
local function add(s) out[#out + 1] = s end
local function section(title) add("") add("== " .. title .. " ==") end

local function tail(path, n)
  local s = store.readFile(path)
  if not s then return nil end
  local lines = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  if lines[#lines] == "" then lines[#lines] = nil end
  local from = math.max(1, #lines - n + 1)
  return table.concat(lines, "\n", from, #lines), #lines - from + 1
end

print("Collecting report (runs the doctor checks)...")
add("TurtleGPS report")
add(("computer #%d  label %s  %s"):format(os.getComputerID(), tostring(os.getComputerLabel()), _HOST or os.version()))
add(("code %s   time %d (epoch ms)"):format(Up.myVersion(), os.epoch("utc")))

section("Config (secret removed)")
local cfg, cfgErr = config.load()
if cfg then
  local copy = {}
  for k, v in pairs(cfg) do copy[k] = v end
  copy.secret = cfg.secret and ("<removed, " .. #cfg.secret .. " chars>") or nil
  add(config.pretty(copy, 0))
else
  add("unreadable: " .. tostring(cfgErr))
end

section("Peripherals")
for _, name in ipairs(peripheral.getNames()) do
  local t = peripheral.getType(name)
  local extra = ""
  if t == "monitor" then
    local m = peripheral.wrap(name)
    local w, h = m.getSize()
    extra = (" %dx%d scale %s color %s"):format(w, h, tostring(m.getTextScale and m.getTextScale()), tostring(m.isColor()))
  elseif t == "modem" then
    extra = " wireless " .. tostring(peripheral.call(name, "isWireless"))
  end
  add(name .. ": " .. tostring(t) .. extra)
end

if turtle then
  section("Turtle")
  add("fuel " .. tostring(turtle.getFuelLevel()) .. " / " .. tostring(turtle.getFuelLimit()))
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d then add(("slot %d: %s x%d"):format(s, d.name, d.count)) end
  end
  add("nav: " .. tostring(store.readFile("/fleet/data/nav")))
end

section("Doctor")
local _, counts = D.run({ out = function(r) add(D.format(r)) write(".") end })
print("")
add(("%d ok, %d warnings, %d problems"):format(counts.pass, counts.warn, counts.fail))

section("Update state")
add(tostring(store.readFile("/fleet/data/update") or "none"))

local db = store.load("/fleet/data/fleet.db", nil)
if type(db) == "table" then
  section("Fleet state (control)")
  for _, a in ipairs(db.alerts or {}) do
    if a.active then add("ALERT " .. tostring(a.text)) end
  end
  for id, t in pairs(db.turtles or {}) do
    add(("turtle #%s %s %s %s,%s,%s link=%s status=%s fuel=%s ver=%s"):format(tostring(id), tostring(t.label),
      tostring(t.dim), tostring(t.x), tostring(t.y), tostring(t.z), tostring(t.link), tostring(t.status),
      tostring(t.fuel), tostring(t.ver)))
  end
  for id, g in pairs(db.gps or {}) do
    add(("gps #%s %s %s,%s,%s link=%s %s"):format(tostring(id), tostring(g.dim), tostring(g.x), tostring(g.y),
      tostring(g.z), tostring(g.link), tostring(g.verdict)))
  end
end

for _, f in ipairs({ { "/fleet/data/crash.txt", 60 }, { "/fleet/data/log.txt", 150 }, { "/fleet/data/log.txt.old", 40 } }) do
  local text, n = tail(f[1], f[2])
  if text then
    section(f[1] .. " (last " .. n .. " lines)")
    add(text)
  end
end

local text = table.concat(out, "\n") .. "\n"
store.writeFile("/fleet/data/report.txt", text)

local function upload()
  if not http then return nil, "the http API is disabled on this server" end
  local key = "0ec2eb25b6166c0c27a394ae118ad829" -- CraftOS' own pastebin key (rom/programs/http/pastebin.lua)
  local name = ("turtlegps-%d"):format(os.getComputerID())
  local body = "api_option=paste&api_dev_key=" .. key
    .. "&api_paste_private=1&api_paste_expire_date=1W&api_paste_format=text"
    .. "&api_paste_name=" .. textutils.urlEncode(name)
    .. "&api_paste_code=" .. textutils.urlEncode(text)
  local response, err = http.post("https://pastebin.com/api/api_post.php", body)
  if not response then return nil, err or "upload failed" end
  local url = response.readAll()
  response.close()
  if not url or not url:match("^https?://") then return nil, url or "no link returned" end
  return url
end

if fileOnly then
  print("Report written to /fleet/data/report.txt")
  return
end
local url, uerr = upload()
if url then
  if term.isColor() then term.setTextColor(colors.lime) end
  print("Report uploaded (unlisted, expires in a week):")
  print(url)
  if term.isColor() then term.setTextColor(colors.white) end
  store.writeFile("/fleet/data/report.url", url)
else
  printError("Upload failed: " .. tostring(uerr))
  print("Report written to /fleet/data/report.txt")
end
