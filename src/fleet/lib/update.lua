-- Over-the-air code updates, signed like every other fleet message.
--
-- The control computer's /fleet code is the fleet's code. Devices learn the server's
-- version from heartbeat acks / offers, request the files whose hashes differ, verify
-- each against the server's manifest, back up the old code to /fleet.old, swap and
-- reboot. boot.lua rolls back automatically if the new code crashes 3 times in a row.

local sha2 = require("lib.sha2")
local store = require("lib.store")
local P = require("lib.proto")

local Up = {}
Up.ROOT = "/fleet"
Up.BACKUP = "/fleet.old"
Up.MANIFEST = "/fleet/manifest"
Up.STATE = "/fleet/data/update"

local function isCode(rel)
  return not (rel == "config.lua" or rel == "manifest" or rel:sub(1, 5) == "data/" or rel:find("%.tmp$"))
end

local function safePath(rel)
  return type(rel) == "string" and rel ~= "" and not rel:find("%.%.") and rel:sub(1, 1) ~= "/"
    and not rel:find("\\") and isCode(rel)
end
Up.safePath = safePath

--- Lists code files under root as paths relative to it.
function Up.listCode(root)
  root = root or Up.ROOT
  local out = {}
  local function walk(dir, rel)
    for _, name in ipairs(fs.list(dir)) do
      local full, r = fs.combine(dir, name), rel == "" and name or (rel .. "/" .. name)
      if fs.isDir(full) then walk(full, r)
      elseif isCode(r) then out[#out + 1] = r end
    end
  end
  if fs.exists(root) then walk(root, "") end
  table.sort(out)
  return out
end

function Up.version(files)
  local lines = {}
  for path, hash in pairs(files) do lines[#lines + 1] = path .. "=" .. hash end
  table.sort(lines)
  return sha2.sha256Hex(table.concat(lines, "\n")):sub(1, 8)
end

--- Hashes every code file (yields between files: call from its own coroutine).
function Up.computeManifest(root)
  root = root or Up.ROOT
  local files = {}
  for _, rel in ipairs(Up.listCode(root)) do
    files[rel] = sha2.sha256Hex(store.readFile(fs.combine(root, rel)) or "")
    os.queueEvent("fleet_yield")
    os.pullEvent("fleet_yield")
  end
  return { files = files, ver = Up.version(files) }
end

function Up.readManifest()
  local m = store.load(Up.MANIFEST, nil)
  if type(m) == "table" and type(m.files) == "table" then return m end
  return nil
end

function Up.myVersion()
  local m = Up.readManifest()
  return m and m.ver or "none"
end

--- Restores /fleet.old (used by boot.lua after repeated crashes of new code).
function Up.rollback()
  if not fs.exists(Up.BACKUP) then return false end
  for _, rel in ipairs(Up.listCode(Up.ROOT)) do fs.delete(fs.combine(Up.ROOT, rel)) end
  for _, rel in ipairs(Up.listCode(Up.BACKUP)) do
    fs.copy(fs.combine(Up.BACKUP, rel), fs.combine(Up.ROOT, rel))
  end
  local bm = fs.combine(Up.BACKUP, "manifest")
  if fs.exists(bm) then
    if fs.exists(Up.MANIFEST) then fs.delete(Up.MANIFEST) end
    fs.copy(bm, Up.MANIFEST)
  end
  local st = store.load(Up.STATE, {})
  st.pending, st.rolledBack = false, st.ver
  store.save(Up.STATE, st)
  return true
end

-- Device side ------------------------------------------------------------------------

local Client = {}
Client.__index = Client

--- opts: net, serverId, log, canApply (function -> bool, e.g. "turtle is idle")
function Up.client(opts)
  local m = Up.readManifest()
  local st = store.load(Up.STATE, {})
  return setmetatable({
    skip = st.rolledBack, -- a version that crashed here: only an explicit offer retries it
    net = opts.net, serverId = opts.serverId, log = opts.log,
    canApply = opts.canApply or function() return true end,
    have = m and m.files or {}, ver = m and m.ver or "none",
    want = nil, receiving = false, files = {}, deadline = 0, nextTry = 0, ready = nil,
    status = nil,
  }, Client)
end

--- Called with the server's version (from heartbeat acks and offers).
function Client:serverVersion(ver, explicit)
  if type(ver) ~= "string" or ver == self.ver or ver == "none" then return end
  if ver == self.skip and not explicit then
    self.status = "skipping " .. ver .. " (it crashed here; press U on control to retry)"
    return
  end
  self.want = ver
end

--- Feeds a verified message from the server. Returns true if it was an update message.
function Client:handle(from, body)
  if from ~= self.serverId then return false end
  if body.type == P.UPD_OFFER then
    self:serverVersion(body.ver, true)
    self.nextTry = 0
    return true
  elseif body.type == P.UPD_FILE then
    if self.receiving and safePath(body.path) and type(body.data) == "string"
        and sha2.sha256Hex(body.data) == body.hash then
      self.files[body.path] = body.data
    end
    return true
  elseif body.type == P.UPD_END then
    if self.receiving and type(body.files) == "table" then
      local missing = {}
      for path, hash in pairs(body.files) do
        if not safePath(path) then missing[#missing + 1] = tostring(path) end
        if not self.files[path] and self.have[path] ~= hash then missing[#missing + 1] = path end
      end
      self.receiving = false
      if #missing == 0 then
        self.ready = { files = body.files, ver = body.ver }
        self.status = "update " .. tostring(body.ver) .. " ready"
      else
        self.status = "update incomplete (" .. #missing .. " missing), will retry"
        self.nextTry = os.epoch("utc") + 30000
        if self.log then self.log:warn("update %s: %d files missing", tostring(body.ver), #missing) end
      end
    end
    return true
  end
  return false
end

function Client:apply()
  local r = self.ready
  -- back up the running code so boot.lua can roll back
  if fs.exists(Up.BACKUP) then fs.delete(Up.BACKUP) end
  for _, rel in ipairs(Up.listCode(Up.ROOT)) do
    fs.copy(fs.combine(Up.ROOT, rel), fs.combine(Up.BACKUP, rel))
  end
  if fs.exists(Up.MANIFEST) then fs.copy(Up.MANIFEST, fs.combine(Up.BACKUP, "manifest")) end
  for path, data in pairs(self.files) do
    if r.files[path] then
      local ok, err = store.writeFile(fs.combine(Up.ROOT, path), data)
      if not ok then
        if self.log then self.log:error("update write failed: %s", tostring(err)) end
        Up.rollback()
        return false
      end
    end
  end
  for _, rel in ipairs(Up.listCode(Up.ROOT)) do
    if not r.files[rel] then fs.delete(fs.combine(Up.ROOT, rel)) end
  end
  store.save(Up.MANIFEST, { files = r.files, ver = r.ver })
  store.save(Up.STATE, { ver = r.ver, from = self.ver, at = os.epoch("utc"), pending = true, crashes = 0 })
  if self.log then self.log:info("updated %s -> %s, rebooting", self.ver, tostring(r.ver)) end
  os.reboot()
end

--- Call periodically from the program's main coroutine.
function Client:tick()
  local now = os.epoch("utc")
  if self.ready then
    if self.canApply() then self:apply() end
    return
  end
  if self.receiving and now > self.deadline then
    self.receiving = false
    self.status = "update timed out, will retry"
    self.nextTry = now + 60000
  end
  if self.want and not self.receiving and now >= self.nextTry then
    self.receiving, self.files = true, {}
    self.deadline = now + 60000
    self.status = "downloading " .. self.want
    self.net:send(self.serverId, { type = P.UPD_REQ, have = self.have, ver = self.ver })
  end
end

-- Server side --------------------------------------------------------------------------

local Server = {}
Server.__index = Server

function Up.server(opts)
  return setmetatable({ net = opts.net, log = opts.log, manifest = nil, jobs = {}, served = 0 }, Server)
end

function Server:refresh()
  self.manifest = Up.computeManifest(Up.ROOT)
  store.save(Up.MANIFEST, self.manifest)
  return self.manifest
end

function Server:version() return self.manifest and self.manifest.ver or "none" end

function Server:offer()
  if not self.manifest then return false end
  return self.net:broadcast({ type = P.UPD_OFFER, ver = self.manifest.ver })
end

function Server:handle(from, body)
  if body.type ~= P.UPD_REQ then return false end
  if self.manifest then
    local have = type(body.have) == "table" and body.have or {}
    for _, j in ipairs(self.jobs) do
      if j.to == from then j.have = have; return true end
    end
    self.jobs[#self.jobs + 1] = { to = from, have = have }
  end
  return true
end

--- Sends queued updates. Run in its own coroutine; yields between files.
function Server:pump()
  while #self.jobs > 0 do
    local job = table.remove(self.jobs, 1)
    local m = self.manifest
    local sent = 0
    for _, path in ipairs((function()
      local ks = {}
      for k in pairs(m.files) do ks[#ks + 1] = k end
      table.sort(ks)
      return ks
    end)()) do
      local hash = m.files[path]
      if job.have[path] ~= hash then
        local data = store.readFile(fs.combine(Up.ROOT, path))
        if data then
          self.net:send(job.to, { type = P.UPD_FILE, path = path, data = data, hash = hash })
          sent = sent + 1
          sleep(0.05)
        end
      end
    end
    self.net:send(job.to, { type = P.UPD_END, files = m.files, ver = m.ver })
    self.served = self.served + 1
    if self.log then self.log:info("sent update %s to #%d (%d files)", m.ver, job.to, sent) end
  end
end

return Up
