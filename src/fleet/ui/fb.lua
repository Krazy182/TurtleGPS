-- Frame buffer: draw a whole frame in memory, then blit only the rows that changed.
-- Avoids flicker on big monitors and keeps redraws cheap.

local FB = {}
FB.__index = FB

local HEX = {}
for i = 0, 15 do HEX[2 ^ i] = ("0123456789abcdef"):sub(i + 1, i + 1) end
FB.HEX = HEX

function FB.new(target)
  local self = setmetatable({ t = target, last = {} }, FB)
  self:resize()
  return self
end

function FB:resize()
  self.w, self.h = self.t.getSize()
  self.last = {}
  self:clear(colors.black)
end

function FB:clear(bg)
  local b = HEX[bg or colors.black]
  self.ch, self.fg, self.bg = {}, {}, {}
  for y = 1, self.h do
    local c, f, k = {}, {}, {}
    for x = 1, self.w do c[x], f[x], k[x] = " ", "0", b end
    self.ch[y], self.fg[y], self.bg[y] = c, f, k
  end
end

function FB:inside(x, y) return x >= 1 and y >= 1 and x <= self.w and y <= self.h end

--- fg/bg are color numbers; nil keeps what is there.
function FB:set(x, y, ch, fg, bg)
  if x < 1 or y < 1 or x > self.w or y > self.h then return end
  self.ch[y][x] = ch
  if fg then self.fg[y][x] = HEX[fg] end
  if bg then self.bg[y][x] = HEX[bg] end
end

function FB:get(x, y)
  if not self:inside(x, y) then return nil end
  return self.ch[y][x], self.fg[y][x], self.bg[y][x]
end

function FB:text(x, y, s, fg, bg, maxW)
  s = tostring(s)
  if maxW and #s > maxW then s = s:sub(1, maxW) end
  if y < 1 or y > self.h then return x + #s end
  local f, b = fg and HEX[fg], bg and HEX[bg]
  local cr, fr, br = self.ch[y], self.fg[y], self.bg[y]
  for i = 1, #s do
    local xx = x + i - 1
    if xx >= 1 and xx <= self.w then
      cr[xx] = s:sub(i, i)
      if f then fr[xx] = f end
      if b then br[xx] = b end
    end
  end
  return x + #s
end

function FB:fill(x, y, w, h, ch, fg, bg)
  local f, b = fg and HEX[fg], bg and HEX[bg]
  for yy = math.max(1, y), math.min(self.h, y + h - 1) do
    local cr, fr, br = self.ch[yy], self.fg[yy], self.bg[yy]
    for xx = math.max(1, x), math.min(self.w, x + w - 1) do
      cr[xx] = ch
      if f then fr[xx] = f end
      if b then br[xx] = b end
    end
  end
end

function FB:flush()
  local t = self.t
  for y = 1, self.h do
    local s, f, b = table.concat(self.ch[y]), table.concat(self.fg[y]), table.concat(self.bg[y])
    local key = s .. f .. b
    if self.last[y] ~= key then
      t.setCursorPos(1, y)
      t.blit(s, f, b)
      self.last[y] = key
    end
  end
end

return FB
