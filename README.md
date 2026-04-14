# pwdebug-lua

A source-level debugger for Lua 5.1 / LuaJIT programs, implemented as
two small files you drop into any project. No C extensions, no
luasocket, no luaposix — just the Lua standard library on the child
side and LuaJIT FFI on the controller side.

- **`pwdebug_stub.lua`** — plain Lua 5.1, loaded into the target
  process via `LUA_INIT`. Installs a line hook, coroutine hooks, and
  call/return hooks; talks to the controller over two FIFOs.
- **`pwdebug.lua`** — LuaJIT-only controller library. Creates the
  FIFOs, spawns the debugged child with the right env vars, decodes
  events, sends commands.

What you get:

- File+line breakpoints (stop or log-only) with **snap-forward**
  semantics, so you don't have to pick an executable line exactly.
- Full Lua stack walking at every break, with locals, upvalues, and
  **entry-time snapshots** (the parameter values the function was
  called with, before its body modified them).
- On-demand **deep inspection** of any variable: press one key, get
  a full recursive table dump with cycle safety and configurable
  depth/key caps.
- **Coroutine-aware** — breakpoints fire inside coroutines, the
  break event identifies which coroutine, and the stub records
  where each coroutine was spawned so you can trace back to the
  creation site.
- Stepping: `step` (step-into), `next` (step-over, thread-aware),
  `finish` (step-out), `continue`.
- Live add/remove of breakpoints during a pause.

---

## Requirements

- Linux (uses the POSIX FIFO `O_RDWR` trick and `/tmp` semantics)
- `mkfifo` on `PATH`
- Controller: LuaJIT (FFI)
- Target process: Lua 5.1 or LuaJIT

No other dependencies.

---

## Installation

Copy the two files into your project:

```sh
cp pwdebug_stub.lua pwdebug.lua /wherever/you/want/
```

There is no install step. `pwdebug.lua` is `require`d from your
controller; `pwdebug_stub.lua` is passed as an absolute path via
`LUA_INIT`.

---

## Quickstart

Say this is the program you want to debug:

```lua
-- examples/demo.lua
local function greet(name, times)
  local message = "hello, " .. name
  for i = 1, times do
    print(message .. " (" .. i .. ")")
  end
end

greet("world", 3)
```

Here's the minimum controller that sets a breakpoint at line 4,
prints the stack + locals whenever it fires, and continues. This is
`examples/mini_controller.lua`:

```lua
#!/usr/bin/env luajit
-- Minimal pwdebug controller — break at demo.lua:4, print stack
-- and locals, continue. About 50 lines of real code.

local pwdebug = require("pwdebug")

local here = arg[0]:match("(.*/)") or "./"
local stub = here .. "../pwdebug_stub.lua"
local stub_abs = io.popen("realpath " .. stub):read("*l")

local sess, err = pwdebug.new({
  stub_path    = stub_abs,
  breakpoints  = { "demo.lua:4" },
  source_roots = { here },
  on_status    = function(msg) io.stderr:write("[pwdebug] " .. msg .. "\n") end,
})
assert(sess, err)

-- Spawn the child with the env prefix injected into a standard
-- `sh -c 'lua5.1 demo.lua'` wrapper.
local target = arg[1] or (here .. "demo.lua")
local cmd = string.format(
  [[sh -c '%s lua5.1 %s' &]], sess:env_prefix(), target)
print("launching:", cmd)
os.execute(cmd)

-- Poll the session in a loop. Events come back as decoded tables.
print("waiting for events... (Ctrl-C to quit)")
while true do
  for _, ev in ipairs(sess:poll()) do
    if ev.event == "hello" then
      print("child attached; breakpoints:", ev.bps)
    elseif ev.event == "break" then
      print(string.format("\n=== BREAK at %s:%d (reason=%s, thread=%s) ===",
        ev.frames[1].source, ev.line, ev.reason, ev.thread or "?"))
      for i, f in ipairs(ev.frames) do
        print(string.format("  #%d  %s  %s:%d",
          i, f.name, f.source, f.line))
      end
      print("  locals of top frame:")
      for _, v in ipairs(ev.vars[1].locals or {}) do
        print(string.format("    %s = %s", v.name, v.value))
      end
      print("  continuing...")
      sess:cmd_continue()
    end
  end
  os.execute("sleep 0.05")  -- tiny yield so we don't pin a CPU
end
```

Run it:

```sh
cd examples
luajit mini_controller.lua
```

You'll see something like:

```
launching: sh -c 'PWDEBUG_FIFO_OUT=... lua5.1 ./demo.lua' &
waiting for events...
child attached; breakpoints: demo.lua:4

=== BREAK at demo.lua:4 (reason=stop, thread=main) ===
  #1  greet  demo.lua:4
  #2  <main>  demo.lua:8
  locals of top frame:
    name = "world"
    times = 3
    message = "hello, world"
    i = 1
  continuing...
hello, world (1)

=== BREAK at demo.lua:4 (reason=stop, thread=main) ===
  ...
```

