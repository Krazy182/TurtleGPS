-- Simulated block world, one sparse map per dimension, with simple terrain generators.

local World = {}
World.__index = World

World.LIMITS = {
  overworld = { minY = -64, maxY = 319 },
  the_nether = { minY = 0, maxY = 255 },
  the_end = { minY = 0, maxY = 255 },
}

World.FLUIDS = { ["minecraft:water"] = true, ["minecraft:lava"] = true }
World.UNBREAKABLE = {
  ["minecraft:bedrock"] = true, ["minecraft:barrier"] = true, ["minecraft:end_portal_frame"] = true,
}
World.UPGRADES = {
  ["computercraft:wireless_modem_advanced"] = { kind = "modem", ender = true },
  ["computercraft:wireless_modem_normal"] = { kind = "modem", ender = false },
  ["advancedperipherals:chunk_controller"] = { kind = "chunky" },
  ["minecraft:diamond_pickaxe"] = { kind = "tool" },
  ["minecraft:diamond_axe"] = { kind = "tool" },
  ["minecraft:diamond_shovel"] = { kind = "tool" },
  ["minecraft:diamond_hoe"] = { kind = "tool" },
  ["minecraft:diamond_sword"] = { kind = "tool" },
}

World.DROPS = {
  ["minecraft:stone"] = "minecraft:cobblestone",
  ["minecraft:grass_block"] = "minecraft:dirt",
  ["minecraft:deepslate"] = "minecraft:cobbled_deepslate",
  ["minecraft:coal_ore"] = "minecraft:coal",
  ["minecraft:iron_ore"] = "minecraft:raw_iron",
  ["minecraft:oak_leaves"] = false,
}

local function key(x, y, z) return x .. "," .. y .. "," .. z end

function World.new()
  local w = setmetatable({ dims = {} }, World)
  w:setGen("overworld", World.flatGen(64))
  w:setGen("the_nether", World.netherGen())
  w:setGen("the_end", World.endGen(80))
  return w
end

function World:dim(name)
  local d = self.dims[name]
  if not d then
    local lim = World.LIMITS[name] or { minY = 0, maxY = 255 }
    d = { blocks = {}, occupants = {}, gen = function() return nil end, minY = lim.minY, maxY = lim.maxY }
    self.dims[name] = d
  end
  return d
end

function World:setGen(name, fn) self:dim(name).gen = fn end

--- Returns block table { name = ..., state = {...} } or nil for air.
function World:get(dim, x, y, z)
  local d = self:dim(dim)
  local b = d.blocks[key(x, y, z)]
  if b == nil then return d.gen(x, y, z) end
  return b or nil
end

function World:set(dim, x, y, z, name, state)
  local d = self:dim(dim)
  d.blocks[key(x, y, z)] = name and { name = name, state = state or {} } or false
end

function World:fill(dim, x1, y1, z1, x2, y2, z2, name)
  for x = math.min(x1, x2), math.max(x1, x2) do
    for y = math.min(y1, y2), math.max(y1, y2) do
      for z = math.min(z1, z2), math.max(z1, z2) do self:set(dim, x, y, z, name) end
    end
  end
end

function World:occupant(dim, x, y, z) return self:dim(dim).occupants[key(x, y, z)] end

function World:setOccupant(dim, x, y, z, who)
  self:dim(dim).occupants[key(x, y, z)] = who
end

--- Solid for movement purposes: a block that is not a fluid, or another turtle.
function World:blocked(dim, x, y, z)
  if self:occupant(dim, x, y, z) then return true end
  local b = self:get(dim, x, y, z)
  return b ~= nil and not World.FLUIDS[b.name]
end

-- Generators -----------------------------------------------------------------

function World.flatGen(ground)
  return function(x, y, z)
    if y <= -64 then return { name = "minecraft:bedrock", state = {} } end
    if y < ground - 3 then return { name = "minecraft:stone", state = {} } end
    if y < ground then return { name = "minecraft:dirt", state = {} } end
    if y == ground then return { name = "minecraft:grass_block", state = { snowy = false } } end
    return nil
  end
end

function World.netherGen()
  return function(x, y, z)
    if y <= 0 or y >= 127 then return { name = "minecraft:bedrock", state = {} } end
    if y <= 31 then return { name = "minecraft:lava", state = { level = 0 } } end
    if y <= 40 or y >= 110 then return { name = "minecraft:netherrack", state = {} } end
    return nil
  end
end

function World.endGen(radius)
  return function(x, y, z)
    if x * x + z * z <= radius * radius and y >= 50 and y <= 60 then
      return { name = "minecraft:end_stone", state = {} }
    end
    return nil
  end
end

World.key = key
return World
