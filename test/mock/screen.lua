-- Terminal / monitor buffer implementing the CC `term` object API, with text dumps
-- (Unicode approximation of the CC font) and raw dumps for tools/render_screen.py.

local Screen = {}
Screen.__index = Screen

local HEX = "0123456789abcdef"

local function toHex(c)
  local n = math.floor(math.log(c) / math.log(2) + 0.5)
  return HEX:sub(n + 1, n + 1)
end

local function fromHex(h)
  local n = HEX:find(h:lower(), 1, true)
  return 2 ^ (n - 1)
end

function Screen.new(w, h, isColor)
  local s = setmetatable({ w = w, h = h, color = isColor ~= false, scale = 1 }, Screen)
  s.cx, s.cy, s.fg, s.bg, s.blink = 1, 1, "0", "f", false
  s:reset()
  return s
end

--- Monitor of bw x bh blocks; size follows the CC:Tweaked monitor formula.
function Screen.monitor(bw, bh, isColor)
  local s = Screen.new(1, 1, isColor)
  s.bw, s.bh = bw, bh
  s:setScale(1)
  return s
end

function Screen:setScale(scale)
  self.scale = scale
  local border = 2 * (2 / 16 + 0.5 / 16)
  self.w = math.max(math.floor((self.bw - border) / (scale * 6 / 64) + 0.5), 1)
  self.h = math.max(math.floor((self.bh - border) / (scale * 9 / 64) + 0.5), 1)
  self:reset()
end

function Screen:reset()
  self.text, self.fgs, self.bgs = {}, {}, {}
  for y = 1, self.h do self:blankRow(y) end
end

function Screen:blankRow(y)
  local t, f, b = {}, {}, {}
  for x = 1, self.w do t[x], f[x], b[x] = " ", self.fg, self.bg end
  self.text[y], self.fgs[y], self.bgs[y] = t, f, b
end

function Screen:put(str, fg, bg)
  local y = self.cy
  if y < 1 or y > self.h then
    self.cx = self.cx + #str
    return
  end
  for i = 1, #str do
    local x = self.cx + i - 1
    if x >= 1 and x <= self.w then
      local ch = str:sub(i, i)
      if ch == "\t" then ch = " " end
      self.text[y][x] = ch
      self.fgs[y][x] = fg and fg:sub(i, i) or self.fg
      self.bgs[y][x] = bg and bg:sub(i, i) or self.bg
    end
  end
  self.cx = self.cx + #str
end

--- The object handed to Lua code (functions are called with '.', not ':').
function Screen:api()
  local s = self
  local t = {}
  function t.write(str)
    if type(str) == "number" then str = tostring(str) end
    s:put(tostring(str))
  end
  function t.blit(text, fg, bg)
    if #text ~= #fg or #text ~= #bg then error("Arguments must be the same length", 2) end
    s:put(text, fg:lower(), bg:lower())
  end
  function t.clear() for y = 1, s.h do s:blankRow(y) end end
  function t.clearLine() if s.cy >= 1 and s.cy <= s.h then s:blankRow(s.cy) end end
  function t.getCursorPos() return s.cx, s.cy end
  function t.setCursorPos(x, y) s.cx, s.cy = math.floor(x), math.floor(y) end
  function t.setCursorBlink(b) s.blink = b end
  function t.getCursorBlink() return s.blink end
  function t.getSize() return s.w, s.h end
  function t.scroll(n)
    for _ = 1, math.abs(n) do
      if n > 0 then
        table.remove(s.text, 1); table.remove(s.fgs, 1); table.remove(s.bgs, 1)
        s:blankRow(s.h)
      else
        table.insert(s.text, 1, {}); table.insert(s.fgs, 1, {}); table.insert(s.bgs, 1, {})
        table.remove(s.text); table.remove(s.fgs); table.remove(s.bgs)
        s:blankRow(1)
      end
    end
  end
  function t.isColor() return s.color end
  t.isColour = t.isColor
  function t.setTextColor(c) s.fg = toHex(c) end
  t.setTextColour = t.setTextColor
  function t.getTextColor() return fromHex(s.fg) end
  t.getTextColour = t.getTextColor
  function t.setBackgroundColor(c) s.bg = toHex(c) end
  t.setBackgroundColour = t.setBackgroundColor
  function t.getBackgroundColor() return fromHex(s.bg) end
  t.getBackgroundColour = t.getBackgroundColor
  function t.setPaletteColor() end
  t.setPaletteColour = t.setPaletteColor
  function t.getPaletteColor() return 0, 0, 0 end
  t.getPaletteColour = t.getPaletteColor
  if s.bw then
    function t.setTextScale(sc)
      if sc < 0.5 or sc > 5 then error("Expected number in range 0.5-5", 2) end
      s:setScale(sc)
    end
    function t.getTextScale() return s.scale end
  end
  return t
end

-- Unicode approximations of the CC font for text dumps.
local GLYPH = {
  [1] = "☺", [2] = "☻", [3] = "♥", [4] = "♦", [5] = "♣", [6] = "♠", [7] = "•", [8] = "◘",
  [9] = "○", [10] = "◙", [11] = "♂", [12] = "♀", [13] = "♪", [14] = "♫", [15] = "☼",
  [16] = "►", [17] = "◄", [18] = "↕", [19] = "‼", [20] = "¶", [21] = "§", [22] = "▬",
  [23] = "↨", [24] = "↑", [25] = "↓", [26] = "→", [27] = "←", [28] = "∟", [29] = "↔",
  [30] = "▲", [31] = "▼", [127] = "⌂",
}

local function utf8char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  end
  return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local function glyph(ch)
  local b = ch:byte()
  if GLYPH[b] then return GLYPH[b] end
  if b >= 128 and b < 160 then return b == 128 and " " or "▒" end
  if b >= 160 then return utf8char(b) end
  if b < 32 then return "?" end
  return ch
end

function Screen:row(y)
  return table.concat(self.text[y]), table.concat(self.fgs[y]), table.concat(self.bgs[y])
end

function Screen:dumpText()
  local out = {}
  for y = 1, self.h do
    local line = {}
    for x = 1, self.w do line[x] = glyph(self.text[y][x]) end
    out[y] = table.concat(line)
  end
  return table.concat(out, "\n")
end

--- Finds text on screen. Returns x, y of the first match or nil.
function Screen:find(str)
  for y = 1, self.h do
    local x = table.concat(self.text[y]):find(str, 1, true)
    if x then return x, y end
  end
end

function Screen:contains(str) return self:find(str) ~= nil end

--- Writes a simple JSON dump for tools/render_screen.py.
function Screen:dumpRaw(path)
  local rows = {}
  for y = 1, self.h do
    local codes = {}
    for x = 1, self.w do codes[x] = tostring(self.text[y][x]:byte()) end
    rows[y] = string.format('{"t":[%s],"f":"%s","b":"%s"}', table.concat(codes, ","),
      table.concat(self.fgs[y]), table.concat(self.bgs[y]))
  end
  local f = assert(io.open(path, "w"))
  f:write(string.format('{"w":%d,"h":%d,"rows":[%s]}', self.w, self.h, table.concat(rows, ",\n")))
  f:close()
end

Screen.toHex = toHex
return Screen
