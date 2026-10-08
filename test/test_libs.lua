local H = require("helpers")

local sha2 = dofile("src/fleet/lib/sha2.lua")
local ser = dofile("src/fleet/lib/ser.lua")

local function bare(sim, id)
  H.lastSim = sim
  return sim:add({ id = id or 5, boot = false, peripherals = { back = { "modem", ender = true } } })
end

return {
  { "sha256 test vectors", function()
    H.eq(sha2.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    H.eq(sha2.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    H.eq(sha2.sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    H.eq(sha2.sha256Hex(string.rep("a", 1000)),
      "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
  end },
  { "hmac-sha256 RFC 4231", function()
    H.eq(sha2.hmacHex(string.rep("\11", 20), "Hi There"),
      "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    H.eq(sha2.hmacHex("Jefe", "what do ya want for nothing?"),
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    H.eq(sha2.hmacHex(string.rep("\170", 131), "Test Using Larger Than Block-Size Key - Hash Key First"),
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
  end },
  { "ser round trip", function()
    local v = { 1, 2.5, -3, "a\nb\"c\\", { x = 1e15, y = -0.1 }, [10] = true,
      ["key with space"] = "v", ["end"] = 1, nested = { deep = { 1, 2, 3 } }, bin = "\0\200\255" }
    local s = ser.serialize(v)
    local back = ser.unserialize(s)
    H.eq(ser.serialize(back), s, "re-serialize")
    H.eq(back[4], "a\nb\"c\\")
    H.eq(back.bin, "\0\200\255")
    H.eq(back.x, nil)
    H.eq(back[5].x, 1e15)
    H.eq(back["end"], 1)
    H.eq(ser.serialize({ b = 1, a = 2 }), "{a=2,b=1}", "sorted keys")
    H.ok(not ser.unserialize("os.exit()"), "no globals in unserialize")
    H.ok(not pcall(ser.serialize, { f = print }), "functions rejected")
  end },
  { "locate.solve: exact, coplanar, bad host", function()
    local sim = H.Sim.new()
    local L = H.lib(bare(sim), "lib.locate")
    local hosts = { { 0, 90, 0 }, { 8, 90, 0 }, { 0, 90, 8 }, { 0, 98, 0 } }
    local function fixesFor(x, y, z, list)
      local f = {}
      for _, h in ipairs(list) do
        f[#f + 1] = { p = { x = h[1], y = h[2], z = h[3] },
          d = math.sqrt((x - h[1]) ^ 2 + (y - h[2]) ^ 2 + (z - h[3]) ^ 2) }
      end
      return f
    end
    for _, target in ipairs({ { 5, 64, 5 }, { -12000, -50, 25000 }, { 3, 95, 1 } }) do
      local p = H.ok(L.solve(fixesFor(target[1], target[2], target[3], hosts)))
      H.near(p.x, target[1], 1e-3, "x"); H.near(p.y, target[2], 1e-3, "y"); H.near(p.z, target[3], 1e-3, "z")
      H.ok(p.res < 1e-3, "residual")
    end
    local flat = { { 0, 90, 0 }, { 8, 90, 0 }, { 0, 90, 8 }, { 8, 90, 8 } }
    local p, err = L.solve(fixesFor(5, 64, 5, flat))
    H.eq(p, nil); H.ok(err:find("coplanar"), err)
    H.eq(select(2, L.solve(fixesFor(5, 64, 5, { hosts[1], hosts[2], hosts[3] }))), "need 4 GPS hosts, heard 3")
    -- a fifth host whose owner typed the wrong coordinates is detected and dropped
    local five = fixesFor(40, 64, -30, { hosts[1], hosts[2], hosts[3], hosts[4], { 8, 98, 8 } })
    five[5].p = { x = 8, y = 98, z = 18 }
    p = H.ok(L.robustSolve(five))
    H.near(p.x, 40, 1e-3); H.near(p.z, -30, 1e-3)
    H.eq(p.dropped, five[5], "dropped the bad host")
  end },
  { "net: sign, verify, replay, expiry, tamper", function()
    local sim = H.Sim.new()
    local a, b = bare(sim, 5), bare(sim, 6)
    local NetA, NetB = H.lib(a, "lib.net"), H.lib(b, "lib.net")
    local na = NetA.new({ secret = "s3cret-s3cret", dim = "overworld" })
    local nb = NetB.new({ secret = "s3cret-s3cret", dim = "the_nether" })
    local e = na:wrap(6, { type = "hb", fuel = 10 })
    local from, body = nb:unwrap(5, e, "turtlegps")
    H.eq(from, 5); H.eq(body.fuel, 10); H.eq(body.dim, "overworld")
    local _, why = nb:unwrap(5, e, "turtlegps")
    H.eq(why, "replay")
    local e2 = na:wrap(6, { type = "hb", fuel = 10 })
    e2.b = e2.b:gsub("10", "99")
    _, why = nb:unwrap(5, e2, "turtlegps")
    H.eq(why, "bad signature")
    local e3 = na:wrap(6, { type = "hb" })
    _, why = nb:unwrap(7, e3, "turtlegps")
    H.eq(why, "sender mismatch")
    local e4 = na:wrap(6, { type = "hb" })
    sim:run(31)
    _, why = nb:unwrap(5, e4, "turtlegps")
    H.eq(why, "expired")
    local nc = NetA.new({ secret = "other-secret!", dim = "x" })
    local e5 = nc:wrap(6, { type = "hb" })
    _, why = nb:unwrap(5, e5, "turtlegps")
    H.eq(why, "bad signature")
    local e6 = na:wrap(9, { type = "hb" })
    _, why = nb:unwrap(5, e6, "turtlegps")
    H.eq(why, "not for me")
    _, why = nb:unwrap(5, { t = 6, v = 1, f = 5.5 }, "turtlegps")
    H.eq(why, "format")
    _, why = nb:unwrap(5, "junk", "turtlegps")
    H.eq(why, "format")
    _, why = nb:unwrap(5, e, "other")
    H.eq(why, "protocol")
    H.eq(nb.stats.rejected, 7)
  end },
}
