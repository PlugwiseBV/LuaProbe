-- pwdebug — controller-side library for the pwdebug Lua debugger.
--
-- This module owns the two-FIFO transport, the Lua-literal decoder,
-- and the session lifecycle. It has NO global state and no
-- dependencies on any UI framework — a session is an object you
-- create explicitly, poll in your main loop, and close when done.
--
-- Runs under LuaJIT only (uses FFI for non-blocking POSIX I/O).
-- The debugged child process must run under Lua 5.1 or LuaJIT.
--
-- See README.md for usage and DEBUGGER.md for internals.

local ffi = require("ffi")

-- ---------- POSIX via FFI ----------
ffi.cdef[[
int    open(const char *pathname, int flags);
long   read(int fd, void *buf, unsigned long count);
long   write(int fd, const void *buf, unsigned long count);
int    close(int fd);
int    unlink(const char *pathname);
]]

local C = ffi.C
local O_RDONLY   = 0
local O_WRONLY   = 1
local O_RDWR     = 2
local O_NONBLOCK = 2048  -- Linux

local BUF_SIZE = 8192

local M = {}

-- ---------- small helpers ----------

local function mkfifo(path)
  os.execute("rm -f '" .. path .. "' 2>/dev/null")
  os.execute("mkfifo -m 600 '" .. path .. "' 2>/dev/null")
end

local function fd_close(fd)
  if fd and fd >= 0 then C.close(fd) end
end

-- Decode a single Lua-literal line in a sandboxed env. Returns the
-- table on success, or nil + error string.
local function decode(line)
  local chunk, err = loadstring(line)
  if not chunk then return nil, err end
  setfenv(chunk, {})
  local ok, val = pcall(chunk)
  if not ok then return nil, val end
  return val
end

