-- Crash-safe table persistence. Writes go to <path>.tmp first, then replace the file.

local ser = require("lib.ser")

local S = {}

local function readFile(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

--- Returns the stored table, or `default` when the file is missing or corrupt.
function S.load(path, default)
  for _, p in ipairs({ path, path .. ".tmp" }) do
    local s = readFile(p)
    if s then
      local v = ser.unserialize(s)
      if v ~= nil then return v end
    end
  end
  return default
end

--- Returns true on success, or false plus an error (for example "Out of space").
function S.save(path, value)
  local data = ser.serialize(value)
  local tmp = path .. ".tmp"
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h, err = fs.open(tmp, "w")
  if not h then return false, err end
  local ok, werr = pcall(function()
    h.write(data)
    h.close()
  end)
  if not ok then
    pcall(h.close)
    return false, werr
  end
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

function S.readFile(path) return readFile(path) end

function S.writeFile(path, data)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h, err = fs.open(path, "w")
  if not h then return false, err end
  h.write(data)
  h.close()
  return true
end

return S
