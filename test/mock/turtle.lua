-- Mock `turtle` API. Effects apply immediately; the call then waits for a
-- "turtle_response" event like CC:Tweaked does, so other events reaching the same
-- coroutine meanwhile are discarded (the real-game behaviour programs must survive).

local World = require("mock.world")

local UPGRADES = World.UPGRADES

local FUEL = {
  ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:coal_block"] = 800,
  ["minecraft:lava_bucket"] = 1000, ["minecraft:oak_planks"] = 15, ["minecraft:oak_log"] = 15,
}

local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = -1, 0, 1, 0 }

return function(sim, c)
  local T = c.turtle
  local world = sim.world
  local api = {}

  local function wait(duration, ok, err)
    local id = sim:turtleResponse(c, duration, ok, err)
    while true do
      local ev = { coroutine.yield("turtle_response") }
      if ev[1] == "turtle_response" and ev[2] == id then return ev[3], ev[4] end
    end
  end

  local function act(duration, fn)
    local ok, err = fn()
    if ok then return wait(duration, true) end
    return wait(0.05, false, err)
  end

  local function target(dir)
    local p = c.pos
    if dir == "up" then return p.x, p.y + 1, p.z end
    if dir == "down" then return p.x, p.y - 1, p.z end
    local h = c.heading
    if dir == "back" then h = (h + 2) % 4 end
    return p.x + DX[h], p.y, p.z + DZ[h]
  end

  local function unlimited() return T.fuelLimit == "unlimited" end

  local function move(dir)
    return act(0.4, function()
      if not unlimited() and T.fuel <= 0 then return false, "Out of fuel" end
      local x, y, z = target(dir)
      local d = world:dim(c.dim)
      if y > d.maxY then return false, "Too high to move" end
      if y < d.minY then return false, "Too low to move" end
      if world:blocked(c.dim, x, y, z) then return false, "Movement obstructed" end
      world:setOccupant(c.dim, c.pos.x, c.pos.y, c.pos.z, nil)
      c.pos = { x = x, y = y, z = z }
      world:setOccupant(c.dim, x, y, z, c)
      if not unlimited() then T.fuel = T.fuel - 1 end
      sim:onTurtleMoved(c)
      return true
    end)
  end

  function api.forward() return move("forward") end
  function api.back() return move("back") end
  function api.up() return move("up") end
  function api.down() return move("down") end
  function api.turnLeft()
    return act(0.4, function() c.heading = (c.heading + 3) % 4; return true end)
  end
  function api.turnRight()
    return act(0.4, function() c.heading = (c.heading + 1) % 4; return true end)
  end

  local function hasTool()
    for _, side in ipairs({ "left", "right" }) do
      local u = T.equipped[side] and UPGRADES[T.equipped[side]]
      if u and u.kind == "tool" then return true end
    end
    return false
  end

  local function store(name, count)
    for i = 0, 15 do
      local slot = (T.selected - 1 + i) % 16 + 1
      local s = T.slots[slot]
      if s and s.name == name and s.count < 64 then
        local add = math.min(count, 64 - s.count)
        s.count, count = s.count + add, count - add
      elseif not s then
        local add = math.min(count, 64)
        T.slots[slot] = { name = name, count = add }
        count = count - add
      end
      if count <= 0 then return 0 end
    end
    return count
  end

  local function dig(dir)
    return act(0.4, function()
      if not hasTool() then return false, "No tool to dig with" end
      local x, y, z = target(dir)
      local b = world:get(c.dim, x, y, z)
      if not b or World.FLUIDS[b.name] then return false, "Nothing to dig here" end
      if World.UNBREAKABLE[b.name] then return false, "Cannot break unbreakable block" end
      world:set(c.dim, x, y, z, nil)
      local drop = World.DROPS[b.name]
      if drop == nil then drop = b.name end
      if drop then store(drop, 1) end
      return true
    end)
  end
  function api.dig() return dig("forward") end
  function api.digUp() return dig("up") end
  function api.digDown() return dig("down") end

  local function detect(dir)
    local x, y, z = target(dir)
    return wait(0.05, world:blocked(c.dim, x, y, z))
  end
  function api.detect() return detect("forward") end
  function api.detectUp() return detect("up") end
  function api.detectDown() return detect("down") end

  local function inspect(dir)
    local x, y, z = target(dir)
    local occ = world:occupant(c.dim, x, y, z)
    local b = occ and { name = "computercraft:turtle_advanced", state = { facing = "north" } } or world:get(c.dim, x, y, z)
    sim:onInspect(c, x, y, z, b)
    wait(0.05, true)
    if not b then return false, "No block to inspect" end
    local copy = { name = b.name, state = {}, tags = {} }
    for k, v in pairs(b.state or {}) do copy.state[k] = v end
    return true, copy
  end
  function api.inspect() return inspect("forward") end
  function api.inspectUp() return inspect("up") end
  function api.inspectDown() return inspect("down") end

  local function place(dir)
    return act(0.05, function()
      local s = T.slots[T.selected]
      if not s then return false, "No items to place" end
      local x, y, z = target(dir)
      if world:blocked(c.dim, x, y, z) then return false, "Cannot place block here" end
      world:set(c.dim, x, y, z, s.name)
      s.count = s.count - 1
      if s.count <= 0 then T.slots[T.selected] = nil end
      return true
    end)
  end
  function api.place() return place("forward") end
  function api.placeUp() return place("up") end
  function api.placeDown() return place("down") end

  local function drop(dir, count)
    return act(0.05, function()
      local s = T.slots[T.selected]
      if not s then return false, "No items to drop" end
      local n = math.min(count or s.count, s.count)
      s.count = s.count - n
      if s.count <= 0 then T.slots[T.selected] = nil end
      sim:onDrop(c, dir, s.name, n)
      return true
    end)
  end
  function api.drop(n) return drop("forward", n) end
  function api.dropUp(n) return drop("up", n) end
  function api.dropDown(n) return drop("down", n) end
  function api.suck() return wait(0.05, false, "No items to take") end
  api.suckUp, api.suckDown = api.suck, api.suck
  function api.attack() return wait(0.05, false, "Nothing to attack here") end
  api.attackUp, api.attackDown = api.attack, api.attack

  function api.select(n)
    if type(n) ~= "number" or n < 1 or n > 16 then error("Slot out of range", 2) end
    T.selected = n
    return true
  end
  function api.getSelectedSlot() return T.selected end
  function api.getItemCount(n)
    local s = T.slots[n or T.selected]
    return s and s.count or 0
  end
  function api.getItemSpace(n)
    local s = T.slots[n or T.selected]
    return s and (64 - s.count) or 64
  end
  function api.getItemDetail(n)
    local s = T.slots[n or T.selected]
    if not s then return nil end
    return { name = s.name, count = s.count }
  end
  function api.transferTo(slot, count)
    return act(0.05, function()
      local s = T.slots[T.selected]
      if not s then return false, "No items to transfer" end
      local d = T.slots[slot]
      local n = math.min(count or s.count, s.count)
      if d and d.name ~= s.name then return false, "No space for items" end
      if d then n = math.min(n, 64 - d.count) end
      if not d then T.slots[slot] = { name = s.name, count = 0 }; d = T.slots[slot] end
      d.count, s.count = d.count + n, s.count - n
      if s.count <= 0 then T.slots[T.selected] = nil end
      return true
    end)
  end

  function api.getFuelLevel()
    if unlimited() then return "unlimited" end
    return T.fuel
  end
  function api.getFuelLimit() return T.fuelLimit end
  function api.refuel(count)
    return act(0.05, function()
      local s = T.slots[T.selected]
      if not s or not FUEL[s.name] then return false, "Items not combustible" end
      local n = math.min(count or s.count, s.count)
      if n == 0 then return true end
      T.fuel = math.min(T.fuel + FUEL[s.name] * n, T.fuelLimit)
      s.count = s.count - n
      if s.count <= 0 then T.slots[T.selected] = nil end
      return true
    end)
  end

  local function equip(side)
    return act(0.05, function()
      local s = T.slots[T.selected]
      if s and not UPGRADES[s.name] then return false, "Not a valid upgrade" end
      local old = T.equipped[side]
      T.equipped[side] = s and s.name or nil
      if s then
        s.count = s.count - 1
        if s.count <= 0 then T.slots[T.selected] = nil end
      end
      if old then store(old, 1) end
      sim:onEquipChanged(c, side)
      return true
    end)
  end
  function api.equipLeft() return equip("left") end
  function api.equipRight() return equip("right") end
  function api.getEquippedLeft()
    return T.equipped.left and { name = T.equipped.left, count = 1 } or nil
  end
  function api.getEquippedRight()
    return T.equipped.right and { name = T.equipped.right, count = 1 } or nil
  end

  return api
end