-- Encode a flat table of primitives as a `return {...}` Lua chunk,
-- one line. Type-aware so numbers land on the stub as numbers, not
-- as quoted strings.
local function encode_cmd(tbl)
  local parts = { "return {" }
  for k, v in pairs(tbl) do
    local t = type(v)
    local enc
    if t == "number" or t == "boolean" or t == "nil" then
      enc = tostring(v)
    else
      enc = string.format("%q", tostring(v))
    end
    parts[#parts + 1] = k .. "=" .. enc .. ","
  end
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

-- ---------- Session class ----------

local Session = {}
Session.__index = Session

local session_counter = 0
local function fresh_paths()
  session_counter = session_counter + 1
  local id = tostring(os.time()) .. "-" .. tostring(session_counter)
  return "/tmp/pwdebug-" .. id .. ".out",
         "/tmp/pwdebug-" .. id .. ".in"
end

-- Public constructor. Creates the FIFOs, opens the TUI-side ends
-- non-blocking, and returns a session object ready to have its env
-- prefix injected into a child-process launch command.
--
-- opts:
--   stub_path     (required) absolute path to pwdebug_stub.lua
--   breakpoints   (optional) array of "FILE:LINE[!]" strings
--   on_status     (optional) callback(string) for status messages
--                 (decode errors, session lifecycle, etc.)
--   source_roots  (optional) array of directories to search when
--                 `session:get_source(path)` needs to load a file
--                 for display. Defaults to {"."}.
function M.new(opts)
  assert(type(opts) == "table", "pwdebug.new requires an options table")
  assert(type(opts.stub_path) == "string" and #opts.stub_path > 0,
    "pwdebug.new: opts.stub_path is required")

  local self = setmetatable({}, Session)
  self.stub_path    = opts.stub_path
  self.breakpoints  = {}
  self.source_roots = opts.source_roots or { "." }
  self.on_status    = opts.on_status or function() end
  self.source_cache = {}
  self.buf          = ""
  self.paused       = false
  self.alive        = false
  self.frames       = {}
  self.vars         = {}
  self.log_history  = {}

  if opts.breakpoints then
    for _, spec in ipairs(opts.breakpoints) do
      local bp = self:_parse_bp(spec)
      if bp then self.breakpoints[#self.breakpoints + 1] = bp end
    end
  end

  self.out_path, self.in_path = fresh_paths()
  mkfifo(self.out_path)
  mkfifo(self.in_path)

  -- Read end of out-fifo: non-blocking so drain never stalls.
  self.fd_in = C.open(self.out_path, O_RDONLY + O_NONBLOCK)
  -- Write end of in-fifo: open O_RDWR (Linux quirk) so the open
  -- itself doesn't block waiting for a reader, and non-blocking so
  -- writes can't stall either.
  self.fd_out = C.open(self.in_path, O_RDWR + O_NONBLOCK)

  if self.fd_in < 0 or self.fd_out < 0 then
    fd_close(self.fd_in); fd_close(self.fd_out)
    C.unlink(self.out_path); C.unlink(self.in_path)
    return nil, "failed to open FIFOs"
  end

  self.alive   = true
  self.read_buf = ffi.new("char[?]", BUF_SIZE)
  return self
end

-- Close the session, unlink FIFOs, release fds.
function Session:close()
  if not self.alive then return end
  self.alive = false
  fd_close(self.fd_in);  self.fd_in  = -1
  fd_close(self.fd_out); self.fd_out = -1
  if self.out_path then C.unlink(self.out_path) end
  if self.in_path  then C.unlink(self.in_path)  end
end

-- Build the shell env-var prefix that launches a debugged child.
-- The caller should prepend this to their existing subprocess
-- command, e.g.:
--
--   local cmd = "sh -c '" .. sess:env_prefix() .. " lua5.1 demo.lua' &"
--   os.execute(cmd)
--
-- Note the outer single quotes around the sh -c string: the env
-- prefix uses DOUBLE quotes for its own values specifically so that
-- embedding works without shell quoting errors.
function Session:env_prefix()
  local bp_parts = {}
  for _, bp in ipairs(self.breakpoints) do
    bp_parts[#bp_parts + 1] = bp.path .. ":" .. bp.line ..
      (bp.log and "!" or "")
  end
  local bp_env = table.concat(bp_parts, ",")
  return string.format(
    'PWDEBUG_FIFO_OUT="%s" PWDEBUG_FIFO_IN="%s" PWDEBUG_BREAKPOINTS="%s" LUA_INIT="@%s"',
    self.out_path, self.in_path, bp_env, self.stub_path)
end

-- Drain the FIFO and return an array of decoded events. Call this
-- every tick from your main loop. Non-blocking: returns an empty
-- array when nothing is pending. Events have the shape documented
-- in README.md under "Events from the stub".
function Session:poll()
  if not self.alive then return {} end
  -- Drain all available bytes.
  while true do
    local n = C.read(self.fd_in, self.read_buf, BUF_SIZE)
    if n <= 0 then break end
    self.buf = self.buf .. ffi.string(self.read_buf, n)
  end
  -- Split on newlines and decode each complete line.
  local events = {}
  while true do
    local nl = self.buf:find("\n", 1, true)
    if not nl then break end
    local line = self.buf:sub(1, nl - 1)
    self.buf = self.buf:sub(nl + 1)
    if #line > 0 then
      local ev, err = decode(line)
      if ev then
        events[#events + 1] = ev
        self:_update_from_event(ev)
      else
        self.on_status("decode error: " .. tostring(err))
      end
    end
  end
  return events
end

-- Internal: update the session's mirror state from an incoming
-- event. Users can ignore this and react to events from :poll()
-- directly, but these fields are handy for simple UIs.
function Session:_update_from_event(ev)
  if ev.event == "hello" then
    self.child_attached = true
  elseif ev.event == "break" then
    -- Scrub raw control characters from value strings — after the
    -- %q round-trip these can contain real newlines / tabs, which
    -- break terminal renderers that assume one row per value.
    local function scrub(s)
      if type(s) ~= "string" then return s end
      return (s:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "    "))
    end
    for _, fv in ipairs(ev.vars or {}) do
      for _, g in ipairs(fv.locals   or {}) do g.value = scrub(g.value) end
      for _, g in ipairs(fv.upvalues or {}) do g.value = scrub(g.value) end
      for _, g in ipairs(fv.entry    or {}) do g.value = scrub(g.value) end
    end
    self.frames       = ev.frames or {}
    self.vars         = ev.vars   or {}
    self.reason       = ev.reason
    self.line         = ev.line
    self.thread       = ev.thread
    self.is_main      = ev.is_main
    self.created_src  = ev.created_src
    self.created_line = ev.created_line
    if ev.reason == "log" then
      self.log_history[#self.log_history + 1] = ev
    else
      self.paused = true
    end
  end
end

-- ---------- commands to the stub ----------

function Session:_send_cmd(tbl)
  if not self.alive or self.fd_out < 0 then return end
  local s = encode_cmd(tbl)
  C.write(self.fd_out, s, #s)
end

local function resume(self, cmd)
  self.paused = false
  self:_send_cmd({ cmd = cmd })
end

function Session:cmd_continue() resume(self, "continue") end
function Session:cmd_step()     resume(self, "step")     end
function Session:cmd_next()     resume(self, "next")     end
function Session:cmd_finish()   resume(self, "finish")   end

-- Ask the stub for a deep dump of a variable in a specific frame.
-- Result arrives asynchronously as an "inspect" event from :poll().
function Session:inspect_var(frame, kind, name)
  if not self.paused then return end
  self:_send_cmd({
    cmd      = "inspect",
    src      = frame.source or "",
    src_line = frame.line or 0,
    kind     = kind,
    name     = name,
  })
end

-- ---------- breakpoint management ----------

function Session:_parse_bp(spec)
  spec = spec:match("^%s*(.-)%s*$")
  if spec == "" then return nil end
  local log_only = false
  if spec:sub(-1) == "!" then
    log_only = true
    spec = spec:sub(1, -2)
  end
  local path, line = spec:match("^(.-):(%d+)$")
  if not path or path == "" then return nil end
  return {
    path = path:gsub("^%./", ""),
    line = tonumber(line),
    log  = log_only,
  }
end

-- Add a breakpoint. Takes either a "FILE:LINE[!]" string or three
-- explicit arguments (path, line, log_only). If the session's child
-- is already running, the breakpoint is pushed live via add_bp.
-- Otherwise it's added to the list and will be included in the env
-- prefix the next time env_prefix() is called.
function Session:add_breakpoint(spec_or_path, line, log_only)
  local bp
  if type(spec_or_path) == "string" and line == nil then
    bp = self:_parse_bp(spec_or_path)
  else
    bp = {
      path = tostring(spec_or_path):gsub("^%./", ""),
      line = tonumber(line),
      log  = log_only or false,
    }
  end
  if not bp then return false end
  for _, existing in ipairs(self.breakpoints) do
    if existing.path == bp.path and existing.line == bp.line then
      return false  -- already present, dedupe
    end
  end
  self.breakpoints[#self.breakpoints + 1] = bp
  self:_send_cmd({
    cmd  = "add_bp",
    spec = bp.path .. ":" .. bp.line .. (bp.log and "!" or ""),
  })
  return true
end

function Session:remove_breakpoint(path, line)
  path = path:gsub("^%./", "")
  for i, bp in ipairs(self.breakpoints) do
    if bp.path == path and bp.line == line then
      table.remove(self.breakpoints, i)
      self:_send_cmd({ cmd = "del_bp", spec = path .. ":" .. line })
      return true
    end
  end
  return false
end

function Session:find_breakpoint(path, line)
  path = path:gsub("^%./", "")
  for _, bp in ipairs(self.breakpoints) do
    if bp.path == path and bp.line == line then return bp end
  end
  return nil
end

-- ---------- source loading (for a source pane) ----------

-- Read a source file into an array of lines. Tries the path as
-- given, then each source_root from opts. Caches results per
-- session. Safe against Linux directories (io.open can open them
-- and then f:lines() throws).
function Session:get_source(path)
  if not path or path == "" then return nil end
  local cached = self.source_cache[path]
  if cached then return cached end

  local function try(p)
    if p == "" then return nil end
    if p:sub(1, 1) == "[" or p:sub(1, 1) == "=" then return nil end
    local f = io.open(p, "r")
    if not f then return nil end
    local lines = {}
    local ok = pcall(function()
      for l in f:lines() do lines[#lines + 1] = l end
    end)
    f:close()
    if ok then return lines end
    return nil
  end

  local lines = try(path)
  if not lines then
    for _, root in ipairs(self.source_roots) do
      lines = try(root .. "/" .. path)
      if lines then break end
    end
  end
  if not lines then
    lines = { "<source not found: " .. tostring(path) .. ">" }
  end
  self.source_cache[path] = lines
  return lines
end

return M
