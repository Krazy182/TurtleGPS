-- Test runner:  lua5.2 test/run.lua [filter]
-- Runs every test/test_*.lua. Each file returns a list of { "name", function(t) ... end }.

package.path = "./test/?.lua;./test/?/init.lua;" .. package.path

local filter = arg[1]
local files = {}
local p = io.popen("ls test/test_*.lua")
for f in p:lines() do files[#files + 1] = f end
p:close()

local passed, failed, failures = 0, 0, {}
local t0 = os.clock()
for _, file in ipairs(files) do
  local tests = dofile(file)
  for _, case in ipairs(tests) do
    local name = file:match("test_(.-)%.lua") .. ": " .. case[1]
    if not filter or name:find(filter, 1, true) then
      local ok, err = xpcall(case[2], debug.traceback)
      if ok then
        passed = passed + 1
        io.write("  ok    ", name, "\n")
      else
        failed = failed + 1
        failures[#failures + 1] = { name = name, err = err }
        io.write("  FAIL  ", name, "\n")
      end
    end
  end
end

for _, f in ipairs(failures) do
  io.write("\n---- ", f.name, " ----\n", tostring(f.err), "\n")
end
io.write(string.format("\n%d passed, %d failed (%.1fs cpu)\n", passed, failed, os.clock() - t0))
os.exit(failed == 0 and 0 or 1)
