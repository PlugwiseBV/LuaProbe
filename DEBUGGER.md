# luaprobe Lua debugger

A source-level debugger for Lua 5.1 / LuaJIT programs, built around the
standard `debug` library. The debugged process runs under `luajit` (or
`lua5.1`) unmodified; a small stub injected via `LUA_INIT` attaches a
hook at startup, talks to a controller over two FIFOs, and lets the
controller inspect frames, locals, upvalues, and arbitrary table
values at breakpoint time.

This document describes **only** the debugger subsystem — the stub,
the controller side's `src/debugger.lua`, the wire protocol, and the
semantics of how breakpoints resolve and how variables are captured.
It does not cover how a UI renders any of that; the protocol is
deliberately decoupled from presentation.

---

## Getting started

### Requirements

- The process you want to debug must run under **Lua 5.1** or
  **LuaJIT**. No other Lua versions.
- Your controller (the process holding the other end of the FIFOs)
  must run under **LuaJIT** — it uses FFI for non-blocking I/O.
- Linux (the `O_RDWR` FIFO trick and `/tmp` semantics are
  Linux-specific).
- `mkfifo` on `PATH`.

Nothing else. No `luaposix`, no `luasocket`, no C extensions.

### Installation

There is no install step. The debugger is two files:

```
luaprobe_stub.lua     ← copy next to your controller
src/debugger.lua     ← the controller-side module
```

Drop them in your project tree. Done.

### Five-minute walkthrough

Say you have a Lua program you want to break into:

```lua
-- demo.lua
local function greet(name, times)
  local message = "hello, " .. name
  for i = 1, times do
    print(message .. " (" .. i .. ")")
  end
end

greet("world", 3)
```

And you want to pause at the `print` statement with all locals
visible. Here's the minimum controller that does it, end-to-end,
without any UI framework:

```lua
-- mini_controller.lua — LuaJIT only, run with `luajit mini_controller.lua demo.lua`
local ffi = require("ffi")
ffi.cdef[[
  int  open(const char *pathname, int flags);
  long read(int fd, void *buf, unsigned long count);
  long write(int fd, const void *buf, unsigned long count);
  int  close(int fd);
  int  unlink(const char *pathname);
]]
local O_RDONLY, O_RDWR, O_NONBLOCK = 0, 2, 2048

-- Where the stub lives, absolute path.
local STUB = "/absolute/path/to/luaprobe_stub.lua"

-- 1. Generate unique FIFO paths.
local id = tostring(os.time())
local out_path = "/tmp/luaprobe-" .. id .. ".out"  -- child → controller
local in_path  = "/tmp/luaprobe-" .. id .. ".in"   -- controller → child

-- 2. mkfifo both.
os.execute("rm -f " .. out_path .. " " .. in_path)
os.execute("mkfifo -m 600 " .. out_path)
os.execute("mkfifo -m 600 " .. in_path)

-- 3. Open OUR ends BEFORE spawning the child. Non-blocking throughout.
local fd_out = ffi.C.open(out_path, O_RDONLY + O_NONBLOCK)  -- we read from this
local fd_in  = ffi.C.open(in_path,  O_RDWR   + O_NONBLOCK)  -- we write to this
assert(fd_out >= 0 and fd_in >= 0, "fifo open failed")

-- 4. Spawn the child with the env vars pointing at the FIFOs, and
--    LUA_INIT pointing at the stub. Use double quotes inside the
--    single-quoted sh -c string.
local target = arg[1] or "demo.lua"
local cmd = string.format(
  [[sh -c 'LUAPROBE_FIFO_OUT="%s" LUAPROBE_FIFO_IN="%s" LUAPROBE_BREAKPOINTS="%s" LUA_INIT="@%s" lua5.1 %s' &]],
  out_path, in_path, "demo.lua:4", STUB, target)
print("launching:", cmd)
os.execute(cmd)

-- 5. Poll the out-fifo for events. Non-blocking reads, single-line
--    Lua-literal decoding. When a "break" event arrives, dump the
--    stack + locals and send a "continue" command back.
local buf = ffi.new("char[?]", 8192)
local accum = ""

local function read_some()
  local n = ffi.C.read(fd_out, buf, 8192)
  if n > 0 then accum = accum .. ffi.string(buf, n) end
end

local function next_line()
  local nl = accum:find("\n", 1, true)
  if not nl then return nil end
  local line = accum:sub(1, nl - 1)
  accum = accum:sub(nl + 1)
  return line
end

local function send_cmd(tbl)
  local parts = { "return {" }
  for k, v in pairs(tbl) do
    local t = type(v)
    if t == "number" or t == "boolean" then
      parts[#parts + 1] = k .. "=" .. tostring(v) .. ","
    else
      parts[#parts + 1] = k .. "=" .. string.format("%q", tostring(v)) .. ","
    end
  end
  parts[#parts + 1] = "}\n"
  local s = table.concat(parts)
  ffi.C.write(fd_in, s, #s)
end

print("waiting for events... (Ctrl-C to quit)")
while true do
  read_some()
  local line = next_line()
  if line then
    local chunk = loadstring(line)
    if chunk then
      setfenv(chunk, {})
      local ok, ev = pcall(chunk)
      if ok and type(ev) == "table" then
        if ev.event == "hello" then
          print("child attached; breakpoints:", ev.bps)
        elseif ev.event == "break" then
          print(string.format("\n=== BREAK at %s:%d (reason=%s) ===",
            ev.frames[1].source, ev.line, ev.reason))
          for i, f in ipairs(ev.frames) do
            print(string.format("  #%d  %s  %s:%d", i, f.name, f.source, f.line))
          end
          print("  locals of top frame:")
          for _, v in ipairs(ev.vars[1].locals or {}) do
            print(string.format("    %s = %s", v.name, v.value))
          end
          print("  continuing...")
          send_cmd({ cmd = "continue" })
        end
      end
    end
  end
  -- tiny sleep so we don't pin a CPU core
  os.execute("sleep 0.05")
end
```

