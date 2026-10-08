-- Compact, deterministic serializer (keys sorted) and a sandboxed unserializer.
-- Same output in-game and in the mock harness, so signatures and saved files match.

local format, concat, sort = string.format, table.concat, table.sort
local floor, huge = math.floor, math.huge

local M = {}

local escapes = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ['"'] = '\\"', ["\\"] = "\\\\" }

local function quote(s)
  return '"' .. s:gsub('[%c"\\\128-\255]', function(c)
    return escapes[c] or format("\\%03d", c:byte())
  end) .. '"'
end

local function num(n)
  if n ~= n then return "0/0" end
  if n == huge then return "1/0" end
  if n == -huge then return "-1/0" end
  if n == floor(n) and n >= -9007199254740992 and n <= 9007199254740992 then
    return format("%d", n)
  end
  local s = format("%.14g", n)
  if tonumber(s) ~= n then s = format("%.17g", n) end
  return s
end

local keywords = {}
for w in ([[and break do else elseif end false for function goto if in
  local nil not or repeat return then true until while]]):gmatch("%a+") do keywords[w] = true end

local function keyOrder(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta < tb end
  return a < b
end

local function write(v, out, seen)
  local t = type(v)
  if t == "string" then out[#out + 1] = quote(v)
  elseif t == "number" then out[#out + 1] = num(v)
  elseif t == "boolean" or t == "nil" then out[#out + 1] = tostring(v)
  elseif t == "table" then
    if seen[v] then error("ser: cannot serialize a table that contains itself", 0) end
    seen[v] = true
    out[#out + 1] = "{"
    local n = #v
    for i = 1, n do
      write(v[i], out, seen)
      out[#out + 1] = ","
    end
    local keys = {}
    for k in pairs(v) do
      local tk = type(k)
      if not (tk == "number" and k >= 1 and k <= n and k == floor(k)) then
        if tk ~= "string" and tk ~= "number" and tk ~= "boolean" then
          error("ser: cannot serialize key of type " .. tk, 0)
        end
        keys[#keys + 1] = k
      end
    end
    sort(keys, keyOrder)
    for _, k in ipairs(keys) do
      if type(k) == "string" and k:match("^[%a_][%w_]*$") and not keywords[k] then
        out[#out + 1] = k
      else
        out[#out + 1] = "["
        write(k, out, seen)
        out[#out + 1] = "]"
      end
      out[#out + 1] = "="
      write(v[k], out, seen)
      out[#out + 1] = ","
    end
    if out[#out] == "," then out[#out] = "}" else out[#out + 1] = "}" end
    seen[v] = nil
  else
    error("ser: cannot serialize a " .. t, 0)
  end
end

function M.serialize(v)
  local out = {}
  write(v, out, {})
  return concat(out)
end

--- Returns the value, or nil plus an error message. Runs with an empty environment.
function M.unserialize(s)
  if type(s) ~= "string" then return nil, "not a string" end
  local fn, err = load("return " .. s, "=ser", "t", {})
  if not fn then return nil, err end
  local ok, v = pcall(fn)
  if not ok then return nil, v end
  return v
end

return M
