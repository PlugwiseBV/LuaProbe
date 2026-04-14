-- Tiny program used by examples/mini_controller.lua to demonstrate
-- pwdebug. Set a breakpoint at line 4 and you'll pause once per
-- iteration of the loop, with `name`, `times`, `message`, and `i`
-- visible as locals.

local function greet(name, times)
  local message = "hello, " .. name
  for i = 1, times do
    print(message .. " (" .. i .. ")")
  end
end

greet("world", 3)
