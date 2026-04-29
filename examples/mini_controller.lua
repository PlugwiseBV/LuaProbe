#!/usr/bin/env luajit
-- Minimal luaprobe controller.
--
-- Spawns ./demo.lua with a breakpoint at line 4, prints the stack
-- and locals whenever it pauses, then continues. Run as:
--
--   cd examples
--   luajit mini_controller.lua
--
-- Or point it at a different target:
--
--   luajit mini_controller.lua ../some/other.lua
--
-- No UI framework, no curses — just plain stdout.

-- Find ../luaprobe.lua so we can require it without installing.
local here = arg[0]:match("(.*/)") or "./"
package.path = here .. "../?.lua;" .. package.path

local luaprobe = require("luaprobe")

-- Absolute path to the stub (LUA_INIT needs an absolute path).
local stub_abs
do
  local f = io.popen("realpath '" .. here .. "../luaprobe_stub.lua'")
  stub_abs = f:read("*l")
  f:close()
end

local sess, err = luaprobe.new({
  stub_path    = stub_abs,
  breakpoints  = { "demo.lua:7" },
  source_roots = { here },
  on_status    = function(msg)
    io.stderr:write("[luaprobe] " .. msg .. "\n")
  end,
})
assert(sess, err)

-- Spawn the child with the env prefix injected into an sh -c wrapper.
-- env_prefix() returns values with double quotes so this is safe.
local target = arg[1] or (here .. "demo.lua")
local cmd = string.format(
  [[sh -c '%s lua5.1 %s' &]], sess:env_prefix(), target)
print("launching:", cmd)
os.execute(cmd)

-- Main loop.
print("waiting for events... (Ctrl-C to quit)")
local seen_exit = false
while not seen_exit do
  for _, ev in ipairs(sess:poll()) do
    if ev.event == "hello" then
      print("child attached; breakpoints: " .. tostring(ev.bps))

    elseif ev.event == "break" then
      local thread_tag = ev.is_main and "main"
                       or ("co:" .. tostring(ev.thread):sub(-8))
      print(string.format(
        "\n=== BREAK at %s:%d  [%s]  (reason=%s) ===",
        (ev.frames[1] and ev.frames[1].source) or "?",
        ev.line or 0, thread_tag, ev.reason or "?"))

      -- Stack
      print("  stack:")
      for i, f in ipairs(ev.frames) do
        print(string.format("    #%d  %-20s  %s:%d",
          i, f.name or "?", f.source or "?", f.line or 0))
      end

      -- Coroutine creation site, if any
      if ev.created_src then
        print(string.format("  coroutine created at %s:%d",
          ev.created_src, ev.created_line or 0))
      end

      -- Locals + upvalues of the top frame
      local fv = ev.vars and ev.vars[1]
      if fv then
        if fv.locals and #fv.locals > 0 then
          print("  locals:")
          for _, v in ipairs(fv.locals) do
            print(string.format("    %s = %s", v.name, v.value))
          end
        end
        if fv.upvalues and #fv.upvalues > 0 then
          print("  upvalues:")
          for _, v in ipairs(fv.upvalues) do
            print(string.format("    %s = %s", v.name, v.value))
          end
        end
        if fv.entry and #fv.entry > 0 then
          print("  entry-time values (as passed into the function):")
          for _, v in ipairs(fv.entry) do
            print(string.format("    %s = %s", v.name, v.value))
          end
        end
      end

      print("  continuing...")
      sess:cmd_continue()

    elseif ev.event == "inspect" then
      print(string.format("  inspect %s = %s", ev.name, ev.repr))

    elseif ev.event == "error" then
      io.stderr:write("stub error at " .. tostring(ev.where) ..
        ": " .. tostring(ev.err) .. "\n")
    end
  end
  os.execute("sleep 0.05")
end

sess:close()
