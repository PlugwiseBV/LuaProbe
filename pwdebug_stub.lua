-- pwdebug_stub.lua — child-side debugger stub.
--
-- Loaded into the debugged Lua 5.1 process via LUA_INIT=@<abs>/pwdebug_stub.lua.
-- Talks to the pwdebug TUI over two FIFOs:
--   PWDEBUG_FIFO_OUT — stub writes events to (stack/locals on break)
--   PWDEBUG_FIFO_IN  — stub reads commands from (step/next/continue/...)
--
-- Breakpoints arrive via PWDEBUG_BREAKPOINTS as a comma-separated list of
-- FILE:LINE or FILE:LINE! (the trailing ! means "log stack and continue").
--
-- Coroutine caveat: debug.sethook is per-thread in Lua 5.1, so we
-- monkey-patch coroutine.create / coroutine.wrap to install the hook on
-- every new coroutine before it runs.
--
-- Pure Lua 5.1, no FFI, no luasocket. Blocking reads on the in-FIFO are
-- intentional — "paused at breakpoint" means the thread is blocked.

local fifo_out_path = os.getenv("PWDEBUG_FIFO_OUT")
local fifo_in_path  = os.getenv("PWDEBUG_FIFO_IN")
local bps_env       = os.getenv("PWDEBUG_BREAKPOINTS") or ""

-- Launch trace. Open append-mode so multi-coroutine / multi-process
-- loads don't clobber each other. Silently ignore if /tmp is unwritable.
local function trace(msg)
  local f = io.open("/tmp/pwdebug-debugger.log", "a")
  if not f then return end
  f:write("[stub ", tostring(os.time()), "] ", msg, "\n")
  f:close()
end

if not fifo_out_path or not fifo_in_path or fifo_out_path == "" then
  trace("no env vars set, acting as no-op")
  return
end
trace("loaded; bps=" .. bps_env ..
  " out=" .. fifo_out_path .. " in=" .. fifo_in_path)

-- ---------- breakpoint table ----------
-- bp_list is an array of entries; each entry is the breakpoint the user
-- requested plus the line we snapped to on first observation.
--
-- "Snapping": the Lua line hook only fires on lines the compiler emitted
-- opcodes for. If the user asks for `foo.lua:43` but 43 is a comment or
-- blank, 43 never fires — 45 (or whatever the next executable line is)
-- does. So on the first hook hit that (a) matches this file and (b) has
-- line >= requested, we record that actual line as the resolved line
-- and fire. From then on we match exactly on the resolved line.
--
-- This is what you'd expect from gdb: "b foo.lua:43" drops the bp on
-- the nearest following statement, not on the literal line number.
local bp_list = {}

