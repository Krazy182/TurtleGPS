-- Viewport math shared by every map screen. A character cell is 6x9 pixels, so each
-- row covers 1.5x the blocks of a column to keep the map square.

local M = {}

M.ZOOMS = { 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512 }
M.DEFAULT_ZOOM = 5
M.ASPECT = 1.5

function M.new(cx, cz, zi) return { cx = cx or 0, cz = cz or 0, zi = zi or M.DEFAULT_ZOOM } end

function M.scale(v) return M.ZOOMS[v.zi] end

--- "1:4" = one character is 4 blocks wide; "4:1" = a block is 4 characters wide.
function M.scaleLabel(v)
  local s = M.scale(v)
  if s >= 1 then return "1:" .. s end
  return math.floor(1 / s + 0.5) .. ":1"
end

function M.zoom(v, d) v.zi = math.max(1, math.min(#M.ZOOMS, v.zi + d)) end

--- World block (x, z) -> screen cell inside rect r.
function M.toScreen(v, r, x, z)
  local s = M.scale(v)
  local col = r.x + math.floor((x + 0.5 - v.cx) / s + r.w / 2)
  local row = r.y + math.floor((z + 0.5 - v.cz) / (s * M.ASPECT) + r.h / 2)
  return col, row
end

--- Screen cell -> world block at the cell's centre.
function M.toWorld(v, r, col, row)
  local s = M.scale(v)
  local x = v.cx + (col - r.x + 0.5 - r.w / 2) * s
  local z = v.cz + (row - r.y + 0.5 - r.h / 2) * s * M.ASPECT
  return math.floor(x), math.floor(z)
end

function M.inside(r, col, row)
  return col >= r.x and row >= r.y and col < r.x + r.w and row < r.y + r.h
end

--- Pans by a number of cells.
function M.pan(v, dcol, drow)
  local s = M.scale(v)
  v.cx = v.cx + dcol * s
  v.cz = v.cz + drow * s * M.ASPECT
end

--- Grid spacing in blocks: a power of two at least 16 that leaves ~8 cells between lines.
function M.gridStep(v)
  local s = M.scale(v)
  local g = 16
  while g / s < 8 do g = g * 2 end
  return g
end

--- Columns (and rows) of r that contain a grid line, as a set.
function M.gridCells(v, r)
  local g = M.gridStep(v)
  local s = M.scale(v)
  local cols, rows = {}, {}
  for col = r.x, r.x + r.w - 1 do
    local x0 = v.cx + (col - r.x - r.w / 2) * s
    local x1 = x0 + s
    if math.ceil(x0 / g) * g < x1 then cols[#cols + 1] = col end
  end
  for row = r.y, r.y + r.h - 1 do
    local z0 = v.cz + (row - r.y - r.h / 2) * s * M.ASPECT
    local z1 = z0 + s * M.ASPECT
    if math.ceil(z0 / g) * g < z1 then rows[#rows + 1] = row end
  end
  return cols, rows, g
end

return M
