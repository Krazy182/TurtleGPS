-- Map symbols. Codes checked against CC:Tweaked's term_font.png: 1-31 are CP437-style
-- icons (but 13-15 differ from CP437) and 127 is a checkerboard, not a house.
-- Set ui = { ascii = true } in config.lua to use plain letters instead.

local G = {}

G.font = {
  heading = { [0] = "\30", [1] = "\16", [2] = "\31", [3] = "\17" }, -- triangles N E S W
  noHeading = "\7",   -- bullet
  player = "\2",      -- smiley
  garage = "G",
  waypoint = "\4",    -- diamond
  gps = "\164",       -- currency sign, looks like a little satellite
  target = "x",
  grid = "+",
  left = "\17", right = "\16", up = "\30", down = "\31",
  panLeft = "\27", panRight = "\26", panUp = "\24", panDown = "\25", -- thin arrows
  center = "\7",
  alert = "!",
  menu = "=",
}

G.ascii = {
  heading = { [0] = "^", [1] = ">", [2] = "v", [3] = "<" },
  noHeading = "o",
  player = "@",
  garage = "G",
  waypoint = "*",
  gps = "%",
  target = "x",
  grid = "+",
  left = "<", right = ">", up = "^", down = "v",
  panLeft = "<", panRight = ">", panUp = "^", panDown = "v",
  center = "o",
  alert = "!",
  menu = "=",
}

function G.get(ascii) return ascii and G.ascii or G.font end

return G
