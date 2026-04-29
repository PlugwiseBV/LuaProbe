-- demo.lua — target program for the luaprobe quickstart.
-- Try: bin/luaprobe -b demo.lua:5 examples/demo.lua

local function greet(name, times)
  local message = "hello, " .. name   -- line 5
  for i = 1, times do
    print(message .. " (" .. i .. ")")  -- line 7
  end
end

greet("world", 3)
