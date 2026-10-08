-- Join codes: the control computer's ID and the shared secret in one pasteable string,
-- with a short checksum so a typo is caught instead of producing a silent bad config.
--   TG-<control id>-<secret>-<4 hex checksum>

local sha2 = require("lib.sha2")

local J = {}

local function checksum(id, secret)
  return sha2.sha256Hex(id .. ":" .. secret):sub(1, 4)
end

function J.make(id, secret)
  return ("TG-%d-%s-%s"):format(id, secret, checksum(id, secret))
end

function J.looksLike(s)
  return type(s) == "string" and s:match("^%s*[Tt][Gg]%-%d+%-.+%-%x%x%x%x%s*$") ~= nil
end

--- Returns controlId, secret  or  nil, reason.
function J.parse(s)
  if type(s) ~= "string" then return nil, "not a join code" end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  local id, secret, chk = s:match("^[Tt][Gg]%-(%d+)%-(.+)%-(%x%x%x%x)$")
  if not id then return nil, "not a join code (it looks like TG-7-abcd...-1f2e)" end
  id = tonumber(id)
  if checksum(id, secret) ~= chk:lower() then
    return nil, "join code has a typo (checksum does not match)"
  end
  return id, secret
end

return J