Save that, edit the `STUB` path, then:

```sh
luajit mini_controller.lua demo.lua
```

You should see:

```
launching: sh -c '... lua5.1 demo.lua' &
waiting for events...
child attached; breakpoints: demo.lua:4

=== BREAK at demo.lua:4 (reason=stop) ===
  #1  greet  demo.lua:4
  #2  <main>  demo.lua:8
  locals of top frame:
    name = "world"
    times = 3
    message = "hello, world"
    i = 1
  continuing...
hello, world (1)

=== BREAK at demo.lua:4 (reason=stop) ===
  #1  greet  demo.lua:4
  ...
```

That's the full loop: breakpoint fires, stack + locals come back as a
single line of Lua literals, the controller prints them, sends
`continue`, and the child resumes.

### Breakpoint syntax cheat sheet

Set via the `LUAPROBE_BREAKPOINTS` env var as a newline-separated
list (comma is also accepted as a legacy separator, but newline is
canonical because conditional expressions can contain commas):

| spec | meaning |
|---|---|
| `foo.lua:42` | **Stop** at line 42 of `foo.lua`. Pauses the process until the controller sends a resume command. |
| `foo.lua:42!` | **Log** at line 42 of `foo.lua`. Emits a `break` event with `reason="log"` and continues immediately — no pause, no resume needed. |
| `foo.lua:42 if x > 5` | **Conditional stop**. The expression after `if` is compiled lazily on first hit and evaluated against the function's locals + upvalues + `_G`; the breakpoint fires only if the result is truthy. Compile failures are logged once and treated as "never fire." Runtime errors during evaluation are silently treated as "skip this hit." |
| `foo.lua:42! if x > 5` | **Conditional log**. Combines the above. |
| `foo.lua:42![locals]` | **Capture filter** (include form). The break event will only carry the top frame's locals — no upvalues, no entry-snapshots, no further-up stack frames. The filter applies *at serialization time* in the stub: skipped fields aren't walked or `safe_serialize`d, so this is a real perf knob, not just a display one. |
| `foo.lua:42![-upvalues]` | **Capture filter** (exclude form). Capture everything except upvalues. Mix of `+` and `-` is tolerated; the first item's prefix decides the starting state. |
| `foo.lua:42![]` | Capture **nothing** beyond the line/source/reason and the top frame's identity. Cheapest possible log breakpoint. |
| `foo.lua:42![locals,stack] if i > 5` | Filters and conditions compose freely with each other and with `!`. |
| multi-line value | Multiple breakpoints in one env var, one per line. |

Paths are matched by **suffix** against what `debug.getinfo` reports
(which is whatever the loader used). You can abbreviate generously:
`config.lua:43` will match `@./config.lua`, `@src/config.lua`, and
`@/abs/path/to/config.lua` all the same. Use the most specific
prefix you need to disambiguate when multiple files share a
basename.

Line numbers **snap forward** to the nearest executable line — see
*Breakpoint snapping* below. You don't have to pick a line with
actual code on it, just one close to what you want.

### Running the controller alongside an existing program

You don't need to rewrite the child process at all. The stub attaches
via `LUA_INIT`, so anything that ultimately runs `lua5.1` or `luajit`
with that env var set gets debugged:

```sh
LUAPROBE_FIFO_OUT=/tmp/luaprobe.out \
LUAPROBE_FIFO_IN=/tmp/luaprobe.in \
LUAPROBE_BREAKPOINTS=src/foo.lua:42 \
LUA_INIT=@/abs/path/to/luaprobe_stub.lua \
./my_test_runner some_scenario.lua
```

The stub will attach regardless of how deeply your test runner
wraps the interpreter call, as long as the env vars propagate. Shell
wrappers propagate env vars by default; `su`, `sudo`, and `env -i`
do not.

**Important:** the controller must have both FIFO ends open before
the child tries to `io.open` them, or the child will block on the
first open forever. In practice this means: have your controller
`mkfifo` and `open` first, then spawn the child. Don't spawn in the
foreground and open the FIFOs later.

### Smoke test

To verify the stub is attached and firing:

```sh
# Terminal 1
mkfifo /tmp/p.in /tmp/p.out
# Open the controller side first so the child doesn't block
(tail -f /tmp/p.out &) ; sleep 0.1

# Terminal 2
LUAPROBE_FIFO_OUT=/tmp/p.out \
LUAPROBE_FIFO_IN=/tmp/p.in \
LUAPROBE_BREAKPOINTS=demo.lua:4 \
LUA_INIT="@$PWD/luaprobe_stub.lua" \
lua5.1 demo.lua
```

In Terminal 1 you should see a `return {bps=...,event="hello"}` line
land immediately when the child starts, followed by a
`return {line=4,reason="stop",event="break",...}` line the first
time line 4 executes. The child will then block forever waiting for
a resume command — kill it with Ctrl-C.