local function bp_path_matches(src, path)
  return src == path or src:sub(-(#path + 1)) == "/" .. path
end

local function add_bp(spec)
  local log_only = false
  if spec:sub(-1) == "!" then
    log_only = true
    spec = spec:sub(1, -2)
  end
  local path, line = spec:match("^(.-):(%d+)$")
  if not path then return end
  line = tonumber(line)
  path = path:gsub("^%./", "")
  bp_list[#bp_list + 1] = {
    path          = path,
    requested     = line,
    mode          = log_only and "log" or "stop",
    resolved_line = nil,
  }
end

local function del_bp_spec(spec)
  local path, line = spec:match("^(.-):(%d+)$")
  if not path then return end
  path = path:gsub("^%./", "")
  line = tonumber(line)
  for i, bp in ipairs(bp_list) do
    if bp.path == path and bp.requested == line then
      table.remove(bp_list, i)
      return
    end
  end
end

for item in bps_env:gmatch("[^,]+") do
  item = item:match("^%s*(.-)%s*$")
  if item ~= "" then add_bp(item) end
end

-- Gap (in lines) we're willing to tolerate when snapping in a main
-- chunk. Main chunks have `linedefined = 0` in Lua 5.1 so we can't
-- use the linedefined/lastlinedefined range check; we fall back to
-- a small proximity window to prevent snapping across the entire
-- module at load time.
local MAIN_CHUNK_SNAP_WINDOW = 5

-- Walk bp_list on every hit. `info` is the raw `debug.getinfo(2, "S")`
-- result from the hook — needed for scope-aware snapping so we don't
-- fire at `M.lastTopLevelStatement` when the user set a breakpoint
-- inside a method body that hasn't been called yet.
local function lookup_bp(src, line, info)
  for _, bp in ipairs(bp_list) do
    if bp_path_matches(src, bp.path) then
      if bp.resolved_line then
        if bp.resolved_line == line then return bp.mode end
      elseif line >= bp.requested then
        local range_ok = false
        if info and info.what == "Lua" then
          -- Function body: the requested line must be inside this
          -- function's definition range, else we'd snap out of one
          -- function into a completely unrelated one.
          if info.linedefined and info.lastlinedefined
             and info.linedefined <= bp.requested
             and bp.requested <= info.lastlinedefined then
            range_ok = true
          end
        elseif info and info.what == "main" then
          -- Main chunk: no reliable range info, so require the gap to
          -- be small enough that the user meant "nearest executable
          -- line" rather than "somewhere else entirely in this file".
          if line - bp.requested <= MAIN_CHUNK_SNAP_WINDOW then
            range_ok = true
          end
        end
        if range_ok then
          bp.resolved_line = line
          if line ~= bp.requested then
            trace("snap bp " .. bp.path .. ":" .. bp.requested ..
                  " -> actual executable line " .. line ..
                  " (what=" .. tostring(info and info.what) .. ")")
          end
          return bp.mode
        end
      end
    end
  end
  return nil
end

-- ---------- FIFO setup ----------
-- The TUI opens its ends (O_RDONLY on out, O_RDWR on in) BEFORE spawning
-- this process, so neither open here blocks.
local fifo_out = io.open(fifo_out_path, "w")
if not fifo_out then trace("FAILED to open fifo_out") ; return end
local fifo_in  = io.open(fifo_in_path,  "r")
if not fifo_in  then trace("FAILED to open fifo_in")  ; return end
fifo_out:setvbuf("no")
trace("fifos opened, hook installed")

-- ---------- Lua-literal serializer ----------
-- Variable-value serialization: shallow, so break events don't balloon
-- when a local happens to be a giant pwcore table.
local MAX_DEPTH = 2
local MAX_KEYS  = 50
local MAX_STR   = 400
-- Deep mode for on-demand `inspect`: walks much further so the TUI can
-- render a full dump of a specific variable the user clicked on.
local DEEP_MAX_DEPTH = 6
local DEEP_MAX_KEYS  = 500
local DEEP_MAX_STR   = 50000
-- Envelope depth for the break event itself. Its shape is bounded —
-- event → frames array → per-frame table → fields (all strings/ints,
-- since each variable's value was already flattened to a string via
-- safe_serialize). Depth 6 safely walks all the way through.
local EVENT_MAX_DEPTH = 6
local EVENT_MAX_KEYS  = 1000
local EVENT_MAX_STR   = 60000

local function short_repr(v)
  local t = type(v)
  if t == "table" then
    local n = 0; for _ in pairs(v) do n = n + 1 end
    return "<table:" .. n .. ">"
  end
  return "<" .. t .. ">"
end

local serialize
serialize = function(v, depth, seen, max_depth, max_keys, max_str)
  max_depth = max_depth or MAX_DEPTH
  max_keys  = max_keys  or MAX_KEYS
  max_str   = max_str   or MAX_STR
  local t = type(v)
  if t == "nil" or t == "boolean" or t == "number" then
    return tostring(v)
  elseif t == "string" then
    if #v > max_str then v = v:sub(1, max_str) .. "...<+" .. (#v - max_str) .. "B>" end
    return string.format("%q", v)
  elseif t == "table" then
    if seen[v] then return string.format("%q", "<cycle>") end
    if depth >= max_depth then
      return string.format("%q", short_repr(v))
    end
    seen[v] = true
    local parts = { "{" }
    local count = 0
    for k, val in pairs(v) do
      count = count + 1
      if count > max_keys then
        parts[#parts + 1] = string.format("[%q]=%q,", "__truncated", "more...")
        break
      end
      local ks
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        ks = k .. "="
      else
        ks = "[" .. serialize(k, depth + 1, seen, max_depth, max_keys, max_str) .. "]="
      end
      parts[#parts + 1] = ks .. serialize(val, depth + 1, seen, max_depth, max_keys, max_str) .. ","
    end
    parts[#parts + 1] = "}"
    seen[v] = nil
    return table.concat(parts)
  else
    return string.format("%q", short_repr(v))
  end
end

local function encode(tbl)
  return "return " .. serialize(tbl, 0, {}, EVENT_MAX_DEPTH, EVENT_MAX_KEYS, EVENT_MAX_STR)
end

local function send(tbl)
  local ok, s = pcall(encode, tbl)
  if not ok then
    s = string.format("return {event=%q,err=%q}", "encode_error", tostring(s))
  end
  -- %q emits raw newlines for \n inside strings (as backslash + real
  -- newline), which would break our one-message-per-line transport.
  -- Convert those `\<newline>` sequences to proper `\n` escapes, then
  -- drop any stray whitespace so the payload is physically one line.
  s = s:gsub("\\\n", "\\n"):gsub("\\\r", "\\r"):gsub("\n", " "):gsub("\r", " ")
  trace("SEND (" .. #s .. " bytes): " .. s:sub(1, 400) ..
        (#s > 400 and " ...[+" .. (#s - 400) .. "B]" or ""))
  fifo_out:write(s, "\n")
  fifo_out:flush()
end

local function recv()
  return fifo_in:read("*l")
end

-- ---------- stack introspection ----------
-- NOTE on `debug.getinfo` / `debug.getlocal` levels: these are
-- relative to the calling function. That means the absolute level a
-- frame has depends on where you're standing when you ask. So we do
-- the ENTIRE walk (frames + their locals + upvalues) inside pause()
-- at one reference point; the separate collect_frames / collect_locals
-- helpers that existed earlier were easy to get wrong.
local function safe_serialize(v)
  local ok, s = pcall(serialize, v, 0, {})
  if ok then return s end
  return "<serialize error: " .. tostring(s):sub(1, 80) .. ">"
end

-- ---------- entry-value snapshots (per thread) ----------
-- On every function call, we push an entry onto a per-coroutine stack.
-- If the called function is in a file that has an active breakpoint,
-- the entry carries a snapshot of the function's parameters/initial
-- locals (what `debug.getlocal(level, i)` sees the moment the function
-- is entered — before the body has run). On return we pop.
--
-- Cost: the stack push/pop happens on every Lua call, unconditionally,
-- but the expensive part (walking getlocal and serialize) only runs
-- for functions in breakpoint-matching files. In practice that's
-- handful per run — cheap.
local entry_stacks = setmetatable({}, { __mode = "k" })

local function entry_stack_for(co)
  local key = co or "main"
  local s = entry_stacks[key]
  if not s then
    s = {}
    entry_stacks[key] = s
  end
  return s
end

-- Given a frame (captured at break time), find the matching entry
-- snapshot: walk the per-thread stack backwards comparing func ids.
-- Returns the locals array or nil.
local function find_entry_locals(co, target_func)
  if not target_func then return nil end
  local s = entry_stacks[co or "main"]
  if not s then return nil end
  for i = #s, 1, -1 do
    if s[i].func == target_func and s[i].locals then
      return s[i].locals
    end
  end
  return nil
end

-- ---------- step state ----------
local step_mode   = nil   -- nil | "step" | "next" | "finish"
local step_thread = nil
local step_depth  = nil

local function current_depth()
  local d = 0
  while debug.getinfo(d + 3, "") do d = d + 1 end
  return d
end

-- ---------- pause / break handler ----------
local in_hook = false  -- reentrancy guard

-- Collect the current thread's frames + per-frame locals/upvalues.
-- The caller MUST be line_hook directly. Rationale: line_hook is
-- called by the Lua VM as a hook, and from inside line_hook,
-- `debug.getinfo(2)` is documented to return the running user
-- function. That's a stable anchor. From any helper one level deeper
-- (i.e. this function), user code is at level 3. Nested helpers
-- beyond that add Lua VM C dispatch frames which break the offset.
local function collect_frames_from_hook_helper()
  local frames          = {}
  local locals_by_frame = {}
  local co              = coroutine.running()
  -- Stack at this point:
  --   level 1 = this helper
  --   level 2 = line_hook
  --   level 3 = user code (running function that triggered the hook)
  -- CRITICAL: line_hook must have called us via a NORMAL call (not
  -- `return collect(...)`). Tail calls in Lua 5.1 replace the caller's
  -- frame, which would move line_hook out and shift all the levels.
  local level = 3
  while true do
    local info = debug.getinfo(level, "nSlf")
    if not info then break end
    local src = info.source
    if type(src) == "string" and src:sub(1, 1) == "@" then
      src = src:sub(2)
    end
    -- Synthesize a name when info.name is nil. Most of pwcore's
    -- coroutine-hosted closures (proxy.lua, scheduler callbacks, etc.)
    -- are anonymous from `debug.getinfo`'s POV — it can only name
    -- functions that the caller reached via a known local/global/field.
    -- Falling back to `what@linedefined` at least gives the user a
    -- stable visual anchor.
    local frame_name = info.name
    if not frame_name or frame_name == "" then
      if info.what == "main" then
        frame_name = "<main>"
      elseif info.what == "C" then
        frame_name = "[C]"
      elseif info.what == "Lua" then
        frame_name = "fn@" .. tostring(info.linedefined or "?")
      else
        frame_name = "?"
      end
    end

    frames[#frames + 1] = {
      level     = level,
      name      = frame_name,
      namewhat  = info.namewhat,   -- "method" / "local" / "upvalue" / "" etc.
      what      = info.what,
      source    = src,
      short_src = info.short_src,
      line      = info.currentline,
      line_def  = info.linedefined,
    }

    local locals, upvals = {}, {}
    local i = 1
    while true do
      local n, v = debug.getlocal(level, i)
      if not n then break end
      if n:sub(1, 1) ~= "(" then
        locals[#locals + 1] = { name = n, value = safe_serialize(v) }
      end
      i = i + 1
    end
    if info.func then
      i = 1
      while true do
        local ok_n, n, v = pcall(debug.getupvalue, info.func, i)
        if not ok_n or not n then break end
        upvals[#upvals + 1] = { name = n, value = safe_serialize(v) }
        i = i + 1
      end
    end
    -- Look up this frame's entry-time snapshot, if any. find_entry_locals
    -- walks the per-thread entry stack for a matching func pointer.
    local entry_locals = find_entry_locals(co, info.func)

    locals_by_frame[#locals_by_frame + 1] = {
      locals   = locals,
      upvalues = upvals,
      entry    = entry_locals,  -- may be nil (e.g. C frames, or file not in bps)
    }

    level = level + 1
    if level > 40 then break end
  end
  return frames, locals_by_frame
end

-- ---------- coroutine creation-site tracking ----------
-- When user code calls coroutine.create / coroutine.wrap, we grab
-- the caller's source+line via debug.getinfo and remember it. Later,
-- when a breakpoint fires inside that coroutine, the break event
-- carries the creation site so the TUI can show "this coroutine was
-- born at scheduler.lua:412" — which is usually far more useful than
-- the coroutine's pointer.
--
-- Weak keys so we don't pin dead coroutines in memory.
-- MUST be declared before pause(), because pause() reads it.
local co_creation = setmetatable({}, { __mode = "k" })

local function capture_creation_site(co, stack_level)
  local info = debug.getinfo(stack_level, "Sl")
  if not info then return end
  local src = info.source or "?"
  if type(src) == "string" and src:sub(1, 1) == "@" then
    src = src:sub(2):gsub("^%./", "")
  end
  co_creation[co] = {
    source = src,
    line   = info.currentline or 0,
  }
end

local function pause(reason, line, frames, locals_by_frame)
  if in_hook then return end
  in_hook = true
  do
    local top = frames and frames[1]
    trace("break reason=" .. tostring(reason) ..
          " line=" .. tostring(line) ..
          " src=" .. tostring(top and top.source or "?") ..
          " frames=" .. #(frames or {}))
  end

  -- Fine-grained tracing between the break announcement and the
  -- actual send() call. If the stub dies somewhere in here, the log
  -- will tell us exactly which step didn't make it.
  local ok_pause, pause_err = pcall(function()
    trace("pause step 1: about to call coroutine.running()")
    local co = coroutine.running()
    trace("pause step 2: co = " .. tostring(co))

    trace("pause step 3: looking up creation site")
    local creation = nil
    if co then
      creation = co_creation[co]
    end
    trace("pause step 4: creation = " .. tostring(creation))

    trace("pause step 5: building event table")
    local ev = {
      event          = "break",
      reason         = reason,
      line           = line,
      frames         = frames,
      vars           = locals_by_frame,
      thread         = co and tostring(co) or "main",
      is_main        = co == nil,
      created_src    = creation and creation.source or nil,
      created_line   = creation and creation.line   or nil,
    }
    trace("pause step 6: calling send")
    send(ev)
    trace("pause step 7: send returned")
  end)
  if not ok_pause then
    trace("pause ERROR before/during send: " .. tostring(pause_err))
    -- Try to report the error to the TUI so we don't just hang.
    pcall(send, {
      event = "error",
      where = "pause.send",
      err   = tostring(pause_err),
    })
  end

  if reason == "log" then
    in_hook = false
    return
  end

  while true do
    local raw = recv()
    if not raw then
      -- TUI went away — continue forever.
      step_mode = nil
      break
    end
    local chunk = loadstring(raw)
    if not chunk then break end
    local ok, msg = pcall(chunk)
    if not ok or type(msg) ~= "table" then break end
    local cmd = msg.cmd
    if cmd == "continue" then
      step_mode = nil
      break
    elseif cmd == "step" then
      step_mode = "step"
      break
    elseif cmd == "next" then
      step_mode   = "next"
      step_thread = coroutine.running()
      step_depth  = current_depth()
      break
    elseif cmd == "finish" then
      step_mode   = "finish"
      step_thread = coroutine.running()
      step_depth  = current_depth()
      break
    elseif cmd == "inspect" then
      -- The TUI sends us a (source, line, name, kind) identifying a
      -- variable in one of the frames we captured at break time. The
      -- captured frames have `level` values computed relative to
      -- collect_frames_from_hook_helper — which is NOT our current
      -- stack frame, so those levels are wrong from here. Instead,
      -- re-walk the live stack right now looking for a frame whose
      -- (source, currentline) matches what the TUI asked for, and
      -- use THAT level.
      local want_src  = msg.src or ""
      local want_line = msg.src_line or -1
      local name      = msg.name
      local kind      = msg.kind  -- "local" | "upvalue"

      local target_level
      for lvl = 2, 40 do
        local info = debug.getinfo(lvl, "Sl")
        if not info then break end
        local s = info.source or ""
        if s:sub(1, 1) == "@" then s = s:sub(2):gsub("^%./", "") end
        local cand = want_src:gsub("^%./", "")
        if (s == cand or s:sub(-(#cand + 1)) == "/" .. cand)
           and info.currentline == want_line then
          target_level = lvl
          break
        end
      end

      local value, found = nil, false
      if target_level and kind == "local" then
        local i = 1
        while true do
          local n, v = debug.getlocal(target_level, i)
          if not n then break end
          if n == name then value = v; found = true end
          i = i + 1
        end
      elseif target_level and kind == "upvalue" then
        local info = debug.getinfo(target_level, "f")
        if info and info.func then
          local i = 1
          while true do
            local n, v = debug.getupvalue(info.func, i)
            if not n then break end
            if n == name then value = v; found = true end
            i = i + 1
          end
        end
      end
      local repr
      if found then
        local ok, s = pcall(serialize, value, 0, {},
          DEEP_MAX_DEPTH, DEEP_MAX_KEYS, DEEP_MAX_STR)
        repr = ok and s or ("<serialize error: " .. tostring(s) .. ">")
      else
        repr = "<variable not found at this frame>"
      end
      send({
        event = "inspect",
        name  = name,
        kind  = kind,
        repr  = repr,
      })
      -- fall through: keep reading commands
    elseif cmd == "add_bp" then
      add_bp(msg.spec or "")
    elseif cmd == "del_bp" then
      del_bp_spec(msg.spec or "")
    end
    -- loop: consume more commands until one that resumes
  end

  in_hook = false
end

-- Forward declaration — actual body is defined further down, next to
-- the other hook code, but line_hook needs to reference it before that.
local call_hook_body

-- ---------- diagnostics ----------
-- Log every unique `info.source` the hook ever sees, plus a summary of
-- hook-call volume every N calls. This is how we chase "breakpoint
-- never fires" — it tells us what the debug library is actually
-- reporting vs. what the user's breakpoint paths look like.
local seen_sources = {}
local hook_calls = 0
local HOOK_LOG_EVERY = 50000

-- ---------- unified hook ----------
-- IMPORTANT: this function is registered directly with `debug.sethook`
-- (no dispatcher indirection). That matters because downstream code
-- (`collect_frames_from_hook_helper`, snap logic) assumes
-- `debug.getinfo(2)` from inside this hook is user code, which Lua
-- only guarantees when the hook is the registered function itself.
-- Adding *any* wrapper between sethook and this body would shift every
-- level by 1 and silently break everything.
local function line_hook(event, line)
  if event ~= "line" then
    -- Call / tail call / return / tail return handling lives inline
    -- here — see call_hook_body below — so we don't introduce a
    -- wrapper function around line handling.
    return call_hook_body(event)
  end

  if in_hook then return end

  hook_calls = hook_calls + 1
  if hook_calls % HOOK_LOG_EVERY == 0 then
    trace("hook calls so far: " .. hook_calls ..
          "  unique sources: " .. (function()
            local n = 0; for _ in pairs(seen_sources) do n = n + 1 end; return n
          end)())
  end

  if step_mode then
    local should = false
    if step_mode == "step" then
      should = true
    elseif step_mode == "next" then
      if coroutine.running() == step_thread and current_depth() <= step_depth then
        should = true
      end
    elseif step_mode == "finish" then
      if coroutine.running() == step_thread and current_depth() < step_depth then
        should = true
      end
    end
    if should then
      step_mode = nil
      local frames, vars = collect_frames_from_hook_helper()
      pause("step", line, frames, vars)
      return
    end
  end

  local info = debug.getinfo(2, "S")
  if not info then return end
  local raw_src = info.source
  if not raw_src then return end

  -- Log every unique source the hook encounters (cap so we don't
  -- spam the log with generated chunks).
  if not seen_sources[raw_src] then
    seen_sources[raw_src] = true
    local n = 0; for _ in pairs(seen_sources) do n = n + 1 end
    if n <= 500 then
      trace("new source seen: " .. raw_src)
    end
  end

  -- Accept both `@path` (loaded from file) and `=something` (loaded
  -- from a string / precompiled chunk with a name) forms. For `=`
  -- sources we match against the whole tail as a basename hint.
  local src
  if raw_src:sub(1, 1) == "@" then
    src = raw_src:sub(2):gsub("^%./", "")
  elseif raw_src:sub(1, 1) == "=" then
    src = raw_src:sub(2)
  else
    return
  end

  -- Log every line hit on any file whose basename includes the string
  -- from any active breakpoint — helps diagnose "wrong line number".
  for _, bp in ipairs(bp_list) do
    local base = bp.path:match("([^/]+)$") or bp.path
    if src:find(base, 1, true) then
      local k = "near:" .. src .. ":" .. line
      if not seen_sources[k] then
        seen_sources[k] = true
        trace("near-match hit " .. src .. ":" .. line ..
              " (looking for " .. bp.path .. ":" .. bp.requested .. ")")
      end
      break
    end
  end

  local hit = lookup_bp(src, line, info)
  if hit then
    -- Collect stack FIRST so we have a stable anchor (level 2 from
    -- here is user code, confirmed). Then call pause with the result
    -- as a NORMAL call (not a tail call — tail calls replace the
    -- current frame, which would shift the inspect command's levels
    -- by 1 later on).
    local frames, vars = collect_frames_from_hook_helper()
    pause(hit, line, frames, vars)
    return
  end
end

-- ---------- call/return hook body for entry snapshots ----------
-- NOTE: this is always invoked as a tail call from `line_hook`
-- (`return call_hook_body(event)`), which in Lua 5.1 REPLACES the
-- line_hook frame entirely. So from inside call_hook_body, level 2 is
-- user code — same as if line_hook had inlined this code. That's the
-- only way to keep debug.getinfo offsets consistent across both
-- events without a dispatcher wrapper.
call_hook_body = function(event)  -- forward-declared above line_hook
  local info = debug.getinfo(2, "Sf")
  if not info then
    if event == "return" or event == "tail return" then
      local s = entry_stack_for(coroutine.running())
      if #s > 0 then s[#s] = nil end
    end
    return
  end

  if event == "call" or event == "tail call" then
    local entry = { func = info.func }
    -- Only bother snapshotting locals for Lua functions whose source
    -- is in a file with an active breakpoint — everything else is wasted.
    if info.what == "Lua" and #bp_list > 0 then
      local src = info.source
      if type(src) == "string" and src:sub(1, 1) == "@" then
        src = src:sub(2):gsub("^%./", "")
        local matches = false
        for _, bp in ipairs(bp_list) do
          if bp_path_matches(src, bp.path) then
            matches = true; break
          end
        end
        if matches then
          local locals = {}
          local i = 1
          while true do
            local n, v = debug.getlocal(2, i)
            if not n then break end
            if n:sub(1, 1) ~= "(" then
              locals[#locals + 1] = { name = n, value = safe_serialize(v) }
            end
            i = i + 1
          end
          entry.locals = locals
        end
      end
    end
    local s = entry_stack_for(coroutine.running())
    s[#s + 1] = entry
  elseif event == "return" or event == "tail return" then
    local s = entry_stack_for(coroutine.running())
    if #s > 0 then s[#s] = nil end
  end
end

-- ---------- install on main thread + coroutines ----------
-- line_hook is the single registered function; it handles line,
-- call, tail call, return, and tail return events internally.
-- Registering a wrapper between debug.sethook and this body would
-- shift debug.getinfo levels by 1 and silently break everything.
debug.sethook(line_hook, "crl")

local _create = coroutine.create
coroutine.create = function(f)
  local co = _create(f)
  debug.sethook(co, line_hook, "crl")
  -- Stack here: level 1 = this wrapper, level 2 = caller of
  -- coroutine.create (user code — the line that created the coroutine).
  capture_creation_site(co, 2)
  return co
end

local _wrap = coroutine.wrap
coroutine.wrap = function(f)
  local co = _create(f)
  debug.sethook(co, line_hook, "crl")
  capture_creation_site(co, 2)
  return function(...)
    local r = { coroutine.resume(co, ...) }
    if r[1] then
      return unpack(r, 2)
    else
      error(r[2], 2)
    end
  end
end

-- Announce ourselves so the TUI knows the child is live.
send({ event = "hello", bps = bps_env })
