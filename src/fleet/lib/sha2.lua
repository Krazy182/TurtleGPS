-- SHA-256 and HMAC-SHA256 in pure Lua (CC:Tweaked / Lua 5.2, uses bit32).
-- Used to sign every fleet message so the shared secret never goes over the air.

local band, bxor, bnot = bit32.band, bit32.bxor, bit32.bnot
local rrotate, rshift = bit32.rrotate, bit32.rshift
local byte, char, rep, format = string.byte, string.char, string.rep, string.format
local concat = table.concat

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local M32 = 0xffffffff
local W = {}

local function compress(H, s, off)
  for j = 1, 16 do
    local a, b, c, d = byte(s, off + 1, off + 4)
    W[j] = ((a * 256 + b) * 256 + c) * 256 + d
    off = off + 4
  end
  for j = 17, 64 do
    local v15, v2 = W[j - 15], W[j - 2]
    local s0 = bxor(rrotate(v15, 7), rrotate(v15, 18), rshift(v15, 3))
    local s1 = bxor(rrotate(v2, 17), rrotate(v2, 19), rshift(v2, 10))
    W[j] = band(W[j - 16] + s0 + W[j - 7] + s1, M32)
  end
  local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
  for j = 1, 64 do
    local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
    local ch = bxor(band(e, f), band(bnot(e), g))
    local t1 = h + S1 + ch + K[j] + W[j]
    local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
    local maj = bxor(band(a, b), band(a, c), band(b, c))
    h, g, f, e, d, c, b = g, f, e, band(d + t1, M32), c, b, a
    a = band(t1 + S0 + maj, M32)
  end
  H[1] = band(H[1] + a, M32); H[2] = band(H[2] + b, M32)
  H[3] = band(H[3] + c, M32); H[4] = band(H[4] + d, M32)
  H[5] = band(H[5] + e, M32); H[6] = band(H[6] + f, M32)
  H[7] = band(H[7] + g, M32); H[8] = band(H[8] + h, M32)
end

local function word(w)
  return char(band(rshift(w, 24), 255), band(rshift(w, 16), 255), band(rshift(w, 8), 255), band(w, 255))
end

local M = {}

--- Raw 32-byte SHA-256 digest of a string.
function M.sha256(msg)
  local len = #msg
  local bits = len * 8
  local pad = (64 - (len + 9) % 64) % 64
  msg = msg .. "\128" .. rep("\0", pad) .. word(math.floor(bits / 4294967296)) .. word(bits % 4294967296)
  local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  for off = 0, #msg - 1, 64 do compress(H, msg, off) end
  local out = {}
  for i = 1, 8 do out[i] = word(H[i]) end
  return concat(out)
end

function M.hex(bin)
  return (bin:gsub(".", function(c) return format("%02x", byte(c)) end))
end

local padCache = {}

local function pads(key)
  local p = padCache[key]
  if p then return p[1], p[2] end
  local k = key
  if #k > 64 then k = M.sha256(k) end
  k = k .. rep("\0", 64 - #k)
  local i, o = {}, {}
  for n = 1, 64 do
    local b = byte(k, n)
    i[n] = char(bxor(b, 0x36))
    o[n] = char(bxor(b, 0x5c))
  end
  local ipad, opad = concat(i), concat(o)
  padCache = { [key] = { ipad, opad } }
  return ipad, opad
end

--- Raw 32-byte HMAC-SHA256.
function M.hmac(key, msg)
  local ipad, opad = pads(key)
  return M.sha256(opad .. M.sha256(ipad .. msg))
end

function M.hmacHex(key, msg) return M.hex(M.hmac(key, msg)) end
function M.sha256Hex(msg) return M.hex(M.sha256(msg)) end

return M
