-- Map symbols. CC's font has CP437-style arrows and icons in the low character codes;
-- set ui = { ascii = true } in config.lua if they show up as '?' on your setup.

local G = {}

G.font = {
  heading = { [0] = "\30", [1] = "\16", [2] = "\31", [3] = "\17" }, -- triangles N E S W
  noHeading = "\7",   -- bullet
  player = "\2",      -- smiley
  garage = "\127",    -- house
  waypoint = "\4",    -- diamond
  gps = "\15",        -- sun
  target = "x",
  grid = "+",
  left = "\17", right = "\16", up = "\30", down = "\31",
  center = "\7",
  alert = "!",
  bar = "\127",
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
  center = "o",
  alert = "!",
  bar = "#",
  menu = "=",
}

function G.get(ascii) return ascii and G.ascii or G.font end

return G
