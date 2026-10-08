-- Logger: keeps the last lines in memory (for on-screen consoles) and appends to a
-- size-capped file so in-game problems can be reported afterwards.

local L = {}
L.__index = L

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

--- opts: path (file, optional), keep (lines in memory), maxBytes (rotate size), echo (print lines)
function L.new(opts)
  opts = opts or {}
  return setmetatable({
    path = opts.path,
    keep = opts.keep or 40,
    maxBytes = opts.maxBytes or 24000,
    echo = opts.echo,
    level = LEVELS[opts.level or "info"] or 2,
    lines = {},
    seq = 0,
  }, L)
end

function L:write(level, fmt, ...)
  if (LEVELS[level] or 2) < self.level then return end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) end
  local t = os.epoch("utc")
  local secs = math.floor(t / 1000) % 86400
  local stamp = string.format("%02d:%02d:%02d", math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60)
  local line = stamp .. " " .. level:sub(1, 1):upper() .. " " .. msg
  self.seq = self.seq + 1
  local lines = self.lines
  lines[#lines + 1] = { seq = self.seq, level = level, text = line }
  if #lines > self.keep then table.remove(lines, 1) end
  if self.echo then print(line) end
  if self.path then self:append(line) end
end

function L:append(line)
  pcall(function()
    if fs.exists(self.path) and fs.getSize(self.path) > self.maxBytes then
      local old = self.path .. ".old"
      if fs.exists(old) then fs.delete(old) end
      fs.move(self.path, old)
    end
    local h = fs.open(self.path, "a")
    if h then
      h.writeLine(line)
      h.close()
    end
  end)
end

function L:debug(...) self:write("debug", ...) end
function L:info(...) self:write("info", ...) end
function L:warn(...) self:write("warn", ...) end
function L:error(...) self:write("error", ...) end

return L