If you see the `hello` but no `break`, either the line you picked
never executes, or `debug.getinfo` is reporting a different source
path than you typed. Check `/tmp/luaprobe.log` — the stub
logs every unique source it sees and every near-match file+line
hit. The diagnostic workflow in *Debugging the debugger* at the
bottom of this doc walks through which log pattern maps to which
class of bug.

---

## Architecture at a glance

```
  ┌───────────────────────────┐          ┌───────────────────────────┐
  │     Controller process    │          │      Debugged process     │
  │      (LuaJIT, TUI-ish)    │          │       (lua5.1 /luajit)    │
  │                           │          │                           │
  │   src/debugger.lua        │          │   luaprobe_stub.lua        │
  │   • owns two FIFO fds     │          │   • line + call + return  │
  │   • poll()s them each     │          │     hook installed via    │
  │     tick (non-blocking)   │          │     debug.sethook         │
  │   • decodes Lua-literal   │          │   • monkey-patches        │
  │     events via loadstring│◄────────►│     coroutine.create/wrap│
  │   • sends commands back   │  FIFOs   │   • blocking I/O on stop  │
  │     as Lua literals       │          │     (nothing is async    │
  │                           │          │     on the stub side)    │
  └───────────────────────────┘          └───────────────────────────┘
```

Two processes, two FIFOs, one line-oriented Lua-literal protocol.

### Why FIFOs and not sockets

- The debugged process is **plain Lua 5.1** (no FFI available). The
  cleanest zero-dependency way to get bidirectional byte transport
  from plain Lua 5.1 is `io.open(fifo, "r"|"w")` — which blocks until
  the other end is open, but blocking is what "paused at breakpoint"
  means anyway.
- The controller is **LuaJIT**, so it can use FFI to `open()` the
  FIFOs with `O_NONBLOCK` and never stall its own main loop.
- The controller opens the in-FIFO with `O_RDWR | O_NONBLOCK`. On
  Linux this quirk lets it open a FIFO's write end **without** a
  reader already being present, which is important because the stub
  (the reader) doesn't exist yet when the controller is setting up.
- The out-FIFO is opened with `O_RDONLY | O_NONBLOCK` — reads never
  stall, and writes come from the stub which is happy to block.

### Rendezvous sequence

1. Controller generates two unique paths in `/tmp/luaprobe-<id>.{in,out}`.
2. Controller `mkfifo`s both.
3. Controller opens its ends (`O_RDWR | O_NONBLOCK` on the in-fifo,
   `O_RDONLY | O_NONBLOCK` on the out-fifo).
4. Controller `fork+exec`s the debugged process with
   `LUA_INIT=@/abs/path/luaprobe_stub.lua` and two env vars pointing at
   the FIFO paths.
