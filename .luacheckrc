-- luacheck config: CC:Tweaked globals for src/, plain Lua 5.2 for the harness.
std = "lua52"
exclude_files = { "test/rom/**", "test/out/**" }
max_line_length = 160

files["src/fleet"] = {
  read_globals = {
    "term", "fs", "os", "peripheral", "rednet", "colors", "colours", "keys", "parallel",
    "sleep", "write", "print", "printError", "read", "shell", "turtle", "pocket", "gps",
    "textutils", "settings", "vector", "window", "multishell", "http", "redstone", "rs", "_HOST",
  },
}
files["test"] = { globals = { "keys" }, unused_args = false }
files["tools"] = {}