That's the full debugger loop: breakpoint fires, the stub serializes
the stack + locals as a single line of Lua literals, the controller
decodes it, prints what it wants, and sends a `continue` command.

---

## API

### `pwdebug.new(opts) -> session | nil, err`

Creates a new debug session. Returns a session object or `(nil,
errmsg)` on failure.

```lua
local sess = pwdebug.new({
  stub_path    = "/abs/path/to/pwdebug_stub.lua",  -- required
  breakpoints  = { "src/foo.lua:42", "bar.lua:88!" },
  source_roots = { ".", "src" },
  on_status    = function(msg) print("[dbg] " .. msg) end,
})
```

**`stub_path`** (required) — absolute path to `pwdebug_stub.lua`.
The session will inject this into the child's `LUA_INIT`.

**`breakpoints`** (optional) — initial breakpoint specs as an array
of strings, each `"FILE:LINE"` (stop) or `"FILE:LINE!"` (log-only:
send the stack and continue without pausing).

**`source_roots`** (optional) — directories to search when resolving
relative source paths in `session:get_source(path)`. Default:
`{"."}`.

**`on_status`** (optional) — callback invoked with a status string
on decode errors and other lifecycle events. Default: no-op.

### `session:env_prefix() -> string`

Returns the shell env-var prefix to inject into your child-process
launch command. The string includes:

```
PWDEBUG_FIFO_OUT="..." PWDEBUG_FIFO_IN="..." PWDEBUG_BREAKPOINTS="..." LUA_INIT="@..."
```

All values are **double-quoted** so the string can be safely embedded
inside a single-quoted `sh -c '...'` wrapper. Use like:

```lua
local cmd = "sh -c '" .. sess:env_prefix() .. " lua5.1 target.lua' &"
os.execute(cmd)
```

The controller end of the FIFOs must already be open at the point
you spawn the child — `pwdebug.new()` handles that for you. Don't
sleep or do blocking work between `new()` and your `os.execute`.

### `session:poll() -> events_array`

Non-blocking drain + decode step. Call it every tick of your main
loop. Returns an array of decoded event tables (possibly empty).
Also updates the session's mirror state (`session.frames`, `.vars`,
`.paused`, `.line`, `.thread`, etc.) for simple UIs that don't want
to manage events manually.

### `session:cmd_continue()`

Resume execution. If the session isn't currently paused, this is a
no-op. The next break (if any) arrives as a new event from `:poll()`.

### `session:cmd_step() / :cmd_next() / :cmd_finish()`

Stepping commands. `step` steps into the next executable line
anywhere. `next` steps over function calls (same thread, stack
depth ≤ current). `finish` runs until the current function returns
(same thread, stack depth < current). All three resume immediately;
the next break event arrives when the step condition is met.

### `session:inspect_var(frame, kind, name)`

Ask the stub for a deep dump of a variable in a specific frame.

```lua
sess:inspect_var(sess.frames[1], "local", "self")
```

`frame` is one of the entries in `session.frames`. `kind` is
`"local"` or `"upvalue"`. `name` is the variable name as it appears
in the locals/upvalues list of that frame.

The dump is deep: tables are recursively walked up to the stub's
deep-mode caps (depth 6, 500 keys per table, 50 KB per string —
adjust in the stub if needed). Cycles are rendered as `"<cycle>"`.

The result arrives asynchronously as an event from the next
`:poll()`:

```lua
for _, ev in ipairs(sess:poll()) do
  if ev.event == "inspect" then
    print("inspect " .. ev.name .. " = " .. ev.repr)
  end
end
```

### `session:add_breakpoint(spec) / :add_breakpoint(path, line, log_only)`

Add a breakpoint during a running session. Takes either a
`"FILE:LINE[!]"` string or three explicit arguments. Deduplicates
against the existing breakpoint list. If the stub is already
attached, pushes the breakpoint live via an `add_bp` command; the
stub's snap logic will kick in on the next matching hit.

Returns `true` if added, `false` if it was already present or the
spec was malformed.

### `session:remove_breakpoint(path, line)`

Remove a breakpoint by path and line. Returns `true` if removed,
`false` if no matching breakpoint existed.

### `session:find_breakpoint(path, line) -> bp | nil`

Lookup helper. Returns the breakpoint table (`{path, line, log}`)
if present, else nil.

### `session:get_source(path) -> lines_array`

Read a source file into an array of lines, with caching. Tries the
path as given, then each `source_roots` directory. Never crashes on
directories or non-existent files — unreadable paths return a
one-element array with an error placeholder string. Useful for
rendering a source pane alongside the stack.

