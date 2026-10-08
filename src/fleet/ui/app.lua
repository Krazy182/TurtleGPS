-- The map application. One renderer for every screen size:
--   wide  (monitors, 50+ columns): top bar, map, side panel, status line
--   compact (pocket 26x20): top bar, full map, overlays for details/alerts/menu
-- Data comes from a "source" with :view(dim) and :action(a) (local server or rednet).

local P = require("lib.proto")
local U = require("lib.util")
local FB = require("ui.fb")
local Map = require("ui.map")
local Glyphs = require("ui.glyphs")
local store = require("lib.store")

local App = {}
App.__index = App

local SEV_COLOR = { [1] = colors.lightGray, [2] = colors.orange, [3] = colors.red }
local BAR_BG, BTN_BG, ON_BG = colors.gray, colors.lightGray, colors.green
local PANEL_BG = colors.black

--- opts: term, source, kind ("monitor"|"pocket"|"term"), side (monitor side), dim, ascii, title
function App.new(opts)
  local self = setmetatable({
    term = opts.term, source = opts.source, kind = opts.kind or "term", side = opts.side,
    G = Glyphs.get(opts.ascii),
    dim = P.normDim(opts.dim) or "overworld",
    views = {},
    layers = { turtles = true, players = true, waypoints = true, terrain = true },
    sel = nil, panel = nil, target = nil,
    toast = nil, toastUntil = 0,
    buttons = {}, hits = {},
    blink = false, data = nil,
    title = opts.title or "TurtleGPS",
    statePath = opts.statePath, stateDirty = false, stateSavedAt = 0,
  }, App)
  self.fb = FB.new(opts.term)
  self:loadState()
  return self
end

-- Remembers dimension, zoom/pan per dimension and layers across reboots.
function App:loadState()
  if not self.statePath then return end
  local st = store.load(self.statePath, nil)
  if type(st) ~= "table" then return end
  if type(st.dim) == "string" then self.dim = st.dim end
  if type(st.views) == "table" then
    for d, v in pairs(st.views) do
      if type(v) == "table" and type(v.cx) == "number" and type(v.cz) == "number" and Map.ZOOMS[v.zi] then
        self.views[d] = Map.new(v.cx, v.cz, v.zi)
      end
    end
  end
  if type(st.layers) == "table" then
    for k in pairs(self.layers) do
      if type(st.layers[k]) == "boolean" then self.layers[k] = st.layers[k] end
    end
  end
end

function App:saveState(force)
  if not self.statePath or not self.stateDirty then return end
  local now = os.epoch("utc")
  if not force and now - self.stateSavedAt < 5000 then return end
  store.save(self.statePath, { dim = self.dim, views = self.views, layers = self.layers })
  self.stateDirty, self.stateSavedAt = false, now
end

function App:say(msg, secs)
  self.toast = msg
  self.toastUntil = os.epoch("utc") + (secs or 4) * 1000
end

-- Data ---------------------------------------------------------------------------------

function App:refresh()
  local ok, d = pcall(self.source.view, self.source, self.dim)
  if ok and d then self.data = d end
end

function App:turtle(id)
  for _, t in ipairs(self.data and self.data.turtles or {}) do
    if t.id == id then return t end
  end
end

