-- Signed rednet messaging over ender modems.
--
-- Every message is an envelope:
--   { v = 1, f = fromId, t = toId|-1, ts = epochMs, n = nonce, b = "<serialized body>", m = hmac }
-- m = HMAC-SHA256(secret, "v|f|t|ts|n|b"). The secret itself is never transmitted.
-- Receivers drop anything that is not ours, too old, replayed, or badly signed, before
-- unserializing it. Who may do *what* (allowlists) is decided by the caller.

local sha2 = require("lib.sha2")
local ser = require("lib.ser")
local P = require("lib.proto")
local U = require("lib.util")

local Net = {}
Net.__index = Net

--- opts: secret, dim (string or function returning one), window (seconds), maxBody (bytes)
function Net.new(opts)
  local self = setmetatable({}, Net)
  self.secret = assert(opts.secret, "net: secret required")
  self.id = os.getComputerID()
  self.window = (opts.window or 30) * 1000
  self.maxBody = opts.maxBody or 65536
  self.protocol = opts.protocol or P.PROTOCOL
  if type(opts.dim) == "function" then self.dimFn = opts.dim
  else
    local d = opts.dim
    self.dimFn = function() return d end
  end
  self.seq = 0
  self.seen, self.seenCount = {}, 0
  self.stats = { sent = 0, recv = 0, rejected = 0, reasons = {}, last = {} }
  math.randomseed(os.epoch("utc") % 2147483647 + self.id * 7919)
  return self
end

--- Opens rednet on the first wireless modem. Returns true if one is available.
function Net:open()
  if self.side and peripheral.getType(self.side) == "modem" and rednet.isOpen(self.side) then
    return true
  end
  local _, side = U.findWirelessModem()
  self.side = side
  if not side then return false end
  if not rednet.isOpen(side) then rednet.open(side) end
  return true
end

function Net:isUp()
  return self.side ~= nil and peripheral.getType(self.side) == "modem" and rednet.isOpen(self.side)
end

local function isInt(x)
  return type(x) == "number" and x == math.floor(x) and x > -1e15 and x < 1e16
end

local function macInput(e)
  return string.format("%d|%d|%d|%d|%s|%s", e.v, e.f, e.t, e.ts, e.n, e.b)
end

function Net:wrap(to, body)
  if body.dim == nil then body.dim = self.dimFn() end
  self.seq = self.seq + 1
  local e = {
    v = P.VERSION, f = self.id, t = to, ts = os.epoch("utc"),
    n = string.format("%x.%x", self.seq, math.random(0, 0xffffff)),
    b = ser.serialize(body),
  }
  e.m = sha2.hmacHex(self.secret, macInput(e))
  return e
end

--- Sends a body table to one computer. Returns false if no modem is available.
function Net:send(to, body)
  if not self:open() then return false end
  rednet.send(to, self:wrap(to, body), self.protocol)
  self.stats.sent = self.stats.sent + 1
  return true
end

function Net:broadcast(body)
  if not self:open() then return false end
  rednet.broadcast(self:wrap(P.BROADCAST, body), self.protocol)
  self.stats.sent = self.stats.sent + 1
  return true
end

function Net:reject(sender, reason)
  local s = self.stats
  s.rejected = s.rejected + 1
  s.reasons[reason] = (s.reasons[reason] or 0) + 1
  table.insert(s.last, 1, { from = sender, reason = reason, t = os.epoch("utc") })
  if #s.last > 8 then table.remove(s.last) end
  return nil, reason
end

function Net:pruneSeen(now)
  if self.seenCount < 400 then return end
  local n = 0
  for k, exp in pairs(self.seen) do
    if exp < now then self.seen[k] = nil else n = n + 1 end
  end
  self.seenCount = n
end

--- Checks a rednet_message. Returns fromId, body  or  nil, reason.
--- Messages for other protocols or other computers return nil without counting as rejected.
function Net:unwrap(sender, e, protocol)
  if protocol ~= self.protocol then return nil, "protocol" end
  if type(e) ~= "table" then return self:reject(sender, "format") end
  if not isInt(e.t) then return self:reject(sender, "format") end
  if e.t ~= self.id and e.t ~= P.BROADCAST then return nil, "not for me" end
  if e.v ~= P.VERSION or not isInt(e.f) or not isInt(e.ts)
      or type(e.n) ~= "string" or type(e.b) ~= "string" or type(e.m) ~= "string" then
    return self:reject(sender, "format")
  end
  if #e.b > self.maxBody or #e.n > 40 then return self:reject(sender, "too big") end
  if e.f ~= sender then return self:reject(sender, "sender mismatch") end
  local now = os.epoch("utc")
  if math.abs(now - e.ts) > self.window then return self:reject(sender, "expired") end
  local key = e.f .. ":" .. e.n
  if self.seen[key] then return self:reject(sender, "replay") end
  if sha2.hmacHex(self.secret, macInput(e)) ~= e.m then return self:reject(sender, "bad signature") end
  self.seen[key] = e.ts + self.window
  self.seenCount = self.seenCount + 1
  self:pruneSeen(now)
  local body = ser.unserialize(e.b)
  if type(body) ~= "table" or type(body.type) ~= "string" then return self:reject(sender, "body") end
  body.dim = P.normDim(body.dim)
  self.stats.recv = self.stats.recv + 1
  return e.f, body
end

--- Blocks until a valid message arrives (or timeout). Other events are discarded,
--- so only call this from a coroutine dedicated to receiving.
function Net:receive(timeout)
  local timer = timeout and os.startTimer(timeout)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" then
      local from, body = self:unwrap(a, b, c)
      if from then
        if timer then os.cancelTimer(timer) end
        return from, body
      end
    elseif ev == "timer" and a == timer then
      return nil
    end
  end
end

return Net