5. Stub runs, opens `fifo_out` for writing (blocks if the controller
   isn't ready — but it is, from step 3). Opens `fifo_in` for reading.
6. Stub installs the `debug.sethook`, monkey-patches
   `coroutine.create` / `coroutine.wrap`, and returns from `LUA_INIT`
   back to the Lua runtime, which proceeds to run the main chunk.
7. From the stub's POV, from here on it does nothing until the line
   hook fires on a breakpointed line.

---

## The stub (`luaprobe_stub.lua`)

Pure Lua 5.1, no C extensions, no LuaJIT-specific features. Designed
to be loaded into an arbitrary Lua 5.1 interpreter via `LUA_INIT` and
quietly attach a debugger.

### Entry

```lua
local fifo_out_path = os.getenv("LUAPROBE_FIFO_OUT")
local fifo_in_path  = os.getenv("LUAPROBE_FIFO_IN")
local bps_env       = os.getenv("LUAPROBE_BREAKPOINTS") or ""
```

If either FIFO path is missing or empty, the stub returns immediately
— it's a no-op outside a debug session, so installing it via
`LUA_INIT` globally costs nothing when no debugger is attached.

### Breakpoint table

Breakpoints arrive as a newline-separated list (commas are also
accepted as a legacy separator — the parser picks `\n` when present,
otherwise `,`, so old `,`-joined env vars from non-current
controllers still work):

```
LUAPROBE_BREAKPOINTS="core/foo.lua:42
core/bar.lua:88!
core/baz.lua:10 if user.id == target_id"
```

`FILE:LINE` is a **stop** breakpoint; the trailing `!` makes it a
**log** breakpoint (send the stack but don't pause). An optional
`if EXPR` clause makes the breakpoint conditional — the expression
is shipped verbatim, compiled lazily on first hit, and evaluated
against the function's locals/upvalues with `_G` as the fallback.

Internally they're stored as an array:

```lua
bp_list[i] = {
  path          = "core/foo.lua",
  requested     = 42,
  mode          = "stop" | "log",
  resolved_line = nil,  -- filled in by snap, see below
  cond          = "user.id == target_id",  -- nil if unconditional
  cond_compiled = nil,  -- nil = not yet tried, false = compile failed,
                        --                         function = chunk
  fields        = nil,  -- nil = capture everything (default).
                        -- Otherwise: {stack=,locals=,upvalues=,entry=}
                        -- four-key boolean table; collect_frames_from_hook_helper
                        -- short-circuits the false ones so we don't pay
                        -- the per-frame walk + safe_serialize cost.
}
```

An array scan is fine because the number of active breakpoints is
always small (single digits in practice). There is a per-(src, line)
cache for line-hook fast-path misses, but it is invalidated on every
`add_bp` / `del_bp` command.

### Breakpoint snapping

Lua's line hook only fires on lines the compiler emitted opcodes for.
If the user asks for `foo.lua:43` but 43 is a comment, a blank line,
or a multi-statement fragment that Lua attributes to the surrounding
line, the hook will never report line 43 and the breakpoint would
silently never fire.

To fix this, breakpoints **snap** to the first executable line
**at or after** the requested line — but only **within the
appropriate scope**:

- **`info.what == "Lua"` (a function body).** Snap only if
  `linedefined <= requested <= lastlinedefined`, i.e. the requested
  line is physically inside this function's source range. Prevents a
  breakpoint on "line 1070 of OpenThermBoiler.lua" from firing when
  the VM happens to hit line 1078 of the module's top-level chunk
  during require.
- **`info.what == "main"` (a module's top-level chunk).** Lua 5.1
  reports `linedefined = 0 = lastlinedefined` for main chunks, so the
  range check can't be used. Instead, snap only if the gap between
  the requested line and the first hit is ≤ 5 lines. Good enough for
  `config.lua:43 → 45`; refuses to snap `Module.lua:10 → 200`.
- **Other `what` values** (`C`, etc.): don't snap. C functions don't
  have line numbers anyway.

The first hit that survives this filter sets `bp.resolved_line`. From
then on, the breakpoint fires **exactly** on that resolved line. This
means execution paths that happen to hit it from different callers
will all trigger the break — you don't have to re-resolve per call.

Snapping is logged:

```
[stub 1776082305] snap bp OpenThermBoiler.lua:1070 -> actual executable line 1078 (what=Lua)
```

and the controller's breakpoint table is **not** retroactively
updated — only the stub knows the resolved line. `del_bp` keys by the
original `FILE:LINE` the user typed.

### The hook function

Registered directly as `debug.sethook(line_hook, "crl")`. No wrapper
function between `sethook` and `line_hook` — see **Level discipline**
below for why.

Dispatch on event:

```lua
local function line_hook(event, line)
  if event ~= "line" then
    return call_hook_body(event)   -- tail call, deliberately
  end
  -- ... line-hook body ...
end
```

### Line hook body

1. Reentrancy guard (`in_hook`): if we're already inside the stub's
   serialize/send logic, return immediately. Without this, any
   function call the stub itself makes would re-trigger the line
   hook on its own bookkeeping code.
2. If a step command is pending (`step`, `next`, `finish`), check
   whether this line should pause the step. `next` and `finish` are
   thread-aware and compare `coroutine.running()` + stack depth
   against the saved values from when step was requested.
3. Otherwise, `debug.getinfo(2, "S")` gets the running function's
   source and `what`. Sources starting with `@` are file paths (the
   common case); sources starting with `=` are synthetic chunks
   (e.g. `loadstring(code, "name")`) and are matched against the
   tail. Anything else is ignored.
4. `lookup_bp(src, line, info)` walks `bp_list`. On a hit, the stub
   **collects the frame stack from here** (not from a deeper helper)
   and calls `pause(reason, line, frames, vars)`. The collection is
   done in a helper specifically so the caller levels are known and
   stable; see next section.

### Call / return hook body

Aligned with the per-coroutine **entry snapshot stack**. Every call
pushes an entry, every return pops. If the called function's source
matches one of the active breakpoint files, the stub also walks
`debug.getlocal(2, i)` to capture the function's initial locals —
which, because the function's body hasn't run yet, **are exactly the
parameter values as passed in**. That's the "value at function entry"
data surfaced alongside the current-value locals at break time.

If the called function is not in a breakpointed file, the stub still
pushes a (func-only, no-locals) entry to keep the stack depth
correct — otherwise pops on return would unbalance.

Tail calls (`tail call` / `tail return`) are handled as ordinary
call/return for stack balance purposes, which is approximate but
correct for the common debugging case.

### Level discipline

`debug.getinfo` / `debug.getlocal` / `debug.getupvalue` take **stack
levels relative to the calling function**, which means the absolute
level of "user code" depends on where you're standing in the stub
when you ask. Getting this right is the single most error-prone part
of the stub, and has been silently broken more than once.

Key rules:

1. **The registered hook function must reach user code at level 2.**
   That is Lua's documented guarantee: from inside a function
   registered with `debug.sethook`, `debug.getinfo(2)` returns the
   running user function. If you put any wrapper between
   `debug.sethook` and the body that accesses `getinfo`, every level
   shifts by 1 and snapping, collection, and the inspect command all
   silently return wrong data (typically the stub file itself). The
   stub therefore registers `line_hook` **directly** and dispatches
   other events via a tail call (`return call_hook_body(event)`),
   which replaces the frame and keeps the level constant.
2. **Never tail-call into a function that walks the stack.**
   Tail calls in Lua 5.1 replace the caller's frame, so a helper
   tail-called from the hook will find that the hook is gone from
   the stack and every level is off by one. The stub reaches `pause`
   via a **normal call** (`pause(hit, line, frames, vars); return`)
   specifically so `line_hook` stays on the stack while pause runs.
3. **Collect frames from inside the hook, not from deeper helpers.**
   The collector function is named
   `collect_frames_from_hook_helper` and is always called directly
   from `line_hook` via a normal call. Inside the collector:
   ```
   level 1 = collector
   level 2 = line_hook
   level 3 = running user function  ← start walking here
   ```
4. **The `inspect` command runs from inside `pause`**, which is one
   level deeper than the collector. Rather than trying to maintain
   a matching offset, the inspect handler **re-walks the live stack**
   looking for a frame whose `(source, currentline)` matches what
   was captured at break time, and uses that level. Robust against
   any future changes to the stub's internal call depth.
5. **Declaration order matters.** `pause` references `co_creation`
   (the weak-keyed coroutine → creation-site table). If
   `co_creation` is declared as a local **after** `pause`, the
   compiler silently resolves it as a global and `pause` reads `nil`
   — which only surfaces at runtime when `pause` is first invoked,
   with the stub dying somewhere between sending the break trace and
   actually transmitting the event. Moving the declaration above
   `pause` is the fix. (A future `strict.lua` pass would catch this
   at load time.)

### Stack collection

Called from `line_hook` via normal call. Walks the current thread's
stack upward from level 3 (which is user code — see above). For each
frame:

```lua
{
  level     = <absolute level in this walk>,
  name      = <info.name, or a synthesized "fn@<linedefined>" for
               anonymous Lua functions, "<main>" for main chunks,
               "[C]" for C functions>,
  namewhat  = <info.namewhat — "method", "local", "upvalue", etc.>,
  what      = <info.what — "Lua", "main", or "C">,
  source    = <info.source with leading "@" stripped and "./"
               normalized, or the raw string for "=" chunks>,
  short_src = <info.short_src>,
  line      = <info.currentline>,
  line_def  = <info.linedefined>,
}
```

For each frame, the collector also walks `debug.getlocal(level, i)`
and `debug.getupvalue(info.func, i)` to snapshot current values. Each
value goes through `safe_serialize` (a `pcall`-wrapped `serialize`
call) so a misbehaving `__tostring` / `__index` / `__len` metamethod
on some user table can't crash the collection.

The collector also looks up `find_entry_locals(co, info.func)` for
each frame. If the per-thread entry snapshot stack has a matching
`func`, its captured initial locals are attached as `frame.entry`.
The controller can diff `locals` and `entry` to show "was" values
next to current values.

Frame depth is capped at 40 for safety.

### Anonymous function naming

Lua 5.1's `debug.getinfo(_, "n")` returns `nil` for `info.name` on
most anonymous functions — it can only name functions that were
reached via a **known visible binding** at the call site (`foo()`,
`t.foo()`, `t:foo()`). Most closures passed as callbacks, stored in
tables, or created inline don't qualify.

The stub synthesizes a stable identifier for those:

- `"<main>"` for main chunks
- `"[C]"` for C functions
- `"fn@<linedefined>"` for anonymous Lua functions

`linedefined` is the line where the `function(...)` keyword appears,
so `fn@218` means "the anonymous function whose body starts at line
218". It does **not** drift as execution moves inside the body. The
frame's `line` field (which comes from `currentline`) drifts — so
`fn@218  proxy.lua:276` reads as "anonymous function defined at line
218, currently at line 276".

### Coroutine tracking

The stub monkey-patches `coroutine.create` and `coroutine.wrap` to:

1. Call the original `coroutine.create` to fork the thread.
2. `debug.sethook(co, line_hook, "crl")` on the new thread. Per-Lua
   rules, hooks are per-thread — inheriting the main-thread hook into
   new coroutines requires this explicit install. Without it,
   breakpoints would never fire inside any code that runs under a
   coroutine, which is most of pwcore.
3. `capture_creation_site(co, 2)` — records the caller's file and
   line via `debug.getinfo(2, "Sl")` (level 2 being the caller of
   `coroutine.create`). Stored in a **weak-keyed** table so dead
   coroutines can be GC'd.

The break event then carries `thread`, `is_main`, `created_src`, and
`created_line` fields; the controller can display which coroutine
fired the break and where it was spawned.

Caveats:
- Coroutines created by C code via `lua_newthread` bypass the
  monkey-patch and are invisible to the debugger.
- If a helper wraps `coroutine.create` (e.g.
  `scheduler:spawn(fn) → coroutine.create(fn)`), the recorded
  creation site will be inside the helper, not at the user's
  `scheduler:spawn` call. A full `debug.traceback` at creation time
  would be more informative but is not currently captured.

### Pause loop

When a stop-breakpoint fires, `pause` sends the `break` event and
then enters a **blocking read loop** on the in-FIFO. The loop reads
line-framed Lua literals, `loadstring`s each, `pcall`s the chunk to
get the resulting table, and dispatches on `msg.cmd`:

- `continue` — exits the loop, clears step_mode, returns.
- `step` — sets `step_mode = "step"`, exits the loop.
- `next` — sets `step_mode = "next"`, saves the running thread and
  stack depth, exits the loop.
- `finish` — sets `step_mode = "finish"`, saves thread + depth.
- `add_bp` / `del_bp` — mutates `bp_list`. Does **not** exit the
  loop; keeps reading more commands.
- `inspect` — computes a deep dump of a specific variable and
  replies with an `inspect` event. Does **not** exit the loop.
- `eval` — compiles the supplied expression against a snapshot env
  built from the addressed frame's locals/upvalues with `_G` as
  fallback, runs it under `pcall`, and replies with an `eval`
  event carrying either `repr` (success) or `err` (compile or
  runtime failure). Does **not** exit the loop. The compile path
  tries `return (EXPR)` first, then falls back to compiling the
  raw text as a chunk so statements like `print(x)` also work
  (with no return value).

Log breakpoints (`reason == "log"`) skip the loop entirely: they
send the event and return immediately.

### Inspect command

The inspect command deliberately runs **synchronously from inside the
pause loop**, so the thread whose state is being inspected is still
blocked at the break site. Parameters:

```lua
{
  cmd      = "inspect",
  src      = "path/relative/to/bp.lua",
  src_line = 1078,
  kind     = "local" | "upvalue",
  name     = "someVar",
}
```

The stub **re-walks the live stack** matching `info.source` and
`info.currentline` against `src` and `src_line` to find the right
level, then calls `debug.getlocal` / `debug.getupvalue` and
serializes the result with the deep caps (depth 6, 500 keys/table,
50k chars/string — far larger than the shallow caps used for the
break event envelope).

Frame identity is (source, line) rather than absolute level number
specifically so the inspect handler doesn't need to know how deep
inside the stub it's running.

### Serializer

A hand-rolled Lua-literal emitter. Produces text that can be
`loadstring`'d back into an equivalent value (modulo functions,
which render as `"<function>"`, and cycles, which render as
`"<cycle>"`).

Three cap profiles:

| profile | max depth | max keys/table | max string | where used |
|---------|-----------|----------------|------------|------------|
| shallow | 2 | 50 | 400 B | variable values in break events |
| event | 6 | 1000 | 60 KB | the break/inspect envelope itself |
| deep | 6 | 500 | 50 KB | inspect command result |

The shallow profile is why a break event with 20 locals and 5
frames stays under ~20 KB even when the locals are enormous pwcore
tables: each value pre-renders to `<table:N>` or a one-line head.
The event profile walks the envelope structure (event → frames →
per-frame → fields) without re-truncating those already-flattened
strings.

Cycle safety: a `seen` set per top-level `serialize` call tracks
tables currently being emitted; a re-entry renders as `"<cycle>"`
and the walk continues.

---

## The wire protocol

**Framing:** one message per physical line, newline-terminated. Each
line is a complete `return {...}` Lua chunk.

**Encoding:** Lua literals only. Both sides `loadstring` each frame
and `pcall` it in a sandboxed environment (`setfenv(chunk, {})` on
the controller) to get back a plain table. No JSON, no MessagePack,
no luasocket. Lua literals are safe to parse on both ends because
both ends are Lua and we control what gets sent.

**Newline escaping:** `string.format("%q", s)` in Lua 5.1 emits a
**literal newline** for embedded `\n` in a string (specifically:
backslash + real newline). The stub's `send` function post-processes
the formatted payload to turn `\<newline>` sequences into `\n`
escapes, then scrubs any remaining raw whitespace, so the final
payload is guaranteed to be a single physical line that round-trips
through `loadstring` correctly.

### Stub → controller events

```lua
-- Emitted once after the stub finishes initializing.
return {
  event = "hello",
  bps   = "core/foo.lua:42\ncore/bar.lua:88!\ncore/baz.lua:10 if x > 5",
}

-- Emitted on every stop or log breakpoint.
return {
  event        = "break",
  reason       = "stop" | "log",
  line         = 1078,
  frames       = { <frame>, <frame>, ... },
  vars         = { <frame_vars>, <frame_vars>, ... },
  thread       = "thread: 0x7f1234abcd" | "main",
  is_main      = true | false,
  created_src  = "scheduler.lua",  -- nil if main thread
  created_line = 412,
}

-- Emitted in reply to an inspect command.
return {
  event = "inspect",
  name  = "someVar",
  kind  = "local" | "upvalue",
  repr  = "{...}",  -- deep serialization
}

-- Emitted in reply to an eval command. Exactly one of repr/err is
-- non-nil. `err` is human-readable: "compile: ..." for parse
-- failures, "runtime: ..." for errors thrown by pcall.
return {
  event = "eval",
  expr  = "self.foo + 1",
  repr  = "42",  -- nil if `err` is set, or if the input was a
                 -- statement (no return value)
  err   = nil,   -- or "compile: ..." / "runtime: ..."
}
```

Where `<frame>` is:

```lua
{
  level     = 3,
  name      = "<main>" | "fn@218" | "foo" | "[C]",
  namewhat  = "method" | "local" | "upvalue" | "global" | "",
  what      = "Lua" | "main" | "C",
  source    = "./DomainObject/Protocol/Boiler/OpenThermBoiler.lua",
  short_src = "./DomainObject/.../OpenThermBoiler.lua",
  line      = 1078,
  line_def  = 1060,
}
```

and `<frame_vars>` is:

```lua
{
  locals   = { {name="x", value="42"}, ... },
  upvalues = { {name="self", value="<table:12>"}, ... },
  entry    = { {name="x", value="7"}, ... } | nil,
}
```

`entry` is present only if the stub had captured an entry-time
snapshot for this frame's function. `nil` for C frames, main chunks,
and any function whose source wasn't in a breakpointed file when
its `"call"` event fired.

### Controller → stub commands

```lua
return { cmd = "continue" }
return { cmd = "step" }
return { cmd = "next" }
return { cmd = "finish" }
-- spec accepts the same grammar as LUAPROBE_BREAKPOINTS: a single
-- "FILE:LINE" optionally followed by "!" (log-only) and/or
-- " if EXPR" (conditional).
return { cmd = "add_bp", spec = "core/foo.lua:42 if x > 5" }
return { cmd = "del_bp", spec = "core/foo.lua:42" }
return {
  cmd      = "inspect",
  src      = "core/foo.lua",
  src_line = 42,
  kind     = "local",
  name     = "someVar",
}
-- src/src_line are optional; if omitted, eval runs in the topmost
-- user (Lua/main) frame on the live stack.
return {
  cmd      = "eval",
  expr     = "self.foo + 1",
  src      = "core/foo.lua",
  src_line = 42,
}
```

The controller's command encoder is type-aware: numbers are emitted
as `k=42`, strings as `k=%q`, booleans/nil as `k=true/false/nil`.
Without type awareness, `src_line = 1078` would land on the stub as
the string `"1078"` and the `info.currentline == want_line`
comparison would always fail.

---

## Controller side (`src/debugger.lua`)

Owns the FIFO lifecycle, the poll loop, and the event decoder. Uses
LuaJIT FFI directly for `open(2)` / `read(2)` / `write(2)` / `close(2)` /
`unlink(2)` — no `luaposix` dependency.

### Session creation

`M.begin_session()` is called right before the controller spawns a
debugged child process:

1. Generates unique FIFO paths based on `os.time()` + a monotonic
   counter.
2. `mkfifo`s both (via `os.execute` — posix-level FIFO creation isn't
   in the FFI `cdef` block, which only covers what the stub uses
   after creation).
3. Opens the TUI-side ends (`O_RDONLY | O_NONBLOCK` on out,
   `O_RDWR | O_NONBLOCK` on in). Must happen **before** the child is
   spawned, otherwise the child's `io.open(fifo_out, "w")` will block
   forever waiting for a reader.
4. Builds the env-var prefix string to inject into the child's
   launch command:
   ```
   LUAPROBE_FIFO_OUT="..." LUAPROBE_FIFO_IN="..." \
   LUAPROBE_BREAKPOINTS="..." LUA_INIT="@/abs/path/luaprobe_stub.lua"
   ```
   **Quoting:** the caller embeds this prefix inside a shell wrapper
   that uses single quotes (`sh -c '...'`), so the prefix must use
   **double** quotes — otherwise the first `'` inside the prefix
   closes the outer `sh -c` string. Values never contain `$`,
   backtick, or literal `"`, so this is safe.
5. Returns `(prefix_string, session_table)`. The caller prepends the
   prefix to its subprocess command and is done.

### Polling

`M.poll()` is called every tick from the controller's main loop.
Implementation:

1. `read(fd, buf, 8192)` in a loop, appending to `sess.buf` until
   `read` returns ≤ 0 (non-blocking EAGAIN).
2. Splits `sess.buf` on `\n`, pops complete lines off the front.
3. Each line goes through `decode` (`loadstring` + sandboxed `pcall`)
   → event table → `on_event(sess, ev)`.
4. Decode failures are reported on the controller's status bar and
   logged, so silent dropped events are impossible to miss.

All socket/file I/O happens through FFI syscalls so curses and the
main loop are never blocked.

### Event handler

`on_event` mutates `state.debug_session` based on `ev.event`:

- `"hello"` — marks the child as attached.
- `"break"` — scrubs newlines/tabs from all value strings
  (serialized tables can contain real newlines after decode, which
  would break curses rendering), records `frames`, `vars`, `thread`,
  `is_main`, `created_src`/`created_line`, and `paused` (true for
  stop, false for log).
- `"inspect"` — scrubs and pretty-splits the deep dump into lines
  for scrollable display.

### Commands

Thin wrappers:

```lua
function M.cmd_step()     resume("step")     end
function M.cmd_next()     resume("next")     end
function M.cmd_finish()   resume("finish")   end
function M.cmd_continue() resume("continue") end
function M.inspect_var(frame, kind, name)
function M.add_breakpoint(path, line, log_only)
function M.remove_breakpoint(path, line)
```

All of them send a single Lua-literal chunk down the in-fifo. None
of them block; the effects arrive (or don't) via the next `poll()`.

---

## Debugging the debugger

Every significant event is logged to `/tmp/luaprobe.log` by
both sides, in append mode:

- Controller logs session start with all the env-var and path
  values, plus the raw wire contents of every received message
  (`[tui recv NNNB]: ...`) and any decode failures
  (`[tui DECODE FAIL]: ...`).
- Stub logs its own hello, FIFO open success, every unique
  `info.source` it sees during hook operation (capped at 500
  entries), every `near-match hit <file>:<line>` when a file with an
  active breakpoint executes a non-matching line, every `snap bp`
  resolution, every `break reason=... line=...` at pause entry, and
  every `SEND (NNN bytes): ...` at send time.

Typical diagnostic workflow:

1. No `[stub ...]` lines at all → stub never loaded. Either the
   child's `lua`/`luajit` invocation isn't honoring `LUA_INIT`, or
   the child is a non-Lua process. Check `LUAPROBE_FIFO_*` env vars
   reached the interpreter.
2. `[stub ...] loaded` but nothing after → FIFO open failed.
   Controller didn't have both ends open at spawn time.
3. `[stub ...] fifos opened` but `unique sources: 1` climbing
   through the millions → the hook is only seeing the stub itself.
   A wrapper function was accidentally introduced between
   `debug.sethook` and the hook body, shifting `getinfo` levels by
   1 and silently breaking snapping.
4. `unique sources` climbing normally but no `near-match hit` for
   your breakpoint file → the file isn't being loaded at all during
   this run. Breakpoint path is wrong or the file isn't on the
   scenario's code path.
5. `near-match hit` for your file at various lines but never
   `snap bp ... -> ...` → the requested line is outside the range
   of any currently-executing function body, OR it's in a main
   chunk with gap > 5 lines from any executed line. Pick a
   different line (one that actually appears in the hit log).
6. `break reason=stop` but no `SEND` line following → the stub
   crashed between pause's entry trace and `send`. Most likely
   culprit: a local variable referenced from `pause` was declared
   as a local **after** `pause`, so the compiler resolved it as a
   global and `pause` read `nil`. Check declaration order.
7. `SEND (NNN bytes)` but no `[tui recv NNNB]` → the controller's
   FIFO read isn't draining, or the controller process is gone.
   If frame count on the break event looks normal, the decode
   side is the likely culprit.
8. `SEND` and `tui recv` both present and byte counts match, but
   the frames look empty/`?` on the controller side → the
   **envelope depth cap** in `serialize` is truncating the nested
   frame tables to `<table:N>` strings. Check that `encode()` uses
   the `EVENT_MAX_*` profile, not the shallow defaults.

---

## Known limitations

1. **Performance.** The line hook fires on every line of every Lua
   function in every coroutine. Typical pwcore scenarios do 10–20
   million hook calls. Net slowdown is 2–4×. The call/return hook
   adds more overhead, most of which is per-call `debug.getinfo`
   calls to check whether the callee's source is in a breakpointed
   file. The fastest path is still small (a handful of string
   comparisons), but there is no free lunch here.
2. **Breakpoints only snap forward.** If you ask for line 1070 and
   the nearest executable line is 1065, it won't fire at 1065. It
   will only fire when execution reaches line 1070 or later within
   the same scope. Symmetric snap (backward OR forward, nearest
   wins) would need a second pass and more logic to avoid firing
   too early.
3. **Only one breakpoint per source:line.** `add_bp` doesn't
   deduplicate on the stub side; adding the same `file:line` twice
   creates two entries and both will fire. The controller
   deduplicates before sending. Practical consequence: to change a
   condition or toggle log-mode, remove the old bp first.
4. **No watchpoints.** There is no `debug` facility for "break when
   variable X changes"; you'd need to poll.
5. **`eval` is read-only on locals/upvalues.** The stub builds a
   snapshot env from the paused frame's locals and upvalues and
   evaluates the expression against it; assignments to those names
   don't propagate back to the live frame. Globals and table
   mutations work normally because they go through references that
   survive the snapshot. Promoting eval to read-write would need an
   `__newindex` that calls `debug.setlocal`/`setupvalue` with the
   right level discipline (see §"Level discipline" — the same
   minefield that makes inspect re-walk the live stack instead of
   reusing captured levels).
6. **No reverse/ history debugging.** Pure forward execution.
7. **Coroutines created by C code are invisible.** See "Coroutine
   tracking" above.
8. **Entry snapshots are approximate under tail calls.** Tail-call
   and tail-return events are treated as ordinary call/return for
   the entry-stack balance; a long tail-recursive chain will
   accumulate entries that never pop until the outermost frame
   returns. In practice this only bloats memory for pathological
   recursion, not correctness.
9. **Cycle detection is scope-local per serialization, not global.**
   A table reachable via two separate paths in the same frame's
   vars will be serialized fully twice (within depth/key caps).
   Not a correctness bug, just occasional output bloat.
10. **Compiled bytecode chunks (`info.source` starting with `=`)**
    are matched by basename suffix only. Chunks loaded from a
    string via `loadstring(code, "chunkname")` work if `chunkname`
    ends with a known file name.
11. **No strict-mode check for global reads.** A future improvement
    would be loading a `strict.lua` helper into the stub at startup
    so that accidentally referencing an undeclared local (which Lua
    resolves to a nil global) errors at access time instead of
    failing mysteriously at runtime.
12. **FIFO transport is local-only.** `/tmp/luaprobe-*.{in,out}`
    only works when both processes are on the same host. No network
    transparency.

---

## Files

```
luaprobe_stub.lua      child-side debugger, plain Lua 5.1, loaded
                      via LUA_INIT=@<abs>/luaprobe_stub.lua

src/debugger.lua      controller-side session manager, LuaJIT only
                      (FFI for non-blocking FIFO I/O)
```

The stub has no `require` dependencies beyond the Lua standard
library. It must remain that way — adding a `require` call from
inside the stub would change the set of files the Lua VM tries to
load before the user's main chunk runs, and any of those might
themselves trigger breakpoints before the stub has finished setting
itself up.

The controller module has the usual project dependencies
(`src.config`, `src.state`) and the FFI standard library.

---

## Environment variables

Set by the controller when spawning a debugged process:

| var | purpose |
|-----|---------|
| `LUAPROBE_FIFO_OUT` | abs path; child writes events to it (controller reads) |
| `LUAPROBE_FIFO_IN`  | abs path; child reads commands from it (controller writes) |
| `LUAPROBE_BREAKPOINTS` | newline-separated `FILE:LINE[!] [if EXPR]` list (comma also accepted as a legacy separator) |
| `LUA_INIT` | `@<abs path to luaprobe_stub.lua>` — how the stub gets loaded |

The stub silently no-ops if `LUAPROBE_FIFO_OUT` is unset or empty, so
installing it globally via `LUA_INIT` in your shell is safe.