### `session:close()`

Release the FIFO file descriptors and unlink the FIFO files. Call
this when your controller exits or when you're tearing down a
session to start a new one.

---

## Events from the stub

Events arrive as decoded Lua tables via `session:poll()`. Every
event has an `event` field identifying its shape.

### `{ event = "hello", bps = "..." }`

Emitted once when the stub finishes initializing. `bps` is the raw
string that was passed via `PWDEBUG_BREAKPOINTS`, for logging.

### `{ event = "break", ... }`

Emitted every time a breakpoint or step condition fires. Full
shape:

```lua
{
  event        = "break",
  reason       = "stop" | "log",    -- log reasons don't pause
  line         = <current line>,
  thread       = "thread: 0x..." | "main",
  is_main      = true | false,
  created_src  = "scheduler.lua",   -- nil for main thread
  created_line = 412,
  frames       = { <frame>, <frame>, ... },   -- topmost first
  vars         = { <frame_vars>, ... },       -- same indexing
}
```

`frame` is:

```lua
{
  level     = 3,          -- absolute stack level in stub's walk
  name      = "greet" | "<main>" | "fn@218" | "[C]",
  namewhat  = "method" | "local" | "upvalue" | "global" | "",
  what      = "Lua" | "main" | "C",
  source    = "demo.lua",
  short_src = "demo.lua",
  line      = 4,          -- current line (currentline)
  line_def  = 1,          -- where the function body starts
}
```

Anonymous functions get a synthetic `"fn@<linedefined>"` name since
Lua's `debug.getinfo` can't name them otherwise. The `linedefined`
is where the `function(...)` keyword sits, so `fn@218` means
"anonymous function whose body starts at line 218".

`frame_vars` for each frame is:

```lua
{
  locals   = { {name="x", value="42"}, ... },
  upvalues = { {name="self", value="<table:12>"}, ... },
  entry    = { {name="x", value="7"}, ... } | nil,
}
```

`entry` is present only if the stub captured an entry-time snapshot
of this frame's function — which happens automatically for
functions in files with active breakpoints, via the call hook. Diff
`locals` against `entry` to show "was:" values alongside the
current ones.

### `{ event = "inspect", name = ..., kind = ..., repr = "..." }`

Emitted in response to a `session:inspect_var(...)` call. `repr`
is the deep serialization of the variable, ready to be
pretty-printed.

### `{ event = "error", where = ..., err = ... }`

Emitted if the stub catches an internal error during break handling
(e.g., a serialize failure on a table with a hostile `__tostring`).
The session continues running; you'd typically log this to stderr.

---

## Commands to the stub

All commands are sent as `return {...}` Lua chunks. The helper
methods on the session object cover the common ones; you can also
call `session:_send_cmd(tbl)` directly if you want to extend the
protocol.

| command | payload |
|---|---|
| continue | `{cmd="continue"}` |
| step | `{cmd="step"}` |
| next | `{cmd="next"}` |
| finish | `{cmd="finish"}` |
| add breakpoint | `{cmd="add_bp", spec="foo.lua:42"}` or `"foo.lua:42!"` |
| remove breakpoint | `{cmd="del_bp", spec="foo.lua:42"}` |
| inspect variable | `{cmd="inspect", src="foo.lua", src_line=42, kind="local", name="x"}` |

All commands are fire-and-forget; replies (when they exist) arrive
asynchronously as events from `:poll()`.

---

## Debugging the debugger

Both sides log to `/tmp/pwdebug-debugger.log` (append mode). Useful
patterns:

```sh
# See every event the stub has sent
grep SEND /tmp/pwdebug-debugger.log

# See every source the hook has encountered at runtime
grep 'new source seen' /tmp/pwdebug-debugger.log

# See why a breakpoint might not be firing
grep 'near-match\|snap bp\|break reason' /tmp/pwdebug-debugger.log
```

See `DEBUGGER.md` for a detailed diagnostic flowchart mapping log
patterns to bug classes.

---

## Limitations

- Breakpoints only snap forward (nearest executable line at or
  after the requested line, within the same function scope).
- No conditional breakpoints, no watchpoints, no `eval` during
  pause.
- Coroutines created by C code via `lua_newthread` (bypassing
  Lua-level `coroutine.create`) are invisible to the debugger.
- FIFO transport is local-only. No network debugging.
- The line hook fires on every line of every Lua function in every
  coroutine, which adds 2–4× slowdown to a debug session. The
  call/return hook adds more. Performance-sensitive workloads
  should detach the stub (or don't pass any breakpoints) when not
  actively debugging.

See `DEBUGGER.md` for the full "known limitations" list and
internals.

---

## License

MIT (see `LICENSE`).
