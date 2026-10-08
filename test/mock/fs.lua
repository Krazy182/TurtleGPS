-- In-memory filesystem implementing the CC:Tweaked `fs` API for one mock computer.

local FS = {}
FS.__index = FS

local function norm(path)
  local parts = {}
  for part in tostring(path):gmatch("[^/\\]+") do
    if part == ".." then
      table.remove(parts)
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, "/")
end

local function parent(p)
  return p:match("^(.*)/[^/]*$") or ""
end

--- opts.rom = { files = { ["rom/..."] = content }, dirs = { ["rom/..."] = true } } (read-only)
function FS.new(opts)
  opts = opts or {}
  local self = setmetatable({
    files = {},           -- normalized path -> content
    dirs = { [""] = true },
    capacity = opts.capacity or 1000000,
    readOnly = { rom = true },
  }, FS)
  if opts.rom then
    for p, content in pairs(opts.rom.files) do self.files[p] = content end
    for p in pairs(opts.rom.dirs) do self.dirs[p] = true end
  end
  return self
end

function FS:used()
  local n = 0
  for p, c in pairs(self.files) do
    if p:sub(1, 4) ~= "rom/" then n = n + #c end
  end
  return n
end

function FS:mkdirs(p)
  while p ~= "" and not self.dirs[p] do
    self.dirs[p] = true
    p = parent(p)
  end
end

function FS:writeFile(path, content)
  local p = norm(path)
  self:mkdirs(parent(p))
  self.files[p] = content
end

function FS:readFile(path)
  return self.files[norm(path)]
end

--- Builds the table exposed to Lua code as `fs`.
function FS:api()
  local self_ = self
  local api = {}

  function api.combine(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = select(i, ...) end
    return norm(table.concat(parts, "/"))
  end
  function api.getName(p)
    p = norm(p)
    if p == "" then return "root" end
    return p:match("([^/]+)$")
  end
  function api.getDir(p) return parent(norm(p)) end
  function api.exists(p)
    p = norm(p)
    return self_.files[p] ~= nil or self_.dirs[p] ~= nil
  end
  function api.isDir(p) return self_.dirs[norm(p)] ~= nil end
  function api.isReadOnly(p)
    local top = norm(p):match("^[^/]*")
    return self_.readOnly[top] == true
  end
  function api.getSize(p)
    p = norm(p)
    if self_.files[p] then return #self_.files[p] end
    if self_.dirs[p] then return 0 end
    error("/" .. p .. ": No such file", 2)
  end
  function api.getFreeSpace() return math.max(0, self_.capacity - self_:used()) end
  function api.getCapacity() return self_.capacity end
  function api.list(p)
    p = norm(p)
    if not self_.dirs[p] then error("/" .. p .. ": Not a directory", 2) end
    local out, seen = {}, {}
    local prefix = p == "" and "" or (p .. "/")
    local function add(full)
      if full:sub(1, #prefix) == prefix then
        local rest = full:sub(#prefix + 1)
        if rest ~= "" and not rest:find("/") and not seen[rest] then
          seen[rest] = true
          out[#out + 1] = rest
        end
      end
    end
    for f in pairs(self_.files) do add(f) end
    for d in pairs(self_.dirs) do add(d) end
    table.sort(out)
    return out
  end
  function api.makeDir(p)
    p = norm(p)
    if self_.files[p] then error("/" .. p .. ": File exists", 2) end
    self_:mkdirs(p)
  end
  function api.delete(p)
    p = norm(p)
    if p == "" or api.isReadOnly(p) then error("Access denied", 2) end
    self_.files[p] = nil
    if self_.dirs[p] then
      local prefix = p .. "/"
      for f in pairs(self_.files) do if f:sub(1, #prefix) == prefix then self_.files[f] = nil end end
      for d in pairs(self_.dirs) do if d:sub(1, #prefix) == prefix then self_.dirs[d] = nil end end
      self_.dirs[p] = nil
    end
  end
  function api.copy(a, b)
    a, b = norm(a), norm(b)
    if not api.exists(a) then error("/" .. a .. ": No such file", 2) end
    if api.exists(b) then error("/" .. b .. ": File exists", 2) end
    if self_.files[a] then
      self_:writeFile(b, self_.files[a])
    else
      self_:mkdirs(b)
      local prefix = a .. "/"
      local fl, dl = {}, {}
      for f, c in pairs(self_.files) do if f:sub(1, #prefix) == prefix then fl[f] = c end end
      for d in pairs(self_.dirs) do if d:sub(1, #prefix) == prefix then dl[#dl + 1] = d end end
      for _, d in ipairs(dl) do self_:mkdirs(b .. d:sub(#a + 1)) end
      for f, c in pairs(fl) do self_:writeFile(b .. f:sub(#a + 1), c) end
    end
  end
  function api.move(a, b)
    api.copy(a, b)
    api.delete(a)
  end

  function api.open(p, mode)
    p = norm(p)
    if mode == "r" or mode == "rb" then
      local content = self_.files[p]
      if not content then return nil, "/" .. p .. ": No such file" end
      local pos, closed = 1, false
      local h = {}
      function h.readAll()
        if closed then error("attempt to use a closed file", 2) end
        local s = content:sub(pos)
        pos = #content + 1
        return s
      end
      function h.readLine(withTrailing)
        if closed then error("attempt to use a closed file", 2) end
        if pos > #content then return nil end
        local e = content:find("\n", pos, true)
        local line
        if e then
          line = content:sub(pos, withTrailing and e or e - 1)
          pos = e + 1
        else
          line = content:sub(pos)
          pos = #content + 1
        end
        return line
      end
      function h.read(n)
        if pos > #content then return nil end
        n = n or 1
        local s = content:sub(pos, pos + n - 1)
        pos = pos + n
        if mode == "rb" and n == 1 then return s:byte() end
        return s
      end
      function h.close() closed = true end
      return h
    elseif mode == "w" or mode == "a" or mode == "wb" or mode == "ab" then
      if self_.dirs[p] then return nil, "/" .. p .. ": Cannot write to directory" end
      if api.isReadOnly(p) then return nil, "/" .. p .. ": Access denied" end
      local buf = {}
      if mode:sub(1, 1) == "a" and self_.files[p] then buf[1] = self_.files[p] end
      self_:writeFile(p, table.concat(buf))
      local closed = false
      local h = {}
      local function commit()
        local data = table.concat(buf)
        local others = self_:used() - #(self_.files[p] or "")
        if others + #data > self_.capacity then error("Out of space", 3) end
        self_.files[p] = data
      end
      function h.write(s)
        if closed then error("attempt to use a closed file", 2) end
        if type(s) == "number" and mode:find("b") then s = string.char(s) end
        buf[#buf + 1] = tostring(s)
      end
      function h.writeLine(s) h.write(tostring(s) .. "\n") end
      function h.flush() commit() end
      function h.close()
        if closed then error("attempt to use a closed file", 2) end
        commit()
        closed = true
      end
      return h
    end
    error("Unsupported mode " .. tostring(mode), 2)
  end

  return api
end

FS.norm = norm
return FS