function App:dims()
  local list, seen = {}, {}
  for _, d in ipairs(P.DIM_ORDER) do list[#list + 1] = d; seen[d] = true end
  for d in pairs(self.data and self.data.dims or {}) do
    if not seen[d] then list[#list + 1] = d; seen[d] = true end
  end
  return list
end

--- Viewport for the current dimension, centred on the garage or the fleet the first time.
function App:view()
  local v = self.views[self.dim]
  if v then return v end
  local d = self.data
  if not d or d.view ~= self.dim then return Map.new(0, 0) end
  local cx, cz
  for _, wp in ipairs(d.waypoints or {}) do
    if wp.kind == "garage" then cx, cz = wp.x, wp.z end
  end
  if not cx then
    local n, sx, sz = 0, 0, 0
    for _, t in ipairs(d.turtles) do
      if t.x then n, sx, sz = n + 1, sx + t.x, sz + t.z end
    end
    if n > 0 then cx, cz = math.floor(sx / n), math.floor(sz / n) end
  end
  v = Map.new(cx or 0, cz or 0)
  self.views[self.dim] = v
  return v
end

function App:centerOn(x, z)
  local v = self:view()
  v.cx, v.cz = x, z
end

function App:setDim(d)
  if d == self.dim then return end
  self.dim = d
  self.sel = nil
  self.target = nil
  if self.panel == "point" then self.panel = nil end
  self:refresh()
end

function App:cycleDim(step)
  local list = self:dims()
  local idx = 1
  for i, d in ipairs(list) do if d == self.dim then idx = i end end
  self:setDim(list[(idx - 1 + step) % #list + 1])
end

function App:select(id)
  self.sel = id
  self.panel = nil
  local t = id and self:turtle(id)
  if t and t.x then
    local v = self:view()
    local r = self.rects and self.rects.map
    if r then
      local col, row = Map.toScreen(v, r, t.x, t.z)
      if not Map.inside(r, col, row) then self:centerOn(t.x, t.z) end
    end
  end
end

function App:act(a)
  local ok, msg = self.source:action(a)
  self:say(msg or (ok and "done" or "failed"))
  self:refresh()
  return ok
end

-- Layout -------------------------------------------------------------------------------

function App:layout()
  local w, h = self.fb.w, self.fb.h
  local R = {}
  self.compact = w < 50 or h < 16
  if self.compact then
    R.bar = { x = 1, y = 1, w = w, h = 1 }
    R.map = { x = 1, y = 2, w = w, h = h - 2 }
    R.status = { x = 1, y = h, w = w, h = 1 }
  else
    local bh = h >= 40 and 3 or 1
    local pw = U.clamp(math.floor(w * 0.3), 24, 42)
    R.bar = { x = 1, y = 1, w = w, h = bh }
    R.map = { x = 1, y = bh + 1, w = w - pw, h = h - bh - 1 }
    R.side = { x = w - pw + 1, y = bh + 1, w = pw, h = h - bh - 1 }
    R.status = { x = 1, y = h, w = w, h = 1 }
  end
  self.rects = R
  return R
end

function App:button(x, y, w, h, label, fn, fg, bg)
  local fb = self.fb
  fb:fill(x, y, w, h, " ", fg or colors.black, bg or BTN_BG)
  local ly = y + math.floor((h - 1) / 2)
  local lx = x + math.max(0, math.floor((w - #label) / 2))
  fb:text(lx, ly, label, fg or colors.black, bg or BTN_BG, w)
  self.buttons[#self.buttons + 1] = { x1 = x, y1 = y, x2 = x + w - 1, y2 = y + h - 1, fn = fn }
  return x + w
end

function App:buttonAt(x, y)
  for i = #self.buttons, 1, -1 do
    local b = self.buttons[i]
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b end
  end
end

-- Colours -------------------------------------------------------------------------------

function App:turtleColor(t)
  if t.link == "lost" then return self.blink and colors.red or colors.gray end
  if t.link == "stale" then return colors.lightGray end
  if t.status == "stuck" or t.status == "error" then return colors.red end
  if t.lowFuel then return colors.orange end
  if t.full then return colors.yellow end
  if t.status == "idle" or t.status == "parked" or t.status == "locating" then return colors.white end
  return colors.lime
end

local function severity(t)
  if t.link == "lost" then return 5 end
  if t.status == "stuck" or t.status == "error" then return 4 end
  if t.lowFuel then return 3 end
  if t.full then return 2 end
  return 1
end

-- Drawing --------------------------------------------------------------------------------

function App:draw()
  local R = self:layout()
  local fb = self.fb
  self.buttons = {}
  fb:clear(colors.black)
  if not self.data then
    fb:text(2, 2, self.title .. ": waiting for data...", colors.yellow)
    fb:flush()
    return
  end
  self:drawMap(R.map)
  if self.compact then
    self:drawCompactBar(R.bar)
    if self.panel == "alerts" then self:drawAlertsOverlay(R.map)
    elseif self.panel == "menu" then self:drawMenuOverlay(R.map)
    elseif self.panel == "point" then self:drawPointSheet(R.map)
    elseif self.panel == "gps" then
      self.fb:fill(R.map.x, R.map.y, R.map.w, R.map.h, " ", colors.white, colors.black)
      self:drawGps(R.map)
    elseif self.sel and self:turtle(self.sel) then self:drawDetailSheet(R.map) end
  else
    self:drawWideBar(R.bar)
    self:drawSide(R.side)
  end
  self:drawStatus(R.status)
  fb:flush()
end

function App:drawMap(r)
  local fb, G, d = self.fb, self.G, self.data
  local v = self:view()
  self.hits = {}
  fb:fill(r.x, r.y, r.w, r.h, " ", colors.gray, colors.black)

  -- grid intersections every 16/32/64... blocks
  local cols, rows = Map.gridCells(v, r)
  for _, row in ipairs(rows) do
    for _, col in ipairs(cols) do fb:set(col, row, G.grid, colors.gray) end
  end

  if self.layers.waypoints then
    for _, g in ipairs(d.gps or {}) do
      if g.x then
        local col, row = Map.toScreen(v, r, g.x, g.z)
        if Map.inside(r, col, row) then
          fb:set(col, row, G.gps, g.link == "lost" and colors.red or colors.brown)
        end
      end
    end
    for _, wp in ipairs(d.waypoints or {}) do
      local col, row = Map.toScreen(v, r, wp.x, wp.z)
      if Map.inside(r, col, row) then
        local garage = wp.kind == "garage"
        fb:set(col, row, garage and G.garage or G.waypoint, garage and colors.cyan or colors.magenta)
        if not self.compact then
          fb:text(col + 1, row, wp.name or "", colors.lightGray, nil, r.x + r.w - col - 1)
        end
      end
    end
  end

  if self.layers.players then
    for _, p in ipairs(d.players or {}) do
      local col, row = Map.toScreen(v, r, p.x, p.z)
      if Map.inside(r, col, row) then
        fb:set(col, row, G.player, colors.yellow)
        if not self.compact then fb:text(col + 1, row, p.name or "", colors.yellow, nil, r.x + r.w - col - 1) end
      end
    end
  end

  if self.target and self.target.dim == self.dim then
    local col, row = Map.toScreen(v, r, self.target.x, self.target.z)
    if Map.inside(r, col, row) then fb:set(col, row, G.target, colors.magenta, colors.black) end
  end

  if self.layers.turtles then
    local cells, order = {}, {}
    for _, t in ipairs(d.turtles) do
      if t.x then
        local col, row = Map.toScreen(v, r, t.x, t.z)
        if Map.inside(r, col, row) then
          local k = col .. "," .. row
          if not cells[k] then
            cells[k] = { col = col, row = row, list = {} }
            order[#order + 1] = k
          end
          table.insert(cells[k].list, t)
        end
      end
    end
    for _, k in ipairs(order) do
      local c = cells[k]
      table.sort(c.list, function(a, b) return severity(a) > severity(b) end)
      local top = c.list[1]
      local glyph = #c.list > 1 and tostring(math.min(#c.list, 9)) or (top.h and G.heading[top.h] or G.noHeading)
      local selected = false
      local ids = {}
      for _, t in ipairs(c.list) do
        ids[#ids + 1] = t.id
        if t.id == self.sel then selected = true end
      end
      self.hits[k] = ids
      fb:set(c.col, c.row, glyph, selected and colors.black or self:turtleColor(top), selected and colors.white or colors.black)
      if not self.compact and #c.list == 1 then
        -- label to the right when the space is free
        local label = top.label or ("#" .. top.id)
        local room = r.x + r.w - c.col - 1
        local free = true
        for i = 1, math.min(#label, room) do
          local ch = fb:get(c.col + i, c.row)
          if ch ~= " " then free = false; break end
        end
        if free then fb:text(c.col + 1, c.row, label, colors.lightGray, nil, room) end
      end
    end
    -- selected turtle off-screen: arrow on the edge pointing at it
    local st = self.sel and self:turtle(self.sel)
    if st and st.x then
      local col, row = Map.toScreen(v, r, st.x, st.z)
      if not Map.inside(r, col, row) then
        local ec = U.clamp(col, r.x, r.x + r.w - 1)
        local er = U.clamp(row, r.y, r.y + r.h - 1)
        local g = col < r.x and G.left or (col >= r.x + r.w and G.right or (row < r.y and G.up or G.down))
        fb:set(ec, er, g, colors.black, colors.white)
      end
    end
  end

  fb:text(r.x + r.w - 2, r.y, "N" .. G.up, colors.lightGray, colors.black)
end

function App:dimText(d, full)
  local info = self.data.dims and self.data.dims[d]
  local label = full and P.dimLabel(d) or P.dimShort(d)
  if full and info and info.turtles > 0 then label = label .. " (" .. info.turtles .. ")" end
  return label
end

function App:drawWideBar(r)
  local fb, G = self.fb, self.G
  fb:fill(r.x, r.y, r.w, r.h, " ", colors.white, BAR_BG)
  local mid = r.y + math.floor((r.h - 1) / 2)
  local x = r.x
  local function btn(label, fn, on)
    x = self:button(x, r.y, #label + 2, r.h, label, fn, on and colors.white or colors.black, on and ON_BG or BTN_BG) + 1
  end
  local function txt(s, col)
    fb:text(x, mid, s, col or colors.white, BAR_BG)
    x = x + #s + 1
  end
  btn(G.left, function() self:cycleDim(-1) end)
  local dt = self:dimText(self.dim, true)
  local info = self.data.dims[self.dim]
  txt(U.pad(dt, 15), info and info.lost > 0 and colors.red or colors.yellow)
  btn(G.right, function() self:cycleDim(1) end)
  x = x + 1
  btn("-", function() Map.zoom(self:view(), 1) end)
  txt(U.pad(Map.scaleLabel(self:view()), 5))
  btn("+", function() Map.zoom(self:view(), -1) end)
  x = x + 1
  local v = self:view()
  local m = self.rects.map
  if r.w >= 66 then
    btn(G.panLeft, function() Map.pan(v, -math.floor(m.w / 3), 0) end)
    btn(G.panUp, function() Map.pan(v, 0, -math.floor(m.h / 3)) end)
    btn(G.panDown, function() Map.pan(v, 0, math.floor(m.h / 3)) end)
    btn(G.panRight, function() Map.pan(v, math.floor(m.w / 3), 0) end)
    btn(G.center, function() self:centerOnFleet() end)
    x = x + 1
  end
  local long = r.w >= 110
  for _, l in ipairs({ { "T", "turtles", "Turtles" }, { "P", "players", "Players" },
    { "W", "waypoints", "Waypoints" }, { "M", "terrain", "Terrain" } }) do
    btn(long and l[3] or l[1], function()
      self.layers[l[2]] = not self.layers[l[2]]
      self:say(l[2] .. (self.layers[l[2]] and " shown" or " hidden"), 2)
    end, self.layers[l[2]])
  end
  local n = 0
  for _, a in ipairs(self.data.alerts) do if not a.acked then n = n + 1 end end
  local label = G.alert .. " " .. n
  local ax = r.x + r.w - #label - 2
  if ax > x then
    self:button(ax, r.y, #label + 2, r.h, label, function() self.sel = nil; self.panel = nil end,
      colors.white, n > 0 and colors.red or BTN_BG)
  end
end

function App:drawCompactBar(r)
  local fb, G = self.fb, self.G
  fb:fill(r.x, r.y, r.w, 1, " ", colors.white, BAR_BG)
  local x = r.x
  x = self:button(x, r.y, 1, 1, G.left, function() self:cycleDim(-1) end)
  local info = self.data.dims[self.dim]
  fb:text(x, r.y, self:dimText(self.dim, false), info and info.lost > 0 and colors.red or colors.yellow, BAR_BG)
  x = x + 3
  x = self:button(x, r.y, 1, 1, G.right, function() self:cycleDim(1) end) + 1
  x = self:button(x, r.y, 1, 1, "-", function() Map.zoom(self:view(), 1) end)
  local sl = Map.scaleLabel(self:view())
  fb:text(x, r.y, sl, colors.white, BAR_BG)
  x = x + #sl
  x = self:button(x, r.y, 1, 1, "+", function() Map.zoom(self:view(), -1) end) + 1
  self:button(x, r.y, 1, 1, G.menu, function() self.panel = self.panel ~= "menu" and "menu" or nil end,
    colors.black, self.panel == "menu" and colors.white or BTN_BG)
  local n = 0
  for _, a in ipairs(self.data.alerts) do if not a.acked then n = n + 1 end end
  local label = G.alert .. n
  self:button(r.x + r.w - #label, r.y, #label, 1, label, function()
    self.panel = self.panel ~= "alerts" and "alerts" or nil
  end, colors.white, n > 0 and colors.red or BTN_BG)
end

function App:gpsSummary()
  local list = self.data.gps or {}
  local up = 0
  for _, g in ipairs(list) do if g.link ~= "lost" then up = up + 1 end end
  if #list == 0 then return "GPS: no hosts reporting", colors.orange end
  if up < 4 then return ("GPS: %d/%d up (need 4)"):format(up, #list), colors.red end
  if up < #list then return ("GPS: %d/%d up"):format(up, #list), colors.orange end
  return ("GPS: %d hosts OK"):format(up), colors.lime
end

function App:drawSide(r)
  local fb = self.fb
  fb:fill(r.x, r.y, r.w, r.h, " ", colors.white, PANEL_BG)
  for y = r.y, r.y + r.h - 1 do fb:set(r.x, y, "|", colors.gray) end
  local inner = { x = r.x + 2, y = r.y, w = r.w - 3, h = r.h }
  local t = self.sel and self:turtle(self.sel)
  if t then
    self:drawDetail(inner, t)
  elseif self.panel == "point" and self.target then
    self:drawPoint(inner)
  elseif self.panel == "gps" then
    self:drawGps(inner)
  else
    local half = math.max(6, math.floor(inner.h * 0.55))
    self:drawList({ x = inner.x, y = inner.y, w = inner.w, h = half })
    self:drawAlerts({ x = inner.x, y = inner.y + half, w = inner.w, h = inner.h - half })
  end
end

function App:drawList(r)
  local fb, G, d = self.fb, self.G, self.data
  local y = r.y
  fb:text(r.x, y, ("TURTLES  %s  %d"):format(P.dimLabel(self.dim), #d.turtles), colors.yellow, nil, r.w)
  y = y + 1
  local gs, gc = self:gpsSummary()
  fb:text(r.x, y, gs .. (r.w - #gs >= 8 and "  [hosts]" or ""), gc, nil, r.w)
  self.buttons[#self.buttons + 1] = { x1 = r.x, y1 = y, x2 = r.x + r.w - 1, y2 = y, fn = function() self.panel = "gps" end }
  y = y + 1
  if #d.turtles == 0 then
    fb:text(r.x, y + 1, "No turtles in this dimension.", colors.lightGray, nil, r.w)
    return
  end
  local shown = 0
  local rh = self:rowHeight()
  for i, t in ipairs(d.turtles) do
    if y + rh - 1 >= r.y + r.h - 1 and i < #d.turtles then
      fb:text(r.x, y, ("+%d more"):format(#d.turtles - shown), colors.gray, nil, r.w)
      break
    end
    local col = self:turtleColor(t)
    local status = t.link ~= "ok" and t.link:upper() or (t.status or "?")
    local name = ("#%d %s"):format(t.id, t.label or "")
    local rowW = r.w
    fb:text(r.x, y, t.h and G.heading[t.h] or G.noHeading, col)
    fb:text(r.x + 2, y, U.pad(name, rowW - #status - 3), colors.white)
    fb:text(r.x + rowW - #status, y, status, col)
    local id = t.id
    self.buttons[#self.buttons + 1] = { x1 = r.x, y1 = y, x2 = r.x + rowW - 1, y2 = y + rh - 1, fn = function() self:select(id) end }
    y = y + rh
    shown = shown + 1
  end
end

function App:drawAlerts(r)
  local fb, d = self.fb, self.data
  local y = r.y
  local alerts = d.alerts or {}
  fb:text(r.x, y, "ALERTS " .. #alerts, #alerts > 0 and colors.red or colors.yellow)
  if #alerts > 0 then
    self:button(r.x + r.w - 9, y, 9, 1, "ack all", function() self:act({ op = "ackAll" }) end)
  end
  y = y + 1
  if #alerts == 0 then
    fb:text(r.x, y + 1, "All good.", colors.lightGray, nil, r.w)
    return
  end
  for _, a in ipairs(alerts) do
    local lines = self:wrap(a.text, r.w - 2)
    if y + #lines > r.y + r.h then break end
    local col = a.acked and colors.gray or (SEV_COLOR[a.sev] or colors.white)
    for i, l in ipairs(lines) do
      fb:text(r.x, y, i == 1 and self.G.alert or " ", col)
      fb:text(r.x + 2, y, l, col)
      y = y + 1
    end
    local alert = a
    self.buttons[#self.buttons + 1] = {
      x1 = r.x, y1 = y - #lines, x2 = r.x + r.w - 1, y2 = y - 1 + (self:rowHeight() - 1),
      fn = function() self:openAlert(alert) end,
    }
    y = y + self:rowHeight() - 1
  end
end

--- Rows are 2 lines tall on big monitors so they are easy to touch.
function App:rowHeight()
  return (self.rects and self.rects.bar.h >= 3) and 2 or 1
end

function App:drawGps(r)
  local fb, d = self.fb, self.data
  local y = r.y
  fb:text(r.x, y, "GPS HOSTS  " .. P.dimLabel(self.dim), colors.yellow, nil, r.w)
  y = y + 1
  local gs, gc = self:gpsSummary()
  fb:text(r.x, y, gs, gc, nil, r.w)
  y = y + 2
  local bh = self:rowHeight()
  if #(d.gps or {}) == 0 then
    for _, l in ipairs(self:wrap("No GPS host has reported in this dimension. Each host sends a heartbeat every 20 s once it runs TurtleGPS gpshost.", r.w)) do
      fb:text(r.x, y, l, colors.lightGray, nil, r.w)
      y = y + 1
    end
  end
  for _, g in ipairs(d.gps or {}) do
    if y + 1 >= r.y + r.h - bh then break end
    local lost = g.link == "lost"
    local head = ("#%d %s"):format(g.id, g.x and ("%d,%d,%d"):format(g.x, g.y, g.z) or "?")
    local status = lost and ("OFFLINE " .. U.age(g.age)) or (U.age(g.age) .. " ago")
    fb:text(r.x, y, head, lost and colors.red or colors.white, nil, r.w)
    if #head + 1 + #status <= r.w then
      fb:text(r.x + r.w - #status, y, status, lost and colors.red or colors.gray)
    else
      y = y + 1
      fb:text(r.x + 2, y, status, lost and colors.red or colors.gray, nil, r.w - 2)
    end
    y = y + 1
    if g.verdict and not lost then
      for _, l in ipairs(self:wrap(g.verdict, r.w - 2)) do
        if y >= r.y + r.h - bh then break end
        fb:text(r.x + 2, y, l, g.verdict:find("^OK") and colors.lime or colors.orange, nil, r.w - 2)
        y = y + 1
      end
    end
    if lost then
      local id = g.id
      self:button(r.x + 2, y, 8, bh, "Forget", function() self:act({ op = "forgetGps", id = id }) end,
        colors.white, colors.red)
      y = y + bh
    end
  end
  self:button(r.x, r.y + r.h - bh, 7, bh, "Back", function() self.panel = nil end)
end

function App:openAlert(a)
  if not a.acked then self:act({ op = "ack", id = a.id }) end
  if a.dim and a.dim ~= self.dim then self:setDim(a.dim) end
  if a.tid and self:turtle(a.tid) then self:select(a.tid); self:centerOnSelected() end
end

function App:wrap(text, w) -- luacheck: ignore self
  w = math.max(1, w)
  local lines = {}
  text = tostring(text)
  while #text > w do
    local cut = text:sub(1, w):match("^.*() ") or (w + 1)
    if cut <= 1 then cut = w + 1 end
    lines[#lines + 1] = text:sub(1, cut - 1)
    text = text:sub(cut):gsub("^ +", "")
  end
  lines[#lines + 1] = text
  return lines
end

function App:detailLines(t)
  local L = {}
  local function add(s, c) L[#L + 1] = { s, c or colors.white } end
  add(("#%d %s"):format(t.id, t.label or ""), colors.yellow)
  add(P.dimLabel(t.dim) .. "  facing " .. (t.h and P.HEADING_NAME[t.h] or "?"), colors.lightGray)
  add("Pos  " .. (t.x and U.fmtPos(t) or "unknown"), t.x and colors.white or colors.red)
  local fix
  if t.fix == "gps" then fix = "gps" .. (t.fixAge and (" " .. U.age(t.fixAge * 1000) .. " ago") or "")
  elseif t.fix == "dr" then fix = "dead reckoning" .. (t.fixAge and (", gps " .. U.age(t.fixAge * 1000) .. " ago") or "")
  else fix = "none" .. (t.gpsErr and (": " .. t.gpsErr) or "") end
  add("Fix  " .. fix, t.fix == "none" and colors.red or colors.white)
  if t.fuel and t.fuel >= 0 then
    add(("Fuel %d / %d"):format(t.fuel, t.fuelMax or 0), t.lowFuel and colors.orange)
  else
    add("Fuel unlimited")
  end
  add(("Inv  %s / %s slots"):format(t.invUsed or "?", t.invTotal or "?"), t.full and colors.orange)
  add("Job  " .. (t.job or "-") .. (t.progress and (" " .. math.floor(t.progress * 100) .. "%") or ""))
  add("Stat " .. (t.status or "?"), self:turtleColor(t))
  local seen = "Seen " .. U.age(t.age) .. " ago"
  if t.link ~= "ok" then seen = seen .. "  " .. t.link:upper() end
  add(seen, t.link == "lost" and colors.red or (t.link == "stale" and colors.orange or colors.lightGray))
  if t.msg then add(t.msg, colors.orange) end
  if t.old then add("code " .. tostring(t.ver) .. " -> " .. tostring(self.data.ver), colors.cyan) end
  return L
end

function App:drawDetail(r, t)
  local fb = self.fb
  local y = r.y
  for _, l in ipairs(self:detailLines(t)) do
    for _, part in ipairs(self:wrap(l[1], r.w)) do
      if y >= r.y + r.h - 4 then break end
      fb:text(r.x, y, part, l[2], nil, r.w)
      y = y + 1
    end
  end
  if t.fuel and t.fuel >= 0 and t.fuelMax and t.fuelMax > 0 then
    local n = math.floor((r.w) * math.min(1, t.fuel / t.fuelMax) + 0.5)
    fb:fill(r.x, y, r.w, 1, " ", nil, colors.gray)
    fb:fill(r.x, y, n, 1, " ", nil, t.lowFuel and colors.orange or colors.green)
    y = y + 1
  end
  y = y + 1
  local bh = (self.rects.bar.h >= 3) and 3 or 1
  local x = r.x
  x = self:button(x, y, 8, bh, "Center", function() self:centerOnSelected() end) + 1
  x = self:button(x, y, 7, bh, "Close", function() self.sel = nil end) + 1
  if t.link ~= "ok" then
    local id = t.id
    self:button(x, y, 8, bh, "Forget", function() self.sel = nil; self:act({ op = "forget", id = id }) end,
      colors.white, colors.red)
  end
end

function App:drawPoint(r)
  local fb, t = self.fb, self.target
  fb:text(r.x, r.y, "MARKED POINT", colors.magenta)
  fb:text(r.x, r.y + 1, ("x %d   z %d"):format(t.x, t.z), colors.white)
  fb:text(r.x, r.y + 2, P.dimLabel(t.dim), colors.lightGray)
  local bh = (self.rects.bar.h >= 3) and 3 or 1
  local x = r.x
  x = self:button(x, r.y + 4, 13, bh, "Center here", function()
    self:centerOn(t.x, t.z); self.panel = nil
  end) + 1
  self:button(x, r.y + 4, 7, bh, "Clear", function() self.target = nil; self.panel = nil end)
  fb:text(r.x, r.y + 5 + bh, "Commands arrive in", colors.gray)
  fb:text(r.x, r.y + 6 + bh, "milestone 3.", colors.gray)
end

function App:sheet(r, lines)
  local top = math.max(r.y, r.y + r.h - lines)
  self.fb:fill(r.x, top, r.w, r.y + r.h - top, " ", colors.white, colors.black)
  self.fb:fill(r.x, top, r.w, 1, "\140", colors.gray, colors.black)
  return { x = r.x, y = top + 1, w = r.w, h = r.y + r.h - top - 1 }
end

function App:drawDetailSheet(r)
  local t = self:turtle(self.sel)
  local s = self:sheet(r, 12)
  local fb = self.fb
  local lines = self:detailLines(t)
  local y = s.y
  for i, l in ipairs(lines) do
    if y > s.y + s.h - 2 then break end
    if i ~= 2 then
      fb:text(s.x, y, l[1], l[2], nil, s.w)
      y = y + 1
    end
  end
  local by = s.y + s.h - 1
  local x = s.x
  x = self:button(x, by, 8, 1, "Center", function() self:centerOnSelected() end) + 1
  x = self:button(x, by, 7, 1, "Close", function() self.sel = nil end) + 1
  if t.link ~= "ok" then
    local id = t.id
    self:button(x, by, 8, 1, "Forget", function() self.sel = nil; self:act({ op = "forget", id = id }) end,
      colors.white, colors.red)
  end
end

function App:drawPointSheet(r)
  local s = self:sheet(r, 4)
  local t = self.target
  self.fb:text(s.x, s.y, ("Marked x %d  z %d"):format(t.x, t.z), colors.magenta, nil, s.w)
  local x = s.x
  x = self:button(x, s.y + 1, 13, 1, "Center here", function() self:centerOn(t.x, t.z); self.panel = nil end) + 1
  self:button(x, s.y + 1, 7, 1, "Clear", function() self.target = nil; self.panel = nil end)
end

function App:drawAlertsOverlay(r)
  local fb = self.fb
  fb:fill(r.x, r.y, r.w, r.h, " ", colors.white, colors.black)
  self:drawAlerts({ x = r.x, y = r.y, w = r.w, h = r.h })
end

function App:drawMenuOverlay(r)
  local fb = self.fb
  fb:fill(r.x, r.y, r.w, r.h, " ", colors.white, colors.black)
  local y = r.y
  fb:text(r.x, y, "LAYERS", colors.yellow)
  y = y + 1
  for _, l in ipairs({ { "Turtles", "turtles" }, { "Players", "players" }, { "Waypoints", "waypoints" }, { "Terrain", "terrain" } }) do
    local on = self.layers[l[2]]
    self:button(r.x, y, r.w, 1, (on and "[x] " or "[ ] ") .. l[1], function()
      self.layers[l[2]] = not self.layers[l[2]]
    end, on and colors.white or colors.lightGray, colors.black)
    y = y + 1
  end
  y = y + 1
  self:button(r.x, y, r.w, 1, "Center on fleet", function() self:centerOnFleet(); self.panel = nil end)
  y = y + 1
  self:button(r.x, y, r.w, 1, "GPS hosts", function() self.panel = "gps" end)
  y = y + 2
  self:drawList({ x = r.x, y = y, w = r.w, h = r.y + r.h - y })
end

function App:drawStatus(r)
  local fb, d = self.fb, self.data
  fb:fill(r.x, r.y, r.w, 1, " ", colors.lightGray, colors.black)
  local now = os.epoch("utc")
  local right
  local total, lost = 0, 0
  for _, info in pairs(d.dims or {}) do total, lost = total + info.turtles, lost + info.lost end
  if self.compact then
    local v = self:view()
    right = ("%d,%d"):format(math.floor(v.cx), math.floor(v.cz))
  else
    right = ("%d turtles%s  srv %s"):format(total, lost > 0 and (", " .. lost .. " lost") or "", d.ver or "?")
  end
  fb:text(r.x + r.w - #right, r.y, right, lost > 0 and colors.red or colors.gray)
  local left
  if self.toast and now < self.toastUntil then left = self.toast
  elseif self.compact then left = "drag: pan  tap: select"
  else left = "Tap a turtle for details, the map to mark a point" end
  fb:text(r.x, r.y, left, colors.white, nil, r.w - #right - 1)
end

-- Actions ---------------------------------------------------------------------------------

function App:centerOnSelected()
  local t = self.sel and self:turtle(self.sel)
  if t and t.x then self:centerOn(t.x, t.z) end
end

function App:centerOnFleet()
  local d = self.data
  local n, sx, sz = 0, 0, 0
  for _, t in ipairs(d.turtles) do
    if t.x then n, sx, sz = n + 1, sx + t.x, sz + t.z end
  end
  if n > 0 then
    self:centerOn(math.floor(sx / n), math.floor(sz / n))
  else
    for _, wp in ipairs(d.waypoints or {}) do
      if wp.kind == "garage" then self:centerOn(wp.x, wp.z) end
    end
  end
end

--- Turtles under a cell, or the nearest stack within a couple of cells: monitor
--- touches at text scale 0.5 are hard to place exactly.
function App:hitNear(x, y)
  local ids = self.hits[x .. "," .. y]
  if ids then return ids end
  local radius = self.kind == "monitor" and 2 or 1
  local best, bestD
  for k, list in pairs(self.hits) do
    local hx, hy = k:match("^(-?%d+),(-?%d+)$")
    local d = math.max(math.abs(tonumber(hx) - x), math.abs(tonumber(hy) - y))
    if d <= radius and (not bestD or d < bestD) then best, bestD = list, d end
  end
  return best
end

function App:tapMap(x, y)
  local r = self.rects.map
  local ids = self:hitNear(x, y)
  if ids and #ids > 0 then
    -- tapping a stack of turtles cycles through them
    local nextId = ids[1]
    for i, id in ipairs(ids) do
      if id == self.sel then nextId = ids[i % #ids + 1] end
    end
    self:select(nextId)
    return
  end
  if self.sel or self.panel then
    self.sel, self.panel = nil, nil
    return
  end
  local wx, wz = Map.toWorld(self:view(), r, x, y)
  self.target = { x = wx, z = wz, dim = self.dim }
  self.panel = "point"
  self:say(("Marked %d, %d"):format(wx, wz))
end

function App:tap(x, y)
  if type(x) ~= "number" or type(y) ~= "number" then return false end
  local b = self:buttonAt(x, y)
  if b then
    b.fn()
    return true
  end
  local r = self.rects and self.rects.map
  if r and Map.inside(r, x, y) then
    self:tapMap(x, y)
    return true
  end
  return false
end

--- Feeds one event. Returns true when the screen should be redrawn.
function App:handle(ev, a, b, c)
  if ev == "monitor_touch" then
    if self.kind == "monitor" and a == self.side then return self:tap(b, c) end
    return false
  end
  if self.kind == "monitor" then return false end
  if ev == "mouse_click" then
    local btn = self:buttonAt(b, c)
    if btn then
      btn.fn()
      self.press = nil
      return true
    end
    self.press = { x = b, y = c, lx = b, ly = c, moved = false }
    return false
  elseif ev == "mouse_drag" and self.press then
    local dx, dy = b - self.press.lx, c - self.press.ly
    if dx ~= 0 or dy ~= 0 then
      Map.pan(self:view(), -dx, -dy)
      self.press.lx, self.press.ly, self.press.moved = b, c, true
      return true
    end
  elseif ev == "mouse_up" then
    local p = self.press
    self.press = nil
    if p and not p.moved then return self:tap(p.x, p.y) end
    return p ~= nil
  elseif ev == "mouse_scroll" then
    Map.zoom(self:view(), a)
    return true
  elseif ev == "key" then
    local v, m = self:view(), self.rects.map
    if a == keys.up then Map.pan(v, 0, -math.max(1, math.floor(m.h / 4)))
    elseif a == keys.down then Map.pan(v, 0, math.max(1, math.floor(m.h / 4)))
    elseif a == keys.left then Map.pan(v, -math.max(1, math.floor(m.w / 4)), 0)
    elseif a == keys.right then Map.pan(v, math.max(1, math.floor(m.w / 4)), 0)
    elseif a == keys.tab then self:cycleDim(1)
    elseif a == keys.backspace then self.sel, self.panel = nil, nil
    else return false end
    return true
  elseif ev == "char" then
    if a == "+" or a == "=" then Map.zoom(self:view(), -1)
    elseif a == "-" then Map.zoom(self:view(), 1)
    elseif a == "d" then self:cycleDim(1)
    elseif a == "t" then self.layers.turtles = not self.layers.turtles
    elseif a == "p" then self.layers.players = not self.layers.players
    elseif a == "w" then self.layers.waypoints = not self.layers.waypoints
    elseif a == "m" then self.layers.terrain = not self.layers.terrain
    elseif a == "c" then if self.sel then self:centerOnSelected() else self:centerOnFleet() end
    elseif a == "a" then self.panel = self.panel ~= "alerts" and "alerts" or nil
    else return false end
    return true
  end
  return false
end

--- Main loop: redraws on input and once a second.
function App:run()
  self:refresh()
  self:draw()
  local timer = os.startTimer(1)
  while true do
    local ev = table.pack(os.pullEvent())
    if ev[1] == "timer" and ev[2] == timer then
      self.blink = not self.blink
      self:refresh()
      self:draw()
      self:saveState()
      timer = os.startTimer(1)
    elseif ev[1] == "monitor_resize" or ev[1] == "term_resize" then
      self.fb:resize()
      self:draw()
    elseif self:handle(table.unpack(ev, 1, ev.n)) then
      self.stateDirty = true
      self:refresh()
      self:draw()
    end
  end
end

return App
