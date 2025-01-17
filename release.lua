-- self-extracting mtar loader thingy: header --
-- this is designed for minimal overhead, not speed.
-- Expects an MTAR V1 archive.  Will not work with V0.

local fs = component.proxy(computer.getBootAddress())
local gpu = component.proxy(component.list("gpu")())
gpu.bind(gpu.getScreen() or (component.list("screen")()))

-- filesystem tree
local tree = {__is_a_directory = true}

local handle = assert(fs.open("/init.lua", "r"))

local seq = {"|","/","-","\\"}
local si = 1

gpu.setResolution(50, 16)
gpu.fill(1, 1, 50, 16, " ")
gpu.setForeground(0)
gpu.setBackground(0xFFFFFF)
gpu.set(1, 1, "             Cynosure MTAR-FS Loader              ")
gpu.setBackground(0)
gpu.setForeground(0xFFFFFF)

local function status(x, y, t, c)
  if c then gpu.fill(1, y+1, 50, 1, " ") end
  gpu.set(x, y+1, t)
end

status(1, 1, "Seeking to data section...")
local startoffset = 5536
-- seek in a hardcoded amount for speed reasons
fs.read(handle, 2048)
fs.read(handle, 2048)
fs.read(handle, 1440)
local last_time = computer.uptime()
repeat
  local c = fs.read(handle, 1)
  startoffset = startoffset + 1
  local t = computer.uptime()
  if t - last_time >= 0.1 then
    --status(30, 1, tostring(startoffset))
    status(28, 1, seq[si])
    si = si + 1
    if not seq[si] then si = 1 end
    last_time = t
  end
until c == "\90" -- uppercase z: magic
assert(fs.read(handle, 1) == "\n") -- skip \n

local function split_path(path)
  local s = {}
  for _s in path:gmatch("[^\\/]+") do
    if _s == ".." then
      s[#s] = nil
    elseif s ~= "." then
      s[#s+1]=_s
    end
  end
  return s
end

local function add_to_tree(name, offset, len)
  local cur = tree
  local segments = split_path(name)
  if #segments == 0 then return end
  for i=1, #segments - 1, 1 do
    cur[segments[i]] = cur[segments[i]] or {__is_a_directory = true}
    cur = cur[segments[i]]
  end
  cur[segments[#segments]] = {offset = offset, length = len}
end

local function read(n, offset, rdata)
  if offset then fs.seek(handle, "set", offset) end
  local to_read = n
  local data = ""
  while to_read > 0 do
    local n = math.min(2048, to_read)
    to_read = to_read - n
    local chunk = fs.read(handle, n)
    if rdata then data = data .. (chunk or "") end
  end
  return data
end

local function read_header()
  -- skip V1 header
  fs.read(handle, 3)
  local namelen = fs.read(handle, 2)
  if not namelen then
    return nil
  end
  namelen = string.unpack(">I2", namelen)
  local name = read(namelen, nil, true)
  local flendat = fs.read(handle, 8)
  if not flendat then return end
  local flen = string.unpack(">I8", flendat)
  local offset = fs.seek(handle, "cur", 0)
  status(24, 2, name .. (" "):rep(50 - (24 + #name)))
  fs.seek(handle, "cur", flen)
  add_to_tree(name, offset, flen)
  return true
end

status(1, 2, "Reading file headers... ")
repeat until not read_header()

-- create the mtar fs node --

local function find(f)
  if f == "/" or f == "" then
    return tree
  end

  local s = split_path(f)
  local c = tree
  
  for i=1, #s, 1 do
    if s[i] == "__is_a_directory" then
      return nil, "file not found"
    end
  
    if not c[s[i]] then
      return nil, "file not found"
    end

    c = c[s[i]]
  end

  return c
end

local obj = {}

function obj:stat(f)
  checkArg(1, f, "string")
  
  local n, e = find(f)
  
  if n then
    return {
      permissions = 365,
      owner = 0,
      group = 0,
      lastModified = 0,
      size = 0,
      isDirectory = not not n.__is_a_directory,
      type = n.__is_a_directory and 2 or 1
    }
  else
    return nil, e
  end
end

function obj:touch()
  return nil, "device is read-only"
end

function obj:remove()
  return nil, "device is read-only"
end

function obj:list(d)
  local n, e = find(d)
  
  if not n then return nil, e end
  if not n.__is_a_directory then return nil, "not a directory" end
  
  local f = {}
  
  for k, v in pairs(n) do
    if k ~= "__is_a_directory" then
      f[#f+1] = tostring(k)
    end
  end
  
  return f
end

local function ferr()
  return nil, "bad file descriptor"
end

local _handle = {}

function _handle:read(n)
  checkArg(1, n, "number")
  if self.fptr >= self.node.length then return nil end
  n = math.min(self.fptr + n, self.node.length)
  local data = read(n - self.fptr, self.fptr + self.node.offset, true)
  self.fptr = n
  return data
end

_handle.write = ferr

function _handle:seek(origin, offset)
  checkArg(1, origin, "string")
  checkArg(2, offset, "number", "nil")
  local n = (origin == "cur" and self.fptr) or (origin == "set" and 0) or
    (origin == "end" and self.node.length) or
    (error("bad offset to 'seek' (expected one of: cur, set, end, got "
      .. origin .. ")"))
  n = n + (offset or 0)
  if n < 0 or n > self.node.length then
    return nil, "cannot seek there"
  end
  self.fptr = n
  return n
end

function _handle:close()
  if self.closed then
    return ferr()
  end
  
  self.closed = true
end

function obj:open(f, m)
  checkArg(1, f, "string")
  checkArg(2, m, "string")

  if m:match("[w%+]") then
    return nil, "device is read-only"
  end
  
  local n, e = find(f)
  
  if not n then return nil, e end
  if n.__is_a_directory then return nil, "is a directory" end

  local new = setmetatable({
    node = n, --data = read(n.length, n.offset, true),
    mode = m,
    fptr = 0
  }, {__index = _handle})

  return new
end

obj.node = {getLabel = function() return "mtarfs" end}

status(1, 3, "Loading kernel...")

_G.__mtar_fs_tree = obj

local hdl = assert(obj:open("/boot/cynosure.lua", "r"))
local ldme = hdl:read(hdl.node.length)
hdl:close()

assert(load(ldme, "=mtarfs:/boot/cynosure.lua", "t", _G))()

-- concatenate mtar data past this line
--[=======[Z
�� /sbin/sudo.lua      �-- coreutils: sudo --

local users = require("users")
local process = require("process")

local args = table.pack(...)

local uid = 0
if args[1] and args[1]:match("^%-%-uid=%d+$") then
  uid = tonumber(args[1]:match("uid=(%d+)")) or 0
  table.remove(args, 1)
end

if #args == 0 then
  io.stderr:write([[
sudo: usage: sudo [--uid=UID] COMMAND
Executes COMMAND as root or the specified UID.
]])
  os.exit(1)
end

local password
repeat
  io.write("password: \27[8m")
  password = io.read()
  io.write("\27[0m\n")
until #password > 0

local ok, err = users.exec_as(uid,
  password, function() os.execute(table.concat(args, " ")) end, args[1], true)

if ok ~= 0 and err ~= "__internal_process_exit" then
  io.stderr:write(err, "\n")
  os.exit(ok)
end
�� /sbin/init.lua      {-- USysD init system.  --
-- Copyright (c) 2021 Ocawesome101 under the DSLv2.

if package.loaded.usysd then
  io.stderr:write("\27[97m[ \27[91mFAIL \27[97m] USysD is already running!\n")
  os.exit(1)
end

local usd = {}

--  usysd versioning stuff --

usd._VERSION_MAJOR = 1
usd._VERSION_MINOR = 0
usd._VERSION_PATCH = 4
usd._RUNNING_ON = "unknown"

io.write(string.format("USysD version %d.%d.%d\n", usd._VERSION_MAJOR, usd._VERSION_MINOR,
  usd._VERSION_PATCH))

do
  local handle, err = io.open("/etc/os-release")
  if handle then
    local data = handle:read("a")
    handle:close()

    local name = data:match("PRETTY_NAME=\"(.-)\"")
    local color = data:match("ANSI_COLOR=\"(.-)\"")
    if name then usd._RUNNING_ON = name end
    if color then usd._ANSI_COLOR = color end
  end
end

io.write("\n  \27[97mWelcome to \27[" .. (usd._ANSI_COLOR or "96") .. "m" .. usd._RUNNING_ON .. "\27[97m!\27[37m\n\n")
--#include "src/version.lua"
-- logger stuff --

usd.statii = {
  ok = "\27[97m[\27[92m  OK  \27[97m] ",
  warn = "\27[97m[\27[93m WARN \27[97m] ",
  wait = "\27[97m[\27[93m WAIT \27[97m] ",
  fail = "\27[97m[\27[91m FAIL \27[97m] ",
}

function usd.log(...)
  io.write(...)
  io.write("\n")
end
--#include "src/logger.lua"
-- set the system hostname --

do
  local net = require("network")
  local handle, err = io.open("/etc/hostname", "r")
  if handle then
    local hostname = handle:read("a"):gsub("\n", "")
    handle:close()
    net.sethostname(hostname)
  end
  usd.log(usd.statii.ok, "hostname is \27[37m<\27[90m" .. net.hostname() .. "\27[37m>")
end
--#include "src/hostname.lua"
-- service API --

do
  usd.log(usd.statii.ok, "initializing service management")

  local config = require("config").bracket
  local fs = require("filesystem")
  local users = require("users")
  local process = require("process")

  local autostart = "/etc/usysd/autostart"
  local svc_dir = "/etc/usysd/services/"

  local api = {}
  local running = {}
  usd.running = running

  local starting = {}
  local ttys = {[0] = io.stderr}
  function api.start(name)
    checkArg(1, name, "string")
    if running[name] or starting[name] then return true end

    local full_name = name
    local tty = io.stderr.tty
    do
      local _name, _tty = name:match("(.+)@tty(%d+)")
      name = _name or name
      tty = tonumber(_tty) or tty
      if not ttys[tty] then
        local hnd, err = io.open("/sys/dev/tty" .. tty)
        if not hnd then
          usd.log(usd.statii.fail, "cannot open tty", tty, ": ", err)
          return nil
        end
        ttys[tty] = hnd
        hnd.tty = tty
      end
    end
    
    usd.log(usd.statii.wait, "starting service ", name)
    local cfg = config:load(svc_dir .. name)
    
    if not cfg then
      usd.log("\27[A\27[G\27[2K", usd.statii.fail, "service ", name, " not found!")
      return nil
    end
    
    if not (cfg["usysd-service"] and cfg["usysd-service"].file) then
      usd.log("\27[A\27[G\27[2K", usd.statii.fail, "service ", name,
        " has invalid configuration")
      return nil
    end
    
    local file = cfg["usysd-service"].file
    local user = cfg["usysd-service"].user or "root"
    local uid, err = users.get_uid(user)
    
    if not uid then
      usd.log("\27[A\27[G\27[2K", usd.statii.fail, "service ", name,
        " is configured to run as ", user, " but: ", err)
      return nil
    end
    
    if user ~= process.info().owner and process.info().owner ~= 0 then
      usd.log("\27[A\27[G\27[2K", usd.statii.fail, "service ", name,
        " cannot be started as ", user, ": insufficient permissions")
      return nil
    end

    starting[full_name] = true
    if cfg["usysd-service"].depends then
      for i, svc in ipairs(cfg["usysd-service"].depends) do
        local ok = api.start(svc)
        if not ok then
          usd.log(usd.statii.fail, "failed starting dependency ", svc)
          starting[name] = false
          return nil
        end
      end
    end
    
    local ok, err = loadfile(file)
    if not ok then
      usd.log("\27[A\27[G\27[2K", usd.statii.fail, "failed to load ", name, ": ", err)
      return nil
    end

    local pid, err = users.exec_as(uid, "", ok, "["..name.."]", nil, ttys[tty])
    if not pid and err then
      usd.log("\27[A\27[G\27[2K", usd.statii.fail, "failed to start ", full_name, ": ", err)
      return nil
    end

    usd.log("\27[A\27[G\27[2K", usd.statii.ok, "started service ", full_name)
    
    running[full_name] = pid
    return true
  end

  function api.stop(name)
    checkArg(1, name, "string")
    usd.log(usd.statii.ok, "stopping service ", name)
    if not running[name] then
      usd.log(usd.statii.warn, "service ", name, " is not running")
      return nil
    end
    process.kill(running[name], process.signals.quit)
    running[name] = nil
    return true
  end

  function api.list(enabled, running)
    enabled = not not enabled
    running = not not running
    if running then
      local list = {}
      for name in pairs(usd.running) do
        list[#list + 1] = name
      end
      return list
    end
    if enabled then
      local list = {}
      for line in io.lines(autostart,"l") do
        list[#list + 1] = line
      end
      return list
    end
    return fs.list(svc_dir)
  end

  function api.enable(name)
    checkArg(1, name, "string")
    local enabled = api.list(true)
    local handle, err = io.open(autostart, "w")
    if not handle then return nil, err end
    table.insert(enabled, math.min(#enabled + 1, math.max(1, #enabled - 1)), name)
    handle:write(table.concat(enabled, "\n"))
    handle:close()
    return true
  end

  function api.disable(name)
    checkArg(1, name, "string")
    local enabled = api.list(true)
    local handle, err = io.open(autostart, "w")
    if not handle then return nil, err end
    for i=1, #enabled, 1 do
      if enabled[i] == name then
        table.remove(enabled, i)
        break
      end
    end
    handle:write(table.concat(enabled, "\n"))
    handle:close()
    return true
  end

  usd.api = api
  package.loaded.usysd = api

  for line in io.lines(autostart, "l") do
    api.start(line)
  end
end
--#include "src/serviceapi.lua"
-- wrap computer.shutdown --

do
  local network = require("network")
  local computer = require("computer")
  local shutdown = computer.shutdown

  function usd.shutdown()
    usd.log(usd.statii.wait, "stopping services")
    for name in pairs(usd.running) do
      usd.api.stop(name)
    end
    usd.log(usd.statii.ok, "stopped services")

    if network.hostname() ~= "localhost" then
      usd.log(usd.statii.wait, "saving hostname")
      local handle = io.open("/etc/hostname", "w")
      if handle then
        handle:write(network.hostname())
        handle:close()
      end
      usd.log("\27[A\27[G\27[2K", usd.statii.ok, "saved hostname")
    end

    os.sleep(1)

    shutdown(usd.__should_reboot)
  end

  function computer.shutdown(reboot)
    usd.__should_shut_down = true
    usd.__should_reboot = not not reboot
  end
end
--#include "src/shutdown.lua"

local proc = require("process")
while true do
  coroutine.yield(2)
  for name, pid in pairs(usd.running) do
    if not proc.info(pid) then
      usd.running[name] = nil
    end
  end
  if usd.__should_shut_down then
    usd.shutdown()
  end
end
�� /sbin/usysd.lua      �-- ussyd service management --

local usysd = require("usysd")
local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help or (args[1] ~= "list" and #args < 2) then
  io.stderr:write([[
usage: usysd <start|stop> SERVICE[@ttyN]
   or: usysd <enable|disable> [--now] SERVICE[@ttyN]
   or: usysd list [--enabled]

Manages services under USysD.

USysD copyright (c) 2021 Ocawesome101 under the
DSLv2.
]])
end

local cmd, svc = args[1], args[2]
if cmd == "list" then
  local services, err = usysd.list(opts.enabled, opts.running)
  print(table.concat(services, "\n"))
elseif cmd == "enable" then
  local ok, err = usysd.enable(svc)
  if not ok then io.stderr:write(err, "\n") os.exit(1) end
  if opts.now then usysd.start(svc) end
elseif cmd == "disable" then
  local ok, err = usysd.disable(svc)
  if not ok then io.stderr:write(err, "\n") os.exit(1) end
  if opts.now then usysd.stop(svc) end
elseif cmd == "start" or cmd == "stop" then
  local ok = usysd[cmd](svc)
  if not ok then os.exit(1) end
end
�� /sbin/shutdown.lua      �-- shutdown

local computer = require("computer")

local args, opts = require("argutil").parse(...)

-- don't do anything except broadcast shutdown (TODO)
if opts.k then
  io.stderr:write("shutdown: -k not implemented yet, exiting cleanly anyway\n")
  os.exit(0)
end

local function try(f, a)
  local ok, err = f(a)
  if not ok and err then
    io.stderr:write("shutdown: ", err, "\n")
    os.exit(1)
  end
  os.exit(0)
end

-- reboot
if opts.r or opts.reboot then
  try(computer.shutdown, true)
end

-- halt
if opts.h or opts.halt then
  try(computer.shutdown, "halt")
end

-- just power off
if opts.p or opts.P or opts.poweroff then
  try(computer.shutdown)
end

io.stderr:write([[
usage: shutdown [options]
options:
  --poweroff, -P, -p  power off
  --reboot, -r        reboot
  --halt, -h          halt the system
  -k                  write wall message but do not shut down
]])

os.exit(1)
�� /lib/path.lua      T-- work with some paths!

local lib = {}

function lib.split(path)
  checkArg(1, path, "string")

  local segments = {}
  
  for seg in path:gmatch("[^\\/]+") do
    if seg == ".." then
      segments[#segments] = nil
    elseif seg ~= "." then
      segments[#segments + 1] = seg
    end
  end
  
  return segments
end

function lib.clean(path)
  checkArg(1, path, "string")

  return string.format("/%s", table.concat(lib.split(path), "/"))
end

function lib.concat(...)
  local args = table.pack(...)
  if args.n == 0 then return end

  for i=1, args.n, 1 do
    checkArg(i, args[i], "string")
  end

  return lib.clean("/" .. table.concat(args, "/"))
end

function lib.canonical(path)
  checkArg(1, path, "string")

  if path:sub(1,1) ~= "/" then
    path = lib.concat(os.getenv("PWD") or "/", path)
  end

  return lib.clean(path)
end

return lib
�� /lib/termio/xterm-256color.lua      �-- xterm-256color handler --

local handler = {}

local termio = require("posix.termio")
local isatty = require("posix.unistd").isatty

handler.keyBackspace = 127
handler.keyDelete = 8

local default = termio.tcgetattr(0)
local raw = {}
for k,v in pairs(default) do raw[k] = v end
raw.oflag = 4
raw.iflag = 0
raw.lflag = 35376
default.cc[2] = handler.keyBackspace

function handler.setRaw(_raw)
  if _raw then
    termio.tcsetattr(0, termio.TCSANOW, raw)
  else
    termio.tcsetattr(0, termio.TCSANOW, default)
  end
end

function handler.cursorVisible(v)
  
end

function handler.ttyIn() return isatty(0) == 1 end
function handler.ttyOut() return isatty(1) == 1 end

return handler
�� /lib/termio/cynosure.lua      �-- handler for the Cynosure terminal

local handler = {}

handler.keyBackspace = 8

function handler.setRaw(raw)
  if raw then
    io.write("\27?3;12c\27[8m")
  else
    io.write("\27?13;2c\27[28m")
  end
end

function handler.cursorVisible(v)
  io.write(v and "\27?4c" or "\27?14c")
end

function handler.ttyIn()
  return not not io.input().tty
end

function handler.ttyOut()
  return not not io.output().tty
end

return handler
�� /lib/size.lua      �-- size calculations

local lib = {}

-- if you need more sizes than this, @ me
local sizes = {"K", "M", "G", "T", "P", "E"}
setmetatable(sizes, {
  __index = function(_, k)
    if k > 0 then return "?" end
  end
})

-- override this if you must, but 2^10 is precious.
local UNIT = 1024

function lib.format(n, _)
  if _ then return tostring(n) end
  local i = 0
  
  while n >= UNIT do
    n = n / UNIT
    i = i + 1
  end
  
  return string.format("%.1f%s", n, sizes[i] or "")
end

return lib
�� /lib/termio.lua      	#-- terminal I/O library --

local lib = {}

local function getHandler()
  local term = os.getenv("TERM") or "generic"
  return require("termio."..term)
end

-------------- Cursor manipulation ---------------
function lib.setCursor(x, y)
  if not getHandler().ttyOut() then
    return
  end
  io.write(string.format("\27[%d;%dH", y, x))
end

function lib.getCursor()
  if not (getHandler().ttyIn() and getHandler().ttyOut()) then
    return 1, 1
  end

  io.write("\27[6n")
  
  getHandler().setRaw(true)
  local resp = ""
  
  repeat
    local c = io.read(1)
    resp = resp .. c
  until c == "R"

  getHandler().setRaw(false)
  local y, x = resp:match("\27%[(%d+);(%d+)R")

  return tonumber(x), tonumber(y)
end

function lib.getTermSize()
  local cx, cy = lib.getCursor()
  lib.setCursor(9999, 9999)
  
  local w, h = lib.getCursor()
  lib.setCursor(cx, cy)

  return w, h
end

function lib.cursorVisible(vis)
  getHandler().cursorVisible(vis)
end

----------------- Keyboard input -----------------
local patterns = {}

local substitutions = {
  A = "up",
  B = "down",
  C = "right",
  D = "left",
  ["5"] = "pageUp",
  ["6"] = "pageDown"
}

local function getChar(char)
  local byte = string.unpack("<I"..#char, char)
  if byte + 96 > 255 then
    return utf8.char(byte)
  end
  return string.char(96 + byte)
end

function lib.readKey()
  getHandler().setRaw(true)
  local data = io.stdin:read(1)
  local key, flags
  flags = {}

  if data == "\27" then
    local intermediate = io.stdin:read(1)
    if intermediate == "[" then
      data = ""

      repeat
        local c = io.stdin:read(1)
        data = data .. c
        if c:match("[a-zA-Z]") then
          key = c
        end
      until c:match("[a-zA-Z]")

      flags = {}

      for pat, keys in pairs(patterns) do
        if data:match(pat) then
          flags = keys
        end
      end

      key = substitutions[key] or "unknown"
    else
      key = io.stdin:read(1)
      flags = {alt = true}
    end
  elseif data:byte() > 31 and data:byte() < 127 then
    key = data
  elseif data:byte() == (getHandler().keyBackspace or 127) then
    key = "backspace"
  elseif data:byte() == (getHandler().keyDelete or 8) then
    key = "delete"
  else
    key = getChar(data)
    flags = {ctrl = true}
  end

  getHandler().setRaw(false)

  return key, flags
end

return lib
�� /lib/futil.lua      ~-- futil: file transfer utilities --

local fs = require("filesystem")
local path = require("path")
local text = require("text")

local lib = {}

-- recursively traverse a directory, generating a tree of all filenames
function lib.tree(dir, modify, rootfs)
  checkArg(1, dir, "string")
  checkArg(2, modify, "table", "nil")
  checkArg(3, rootfs, "string", "nil")

  local abs = path.canonical(dir)
  local mounts = fs.mounts()
  local nrootfs = "/"

  for k, v in pairs(mounts) do
    if #nrootfs < #k then
      if abs:match("^"..text.escape(k)) then
        nrootfs = k
      end
    end
  end

  rootfs = rootfs or nrootfs
  
  -- TODO: make this smarter
  if rootfs ~= nrootfs then
    io.stderr:write("futil: not leaving origin filesystem\n")
    return modify or {}
  end
  
  local files, err = fs.list(abs)
  
  if not files then
    return nil, dir .. ": " .. err
  end

  table.sort(files)

  local ret = modify or {}
  for i=1, #files, 1 do
    local full = string.format("%s/%s", abs, files[i], rootfs)
    local info, err = fs.stat(full)
    
    if not info then
      return nil, full .. ": " .. err
    end

    ret[#ret + 1] = path.clean(string.format("%s/%s", dir, files[i]))
    
    if info.isDirectory then
      local _, err = lib.tree(string.format("%s/%s", dir, files[i]), ret, root)
      if not _ then
        return nil, err
      end
    end
  end

  return ret
end

return lib
�� /lib/serializer.lua      �-- serializer --

local function ser(va, seen)
  if type(va) ~= "table" then
    if type(va) == "string" then return string.format("%q", tostring(va))
    else return tostring(va) end end
  if seen[va] then return "{recursed}" end
  seen[va] = true
  local ret = "{"
  for k, v in pairs(va) do
    k = ser(k, seen)
    v = ser(v, seen)
    if k and v then
      ret = ret .. string.format("[%s]=%s,", k, v)
    end
  end
  return ret .. "}"
end

return function(tab)
  return ser(tab, {})
end
�� /lib/tokenizer.lua      	i-- some sort of parser library

local lib = {}

local function esc(c)
  return c:gsub("[%[%]%(%)%.%+%-%*%%%^%$%?]", "%%%1")
end

function lib:matchToken()
  local tok = ""
  local splitter = "[" .. self.brackets .. self.splitters .. "]"
  if self.i >= #self.text then return nil end
  for i=self.i, #self.text, 1 do
    self.i = i + 1
    local c = self.text:sub(i,i)
    if #self.splitters > 0 and c:match(splitter) and #tok == 0 then
      if (not self.discard_whitespace) or (c ~= " " and c ~= "\n") then
        if #self.brackets > 0 and c:match("["..self.brackets.."]") then
          return c, "bracket"
        elseif self.text:sub(i+1,i+1):match(splitter) then
          tok = c
        else
          return c, "splitter"
        end
      end
    elseif #self.splitters > 0 and c:match(splitter) and #tok > 0 then
      if (not self.discard_whitespace) or (c ~= " " and c ~= "\n") then
        if tok:match("%"..c) then
          tok = tok .. c
        else
          self.i = self.i - 1
          return tok, (tok:match(splitter) and "splitter") or "word"
        end
      elseif #tok > 0 then
        return tok, (tok:match(splitter) and "splitter") or "word"
      end
    elseif #self.splitters > 0 and tok:match(splitter) and #tok > 0 then
      self.i = self.i - 1
      return tok, "splitter"
    else
      tok = tok .. c
      if self.text:sub(i+1,i+1):match(splitter) then
        for n, v in ipairs(self.words) do
          if tok == v.word then
            return tok, v.type
          end
        end
        for n, v in ipairs(self.matches) do
          if tok:match(v.pattern) then
            return tok, v.type
          end
        end
      end
    end
  end
  return ((#tok > 0 and tok) or nil), #tok > 0 and "word" or nil
end

function lib:addToken(ttype, pow, ptype)
  if ttype == "match" then
    self.matches[#self.matches + 1] = {
      pattern = pow,
      type = ptype or ttype
    }
  elseif ttype == "bracket" then
    self.brackets = self.brackets .. esc(pow)
    self.splitters = self.splitters .. esc(pow)
  elseif ttype == "splitter" then
    self.splitters = self.splitters .. esc(pow)
  else
    self.words[#self.words + 1] = {
      word = pow,
      type = ptype or ttype
    }
  end
end

function lib.new(text)
  return setmetatable({
    words={},
    matches={},
    i=0,
    text=text or"",
    splitters="",
    brackets=""},{__index=lib})
end

return lib
�� /lib/argutil.lua      
�-- argutil: common argument parsing library

local lib = {}

function lib.parse(...)
  local top = table.pack(...)
  local do_done = true
  
  if type(top[1]) == "boolean" then
    do_done = top[1]
    table.remove(top, 1)
  end

  local args, opts = {}, {}
  local done = false
  
  for i=1, #top, 1 do
    local arg = top[i]
    
    if done or arg:sub(1,1) ~= "-" then
      args[#args+1] = arg
    else
      if arg == "--" and do_done then
        done = true
      elseif arg:sub(1,2) == "--" and #arg > 2 then
        local opt, oarg = arg:match("^%-%-(.-)=(.+)")
  
        opt, oarg = opt or arg:sub(3), oarg or true
        opts[opt] = oarg
      elseif arg:sub(1,2) ~= "--" then
        for c in arg:sub(2):gmatch(".") do
          opts[c] = true
        end
      end
    end
  end

  return args, opts
end

function lib.getopt(_opts, ...)
  checkArg(1, _opts, "table")
  local _args = table.pack(...)
  local args, opts = {}, {}
  local skip_next, done = false, false
  for i, arg in ipairs(_args) do
    if skip_next then skip_next = false
    elseif arg:sub(1,1) == "-" and not done then
      if arg == "--" and opts.allow_finish then
        done = true
      elseif arg:match("%-%-(.+)") then
        arg = arg:sub(3)
        if _opts.options[arg] ~= nil then
          if _opts.options[arg] then
            if (not _args[i+1]) then
              io.stderr:write("option '", arg, "' requires an argument\n")
              os.exit(1)
            end
            opts[arg] = _args[i+1]
            skip_next = true
          else
            opts[arg] = true
          end
        elseif _opts.exit_on_bad_opt then
          io.stderr:write("unrecognized option '", arg, "'\n")
          os.exit(1)
        end
      else
        arg = arg:sub(2)
        if _opts.options[arg:sub(1,1)] then
          local a = arg:sub(1,1)
          if #arg == 1 then
            if not _args[i+1] then
              io.stderr:write("option '", arg, "' requires an argument\n")
              os.exit(1)
            end
            opts[a] = _args[i+1]
            skip_next = true
          else
            opts[a] = arg:sub(2)
          end
        else
          for c in arg:gmatch(".") do
            if _opts.options[c] == nil then
              if _opts.exit_on_bad_opt then
                io.stderr:write("unreciognized option '", arg, "'\n")
                os.exit(1)
              end
            elseif _opts.options[c] then
              if not _args[i+1] then
                io.stderr:write("option '", arg, "' requires an argument\n")
                os.exit(1)
              end
              opts[c] = true
            else
              opts[c] = true
            end
          end
        end
      end
    else
      args[#args+1] = arg
    end
  end
  return args, opts
end

return lib
�� /lib/lfs.lua      7-- LuaFileSystem compatibility layer --

local fs = require("filesystem")
local path = require("path")

local lfs = {}

function lfs.attributes(file, optional)
  checkArg(1, file, "string")
  checkArg(2, optional, "string", "table", "nil")
  file = path.canonical(file)

  local out = {}
  if type(optional) == "table" then out = optional end

  local data, err = fs.stat(file)
  if not data then return nil, err end

  out.dev = 0
  out.ino = 0
  out.mode = (data.isDirectory and "directory") or "file"
  out.uid = data.owner
  out.gid = data.group
  out.rdev = 0
  out.access = data.lastModified
  out.modification = data.lastModified
  out.change = data.lastModified
  out.size = data.size
  out.permissions = "rwxrwxrwx" -- TODO do this properly!!
  out.blksize = 0

  if type(optional) == "string" then
    return out[optional]
  end

  return out
end

function lfs.chdir(dir)
  dir = path.canonical(dir)
  if not fs.stat(dir) then
    return nil, "no such file or directory"
  end
  os.setenv("PWD", dir)
  return true
end

function lfs.lock_dir() end

function lfs.currentdir()
  return os.getenv("PWD")
end

function lfs.dir(dir)
  dir = path.canonical(dir)
  local files, err = fs.list(dir)
  if not files then return nil, err end
  local i = 0
  return function()
    i = i + 1
    return files[i]
  end
end

function lfs.lock() end

function lfs.link() end

function lfs.mkdir(dir)
  dir = path.canonical(dir)
  local ok, err = fs.touch(dir, 2)
  if not ok then return nil, err end
  return true
end

function lfs.rmdir(dir)
  dir = path.canonical(dir)
  local ok, err = fs.remove(dir)
  if not ok then return nil, err end
  return true
end

function lfs.setmode() return "binary" end

lfs.symlinkattributes = lfs.attributes

function lfs.touch(f)
  f = path.canonical(f)
  return fs.touch(f)
end

function lfs.unlock() end

return lfs
�� /lib/semver.lua      
c-- semver: Very scrict semantic versioning library --

local lib = {}

local pattern = "^(%d+)%.(%d+)%.(%d+)([%S%-%.a-zA-Z0-9]*)([%S%+%.a-zA-Z0-9]*)$"

function lib.build(version)
  checkArg(1, version, "table")
  checkArg("major", version.major, "number")
  checkArg("minor", version.minor, "number")
  checkArg("patch", version.patch, "number")
  checkArg("prerelease", version.prerelease, "table", "string", "nil")
  checkArg("build", version.build, "table", "string", "nil")
  version.prerelease = version.prerelease or ""
  version.build = version.build or ""
  if type(version.prerelease) == "table" then
    version.prerelease = table.concat(version.prerelease, ".")
  end
  if type(version.build) == "table" then
    version.build = table.concat(version.build, ".")
  end
  if version.prerelease:match("[^%S%-a-zA-Z0-9%.]")
      or version.prerelease:match("%.%.") then
    return nil, "pre-release suffix contains invalid character(s)"
  end
  if version.build:match("[^%S%-a-zA-Z0-9%.]")
      or version.build:match("%.%.") then
    return nil, "build metadata suffix contains invalid character(s)"
  end
  local final = string.format("%d.%d.%d", version.major, version.minor,
    version.patch)
  if #version.prerelease > 0 then
    final = final .. "-" .. version.prerelease
  end
  if #version.build > 0 then
    final = final .. "+" .. version.build
  end
  return final
end

function lib.parse(vers)
  checkArg(1, vers, "string")
  local maj, min, pat, pre, build = vers:match(pattern)
  if not maj then
    return nil, "invalid version string"
  end

  if pre:sub(1,1) == "+" then
    build = pre
    pre = ""
  end
  pre = pre:sub(2)
  build = build:sub(2)
  if build:match("%+") then
    return nil, "invalid build metadata"
  end

  local pt, bt = {}, {}
  for ent in pre:gmatch("[^%.]+") do
    pt[#pt + 1] = ent
  end
  for ent in build:gmatch("[^.]+") do
    bt[#bt + 1] = ent
  end

  return {
    major = tonumber(maj),
    minor = tonumber(min),
    patch = tonumber(pat),
    prerelease = pt,
    build = bt
  }
end

local function cmp_pre(a, b)
  for i=1, #a, 1 do
    if not b[i] then return true end
    if type(a[i]) == type(b[i]) then
      if a[i] > b[i] then
        return true
      end
    elseif type(a[i]) == "string" then
      return true
    end
  end
  return false
end

-- if v1 > v2
function lib.isGreater(v1, v2)
  checkArg(1, v1, "table")
  checkArg(2, v2, "table")
  return (
    v1.major > v2.major or
    v1.minor > v2.minor or
    v1.patch > v2.patch or
    (#v1.prerelease == 0 and #v2.prerelease > 0) or
    cmp_pre(v1.prerelease, v2.prerelease) or
    #v1.prerelease > #v2.prerelease
  )
end

return lib
�� /lib/upm.lua      1�-- UPM: the ULOS Package Manager, but a library version --

local fs = require("filesystem")
local path = require("path")
local mtar = require("mtar")
local size = require("size")
local config = require("config")
local semver = require("semver")
local network = require("network")
local computer = require("computer")
local filetypes = require("filetypes")

local pfx = {
  info = "\27[92m::\27[39m ",
  warn = "\27[93m::\27[39m ",
  err = "\27[91m::\27[39m "
}

local function log(opts, ...)
  if opts.v or not opts.q then
    io.stderr:write(...)
    io.stderr:write("\n")
  end
end

local function exit(opts, reason)
  log(opts, pfx.err, reason)
  os.exit(1)
end

local function cmpver(a, b)
  local v1 = semver.parse(a)
  local v2 = semver.parse(b)
  v1.build = nil
  v2.build = nil
  return semver.isGreater(v1, v2) or semver.build(v1) == semver.build(v2)
end

local installed, ipath, preloaded

local lib = {}

function lib.preload(cfg, opts)
  if installed then return end
  ipath = path.concat(opts.root, cfg.General.dataDirectory, "installed.list")

  local ilist = path.concat(opts.root, cfg.General.dataDirectory, "installed.list")
  
  if not fs.stat(ilist) then
    local handle, err = io.open(ilist, "w")
    if not handle then
      exit(opts, "cannot create installed.list: " .. err)
    end
    handle:write("{}")
    handle:close()
  end

  local inst, err = config.table:load(ipath)

  if not inst and err then
    exit(opts, "cannot open installed.list: " .. err)
  end

  installed = inst
  
  lib.installed = installed
end

local search, update, download, extract, install_package, install

function search(cfg, opts, name, re)
  if opts.v then log(opts, pfx.info, "querying repositories for package ", name) end
  local repos = cfg.Repositories
  local results = {}
  for k, v in pairs(repos) do
    if opts.v then log(opts, pfx.info, "searching list ", k) end
    local data, err = config.table:load(path.concat(opts.root,
      cfg.General.dataDirectory, k .. ".list"))
    if not data then
      log(opts, pfx.warn, "list ", k, " is nonexistent; run 'upm update' to refresh")
      if err then log(opts, pfx.warn, "(err: ", err, ")") end
    else
      local found
      if data.packages[name] then
        if re then
          found = true
          results[#results+1] = {data.packages[name], k, name}
        else
          return data.packages[name], k
        end
      end
      if re and not found then
        for nk,v in pairs(data.packages) do
          if nk:match(name) then
            results[#results+1] = {data.packages[nk], k, nk}
          end
        end
      end
    end
  end
  if re then
    local i = 0
    return function()
      i = i + 1
      if results[i] then return table.unpack(results[i]) end
    end
  end
  exit(opts, "package " .. name .. " not found")
end

function update(cfg, opts)
  log(opts, pfx.info, "refreshing package lists")
  local repos = cfg.Repositories
  for k, v in pairs(repos) do
    log(opts, pfx.info, "refreshing list: ", k)
    local url = v .. "/packages.list"
    download(opts, url, path.concat(opts.root, cfg.General.dataDirectory, k .. ".list"))
  end
end

local function progress(na, nb, a, b)
  local n = math.floor(0.3 * (na / nb * 100))
  io.stdout:write("\27[G[" ..
    ("#"):rep(n) .. ("-"):rep(30 -  n)
    .. "] (" .. a .. "/" .. b .. ")")
  io.stdout:flush()
end

function download(opts, url, dest, total)
  log(opts, pfx.warn, "downloading ", url, " as ", dest)
  local out, err = io.open(dest, "w")
  if not out then
    exit(opts, dest .. ": " .. err)
  end

  local handle, err = network.request(url)
  if not handle then
    out:close() -- just in case
    exit(opts, err)
  end

  local dl = 0
  local lbut = 0

  if total then io.write("\27[G\27[2K[]") io.stdout:flush() end
  repeat
    local chunk = handle:read(2048)
    if chunk then dl = dl + #chunk out:write(chunk) end
    if total then
      if computer.uptime() - lbut > 0.5 or dl >= total then
        lbut = computer.uptime()
        progress(dl, total, size.format(dl), size.format(total))
      end
    end
  until not chunk
  handle:close()
  out:close()
  if total then io.write("\27[G\27[K") end
end

function extract(cfg, opts, package)
  log(opts, pfx.info, "extracting ", package)
  local base, err = io.open(package, "r")
  if not base then
    exit(opts, package .. ": " .. err)
  end
  local files = {}
  for file, diter, len in mtar.unarchive(base) do
    files[#files+1] = file
    if opts.v then
      log(opts, "  ", pfx.info, "extract file: ", file, " (length ", len, ")")
    end
    local absolute = path.concat(opts.root, file)
    local segments = path.split(absolute)
    for i=1, #segments - 1, 1 do
      local create = table.concat(segments, "/", 1, i)
      if not fs.stat(create) then
        local ok, err = fs.touch(create, filetypes.directory)
        if not ok and err then
          log(opts, pfx.err, "failed to create directory " .. create .. ": " .. err)
          exit(opts, "leaving any already-created files - manual cleanup may be required!")
        end
      end
    end
    if opts.v then
      log(opts, "   ", pfx.info, "writing to: ", absolute)
    end
    local handle, err = io.open(absolute, "w")
    if not handle then
      exit(opts, absolute .. ": " .. err)
    end
    while len > 0 do
      local chunk = diter(math.min(len, 2048))
      if not chunk then break end
      len = len - #chunk
      handle:write(chunk)
    end
    handle:close()
  end
  base:close()
  log(opts, pfx.info, "ok")
  return files
end

function install_package(cfg, opts, name)
  local data, err = search(cfg, opts, name)
  if not data then
    exit(opts, "failed reading metadata for package " .. name .. ": " .. err)
  end
  local old_data = installed[name] or {info={version=0},files={}}
  local files = extract(cfg, opts, path.concat(opts.root, cfg.General.cacheDirectory, name .. ".mtar"))
  installed[name] = {info = data, files = files}
  config.table:save(ipath, installed)

  -- remove files that were previously present in this package but aren't
  -- anymore.  TODO: check for file ownership by other packages, and remove
  -- directories.
  local files_to_remove = {}
  local map = {}
  for k, v in pairs(files) do map[v] = true end
  for i, check in ipairs(old_data.files) do
    if not map[check] then
      files_to_remove[#files_to_remove+1] = check
    end
  end
  if #files_to_remove > 0 then
    os.execute("rm -rf " .. table.concat(files_to_remove, " "))
  end
end

local function dl_pkg(cfg, opts, name, repo, data)
  download(opts,
    cfg.Repositories[repo] .. data.mtar,
    path.concat(opts.root, cfg.General.cacheDirectory, name .. ".mtar"),
    data.size)
end

local function install(cfg, opts, packages)
  if #packages == 0 then
    exit(opts, "no packages to install")
  end
  
  local to_install, total_size = {}, 0
  local resolve, resolving = nil, {}
  resolve = function(pkg)
    local data, repo = search(cfg, opts, pkg)
    if installed[pkg] and cmpver(installed[pkg].info.version, data.version)
        and not opts.f then
      log(opts, pfx.err, pkg .. ": package is already installed")
    elseif resolving[pkg] then
      log(opts, pfx.warn, pkg .. ": circular dependency detected")
    else
      to_install[pkg] = {data = data, repo = repo}
      if data.dependencies then
        local orp = resolving[pkg]
        resolving[pkg] = true
        for i, dep in pairs(data.dependencies) do
          resolve(dep)
        end
        resolving[pkg] = orp
      end
    end
  end

  log(opts, pfx.info, "resolving dependencies")
  for i=1, #packages, 1 do
    resolve(packages[i])
  end

  log(opts, pfx.info, "checking for package conflicts")
  for k, v in pairs(to_install) do
    for _k, _v in pairs(installed) do
      if _v.info.conflicts then
        for __k, __v in pairs(_v.info.conflicts) do
          if k == __v then
            log(opts, pfx.err, "installed package ", _k, " conflicts with package ", __v)
            os.exit(1)
          end
        end
      end
    end
    if v.data.conflicts then
      for _k, _v in pairs(v.data.conflicts) do
        if installed[_v] then
          log(opts, pfx.err, "package ", k, " conflicts with installed package ", _v)
          os.exit(1)
        elseif _v ~= k and to_install[_v] then
          log(opts, pfx.err, "cannot install conflicting packages ", k, " and ", _v)
          os.exit(1)
        end
      end
    end
  end

  local largest = 0
  log(opts, pfx.info, "packages to install:")
  for k, v in pairs(to_install) do
    total_size = total_size + (v.data.size or 0)
    largest = math.max(largest, v.data.size)
    io.write("  " .. k .. "-" .. v.data.version)
  end

  io.write("\n\nTotal download size: " .. size.format(total_size) .. "\n")
  io.write("Space required: " .. size.format(total_size + largest) .. "\n")
  
  if not opts.y then
    io.write("Continue? [Y/n] ")
    repeat
      local c = io.read("l")
      if c == "n" then os.exit() end
      if c ~= "y" and c ~= "" then io.write("Please enter 'y' or 'n': ") end
    until c == "y" or c == ""
  end

  log(opts, pfx.info, "downloading packages")
  for k, v in pairs(to_install) do
    dl_pkg(cfg, opts, k, v.repo, v.data)
  end

  log(opts, pfx.info, "installing packages")
  for k, v in pairs(to_install) do
    install_package(cfg, opts, k, v)
    -- remove package mtar - it just takes up space now
    fs.remove(path.concat(opts.root, cfg.General.cacheDirectory,
      k .. ".mtar"))
  end
end

local function remove(cfg, opts, args)
  local rm = assert(loadfile("/bin/rm.lua"))
  
  log(opts, pfx.info, "packages to remove: ")
  io.write(table.concat(args, "  "), "\n")

  if not opts.y then
    io.write("\nContinue? [Y/n] ")
    repeat
      local c = io.read("l")
      if c == "n" then os.exit() end
      if c ~= "y" and c ~= "" then io.write("Please enter 'y' or 'n': ") end
    until c == "y" or c == ""
  end

  for i=1, #args, 1 do
    local ent = installed[args[i]]
    if not ent then
      log(opts, pfx.err, "package ", args[i], " is not installed")
    else
      log(opts, pfx.info, "removing files")
      local removed = 0
      io.write("\27[G\27[2K")
      for i, file in ipairs(ent.files) do
        removed = removed + 1
        rm("-rf", path.concat(opts.root, file))
        progress(removed, #ent.files, tostring(removed), tostring(#ent.files))
      end
      io.write("\27[G\27[2K")
      log(opts, pfx.info, "unregistering package")
      installed[args[i]] = nil
    end
  end
  config.table:save(ipath, installed)
end

function lib.upgrade(cfg, opts)
  local to_upgrade = {}
  for k, v in pairs(installed) do
    local data, repo = search(cfg, opts, k)
    if not (installed[k] and cmpver(installed[k].info.version, data.version)
        and not opts.f) then
      log(opts, pfx.info, "updating ", k)
      to_upgrade[#to_upgrade+1] = k
    end
  end
  install(cfg, opts, to_upgrade)
end

function lib.cli_search(cfg, opts, args)
  lib.preload()
  for i=1, #args, 1 do
    for data, repo, name in search(cfg, opts, args[i], true) do
      io.write("\27[94m", repo, "\27[39m/", name, "\27[90m-",
        data.version, "\27[37m ",
        installed[name] and "\27[96m(installed)\27[39m" or "", "\n")
      io.write("  \27[92mAuthor: \27[39m", data.author or "(unknown)", "\n")
      io.write("  \27[92mDesc: \27[39m", data.description or
        "(no description)", "\n")
    end
  end
end

function lib.cli_list(cfg, opts, args)
  if args[1] == "installed" then
    for k in pairs(installed) do
      print(k)
    end
  elseif args[1] == "all" or not args[1] then
    for k, v in pairs(cfg.Repositories) do
      if opts.v then log(pfx.info, "searching list ", k) end
      local data, err = config.table:load(path.concat(opts.root,
        cfg.General.dataDirectory, k .. ".list"))
      if not data then
        log(pfx.warn,"list ", k, " is nonexistent; run 'upm update' to refresh")
        if err then log(pfx.warn, "(err: ", err, ")") end
      else
        for p in pairs(data.packages) do
          --io.stderr:write(p, "\n")
          print(p)
        end
      end
    end
  elseif cfg.Repositories[args[1]] then
    local data, err = config.table:load(path.concat(opts.root,
      cfg.General.dataDirectory, args[1] .. ".list"))
    if not data then
      log(pfx.warn, "list ", args[1], " is nonexistent; run 'upm update' to refresh")
      if err then log(pfx.warn, "(err: ", err, ")") end
    else
      for p in pairs(data.packages) do
        print(p)
      end
    end
  else
    exit("cannot determine target '" .. args[1] .. "'")
  end
end

lib.search=search
lib.update=update
lib.download=download
lib.download_package = dl_pkg
lib.extract=extract
lib.install_package=install_package
lib.install=install
lib.remove=remove

return lib
�� /lib/readline.lua      �-- at long last, a proper readline library --

local termio = require("termio")

local rlid = 0

local function readline(opts)
  checkArg(1, opts, "table", "nil")
  
  local uid = rlid + 1
  rlid = uid
  opts = opts or {}
  if opts.prompt then io.write(opts.prompt) end

  local history = opts.history or {}
  history[#history+1] = ""
  local hidx = #history
  
  local buffer = ""
  local cpos = 0

  local w, h = termio.getTermSize()
  
  while true do
    local key, flags = termio.readKey()
    flags = flags or {}
    if not (flags.ctrl or flags.alt) then
      if key == "up" then
        if hidx > 1 then
          if hidx == #history then
            history[#history] = buffer
          end
          hidx = hidx - 1
          local olen = #buffer - cpos
          cpos = 0
          buffer = history[hidx]
          if olen > 0 then io.write(string.format("\27[%dD", olen)) end
          local cx, cy = termio.getCursor()
          if cy < h then
            io.write(string.format("\27[K\27[B\27[J\27[A%s", buffer))
          else
            io.write(string.format("\27[K%s", buffer))
          end
        end
      elseif key == "down" then
        if hidx < #history then
          hidx = hidx + 1
          local olen = #buffer - cpos
          cpos = 0
          buffer = history[hidx]
          if olen > 0 then io.write(string.format("\27[%dD", olen)) end
          local cx, cy = termio.getCursor()
          if cy < h then
            io.write(string.format("\27[K\27[B\27[J\27[A%s", buffer))
          else
            io.write(string.format("\27[K%s", buffer))
          end
        end
      elseif key == "left" then
        if cpos < #buffer then
          cpos = cpos + 1
          io.write("\27[D")
        end
      elseif key == "right" then
        if cpos > 0 then
          cpos = cpos - 1
          io.write("\27[C")
        end
      elseif key == "backspace" then
        if cpos == 0 and #buffer > 0 then
          buffer = buffer:sub(1, -2)
          io.write("\27[D \27[D")
        elseif cpos < #buffer then
          buffer = buffer:sub(0, #buffer - cpos - 1) ..
            buffer:sub(#buffer - cpos + 1)
          local tw = buffer:sub((#buffer - cpos) + 1)
          io.write(string.format("\27[D%s \27[%dD", tw, cpos + 1))
        end
      elseif #key == 1 then
        local wr = true
        if cpos == 0 then
          buffer = buffer .. key
          io.write(key)
          wr = false
        elseif cpos == #buffer then
          buffer = key .. buffer
        else
          buffer = buffer:sub(1, #buffer - cpos) .. key ..
            buffer:sub(#buffer - cpos + 1)
        end
        if wr then
          local tw = buffer:sub(#buffer - cpos)
          io.write(string.format("%s\27[%dD", tw, #tw - 1))
        end
      end
    elseif flags.ctrl then
      if key == "m" then -- enter
        if cpos > 0 then io.write(string.format("\27[%dC", cpos)) end
        io.write("\n")
        break
      elseif key == "a" and cpos < #buffer then
        io.write(string.format("\27[%dD", #buffer - cpos))
        cpos = #buffer
      elseif key == "e" and cpos > 0 then
        io.write(string.format("\27[%dC", cpos))
        cpos = 0
      elseif key == "d" and not opts.noexit then
        io.write("\n")
        ; -- this is a weird lua quirk
        (type(opts.exit) == "function" and opts.exit or os.exit)()
      elseif key == "i" then -- tab
        if type(opts.complete) == "function" and cpos == 0 then
          local obuffer = buffer
          buffer = opts.complete(buffer, rlid) or buffer
          if obuffer ~= buffer and #obuffer > 0 then
            io.write(string.format("\27[%dD", #obuffer - cpos))
            cpos = 0
            local cx, cy = termio.getCursor()
            if cy < h then
              io.write(string.format("\27[K\27[B\27[J\27[A%s", buffer))
            else
              io.write(string.format("\27[K%s", buffer))
            end
          end
        end
      end
    end
  end

  history[#history] = nil
  return buffer
end

return readline
�� /lib/text.lua      m-- text utilities

local lib = {}

function lib.escape(str)
  return (str:gsub("[%[%]%(%)%$%%%^%*%-%+%?%.]", "%%%1"))
end

function lib.split(text, split)
  checkArg(1, text, "string")
  checkArg(2, split, "string", "table")
  
  if type(split) == "string" then
    split = {split}
  end

  local words = {}
  local pattern = "[^" .. lib.escape(table.concat(split)) .. "]+"

  for word in text:gmatch(pattern) do
    words[#words + 1] = word
  end

  return words
end

function lib.padRight(n, text, c)
  return ("%s%s"):format((c or " "):rep(n - #text), text)
end

function lib.padLeft(n, text, c)
  return ("%s%s"):format(text, (c or " "):rep(n - #text))
end

-- default behavior is to fill rows first because that's much easier
-- TODO: implement column-first sorting
function lib.mkcolumns(items, args)
  checkArg(1, items, "table")
  checkArg(2, args, "table", "nil")
  
  local lines = {""}
  local text = {}
  args = args or {}
  -- default max width 50
  args.maxWidth = args.maxWidth or 50
  
  table.sort(items)
  
  if args.hook then
    for i=1, #items, 1 do
      text[i] = args.hook(items[i]) or items[i]
    end
  end

  local longest = 0
  for i=1, #items, 1 do
    longest = math.max(longest, #items[i])
  end

  longest = longest + (args.spacing or 1)

  local n = 0
  for i=1, #text, 1 do
    text[i] = string.format("%s%s", text[i], (" "):rep(longest - #items[i]))
    
    if longest * (n + 1) + 1 > args.maxWidth and #lines[#lines] > 0 then
      n = 0
      lines[#lines + 1] = ""
    end
    
    lines[#lines] = string.format("%s%s", lines[#lines], text[i])

    n = n + 1
  end

  return table.concat(lines, "\n")
end

-- wrap text, ignoring VT100 escape codes but preserving them.
function lib.wrap(text, width)
  checkArg(1, text, "string")
  checkArg(2, width, "number")
  local whitespace = "[ \t\n\r]"
  local splitters = "[ %=%+]"
  local ws_sp = whitespace:sub(1,-2) .. splitters:sub(2)

  local odat = ""

  local len = 0
  local invt = false
  local esc_len = 0
  for c in text:gmatch(".") do
    odat = odat .. c
    if invt then
      esc_len = esc_len + 1
      if c:match("[a-zA-Z]") then invt = false end
    elseif c == "\27" then
      esc_len = esc_len + 1
      invt = true
    else
      len = len + 1
      if c == "\n" then
        len = 0
        esc_len = 0
      elseif len >= width then
        local last = odat:reverse():find(splitters)
        local last_nl = odat:reverse():find("\n") or 0
        local indt = odat:sub(-last_nl + 1):match("^ *") or ""
        
        if last and (last - esc_len) < (width // 4) and last > 1 and
            not c:match(ws_sp) then
          odat = odat:sub(1, -last) .. "\n" .. indt .. odat:sub(-last + 1)
          len = last + #indt - 1
        else
          odat = odat .. "\n" .. indt
          len = #indt
        end
      end
    end
  end
  if odat:sub(-1) ~= "\n" then odat = odat .. "\n" end

  return odat
end

return lib
�� /lib/config.lua      �-- config --

local serializer = require("serializer")

local lib = {}

local function read_file(f)
  local handle, err = io.open(f, "r")
  if not handle then return nil, err end
  return handle:read("a"), handle:close()
end

local function write_file(f, d)
  local handle, err = io.open(f, "w")
  if not handle then return nil, err end
  return true, handle:write(d), handle:close()
end

local function new(self)
  return setmetatable({}, {__index = self})
end

---- table: serialized lua tables ----
lib.table = {new = new}

function lib.table:load(file)
  checkArg(1, file, "string")
  local data, err = read_file(file)
  if not data then return nil, err end
  local ok, err = load("return " .. data, "=(config@"..file..")", "t", _G)
  if not ok then return nil, err end
  return ok()
end

function lib.table:save(file, data)
  checkArg(1, file, "string")
  checkArg(2, data, "table")
  return write_file(file, serializer(data))
end

---- bracket: see example ----
-- [header]
-- key1=value2
-- key2 = [ value1, value3,"value_fortyTwo"]
-- key15=[val5,v7 ]
lib.bracket = {new=new}

local patterns = {
  bktheader = "^%[([%w_-]+)%]$",
  bktkeyval = "^([%w_-]+) ?= ?(.+)",
}

local function pval(v)
  if v:sub(1,1):match("[\"']") and v:sub(1,1) == v:sub(-1) then
    v = v:sub(2,-2)
  elseif v == "true" then
    v = true
  elseif v == "false" then
    v = false
  else
    v = tonumber(v) or v
  end
  return v
end

function lib.bracket:load(file)
  checkArg(1, file, "string")
  local handle, err = io.open(file, "r")
  if not handle then return nil, err end
  local cfg = {}
  local header
  cfg.__load_order = {}
  for line in handle:lines("l") do
    if line:match(patterns.bktheader) then
      header = line:match(patterns.bktheader)
      cfg[header] = {__load_order = {}}
      cfg.__load_order[#cfg.__load_order + 1] = header
    elseif line:match(patterns.bktkeyval) and header then
      local key, val = line:match(patterns.bktkeyval)
      if val:sub(1,1)=="[" and val:sub(-1)=="]" then
        local _v = val:sub(2,-2)
        val = {}
        if #_v > 0 then
          for _val in _v:gmatch("[^,]+") do
            _val=_val:gsub("^ +","") -- remove starting spaces
            val[#val+1] = pval(_val)
          end
        end
      else
        val = pval(val)
      end
      cfg[header].__load_order[#cfg[header].__load_order + 1] = key
      cfg[header][key] = val
    end
  end
  handle:close()
  return cfg
end

function lib.bracket:save(file, cfg)
  checkArg(1, file, "string")
  checkArg(2, cfg, "table")
  local data = ""
  for ind, head in ipairs(cfg.__load_order) do
    local k, v = head, cfg[head]
    data = data .. string.format("%s[%s]", #data > 0 and "\n\n" or "", k)
    for _i, _hd in ipairs(v.__load_order) do
    --for _k, _v in pairs(v) do
      local _k, _v = _hd, v[_hd]
      data = data .. "\n" .. _k .. "="
      if type(_v) == "table" then
        data = data .. "["
        for kk, vv in ipairs(_v) do
          data = data .. serializer(vv) .. (kk < #_v and "," or "")
        end
        data = data .. "]"
      else
        data = data .. serializer(_v)
      end
    end
  end

  data = data .. "\n"

  return write_file(file, data)
end

return lib
�� /lib/mtar.lua      .-- mtar library --

local path = require("path")

local stream = {}

local formats = {
  [0] = { name = ">I2", len = ">I2" },
  [1] = { name = ">I2", len = ">I8" },
}

function stream:writefile(name, data)
  checkArg(1, name, "string")
  checkArg(2, data, "string")
  if self.mode ~= "w" then
    return nil, "cannot write to read-only stream"
  end

  return self.base:write(string.pack(">I2I1", 0xFFFF, 1)
    .. string.pack(formats[1].name, #name) .. name
    .. string.pack(formats[1].len, #data) .. data)
end

function stream:close()
  self.base:close()
end

local mtar = {}

-- this is Izaya's MTAR parsing code because apparently mine sucks
-- however, this is re-indented in a sane way, with argument checking added
function mtar.unarchive(stream)
  checkArg(1, stream, "FILE*")
  local remain = 0
  local function read(n)
    local rb = stream:read(math.min(n,remain))
    if remain == 0 or not rb then
      return nil
    end
    remain = remain - rb:len()
    return rb
  end
  return function()
    while remain > 0 do
      remain=remain-#(stream:read(math.min(remain,2048)) or " ")
    end
    local version = 0
    local nd = stream:read(2) or "\0\0"
    if #nd < 2 then return end
    local nlen = string.unpack(">I2", nd)
    if nlen == 0 then
      return
    elseif nlen == 65535 then -- versioned header
      version = string.byte(stream:read(1))
      nlen = string.unpack(formats[version].name,
        stream:read(string.packsize(formats[version].name)))
    end
    local name = path.clean(stream:read(nlen))
    remain = string.unpack(formats[version].len,
      stream:read(string.packsize(formats[version].len)))
    return name, read, remain
  end
end

function mtar.archive(base)
  checkArg(1, base, "FILE*")
  return setmetatable({
    base = base,
    mode = "w"
  }, {__index = stream})
end

return mtar
�� 	/init.lua      -- cynosure loader --

local fs = component.proxy(computer.getBootAddress())
local gpu = component.proxy(component.list("gpu", true)())
gpu.bind(gpu.getScreen() or (component.list("screen", true)()))
gpu.setResolution(50, 16)
local b, w = 0, 0xFFFFFF
gpu.setForeground(b)
gpu.setBackground(w)
gpu.set(1, 1, "            Cynosure Kernel Loader v1             ")
gpu.setBackground(b)
gpu.setForeground(w)

local function readFile(f, p)
  local handle
  if p then
    handle = fs.open(f, "r")
    if not handle then return "" end
  else
    handle = assert(fs.open(f, "r"))
  end
  local data = ""
  repeat
    local chunk = fs.read(handle, math.huge)
    data = data .. (chunk or "")
  until not chunk
  fs.close(handle)
  return data
end

local function status(x, y, t, c)
  if c then gpu.fill(1, y+1, 50, 1, " ") end
  gpu.set(x, y+1, t)
end

status(1, 1, "Reading configuration")

local cfg = {}
do
  local data = readFile("/boot/cldr.cfg", true)
  for line in data:gmatch("[^\n]+") do
    local word, arg = line:match("([^ ]+) (.+)")
    if word and arg then cfg[word] = tonumber(arg) or arg end
  end

  local flags = cfg.flags or "loglevel=2 root=UUID="..computer.getBootAddress()
  cfg.flags = {}
  for word in flags:gmatch("[^ ]+") do
    cfg.flags[#cfg.flags+1] = word
  end
  cfg.path = cfg.path or "/boot/cynosure.lua"
end

status(1, 2, "Loading kernel from " .. cfg.path)
status(1, 3, "Kernel flags: " .. table.concat(cfg.flags, " "))

assert(xpcall(assert(load(readFile(cfg.path), "="..cfg.path, "t", _G)), debug.traceback, table.unpack(cfg.flags)))
�� /bin/clear.lua      6-- coreutils: clear --

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: clear
Clears the screen by writing to standard output.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

if io.stdout.tty then io.stdout:write("\27[2J\27[1H") end
�� /bin/lshw.lua      �-- coreutils: lshw --

local computer = require("computer")

local args, opts = require("argutil").getopt({
  exit_on_bad_opt = true,
  allow_finish = true,
  options = {
    o = false, openos = false,
    f = false, full = false,
    F = true,  filter = true,
    c = false, class = false,
    C = false, capacity = false,
    d = false, description = false,
    p = false, product = false,
    w = false, width = false,
    v = false, vendor = false,
    h = false, help = false
  }
}, ...)

if opts.h or opts.help then
  io.stderr:write([[
usage: lshw [options] [address|type] ...
List information about the components installed in
a computer.  If no options are specified, defaults
to -fCcdpwvs.
  -o,--openos       Print outputs like OpenOS's
                    'components' command
  -f,--full         Print full output for every
                    component
  -F,--filter CLASS Filter for this class of component
  -c,--class        Print class information
  -C,--capacity     Print capacity information
  -d,--description  Print descriptions
  -p,--product      Print product name
  -w,--width        Print width information
  -v,--vendor       Print vendor information
  -s,--clock        Print clock rate.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(0)
end

if opts.f or opts.full or not next(opts) then
  for _, opt in ipairs {"f","C","c","d","p","w","v","s"} do
    opts[opt] = true
  end
end

local ok, info = pcall(computer.getDeviceInfo)
if not ok and info then
  io.stderr:write("lshw: computer.getDeviceInfo: ", info, "\n")
  os.exit(1)
end

local function read_file(addr, f)
  local handle, err = io.open(f, "r")
  if not handle then
    return info[addr].class
  end
  local data = handle:read("a")
  handle:close()
  return data
end

local field_filter = {
  capacity = opts.C or opts.capacity,
  description = opts.d or opts.description,
  product = opts.p or opts.product,
  width = opts.w or opts.width,
  vendor = opts.v or opts.vendor,
  clock = opts.s or opts.clock,
  class = opts.c or opts.class
}

local function print_information(address)
  if opts.F or opts.filter then
    if info[address].class ~= (opts.F or opts.filter) then
      return
    end
  end
  local info = info[address]
  if opts.o or opts.openos then
    print(address:sub(1, 13).."...  " ..
      read_file(address,
        "/sys/components/by-address/" .. address:sub(1,6) .. "/type"))
    return
  end
  print(address)
  for k, v in pairs(info) do
    if field_filter[k] then
      if not tonumber(v) then v = string.format("%q", v) end
      print("  " .. k .. ": " .. v)
    end
  end
end

if opts.o or opts.openos then
  print("ADDRESS           TYPE")
end

for k in pairs(info) do
  if #args > 0 then
    for i=1, #args, 1 do
      if args[i] == k:sub(1, #args[i]) then
        print_information(k)
        break
      elseif read_file(k, "/sys/components/by-address/" .. k:sub(1,6)
          .. "/type") == args[i] then
        print_information(k)
        break
      end
    end
  else
    print_information(k)
  end
end
�� /bin/rm.lua      V-- coreutils: rm --

local path = require("path")
local futil = require("futil")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

if opts.help or #args == 0 then
  io.stderr:write([[
usage: rm [-rfv] FILE ...
   or: rm --help
Remove all FILE(s).

Options:
  -r      Recurse into directories.  Only
          necessary on some filesystems.
  -f      Ignore nonexistent files/directories.
  -v      Print the path of every file that is
          directly removed.
  --help  Print this help and exit.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local function exit(...)
  if not opts.f then
    io.stderr:write("rm: ", ...)
    os.exit(1)
  end
end

local function remove(file)
  local abs = path.canonical(file)
  local data, err = filesystem.stat(abs)

  if not data then
    exit("cannot delete '", file, "': ", err, "\n")
  elseif data.isDirectory and opts.r then
    local files = futil.tree(abs)
    for i=#files, 1, -1 do
      remove(files[i])
    end
  end

  if data then
    local ok, err = filesystem.remove(abs)
    if not ok then
      exit("cannot delete '", file, "': ", err, "\n")
    end

    if ok and opts.v then
      io.write("removed ", data.isDirectory and "directory " or "",
        "'", abs, "'\n")
    end
  end
end

for i, file in ipairs(args) do remove(file) end
�� /bin/free.lua      2-- free --

local computer = require("computer")
local size = require("size")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: free [-h]
Prints system memory usage information.

Options:
  -h  Print sizes human-readably.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local function pinfo()
  local total = computer.totalMemory()
  local free = computer.freeMemory()
  
  -- collect garbage
  for i=1, 10, 1 do
    coroutine.yield(0)
  end
  
  local garbage = free - computer.freeMemory()
  local used = total - computer.freeMemory()

  print(string.format(
"total:    %s\
used:     %s\
free:     %s",
    size.format(total, not opts.h),
    size.format(used, not opts.h),
    size.format(computer.freeMemory(), not opts.h)))
end

pinfo()
�� /bin/cp.lua      	�-- coreutils: cp --

local path = require("path")
local futil = require("futil")
local ftypes = require("filetypes")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

if opts.help or #args < 2 then
  io.stderr:write([[
usage: cp [-rv] SOURCE ... DEST
Copy SOURCE(s) to DEST.

Options:
  -r  Recurse into directories.
  -v  Be verbose.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(2)
end

local function copy(src, dest)
  if opts.v then
    print(string.format("'%s' -> '%s'", src, dest))
  end

  local inhandle, err = io.open(src, "r")
  if not inhandle then
    return nil, src .. ": " .. err
  end

  local outhandle, err = io.open(dest, "w")
  if not outhandle then
    return nil, dest .. ": " .. err
  end

  repeat
    local data = inhandle:read(8192)
    if data then outhandle:write(data) end
  until not data

  inhandle:close()
  outhandle:close()

  return true
end

local function exit(...)
  io.stderr:write("cp: ", ...)
  os.exit(1)
end

local dest = path.canonical(table.remove(args, #args))

if #args > 1 then -- multiple sources, dest has to be a directory
  local dstat, err = filesystem.stat(dest)

  if dstat and (not dstat.isDirectory) then
    exit("cannot copy to '", dest, "': target is not a directory\n")
  end
end

local disdir = not not (filesystem.stat(dest) or {}).isDirectory

local function cp(f)
  local file = path.canonical(f)
  
  local stat, err = filesystem.stat(file)
  if not stat then
    exit("cannot stat '", f, "': ", err, "\n")
  end

  if stat.isDirectory then
    if not opts.r then
      exit("cannot copy directory '", f, "'; use -r to recurse\n")
    end
    local tree = futil.tree(file)

    filesystem.touch(dest, ftypes.directory)

    for i=1, #tree, 1 do
      local abs = path.concat(dest, tree[i]:sub(#file + 1))
      local data = filesystem.stat(tree[i])
      if data.isDirectory then
        local ok, err = filesystem.touch(abs, ftypes.directory)
        if not ok then
          exit("cannot create directory ", abs, ": ", err, "\n")
        end
      else
        local ok, err = copy(tree[i], abs)
        if not ok then exit(err, "\n") end
      end
    end
  else
    local dst = dest
    if #args > 1 or disdir then
      local segments = path.split(file)
      dst = path.concat(dest, segments[#segments])
    end
    local ok, err = copy(file, dst)
    if not ok then exit(err, "\n") end
  end
end

for i=1, #args, 1 do cp(args[i]) end
�� /bin/sh.lua      #-- stub that executes other shells
local shells = {"/bin/bsh", "/bin/lsh"}
local fs = require("filesystem")
for i, shell in ipairs(shells) do
  if fs.stat(shell..".lua") then
    assert(loadfile(shell .. ".lua"))()
    os.exit(0)
  end
end
io.stderr:write("sh: no shell found\n")
os.exit(1)
�� /bin/cat.lua      -- cat --

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: cat FILE1 FILE2 ...
Concatenate FILE(s) to standard output.  With no
FILE, or where FILE is -, read standard input.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(0)
end

if #args == 0 then
  args[1] = "-"
end

for i=1, #args, 1 do
  local handle, err

  if args[i] == "-" then
    handle, err = io.input(), "missing stdin"
  else
    handle, err = io.open(require("path").canonical(args[i]), "r")
  end
  
  if not handle then
    io.stderr:write("cat: cannot open '", args[i], "': ", err, "\n")
    os.exit(1)
  else
    for line in handle:lines("L") do
      io.write(line)
    end
    if handle ~= io.input() then handle:close() end
  end
end
�� /bin/passwd.lua      �-- coreutils: passwd --

local sha = require("sha3").sha256
local acl = require("acls")
local users = require("users")
local process = require("process")

local n_args = select("#", ...)
local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: passwd [options] USER
   or: passwd [options]
Generate or modify users.

Options:
  -i, --info      Print the user's info and exit.
  --home=PATH     Set the user's home directory.
  --shell=PATH    Set the user's shell.
  --enable=P,...  Enable user ACLs.
  --disable=P,... Disable user ACLs.
  --clear-acls    Clear ACLs before applying
  --              '--enable'.
  -r, --remove    Remove the specified user.

Note that an ACL may only be set if held by the
current user.  Only root may delete users.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local current = users.attributes(process.info().owner).name
local user = args[1] or current

local _ok, _err = users.get_uid(user)
local attr
if not _ok then
  io.stderr:write("passwd: warning: " .. _err .. "\n")
  attr = {}
else
  local err
  attr, err = users.attributes(_ok)
  if not attr then
    io.stderr:write("passwd: failed getting attributes: " .. err .. "\n")
    os.exit(1)
  end
end

attr.home = opts.home or attr.home or "/home/" .. user
attr.shell = opts.shell or attr.shell or "/bin/lsh"
attr.uid = _ok
attr.name = attr.name or user

local acls = attr.acls or 0
attr.acls = {}
if not opts["clear-acls"] then
  for k, v in pairs(acl.user) do
    if acls & v ~= 0 then
      attr.acls[k] = true
    end
  end
end

if opts.i or opts.info then
  print("uid:   " .. attr.uid)
  print("name:  " .. attr.name)
  print("home:  " .. attr.home)
  print("shell: " .. attr.shell)
  local cacls = {}
  for k,v in pairs(attr.acls) do if v then cacls[#cacls+1] = k end end
  print("acls:  " .. table.concat(cacls, " | "))
  os.exit(0)
elseif opts.r or opts.remove then
  local ok, err = users.remove(attr.uid)
  if not ok then
    io.stderr:write("passwd: cannot remove user: ", err, "\n")
    os.exit(1)
  end
  os.exit(0)
end

if n_args == 0 or (args[1] and args[1] ~= current) then
  local pass
  repeat
    io.stderr:write("password for ", args[1] or current, ": \27[8m")
    pass = io.read()
    io.stderr:write("\27[0m\n")
    if #pass < 4 then
      io.stderr:write("passwd: password too short\n")
    end
  until #pass >= 4

  attr.pass = sha(pass):gsub(".", function(x)
    return string.format("%02x", x:byte()) end)
end

for a in (opts.enable or ""):gmatch("[^,]+") do
  attr.acls[a:upper()] = true
end

for a in (opts.disable or ""):gmatch("[^,]+") do
  attr.acls[a:upper()] = false
end

local function pc(f, ...)
  local result = table.pack(pcall(f, ...))
  if not result[1] and result[2] then
    io.stderr:write("passwd: ", result[2], "\n")
    os.exit(1)
  else
    return table.unpack(result, 2, result.n)
  end
end

local ok, err = pc(users.usermod, attr)

if not ok then
  io.stderr:write("passwd: ", err, "\n")
  os.exit(1)
end
�� /bin/hostname.lua      :-- coreutils: hostname --

local network = require("network")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: hostname
   or: hostname NAME
If NAME is specified, tries to set the system
hostname to NAME; otherwise, prints the current
system hostname.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

if #args == 0 then
  print(network.hostname())
else
  local ok, err = network.sethostname(args[1])
  if not ok then
    io.stderr:write("hostname: sethostname: ", err)
    os.exit(1)
  end
end
�� /bin/lua.lua      �-- lua REPL --

local args = table.pack(...)
local opts = {}

local readline = require("readline")

-- prevent some pollution of _G
local prog_env = {}
for k, v in pairs(_G) do prog_env[k] = v end

local exfile, exargs = nil, {}
local ignext = false
for i=1, #args, 1 do
  if ignext then
    ignext = false
  else
    if args[i] == "-e" and not exfile then
      opts.e = args[i + 1]
      if not opts.e then
        io.stderr:write("lua: '-e' needs argument\n")
        opts.help = true
        break
      end
      ignext = true
    elseif args[i] == "-l" and not exfile then
      local arg = args[i + 1]
      if not arg then
        io.stderr:write("lua: '-l' needs argument\n")
        opts.help = true
        break
      end
      prog_env[arg] = require(arg)
      ignext = true
    elseif (args[i] == "-h" or args[i] == "--help") and not exfile then
      opts.help = true
      break
    elseif args[i] == "-i" and not exfile then
      opts.i = true
    elseif args[i]:match("%-.+") and not exfile then
      io.stderr:write("lua: unrecognized option '", args[i], "'\n")
      opts.help = true
      break
    elseif exfile then
      exargs[#exargs + 1] = args[i]
    else
      exfile = args[i]
    end
  end
end

opts.i = #args == 0

if opts.help then
  io.stderr:write([=[
usage: lua [options] [script [args ...]]
Available options are:
  -e stat  execute string 'stat'
  -i       enter interactive mode after executing 'script'
  -l name  require library 'name' into global 'name'
  -v       show version information

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]=])
  os.exit(1)
end

if opts.e then
  local ok, err = load(opts.e, "=(command line)", "bt", prog_env)
  if not ok then
    io.stderr:write("lua: ", err, "\n")
    os.exit(1)
  else
    local result = table.pack(xpcall(ok, debug.traceback))
    if not result[1] and result[2] then
      io.stderr:write("lua: ", result[2], "\n")
      os.exit(1)
    elseif result[1] then
      print(table.unpack(result, 2, result.n))
    end
  end
end

opts.v = opts.v or opts.i
if opts.v then
  if _VERSION == "Lua 5.2" then
    io.write(_VERSION, "  Copyright (C) 1994-2015 Lua.org, PUC-Rio\n")
  else
    io.write(_VERSION, "  Copyright (C) 1994-2020 Lua.org, PUC-Rio\n")
  end
end

if exfile then
  local ok, err = loadfile(exfile, "t", prog_env)
  if not ok then
    io.stderr:write("lua: ", err, "\n")
    os.exit(1)
  end
  local result = table.pack(xpcall(ok, debug.traceback,
    table.unpack(exargs, 1, #exargs)))
  if not result[1] and result[2] then
    io.stderr:write("lua: ", result[2], "\n")
    os.exit(1)
  end
end

if opts.i or (not opts.e and not exfile) then
  local hist = {}
  local rlopts = {history = hist}
  while true do
    io.write("> ")
    local eval = readline(rlopts)
    hist[#hist+1] = eval
    local ok, err = load("return "..eval, "=stdin", "bt", prog_env)
    if not ok then
      ok, err = load(eval, "=stdin", "bt", prog_env)
    end
    if not ok then
      io.stderr:write(err, "\n")
    else
      local result = table.pack(xpcall(ok, debug.traceback))
      if not result[1] and result[2] then
        io.stderr:write(result[2], "\n")
      elseif result[1] then
        print(table.unpack(result, 2, result.n))
      end
    end
  end
end
�� /bin/edit.lua      v#!/usr/bin/env lua
-- edit: a text editor focused purely on speed --

local termio = require("termio")
local sleep = os.sleep or require("posix.unistd").sleep

local file = ...

local buffer = {""}
local cache = {}
local cl, cp = 1, 0
local scroll = {w = 0, h = 0}

if file then
  local handle = io.open(file, "r")
  if handle then
    buffer[1] = nil
    for line in handle:lines("l") do
      buffer[#buffer+1] = line
    end
    handle:close()
  end
else
  io.stderr:write("usage: edit FILE\n")
  os.exit(1)
end

local w, h = termio.getTermSize()

local function status(msg)
  io.write(string.format("\27[%d;1H\27[30;47m\27[2K%s\27[39;49m", h, msg))
end

local function redraw()
  for i=1, h-1, 1 do
    local n = i + scroll.h
    if not cache[n] then
      cache[n] = true
      io.write(string.format("\27[%d;1H%s\27[K", i, buffer[n] or ""))
    end
  end
  status(string.format("%s | ^W=quit ^S=save ^F=find | %d", file:sub(-16), cl))
  io.write(string.format("\27[%d;%dH",
    cl - scroll.h, math.max(1, math.min(#buffer[cl] - cp + 1, w))))
end

local function sscroll(up)
  if up then
    io.write("\27[T")
    scroll.h = scroll.h - 1
    cache[scroll.h + 1] = false
  else
    io.write("\27[S")
    scroll.h = scroll.h + 1
    cache[scroll.h + h - 1] = false
  end
end

local processKey
processKey = function(key, flags)
  flags = flags or {}
  if flags.ctrl then
    if key == "w" then
      io.write("\27[2J\27[1;1H")
      os.exit()
    elseif key == "s" then
      local handle, err = io.open(file, "w")
      if not handle then
        status(err)
        io.flush()
        sleep(1)
        return
      end
      handle:write(table.concat(buffer, "\n") .. "\n")
      handle:close()
    elseif key == "f" then
      status("find: ")
      io.write("\27[30;47m")
      local pat = io.read()
      io.write("\27[39;49m")
      cache = {}
      for i=cl+1, #buffer, 1 do
        if buffer[i]:match(pat) then
          cl = i
          scroll.h = math.max(0, cl - h + 2)
          return
        end
      end
      redraw()
      status("no match")
      io.flush()
      sleep(1)
    elseif key == "m" then
      table.insert(buffer, cl + 1, "")
      processKey("down")
      cache = {}
    end
  elseif not flags.alt then
    if key == "backspace" or key == "delete" or key == "\8" then
      if #buffer[cl] == 0 then
        processKey("up")
        table.remove(buffer, cl + 1)
        cp = 0
        cache = {}
      elseif cp == 0 and #buffer[cl] > 0 then
        buffer[cl] = buffer[cl]:sub(1, -2)
        cache[cl] = false
      elseif cp < #buffer[cl] then
        local tx = buffer[cl]
        buffer[cl] = tx:sub(0, #tx - cp - 1) .. tx:sub(#tx - cp + 1)
        cache[cl] = false
      end
    elseif key == "up" then
      local clch = false
      if (cl - scroll.h) == 1 and cl > 1 then
        sscroll(true)
        cl = cl - 1
        clch = true
      elseif cl > 1 then
        cl = cl - 1
        clch = true
      end
      if clch then
        local dfe_old = #buffer[cl + 1] - cp
        cp = math.max(0, #buffer[cl] - dfe_old)
      end
    elseif key == "down" then
      local clch = false
      if (cl - scroll.h) >= h - 1 and cl < #buffer then
        cl = cl + 1
        sscroll()
        clch = true
      elseif cl < #buffer then
        cl = cl + 1
        clch = true
      end
      if clch then
        local dfe_old = #buffer[cl - 1] - cp
        cp = math.max(0, #buffer[cl] - dfe_old)
      end
    elseif key == "left" then
      if cp < #buffer[cl] then
        cp = cp + 1
      end
    elseif key == "right" then
      if cp > 0 then
        cp = cp - 1
      end
    elseif #key == 1 then
      if cp == 0 then
        buffer[cl] = buffer[cl] .. key
      else
        buffer[cl] = buffer[cl]:sub(0, -cp - 1) .. key .. buffer[cl]:sub(-cp)
      end
      cache[cl] = false
    end
  end
end

io.write("\27[2J")
while true do
  redraw()
  local key, flags = termio.readKey()
  processKey(key, flags)
end
�� /bin/ps.lua      r-- ps: format information from /proc --

local users = require("users")
local fs = require("filesystem")

local args, opts = require("argutil").parse(...)

local function read(f)
  local handle, err = io.open(f)
  if not handle then
    io.stderr:write("ps: cannot open ", f, ": ", err, "\n")
    os.exit(1)
  end
  local data = handle:read("a")
  handle:close()
  return tonumber(data) or data
end

if opts.help then
  io.stderr:write([[
usage: ps
Format process information from /sys/proc.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(0)
end

local procs = fs.list("/sys/proc")
table.sort(procs, function(a, b) return tonumber(a) < tonumber(b) end)

print("   PID  STATUS     TIME NAME")
for i=1, #procs, 1 do
  local base = string.format("/sys/proc/%d/",
    tonumber(procs[i]))
  local data = {
    name = read(base .. "name"),
    pid = tonumber(procs[i]),
    status = read(base .. "status"),
    owner = users.attributes(read(base .. "owner")).name,
    time = read(base .. "cputime")
  }

  print(string.format("%6d %8s %7s %s", data.pid, data.status,
    string.format("%.2f", data.time), data.name))
end
�� /bin/mkdir.lua      �-- coreutils: mkdir --

local path = require("path")
local ftypes = require("filetypes")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

if opts.help or #args == 0 then
  io.stderr:write([[
usage: mkdir [-p] DIRECTORY ...
Create the specified DIRECTORY(ies), if they do
not exist.

Options:
  -p  Do not exit if the file already exists;
      automatically create parent directories as
      necessary.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

for i=1, #args, 1 do
  local dir = path.canonical(args[i])
  local exists = not not filesystem.stat(dir)
  if exists and not opts.p then
    io.stderr:write("mkdir: ", args[i], ": file already exists\n")
    os.exit(1)
  elseif not exists then
    local seg = path.split(dir)
    local parent = path.clean(table.concat(seg, "/", 1, #seg - 1))
    if opts.p then
      local segments = path.split(parent)
      for n, segment in ipairs(segments) do
        local ok, err = filesystem.touch(path.canonical("/"..
          table.concat(segments, "/", 1, n)), ftypes.directory)
        if not ok and err and err ~= "file already exists" then
          io.stderr:write("mkdir: cannot create directory '", args[i], ": ",
            err, "\n")
          --os.exit(2)
        end
      end
    end
    local ok, err = filesystem.touch(dir, ftypes.directory)
    if not ok and err then
      io.stderr:write("mkdir: cannot create directory '", args[i],
        "': ", err, "\n")
      os.exit(2)
    end
  end
end
�� /bin/lsh.lua      :-- lsh: the Lispish SHell

-- Shell syntax is heavily Lisp-inspired but not entirely Lisp-like.
-- String literals with spaces are supported between double-quotes - otherwise,
-- tokens are separated by whitespace.  A semicolon or EOF marks separation of
-- commands.
-- Everything inside () is evaluated as an expression (or subcommand);  the
-- program's output is tokenized by line and passed to the parent command as
-- arguments, such that `echo 1 2 (seq 3 6) 7 8` becomes `echo 1 2 3 4 5 6 7 8`.
-- This behavior is supported recursively.
-- [] behaves identically to (), except that the exit status of the child
-- command is inserted in place of its output.  An exit status of 0 is generally
-- assumed to mean success, and all non-zero exit statii to indicate failure.
-- Variables may be set with the 'set' builtin, and read with the 'get' builtin.
-- Functions may be declared with the 'def' builtin, e.g.:
-- def example (dir) (cd (get dir); print (get PWD));.
-- Comments are preceded by a # and continue until the next newline character
-- or until EOF.

local readline = require("readline")
local process = require("process")
local fs = require("filesystem")
local paths = require("path")
local pipe = require("pipe")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: lsh
The Lisp-like SHell.  See lsh(1) for details.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

-- Initialize environment --
os.setenv("PWD", os.getenv("PWD") or os.getenv("HOME") or "/")
os.setenv("PS1", os.getenv("PS1") or 
  "<(get USER)@(or (get HOSTNAME) localhost): (or (match (get PWD) \"([^/]+)/?$\") /)> ")
os.setenv("PATH", os.getenv("PATH") or "/bin:/sbin:/usr/bin")

local splitters = {
  ["["] = true,
  ["]"] = true,
  ["("] = true,
  [")"] = true,
  ["#"] = true,
}

local rdr = {
  peek = function(s)
    return s.tokens[s.i]
  end,
  next = function(s)
    s.i = s.i + 1
    return s.tokens[s.i-1]
  end,
  sequence = function(s, b, e)
    local seq = {}
    local bl = 1
    repeat
      local tok = s:next()
      seq[#seq+1] = tok
      if s:peek() == b then bl = bl + 1
      elseif s:peek() == e then bl = bl - 1 end
    until bl == 0 or not s:peek()
    s:next()
    return seq
  end,
}

-- split a command into tokens
local function tokenize(str)
  local tokens = {}
  local token = ""
  local in_str = false

  for c in str:gmatch(".") do
    if c == "\"" then
      in_str = not in_str
      if #token > 0 or not in_str then
        if not in_str then
          token = token
            :gsub("\\e", "\27")
            :gsub("\\n", "\n")
            :gsub("\\a", "\a")
            :gsub("\\27", "\27")
            :gsub("\\t", "\t")
        end
        tokens[#tokens+1] = token
        token = ""
      end
    elseif in_str then
      token = token .. c
    elseif c:match("[ \n\t\r]") then
      if #token > 0 then
        tokens[#tokens+1] = token
        token = ""
      end
    elseif splitters[c] then
      if #token > 0 then tokens[#tokens+1] = token token = "" end
      tokens[#tokens+1] = c
    else
      token = token .. c
    end
  end

  if #token > 0 then tokens[#tokens+1] = token end

  return setmetatable({
    tokens = tokens,
    i = 1
  }, {__index = rdr})
end

local processCommand

-- Call a function, return its exit status,
-- and if 'sub' is true return its output.
local sub = false
local function call(name, func, args, fio, nowait)
  local fauxio
  local function proc()
    local old_exit = os.exit
    local old_exec = os.execute

    function os.exit()
      os.exit = old_exit
      os.execute = old_exec
      old_exit(n)
    end

    os.execute = processCommand

    local ok, err, ret = xpcall(func, debug.traceback, table.unpack(args))

    if (not ok and err) or (not err and ret) then
      io.stderr:write(name, ": ", err or ret, "\n")
      os.exit(127)
    end

    os.exit(0)
  end

  if sub then
    fauxio = setmetatable({
      buffer = "",
      write = function(s, ...)
        s.buffer = s.buffer .. table.concat(table.pack(...)) end,
      read = function() return nil, "bad file descriptor" end,
      seek = function() return nil, "bad file descriptor" end,
      close = function() return true end
    }, {__name = "FILE*"})
  end

  if fio then fauxio = fio end

  local pid = process.spawn {
    func = proc,
    name = name,
    stdin = fio or io.stdin,
    stdout = fauxio or io.stdout,
    stderr = io.stderr,
    input = fio or io.input(),
    output = fauxio or io.output()
  }

  local function awaitThread()
    local exitStatus, exitReason = process.await(pid)

    if exitStatus ~= 0 and exitReason ~= "__internal_process_exit"
        and exitReason ~= "exited" and exitReason and #exitReason > 0 then
      io.stderr:write(name, ": ", exitReason, "\n")
    end

    if not nowait then
      local out
      if fauxio then
        out = {}
        for line in fauxio.buffer:gmatch("[^\n]+") do
          out[#out+1] = line
          end
      end

      return exitStatus, out
    end
  end

  if nowait then
    table.insert(process.info().data.self.threads,
      coroutine.create(awaitThread))
    return true
  else
    return awaitThread()
  end
end

local shenv = process.info().data.env

local builtins = {
  ["or"] = function(a, b)
    if #tostring(a) == 0 then a = nil end
    if #tostring(b) == 0 then b = nil end
    print(a or b or "")
  end,
  ["get"] = function(k)
    if not k then
      io.stderr:write("get: usage: get NAME\nRead environment variables.\n")
      os.exit(1)
    end
    print(shenv[k] or "")
  end,
  ["set"] = function(k, v)
    if not k then
      for k,v in pairs(shenv) do
        print(string.format("%s=%q", k, v))
      end
    else
      shenv[k] = tonumber(v) or v
    end
  end,
  ["cd"] = function(dir)
    if dir == "-" then
      if not shenv.OLDPWD then
        io.stderr:write("cd: OLDPWD not set\n")
        os.exit(1)
      end
      dir = shenv.OLDPWD
      print(dir)
    elseif not dir then
      if not shenv.HOME then
        io.stderr:write("cd: HOME not set\n")
        os.exit(1)
      end
      dir = shenv.HOME
    end
    local cdir = paths.canonical(dir)
    local ok, err = fs.stat(cdir)
    if ok then
      shenv.OLDPWD = shenv.PWD
      shenv.PWD = cdir
    else
      io.stderr:write("cd: ", dir, ": ", err, "\n")
      os.exit(1)
    end
  end,
  ["match"] = function(str, pat)
    if not (str and pat) then
      io.stderr:write("match: usage: match STRING PATTERN\nMatch STRING against PATTERN.\n")
      os.exit(1)
    end
    print(table.concat(table.pack(string.match(str, pat)), "\n"))
  end,
  ["gsub"] = function(str, pat, rep)
    if not (str and pat and rep) then
      io.stderr:write("gsub: usage: gsub STRING PATTERN REPLACE\nReplace all matches of PATTERN with REPLACE.\n")
      os.exit(1)
    end
    print(table.concat(table.pack(string.gsub(str,pat,rep)), "\n"))
  end,
  ["sub"] = function(str, i, j)
    if not (str and tonumber(i) and tonumber(j)) then
      io.stderr:write("sub: usage: sub STRING START END\nPrint a substring of STRING, beginning at index\nSTART and ending at END.\n")
      os.exit(1)
    end
    print(string.sub(str, tonumber(i), tonumber(j)))
  end,
  ["print"] = function(...)
    print(table.concat(table.pack(...), " "))
  end,
  ["time"] = function(...)
    local computer = require("computer")
    local start = computer.uptime()
    os.execute(table.concat(table.pack(...), " "))
    print("\ntook " .. (computer.uptime() - start) .. "s")
  end,
  ["+"] = function(a, b) print((tonumber(a) or 0) + (tonumber(b) or 0)) end,
  ["-"] = function(a, b) print((tonumber(a) or 0) + (tonumber(b) or 0)) end,
  ["/"] = function(a, b) print((tonumber(a) or 0) + (tonumber(b) or 0)) end,
  ["*"] = function(a, b) print((tonumber(a) or 0) + (tonumber(b) or 0)) end,
  ["="] = function(a, b) os.exit(a == b and 0 or 1) end,
  ["into"] = function(...)
    local args = table.pack(...)
    local f = args[1] ~= "-p" and args[1] or args[2]
    if not f then
      io.stderr:write([[
into: usage: into [options] FILE ...
Write all arguments to FILE.

Options:
  -p  Execute the arguments as a program rather
      than taking them literally.
]])
      os.exit(1)
    end
    local name, mode = f:match("(.-):(.)")
    name = name or f
    local handle, err = io.open(name, mode or "w")
    if not handle then
      io.stderr:write("into: ", name, ": ", err, "\n")
      os.exit(1)
    end
    if args[1] == "-p" then
      processCommand(table.concat(args, " ", 3, #args), false,
        handle)
    else
      handle:write(table.concat(table.pack(...), "\n"))
    end
    handle:close()
  end,
  ["seq"] = function(start, finish)
    for i=tonumber(start), tonumber(finish), 1 do
      print(i)
    end
  end
}

-- shebang support is still here despite its also being implemented in the kernel
-- mostly so the shell can resolve the shebang command paths.
local shebang_pattern = "^#!(/.-)\n"

local function loadCommand(path, h, nowait)
  local handle, err = io.open(path, "r")
  if not handle then return nil, path .. ": " .. err end
  local data = handle:read("a")
  handle:close()
  if data:match(shebang_pattern) then
    local shebang = data:match(shebang_pattern)
    if not shebang:match("lua") then
      local executor = loadCommand(shebang, h, nowait)
      return function(...)
        return call(table.concat({shebang, path, ...}, " "), executor,
          {path, ...}, h, nowait)
      end
    else
      data = data:gsub(shebang_pattern, "")
      return load(data, "="..path, "t", _G)
    end
  else
    return load(data, "="..path, "t", _G)
  end
end

local extensions = {
  "lua",
  "lsh"
}

local function resolveCommand(cmd, h, nowait)
  local path = os.getenv("PATH")

  local ogcmd = cmd

  if builtins[cmd] then
    return builtins[cmd]
  end

  local try = paths.canonical(cmd)
  if fs.stat(try) then
    return loadCommand(try, h, nowait)
  end

  for k, v in pairs(extensions) do
    if fs.stat(try .. "." .. v) then
      return loadCommand(try .. "." .. v, h, nowait)
    end
  end

  for search in path:gmatch("[^:]+") do
    local try = paths.canonical(paths.concat(search, cmd))
    if fs.stat(try) then
      return loadCommand(try, h, nowait)
    end

    for k, v in pairs(extensions) do
      if fs.stat(try .. "." .. v) then
        return loadCommand(try .. "." .. v, nowait)
      end
    end
  end

  return nil, ogcmd .. ": command not found"
end

local defined = {}

local processTokens
local function eval(set, h, n)
  local osb = sub
  sub = set.getOutput or sub
  local ok, err = processTokens(set, false, h, n)
  sub = osb
  return ok, err
end

processTokens = function(tokens, noeval, handle, nowait)
  local sequence = {}

  if not tokens.next then tokens = setmetatable({i=1,tokens=tokens},
    {__index = rdr}) end
  
  repeat
    local tok = tokens:next()
    if tok == "(" then
      local subc = tokens:sequence("(", ")")
      subc.getOutput = true
      sequence[#sequence+1] = subc
    elseif tok == "[" then
      local subc = tokens:sequence("[", "]")
      sequence[#sequence+1] = subc
    elseif tok == ")" then
      return nil, "unexpected token ')'"
    elseif tok == "]" then
      return nil, "unexpected token ')'"
    elseif tok ~= "#" then
      if defined[tok] then
        sequence[#sequence+1] = defined[tok]
      else
        sequence[#sequence+1] = tok
      end
    end
  until tok == "#" or not tok

  if #sequence == 0 then return "" end

  if sequence[1] == "def" then
    defined[sequence[2]] = sequence[3]
    sequence = ""
  elseif sequence[1] == "if" then
    local ok, err = eval(sequence[2], handle, nowait)
    if not ok then return nil, err end
    local _ok, _err
    if err == 0 then
      _ok, _err = eval(sequence[3], handle, nowait)
    elseif sequence[4] then
      _ok, _err = eval(sequence[4], handle, nowait)
    else
      _ok = ""
    end
    return _ok, _err
  elseif sequence[1] == "for" then
    local iter, err = eval(sequence[3], handle, nowait)
    if not iter then return nil, err end
    local result = {}
    for i, v in ipairs(iter) do
      shenv[sequence[2]] = v
      local ok, _err = eval(sequence[4], handle, nowait)
      if not ok then return nil, _err end
      result[#result+1] = ok
    end
    shenv[sequence[2]] = nil
    return result
  else
    for i=1, #sequence, 1 do
      if type(sequence[i]) == "table" then
        local ok, err = eval(sequence[i], handle, nowait)
        if not ok then return nil, err end
        sequence[i] = ok
      elseif defined[sequence[i]] then
        local ok, err = eval(defined[sequence[i]], handle, nowait)
        if not ok then return nil, err end
        sequence[i] = ok
      end
    end

    -- expand
    local i = 1
    while true do
      local s = sequence[i]
      if type(s) == "table" then
        table.remove(sequence, i)
        for n=#s, 1, -1 do
          table.insert(sequence, i, s[n])
        end
      end
      i = i + 1
      if i > #sequence then break end
    end

    if noeval then return sequence end
    -- now, execute it
    local name = sequence[1]
    if not name then return true end
    local ok, err = resolveCommand(table.remove(sequence, 1), handle, nowait)
    if not ok then return nil, err end
    local old = sub
    sub = sequence.getOutput or sub
    local ex, out = call(name, ok, sequence, handle, nowait)
    sub = old

    if out then
      return out, ex
    end

    return ex
  end

  return sequence
end

processCommand = function(text, ne, h, nowait)
  -- TODO: do this correctly
  local result = {}
  for chunk in text:gmatch("[^;]+") do 
    result = table.pack(processTokens(tokenize(chunk), ne, h, nowait))
  end
  return table.unpack(result)
end

local function processPrompt(text)
  for group in text:gmatch("%b()") do
    text = text:gsub(group:gsub("[%(%)%[%]%.%+%?%$%-%%]", "%%%1"),
      tostring(processCommand(group, true)[1] or ""))
  end
  return (text:gsub("\n", ""))
end

os.execute = processCommand
os.remove = function(file)
  return fs.remove(paths.canonical(file))
end
io.popen = function(command, mode)
  checkArg(1, command, "string")
  checkArg(2, mode, "string", "nil")
  mode = mode or "r"
  assert(mode == "r" or mode == "w", "bad mode to io.popen")

  local handle = pipe.create()

  processCommand(command, false, handle, true)

  return handle
end

if opts.exec then
  local ok, err = processCommand(opts.exec)
  if not ok and err then
    io.stderr:write(err, "\n")
  end
  os.exit()
end

local history = {}
local rlopts = {
  history = history,
}
while true do
  io.write("\27[0m\27?0c\27?0s", processPrompt(os.getenv("PS1")))
  local command = readline(rlopts)
  history[#history+1] = command
  if #history > 32 then
    table.remove(history, 1)
  end
  local ok, err = processCommand(command)
  if not ok and err then
    io.stderr:write(err, "\n")
  end
end
�� /bin/ls.lua      	-- coreutils: ls --

local text = require("text")
local size = require("size")
local path = require("path")
local users = require("users")
local termio = require("termio")
local filetypes = require("filetypes")
local fs = require("filesystem")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([=[
usage: ls [options] [file1 [file2 ...]]
Lists information about file(s).  Defaults to the
current directory.  Sorts entries alphabetically.
  -1            one file per line
  -a            show hidden files
  --color=WHEN  If "no", disable coloration;  if
                "always", force coloration even
                if the standard output is not
                connected to a terminal;
                otherwise, decide automatically.
  -d            Display information about a
                directory as though it were a
                file.
  -h            Use human-readable file sizes.
  --help        Display this help message and
                exit.
  -l            Display full file information
                (permissions, last modification
                date, etc.) instead of just file
                names.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]=])
  os.exit(1)
end

local colors = {
  default = "39;49",
  dir = "49;94",
  exec = "49;92",
  link = "49;96",
  special = "49;93"
}

local dfa = {name = "n/a"}
local function infoify(base, files, hook, hka)
  local infos = {}
  local maxn_user = 0
  local maxn_size = 0
  
  for i=1, #files, 1 do
    local fpath = files[i]
    
    if base ~= files[i] then
      fpath = path.canonical(path.concat(base, files[i]))
    end
    
    local info, err = fs.stat(fpath)
    if not info then
      io.stderr:write("ls: failed getting information for ", fpath, ": ",
        err, "\n")
      return nil
    end
    
    local perms = string.format(
      "%s%s%s%s%s%s%s%s%s%s",
      info.type == filetypes.directory and "d" or
        info.type == filetypes.special and "c" or
        "-",
      info.permissions & 0x1 and "r" or "-",
      info.permissions & 0x2 and "w" or "-",
      info.permissions & 0x4 and "x" or "-",
      info.permissions & 0x8 and "r" or "-",
      info.permissions & 0x10 and "w" or "-",
      info.permissions & 0x20 and "x" or "-",
      info.permissions & 0x40 and "r" or "-",
      info.permissions & 0x80 and "w" or "-",
      info.permissions & 0x100 and "x" or "-")
    
    local user = (users.attributes(info.owner) or dfa).name
    maxn_user = math.max(maxn_user, #user)
    infos[i] = {
      perms = perms,
      user = user,
      size = size.format(math.floor(info.size), not opts.h),
      modified = os.date("%b %d %H:%M", info.lastModified),
    }
  
    maxn_size = math.max(maxn_size, #infos[i].size)
    if hook then files[i] = hook(files[i], hka) end
  end

  for i=1, #files, 1 do
    files[i] = string.format(
      "%s %s %s %s %s",
      infos[i].perms,
      text.padRight(maxn_user, infos[i].user),
      text.padRight(maxn_size, infos[i].size),
      infos[i].modified,
      files[i])
  end
end

local function colorize(f, p)
  if opts.color == "no" or ((not io.output().tty) and opts.color ~= "always") then
    return f
  end
  if type(f) == "table" then
    for i=1, #f, 1 do
      f[i] = colorize(f[i], p)
    end
  else
    local full = f
    if p ~= f then full = path.concat(p, f) end
    
    local info, err = fs.stat(full)
    
    if not info then
      io.stderr:write("ls: failed getting color information for ", f, ": ", err, "\n")
      return nil
    end
    
    local color = colors.default
  
    if info.type == filetypes.directory then
      color = colors.dir
    elseif info.type == filetypes.link then
      color = colors.link
    elseif info.type == filetypes.special then
      color = colors.special
    elseif info.permissions & 4 ~= 0 then
      color = colors.exec
    end
    return string.format("\27[%sm%s\27[39;49m", color, f)
  end
end

local function list(dir)
  local odir = dir
  dir = path.canonical(dir)
  
  local files, err
  local info, serr = fs.stat(dir)
  
  if not info then
    err = serr
  elseif opts.d or not info.isDirectory then
    files = {dir}
  else
    files, err = fs.list(dir)
  end
  
  if not files then
    return nil, string.format("cannot access '%s': %s", odir, err)
  end
  
  local rm = {}
  for i=1, #files, 1 do
    files[i] = files[i]:gsub("[/]+$", "")
    if files[i]:sub(1,1) == "." and not opts.a then
      rm[#rm + 1] = i
    end
  end

  for i=#rm, 1, -1 do
    table.remove(files, rm[i])
  end

  table.sort(files)
  
  if opts.l then
    infoify(dir, files, colorize, dir)
  
    for i=1, #files, 1 do
      print(files[i])
    end
  elseif opts["1"] then
    for i=1, #files, 1 do
      print(colorize(files[i], dir))
    end
  elseif not (io.stdin.tty and io.stdout.tty) then
    for i=1, #files, 1 do
      print(files[i])
    end
  else
    print(text.mkcolumns(files, { hook = function(f)
        return colorize(f, dir)
      end,
      maxWidth = termio.getTermSize() }))
  end

  return true
end

if #args == 0 then
  args[1] = os.getenv("PWD")
end

local ex = 0
for i=1, #args, 1 do
  if #args > 1 then
    if i > 1 then
      io.write("\n")
    end
    print(args[i] .. ":")
  end
  
  local ok, err = list(args[i])
  if not ok and err then
    io.stderr:write("ls: ", err, "\n")
    ex = 1
  end
end

os.exit(ex)
�� /bin/tfmt.lua      q-- coreutils: text formatter --

local text = require("text")

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write([[
usage: tfmt [options] FILE ...
Format FILE(s) according to a simple format
specification.

Options:
  --wrap=WD       Wrap output text at WD
                  characters.
  --output=FILE   Send output to file FILE.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local colors = {
  bold = "97",
  regular = "39",
  italic = "36",
  link = "94",
  file = "93",
  red = "91",
  green = "92",
  yellow = "93",
  blue = "94",
  magenta = "95",
  cyan = "96",
  white = "97",
  gray = "90",
}

local patterns = {
  {"%*({..-})", "bold"},
  {"%$({..-})", "italic"},
  {"@({..-})", "link"},
  {"#({..-})", "file"},
  {"red({..-})", "red"},
  {"green({..-})", "green"},
  {"yellow({..-})", "yellow"},
  {"blue({..-})", "blue"},
  {"magenta({..-})", "magenta"},
  {"cyan({..-})", "cyan"},
  {"white({..-})", "white"},
  {"gray({..-})", "gray"},
}

opts.wrap = tonumber(opts.wrap)

local output = io.output()
if opts.output and type(opts.output) == "string" then
  local handle, err = io.open(opts.output, "w")
  if not handle then
    io.stderr:write("tfmt: cannot open ", opts.output, ": ", err, "\n")
    os.exit(1)
  end

  output = handle
end

for i=1, #args, 1 do
  local handle, err = io.open(args[i], "r")
  if not handle then
    io.stderr:write("tfmt: ", args[i], ": ", err, "\n")
    os.exit(1)
  end
  local data = handle:read("a")
  handle:close()

  for i=1, #patterns, 1 do
    data = data:gsub(patterns[i][1], function(x)
      return string.format("\27[%sm%s\27[%sm", colors[patterns[i][2]],
        x:sub(2, -2), colors.regular)
    end)
  end

  if opts.wrap then
    data = text.wrap(data, opts.wrap)
  end

  output:write(data .. "\n")
  output:flush()
end

if opts.output then
  output:close()
end
�� /bin/more.lua      �-- coreutils: more --

local text = require("text")
local termio = require("termio")

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write([[
usage: more FILE ...
Page through FILE(s).  Similar to less(1), but
slower.
]])
  os.exit(1)
end

local written = 0

local w, h = termio.getTermSize()

local prompt = "\27[30;47m--MORE--\27[39;49m"

local function chw()
  if written >= h - 2 then
    io.write(prompt)
    repeat
      local key = termio.readKey()
      if key == "q" then io.write("\n") os.exit(0) end
    until key == " "
    io.write("\27[2K")
    written = 0
  end
end

local function wline(l)
  local lines = text.wrap(l, w)
  while #lines > 0 do
    local nextnl = lines:find("\n")
    if nextnl then
      local ln = lines:sub(1, nextnl)
      lines = lines:sub(#ln + 1)
      written = written + 1
      io.write(ln)
    else
      written = written + 1
      lines = ""
      io.write(lines)
    end
    chw()
  end
end

local function read(f)
  local handle, err = io.open(f, "r")
  if not handle then
    io.stderr:write(f, ": ", err, "\n")
    os.exit(1)
  end

  local data = handle:read("a")
  
  handle:close()

  wline(data)
end

for i=1, #args, 1 do
  read(args[i])
end

�� /bin/mv.lua      �-- at long last, a mv command --

local args = table.pack(...)
local args, opts = require("argutil").parse(...)

if #args < 2 or opts.help then
  io.stderr:write([[
usage: mv FILE ... DEST
Move FILEs to DEST.  Executes cp(1), then rm(1)
under the hood.

ULOS Coreutils copyright (c) 2021 Ocawesome101
under the DSLv2.
]])
  os.exit(1)
end

local cp = loadfile("/bin/cp.lua")
cp("-r", table.unpack(args))
local rm = loadfile("/bin/rm.lua")
rm("-r", table.unpack(args, 1, #args - 1))
�� /bin/mount.lua      �-- coreutils: mount --

local component = require("component")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

local function readFile(f)
  local handle, err = io.open(f, "r")
  if not handle then
    io.stderr:write("mount: cannot open ", f, ": ", err, "\n")
    os.exit(1)
  end
  local data = handle:read("a")
  handle:close()

  return data
end

if opts.help then
  io.stderr:write([[
usage: mount NODE LOCATION [FSTYPE]
   or: mount -u PATH
Mount the filesystem node NODE at LOCATION.  Or,
if -u is specified, unmount the filesystem node
at PATH.

If FSTYPE is either "overlay" or unset, NODE will
be mounted as an overlay at LOCATION.  Otherwise,
if NODE points to a filesystem in /sys/dev, mount
will try to read device information from the file.
If both of these cases fail, NODE will be treated
as a component address.

Options:
  -u  Unmount rather than mount.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

if #args == 0 then
  for line in io.lines("/sys/mounts", "l") do
    local path, thing = line:match("(.-): (.+)")
    if not thing:match("........%-....%-....%-....%-............") then
      thing = string.format("%q", thing)
    end
    if path and thing then
      print(string.format("%s on %s", thing, path))
    end
  end
  os.exit(0)
end

if opts.u then
  local ok, err = filesystem.umount(require("path").canonical(args[1]))
  if not ok then
    io.stderr:write("mount: unmounting ", args[1], ": ", err, "\n")
    os.exit(1)
  end
  os.exit(0)
end

local node, path, fstype = args[1], args[2], args[3]

do
  local npath = require("path").canonical(node)
  local data = filesystem.stat(npath)
  if data then
    if npath:match("/sys/") then -- the path points to somewhere the sysfs
      if data.isDirectory then
        node = readFile(npath .. "/address")
      else
        node = readFile(npath)
      end
    elseif not data.isDirectory then
      node = readFile(npath)
    end
  end
end

if not fstype then
  local addr = component.get(node)
  if addr then
    node = addr
    if component.type(addr) == "drive" then
      fstype = "raw"
    elseif component.type(addr) == "filesystem" then
      fstype = "node"
    else
      io.stderr:write("mount: ", node, ": not a filesystem or drive\n")
      os.exit(1)
    end
  end
end

if (not fstype) or fstype == "overlay" then
  local abs = require("path").canonical(node)
  local data, err = filesystem.stat(abs)
  if not data then
    io.stderr:write("mount: ", node, ": ", err, "\n")
    os.exit(1)
  end
  if not data.isDirectory then
    io.stderr:write("mount: ", node, ": not a directory\n")
    os.exit(1)
  end
  node = abs
  fstype = "overlay"
end

if not filesystem.types[fstype:upper()] then
  io.stderr:write("mount: ", fstype, ": bad filesystem node type\n")
  os.exit(1)
end

local ok, err = filesystem.mount(node, filesystem.types[fstype:upper()], path)

if not ok then
  io.stderr:write("mount: mounting ", node, " on ", path, ": ", err, "\n")
  os.exit(1)
end
�� /bin/less.lua      x-- coreutils: less --

local text = require("text")
local termio = require("termio")

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write([[
usage: less FILE ...
Page through FILE(s).  They will be concatenated.
]])
  os.exit(1)
end

local lines = {}
local lcache = {}
local w, h = termio.getTermSize()
local scr = 0

local function scroll(down)
  if down then
    if scr+h < #lines then
      local n = math.min(#lines - h, scr + 4)
      if n > scr then
        io.write(string.format("\27[%dS", n - scr))
        for i=scr, scr + n, 1 do lcache[i + h] = false end
        scr = n
      end
    end
  elseif scr > 0 then
    local n = math.max(0, scr - 4)
    if n < scr then
      io.write(string.format("\27[%dT", scr - n))
      for i=scr - n - 3, scr, 1 do lcache[i] = false end
      scr = n
    end
  end
end

for i=1, #args, 1 do
  for line in io.lines(args[i], "l") do
    lines[#lines+1] = line
  end
end

if #lines < h - 1 then
  for i=1, #lines, 1 do
    io.write(lines[i] .. "\n")
  end
  io.write("\27[30;47mEND\27[m")
  repeat local k = termio.readKey() until k == "q"
  io.write("\27[G\27[2K")
  os.exit()
end

local function redraw()
  for i=1, h-1, 1 do
    if not lcache[scr+i] then
      lcache[scr+i] = true
      io.write(string.format("\27[%d;1H\27[2K%s", i, lines[scr+i] or ""))
    end
  end
end

io.write("\27[2J")
redraw()

local prompt = string.format("\27[%d;1H\27[2K:", h)
local lastpat = ""
io.write(prompt)
while true do
  local key, flags = termio.readKey()
  if key == "q" then
    io.write("\27[m\n")
    io.flush()
    os.exit(0)
  elseif key == "up" then
    scroll(false)
  elseif key == "down" then
    scroll(true)
  elseif key == " " then
    lcache = {}
    scr = math.min(scr + h, #lines - h)
  elseif key == "/" then
    io.write(string.format("\27[%d;1H/", h))
    local search = io.read("l")
    if #search > 0 then
      lastpat = search
    else
      search = lastpat
    end
    for i = math.max(scr, 1) + 1, #lines, 1 do
      if lines[i]:match(search) then
        scr = math.min(i, #lines - h)
        break
      end
    end
  end
  redraw()
  io.write(prompt)
end
�� /bin/file.lua      �-- file --

local fs = require("filesystem")
local path = require("path")
local filetypes = require("filetypes")

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write([[
usage: file FILE ...
   or: file [--help]
Prints filetype information for the specified
FILE(s).

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(0)
end

for i=1, #args, 1 do
  local full = path.canonical(args[i])
  local ok, err = fs.stat(full)
  if not ok then
    io.stderr:write("file: cannot stat '", args[i], "': ", err, "\n")
    os.exit(1)
  end
  local ftype = "data"
  for k, v in pairs(filetypes) do
    if v == ok.type then
      ftype = k
      break
    end
  end
  io.write(args[i], ": ", ftype, "\n")
end
�� /bin/bsh.lua      I�-- bsh: Better Shell --

local path = require("path")
local pipe = require("pipe")
local text = require("text")
local fs = require("filesystem")
local process = require("process")
local readline = require("readline")

local args, opts = require("argutil").parse(...)

local _VERSION_FULL = "1.0.0"
local _VERSION_MAJOR = _VERSION_FULL:sub(1, -3)

os.setenv("PATH", os.getenv("PATH") or "/bin:/sbin:/usr/bin")
os.setenv("PS1", os.getenv("PS1") or "<\\u@\\h: \\W> ")
os.setenv("SHLVL", tostring(math.floor(((os.getenv("SHLVL") or "0") + 1))))
os.setenv("BSH_VERSION", _VERSION_FULL)

local logError = function(err)
  if not err then return end
  io.stderr:write(err .. "\n")
end

local aliases = {}
local shenv = process.info().data.env
local builtins
builtins = {
  cd = function(dir)
    if dir == "-" then
      if not shenv.OLDPWD then
        logError("sh: cd: OLDPWD not set")
        return 1
      end
      dir = shenv.OLDPWD
      print(dir)
    elseif not dir then
      if not shenv.HOME then
        logError("sh: cd: HOME not set")
        return 1
      end
      dir = shenv.HOME
    end

    local full = path.canonical(dir)
    local ok, err = fs.stat(full)
    
    if not ok then
      logError("sh: cd: " .. dir .. ": " .. err)
      return 1
    else
      shenv.OLDPWD = shenv.PWD
      shenv.PWD = full
    end
    return 0
  end,
  set = function(...)
    local args = {...}
    if #args == 0 then
      for k, v in pairs(shenv) do
        if v:match(" ") then v = "'" .. v .. "'" end
        print(k.."="..v)
      end
    else
      for i=1, #args, 1 do
        local name, assign = args[i]:match("(.-)=(.+)")
        if name then shenv[name] = assign end
      end
    end
  end,
  unset = function(...)
    local args = table.pack(...)
    for i=1, #args, 1 do
      shenv[args[i]] = nil
    end
  end,
  kill = function(...)
    local args, opts = {}, {}
    local _raw_args = {...}
    local signal = process.signals.interrupt
    for i, argument in ipairs(_raw_args) do
      if argument:match("%-.+") then
        local value = argument:match("%-(.+)"):lower()
        if tonumber(value) then signal = value else opts[value] = true end
      elseif not tonumber(argument) then
        logError("sh: kill: expected number as PID")
        return 1
      else
        args[#args+1] = tonumber(argument)
      end
    end
    local signal = process.signals.interrupt
    for k,v in pairs(opts) do
      if process.signals[k] then signal = process.signals[k] end
    end
    if opts.sighup then signal = process.signals.hangup end
    if opts.sigint then signal = process.signals.interrupt end
    if opts.sigquit then signal = process.signals.quit end
    if opts.sigpipe then signal = process.signals.pipe end
    if opts.sigstop then signal = process.signals.stop end
    if opts.sigcont then signal = process.signals.continue end
    local exstat = 0
    for i=1, #args, 1 do
      local ok, err = process.kill(args[i], signal)
      if not ok then
        logError("sh: kill: kill process " .. args[i] .. ": " .. err)
        exstat = 1
      end
    end
    return exstat
  end,
  exit = function(n)
    if opts.l or opts.login then
      logError("logout")
    else
      logError("exit")
    end
    os.exit(tonumber(n or "") or 0)
  end,
  logout = function(n)
    if not (opts.login or opts.l) then
      logError("sh: logout: not login shell: use `exit'")
      return 1
    end
    logError("logout")
    os.exit(0)
  end,
  pwd = function() print(shenv.PWD) end,
  ["true"] = function() return 0 end,
  ["false"] = function() return 1 end,
  alias = function(...)
    local args = {...}
    local exstat = 0
    if #args == 0 then
      for k, v in pairs(aliases) do
        print("alias " .. k .. "='" .. v .. "'")
      end
    else
      for i=1, #args, 1 do
        local name, alias = args[i]:match("(.-)=(.+)")
        if name then aliases[name] = alias
        elseif aliases[args[i]] then
          print("alias " .. args[i] .. "='" .. aliases[args[i]] .. "'")
        else
          logError("sh: alias: " .. args[i] .. ": not found")
          exstat = 1
        end
      end
    end
    return exstat
  end,
  unalias = function(...)
    local args = {...}
    local exstat = 0
    for i=1, #args, 1 do
      if not aliases[args[i]] then
        logError("sh: unalias: " .. args[i] .. ": not found")
        exstat = 1
      else
        aliases[args[i]] = nil
      end
    end
    return exstat
  end,
  builtins = function()
    for k, v in pairs(builtins) do print(k) end
  end,
  time = function(...)
    local cmd = table.concat(table.pack(...), " ")
    local start = require("computer").uptime()
    os.execute(cmd)
    local time = require("computer").uptime() - start
    print("real  " .. tostring(time) .. "s")
  end
}

local function exists(file)
  if fs.stat(file) then return file
  elseif fs.stat(file .. ".lua") then return file .. ".lua" end
end

local function resolveCommand(name)
  if builtins[name] then return builtins[name] end
  local try = {name}
  for ent in os.getenv("PATH"):gmatch("[^:]+") do
    try[#try+1] = path.concat(ent, name)
  end
  for i, check in ipairs(try) do
    local file = exists(check)
    if file then
      return file
    end
  end
  return nil, "command not found"
end

local jobs = {}

local function executeCommand(cstr, nowait)
  while (cstr.command[1] or ""):match("=") do
    local name = table.remove(cstr.command, 1)
    local assign
    name, assign = name:match("^(.-)=(.+)$")
    if name then cstr.env[name] = assign end
  end
  
  if #cstr.command == 0 then for k,v in pairs(cstr.env) do os.setenv(k, v) end return 0, "exited" end
  
  local file, err = resolveCommand(cstr.command[1])
  if not file then logError("sh: " .. cstr.command[1] .. ": " .. err) return nil, err end
  local ok

  if type(file) == "function" then -- this means it's a builtin
    if cstr.input == io.stdin and cstr.output == io.stdout then
      local result = table.pack(pcall(file, table.unpack(cstr.command, 2)))
      if not result[1] and result[2] then
        logError("sh: " .. cstr.command[1] .. ": " .. result[2])
        return 1, result[2]
      elseif result[1] then
        return table.unpack(result, 2, result.n)
      end
    else
      ok = file
    end
  else
    ok, err = loadfile(file)
    if not ok then logError(cstr.command[1] .. ": " .. err) return nil, err end
  end

  local sios = io.stderr
  local pid = process.spawn {
    func = function()
      local result = table.pack(xpcall(ok, debug.traceback, table.unpack(cstr.command, 2)))
      if not result[1] then
        io.stderr:write(cstr.command[1], ": ", result[2], "\n")
        os.exit(127)
      else
        local errno = result[2]
        if type(errno) == "number" then
          os.exit(errno)
        else
          os.exit(0)
        end
      end
    end,
    name = cstr.command[1],
    stdin = cstr.input,
    input = cstr.input,
    stdout = cstr.output,
    output = cstr.output,
    stderr = cstr.err,
    env = cstr.env
  }

  --print("Waiting for " .. pid)
  
  if not nowait then
    return process.await(pid)
  else
    jobs[#jobs+1] = pid
    print(string.format("[%d] %d", #jobs, pid))
  end
end

local special = "['\" %[%(%$&#|%){}\n;<>~]"

local function tokenize(text)
  text = text:gsub("$([a-zA-Z0-9_]+)", function(x)return os.getenv(x)or""end)
  local tokens = {}
  local idx = 0
  while #text > 0 do
    local index = text:find(special) or #text+1
    local token = text:sub(1, math.max(1,index - 1))
    if token == "'" then
      local nind = text:find("'", 2)
      if not nind then
        return nil, "unclosed string at index " .. idx
      end
      token = text:sub(1, nind)
    elseif token == '"' then
      local nind = text:find('"', 2)
      if not nind then
        return nil, "unclosed string at index " .. idx
      end
      token = text:sub(1, nind)
    end
    idx = idx + index
    text = text:sub(#token + 1)
    tokens[#tokens + 1] = token
  end
  return tokens
end

local mkrdr
do
  local r = {}
  function r:pop()
    self.i=self.i+1
    return self.t[self.i - 1]
  end
  function r:peek(n)
    return self.t[self.i+(n or 0)]
  end
  function r:get_until(c)
    local t={}
    repeat
      local _c=self:pop()
      t[#t+1]=_c
    until (_c and _c:match(c)) or not _c
    return mkrdr(t)
  end
  function r:get_balanced(s,e)
    local t={}
    local i=1
    self:pop()
    repeat
      local _c = self:pop()
      t[#t+1] = _c
      i = i + ((_c == s and 1) or (_c == e and -1) or 0)
    until i==0 or not _c
    return t
  end
  mkrdr = function(t)
    return setmetatable({i=1,t=t or{}},{__index=r})
  end
end

local eval_1, eval_2

eval_1 = function(tokens)
  -- first pass: simplify it all
  local simplified = {""}
  while true do
    local tok = tokens:pop()
    if not tok then break end
    if tok == "$" then
      if tokens:peek() == "(" then
        local seq = tokens:get_balanced("(",")")
        seq[#seq] = nil -- remove trailing )
        local cseq = eval_2(eval_1(mkrdr(seq)), true) or {}
        for i=1, #cseq, 1 do
          if #simplified[#simplified]==0 then
            simplified[#simplified]=cseq[i]
          else
            simplified[#simplified+1]=cseq[i]
          end
        end
      elseif tokens:peek() == "{" then
        local seq = tokens:get_balanced("{","}")
        seq[#seq]=nil
        simplified[#simplified]=simplified[#simplified]..(os.getenv(table.concat(seq))or"")
      else
        simplified[#simplified] = simplified[#simplified] .. tok
      end
    elseif tok == "#" then
      tokens:get_until("\n")
    elseif tok:sub(1,1):match("['\"]") then
      simplified[#simplified] = simplified[#simplified] .. tok:sub(2,-2)
    elseif tok:match("[ |;\n&]") and #simplified[#simplified] > 0 then
      if tok:match("[^\n ]") then simplified[#simplified+1] = tok end
      if #simplified[#simplified] > 0 then simplified[#simplified + 1] = "" end
    elseif tok == "}" then
      return nil, "syntax error near unexpected token `}'"
    elseif tok == ")" then
      return nil, "syntax error near unexpected token `)'"
    elseif tok == ">" then
      if simplified[#simplified] == ">" then
        simplified[#simplified] = ">>"
      else
        simplified[#simplified+1] = tok
      end
    elseif tok == "<" then
      simplified[#simplified+1] = tok
    elseif tok == "~" then
      if #simplified[#simplified] > 0 then
        simplified[#simplified] = simplified[#simplified] .. "~"
      else
        simplified[#simplified + 1] = os.getenv("HOME")
      end
    elseif tok ~= " " then
      simplified[#simplified] = simplified[#simplified] .. tok
    end
  end
  if #simplified == 0 then return end
  return simplified
end

eval_2 = function(simplified, captureOutput, captureInput)
  if not simplified then return nil, captureOutput end
  local _cout_pipe
  if captureOutput then
    _cout_pipe = captureInput or pipe.create()
  end
  -- second pass: set up command structure
  local struct = {{command = {}, input = captureInput or io.stdin,
    output = (_cout_pipe or io.stdout), err = io.stderr, env = {}}}
  local i = 0
  while i < #simplified do
    i = i + 1
    if simplified[i] == ";" then
      if #struct[#struct].command == 0 then
        return nil, "syntax error near unexpected token `;'"
      elseif i ~= #simplified then
        struct[#struct+1] = ";"
        struct[#struct+1] = {command = {}, input = captureInput or io.stdin,
          output = (_cout_pipe or io.stdout), err = io.stderr, env = {}}
      end
    elseif simplified[i] == "|" then
      if type(struct[#struct]) == "string" or #struct[#struct].command == 0 then
        return nil, "syntax error near unexpected token `|'"
      else
        local _pipe = pipe.create()
        struct[#struct].output = _pipe
        struct[#struct+1] = {command = {}, input = _pipe,
          output = (_cout_pipe or io.stdout), err = io.stderr, env = {}}
      end
    elseif simplified[i] == "&" then
      if type(struct[#struct]) == "string" or #struct[#struct].command == 0 then
        return nil, "syntax error near unexpected token `&'"
      elseif simplified[i+1] == "&" then
        i = i + 1
        struct[#struct+1] = "&&"
        struct[#struct+1] = {command = {}, input = captureInput or io.stdin,
          output = (_cout_pipe or io.stdout), err = io.stderr, env = {}}
      else
        -- support for & is broken right now, i might fix it later.
        --struct[#struct+1] = "&"
        --struct[#struct+1] = {command = {}, input = captureInput or io.stdin,
        --  output = (captureOutput and _cout_pipe or io.stdout), err = io.stderr, env = {}}
        return nil, "syntax error near unexpected token `&'"
      end
    elseif simplified[i] == ">" or simplified[i] == ">>" then
      if not simplified[i+1] then
        return nil, "syntax error near unexpected token `" .. simplified[i] .. "'"
      else
        i = i + 1
        local handle, err = io.open(simplified[i], simplified[i-1] == ">" and "w" or "a")
        if not handle then
          return nil, "cannot open " .. simplified[i] .. ": " .. err
        end
        struct[#struct].output = handle
      end
    elseif simplified[i] == "<" then
      if not simplified[i+1] then
        return nil, "syntax error near unexpected token `<'"
      else
        i = i + 1
        local handle, err = io.open(simplified[i], "r")
        if not handle then
          return nil, "cannot open " .. simplified[i] .. ": " .. err
        end
        struct[#struct].input = handle
      end
    elseif #simplified[i] > 0 then
      if #struct[#struct].command == 0 and aliases[simplified[i]] then
        local tokens = eval_1(mkrdr(tokenize(aliases[simplified[i]])))
        for i=1, #tokens, 1 do table.insert(struct[#struct].command, tokens[i]) end
      else
        if simplified[i]:sub(1,1) == "~" then simplified[i] = path.concat(os.getenv("HOME"), 
          simplified[i]) end
        if simplified[i]:sub(-1) == "*" then
          local full = path.canonical(simplified[i])
          if full:sub(-2) == "/*" then -- simpler
            local files = fs.list(full:sub(1,-2)) or {}
            for i=1, #files, 1 do
              table.insert(struct[#struct].command, path.concat(full:sub(1,-2),
                files[i]))
            end
          else
            local _path, name = full:match("^(.+/)(.-)$")
            local files = fs.list(_path) or {}
            name = text.escape(name:sub(1,-2)) .. ".+$"
            for i=1, #files, 1 do
              if files[i]:match(name) then
                table.insert(struct[#struct].command, path.concat(_path, files[i]))
              end
            end
          end
        else
          table.insert(struct[#struct].command, simplified[i])
        end
      end
    end
  end

  local srdr = mkrdr(struct)
  local bg = not not captureInput
  local lastExitStatus, lastExitReason, lastSeparator = 0, "", ";"
  for token in srdr.pop, srdr do
    --bg = (srdr:peek() == "|" or srdr:peek() == "&") or not not captureInput
    if type(token) == "table" then
      if lastSeparator == "&&" then
        if lastExitStatus == 0 then
          local exitStatus, exitReason = executeCommand(token, bg)
          lastExitStatus = exitStatus
          if exitReason ~= "__internal_process_exit" and exitReason ~= "exited"
              and exitReason and #exitReason > 0 then
            logError(exitReason)
          end
        end
      elseif lastSeparator == "|" then
        if lastExitStatus == 0 then
          local exitStatus, exitReason = executeCommand(token, bg)
          lastExitStatus = exitStatus
          if exitReason ~= "__internal_process_exit" and exitReason ~= "exited"
              and exitReason and #exitReason > 0 then
            logError(exitReason)
          end
        end
      elseif lastSeparator == ";" then
        lastExitStatus = 0
        local exitStatus, exitReason = executeCommand(token, bg)
        lastExitStatus = exitStatus
        if exitReason ~= "__internal_process_exit" and exitReason ~= "exited"
            and exitReason and #exitReason > 0 and type(exitStatus) == "number" then
          logError(exitReason)
        end
      end
    elseif type(token) == "string" then
      lastSeparator = token
    end
  end

  --print("reading output")

  if captureOutput and not captureInput then
    local lines = {}
    _cout_pipe:close() -- this ONLY works on pipes!
    for line in _cout_pipe:lines("l") do lines[#lines+1] = line end
    return lines
  else
    return lastExitStatus == 0
  end
end

local function process_prompt(ps)
  return (ps:gsub("\\(.)", {
    ["$"] = os.getenv("USER") == "root" and "#" or "$",
    ["a"] = "\a",
    ["A"] = os.date("%H:%M"),
    ["d"] = os.date("%a %b %d"),
    ["e"] = "\27",
    ["h"] = (os.getenv("HOSTNAME") or "localhost"):gsub("%.(.+)$", ""),
    ["h"] = os.getenv("HOSTNAME") or "localhost",
    ["j"] = "0", -- the number of jobs managed by the shell
    ["l"] = "tty" .. math.floor(io.stderr.tty or 0),
    ["n"] = "\n",
    ["r"] = "\r",
    ["s"] = "sh",
    ["t"] = os.date("%T"),
    ["T"] = os.date("%I:%M:%S"),
    ["@"] = os.date("%H:%M %p"),
    ["u"] = os.getenv("USER"),
    ["v"] = _VERSION_MAJOR_MINOR,
    ["V"] = _VERSION_FULL,
    ["w"] = os.getenv("PWD"):gsub(
      "^"..text.escape(os.getenv("HOME")), "~"),
    ["W"] = (os.getenv("PWD") or "/"):gsub(
      "^"..text.escape(os.getenv("HOME")), "~"):match("([^/]+)/?$") or "/",
  }))
end

function os.execute(...)
  local cmd = table.concat({...}, " ")
  if #cmd > 0 then return eval_2(eval_1(mkrdr(tokenize(cmd)))) end
  return 0
end

function os.remove(_path)
  return fs.remove(path.canonical(_path))
end

function io.popen(command, mode)
  checkArg(1, command, "string")
  checkArg(2, mode, "string", "nil")
  mode = mode or "r"
  assert(mode == "r" or mode == "w", "bad mode to io.popen")

  local handle = pipe.create()

  local ok, err = eval_2(eval_1(mkrdr(tokenize(command))), true, handle)
  if not ok and err then
    return nil, err
  end

  return handle
end

if fs.stat("/etc/bshrc") then
  for line in io.lines("/etc/bshrc") do
    local ok, err = eval_2(eval_1(mkrdr(tokenize(line))))
    if not ok and err then logError("sh: " .. err) end
  end
end

if fs.stat(os.getenv("HOME") .. "/.bshrc") then
  for line in io.lines(os.getenv("HOME") .. "/.bshrc") do
    local ok, err = eval_2(eval_1(mkrdr(tokenize(line))))
    if not ok and err then logError("sh: " .. err) end
  end
end

local hist = {}
local rlopts = {history = hist, exit = builtins.exit}
while true do
  io.write(process_prompt(os.getenv("PS1")))
  local text = readline(rlopts)
  if #text > 0 then
    table.insert(hist, text)
    if #hist > 32 then table.remove(hist, 1) end
    local ok, err = eval_2(eval_1(mkrdr(tokenize(text))))
    if not ok and err then logError("sh: " .. err) end
  end
end
�� /bin/libm.lua      -- preload: preload libraries

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.h or opts.help then
  io.stderr:write([[
usage: libm [-vr] LIB1 LIB2 ...
Loads or unloads libraries.  Internally uses
require().
    -v    be verbose
    -r    unload libraries rather than loading
          them

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
end

local function handle(f, a)
  local ok, err = pcall(f, a)
  if not ok and err then
    io.stderr:write(err, "\n")
    os.exit(1)
  else
    return true
  end
end

for i=1, #args, 1 do
  if opts.v then
    io.write(opts.r and "unload" or "load", " ", args[i], "\n")
  end
  if opts.r then
    handle(function() package.loaded[args[i]] = nil end)
  else
    handle(require, args[i])
  end
end
�� /bin/uname.lua       :-- coreutils: uname --

-- TODO: expand
print(_OSVERSION)
�� /bin/env.lua      4-- env

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: env [options] PROGRAM ...
Executes PROGRAM with the specified options.

Options:
  --unset=KEY,KEY,... Unset all specified
                      variables in the child
                      process's environment.
  --chdir=DIR         Set the child process's
                      working directory to DIR.
                      DIR is not checked for
                      existence.
  -i                  Execute the child process
                      with an empty environment.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local program = table.concat(args, " ")

local pge = require("process").info().data.env

-- TODO: support short opts with arguments, and maybe more opts too

if opts.unset and type(opts.unset) == "string" then
  for v in opts.unset:gmatch("[^,]+") do
    pge[v] =  ""
  end
end

if opts.i then
  pge = {}
end

if opts.chdir and type(opts.chdir) == "string" then
  pge["PWD"] = opts.chdir
end

os.execute(program)
�� /bin/pwd.lua      -- coreutils: pwd --

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: pwd
Print the current working directory.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

io.write(os.getenv("PWD"), "\n")
�� /bin/touch.lua      U-- coreutils: touch --

local path = require("path")
local ftypes = require("filetypes")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write([[
usage: touch FILE ...
Create the specified FILE(s) if they do not exist.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

for i=1, #args, 1 do
  local ok, err = filesystem.touch(path.canonical(args[i]),
    ftypes.file)

  if not ok then
    io.stderr:write("touch: cannot touch '", args[i], "': ", err, "\n")
    os.exit(1)
  end
end
�� /bin/upm.lua      �-- UPM: the ULOS Package Manager --

local config = require("config")
local path = require("path")
local upm = require("upm")

local args, opts = require("argutil").parse(...)

local cfg = config.bracket:load("/etc/upm.cfg") or
  {__load_order={"General","Repositories"}}

cfg.General = cfg.General or {__load_order={"dataDirectory","cacheDirectory"}}
cfg.General.dataDirectory = cfg.General.dataDirectory or "/etc/upm"
cfg.General.cacheDirectory = cfg.General.cacheDirectory or "/etc/upm/cache"
cfg.Repositories = cfg.Repositories or {__load_order={"main","extra"},
  main = "http://ulos.pickardayune.com/upm/main/",
 extra = "http://ulos.pickardayune.com/upm/extra/"}

config.bracket:save("/etc/upm.cfg", cfg)

if type(opts.root) ~= "string" then opts.root = "/" end
opts.root = path.canonical(opts.root)

-- create directories
os.execute("mkdir -p " .. path.concat(opts.root, cfg.General.dataDirectory))
os.execute("mkdir -p " .. path.concat(opts.root, cfg.General.cacheDirectory))

if opts.root ~= "/" then
  config.bracket:save(path.concat(opts.root, "/etc/upm.cfg"), cfg)
end

upm.preload(cfg, opts)

local usage = "\
UPM - the ULOS Package Manager\
\
usage: \27[36mupm \27[39m[\27[93moptions\27[39m] \27[96mCOMMAND \27[39m[\27[96m...\27[39m]\
\
Available \27[96mCOMMAND\27[39ms:\
  \27[96minstall \27[91mPACKAGE ...\27[39m\
    Install the specified \27[91mPACKAGE\27[39m(s).\
\
  \27[96mremove \27[91mPACKAGE ...\27[39m\
    Remove the specified \27[91mPACKAGE\27[39m(s).\
\
  \27[96mupdate\27[39m\
    Update (refetch) the repository package lists.\
\
  \27[96mupgrade\27[39m\
    Upgrade installed packages.\
\
  \27[96msearch \27[91mPACKAGE\27[39m\
    Search local package lists for \27[91mPACKAGE\27[39m, and\
    display information about it.\
\
  \27[96mlist\27[39m [\27[91mTARGET\27[39m]\
    List packages.  If \27[91mTARGET\27[39m is 'all',\
    then list packages from all repos;  if \27[91mTARGET\27[37m\
    is 'installed', then print all installed\
    packages;  otherewise, print all the packages\
    in the repo specified by \27[91mTARGET\27[37m.\
    \27[91mTARGET\27[37m defaults to 'installed'.\
\
Available \27[93moption\27[39ms:\
  \27[93m-q\27[39m            Be quiet;  no log output.\
  \27[93m-f\27[39m            Skip checks for package version and\
                              installation status.\
  \27[93m-v\27[39m            Be verbose;  overrides \27[93m-q\27[39m.\
  \27[93m-y\27[39m            Automatically assume 'yes' for\
                              all prompts.\
  \27[93m--root\27[39m=\27[33mPATH\27[39m   Treat \27[33mPATH\27[39m as the root filesystem\
                instead of /.\
\
The ULOS Package Manager is copyright (c) 2021\
Ocawesome101 under the DSLv2.\
"

local pfx = {
  info = "\27[92m::\27[39m ",
  warn = "\27[93m::\27[39m ",
  err = "\27[91m::\27[39m "
}

local function log(...)
  if opts.v or not opts.q then
    io.stderr:write(...)
    io.stderr:write("\n")
  end
end

local function exit(reason)
  log(pfx.err, reason)
  os.exit(1)
end

if opts.help or args[1] == "help" then
  io.stderr:write(usage)
  os.exit(1)
end

if #args == 0 then
  exit("an operation is required; see 'upm --help'")
end

local installed = upm.installed

cfg.__load_order = nil
for k,v in pairs(cfg) do v.__load_order = nil end

if args[1] == "install" then
  if not args[2] then
    exit("command verb 'install' requires at least one argument")
  end
  
  table.remove(args, 1)
  upm.install(cfg, opts, args)
elseif args[1] == "upgrade" then
  upm.upgrade(cfg, opts)
elseif args[1] == "remove" then
  if not args[2] then
    exit("command verb 'remove' requires at least one argument")
  end

  table.remove(args, 1)
  upm.remove(cfg, opts, args)
elseif args[1] == "update" then
  upm.update(cfg, opts)
elseif args[1] == "search" then
  if not args[2] then
    exit("command verb 'search' requires at least one argument")
  end
  table.remove(args, 1)
  upm.cli_search(cfg, opts, args)
elseif args[1] == "list" then
  table.remove(args, 1)
  upm.cli_list(cfg, opts, args)
else
  exit("operation '" .. args[1] .. "' is unrecognized")
end
�� /bin/df.lua      �-- df --

local path = require("path")
local size = require("size")
local filesystem = require("filesystem")

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: df [-h]
Print information about attached filesystems.
Uses information from the sysfs.

Options:
  -h  Print sizes in human-readable form.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local fscpath = "/sys/components/by-type/filesystem/"
local files = filesystem.list(fscpath)

table.sort(files)

print("      fs      name    total     used     free")

local function readFile(f)
  local handle = assert(io.open(f, "r"))
  local data = handle:read("a")
  handle:close()

  return data
end

local function printInfo(fs)
  local addr = readFile(fs.."/address"):sub(1, 8)
  local name = readFile(fs.."/label")
  local used = tonumber(readFile(fs.."/spaceUsed"))
  local total = tonumber(readFile(fs.."/spaceTotal"))

  local free = total - used

  if opts.h then
    used = size.format(used)
    free = size.format(free)
    total = size.format(total)
  end

  print(string.format("%8s %9s %8s %8s %8s", addr, name, total, used, free))
end

for i, file in ipairs(files) do
  printInfo(path.concat(fscpath, file))
end
�� /bin/wc.lua      �-- coreutils: wc --

local path = require("path")

local args, opts = require("argutil").parse(...)

if opts.help or #args == 0 then
  io.stderr:write([[
usage: wc [-lcw] FILE ...
Print line, word, and character (byte) counts from
all FILEs.

Options:
  -c  Print character counts.
  -l  Print line counts.
  -w  Print word counts.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

if not (opts.l or opts.w or opts.c) then
  opts.l = true
  opts.w = true
  opts.c = true
end

local function wc(f)
  local handle, err = io.open(f, "r")
  if not handle then
    return nil, err
  end

  local data = handle:read("a")
  handle:close()

  local out = {}

  if opts.l then
    local last = 0
    local val = 0
    while true do
      local nex = data:find("\n", last)
      if not nex then break end
      val = val + 1
      last = nex + 1
    end
    out[#out+1] = tostring(val)
  end

  if opts.w then
    local last = 0
    local val = 0
    while true do
      local nex, nen = data:find("[ \n\t\r]+", last)
      if not nex then break end
      val = val + 1
      last = nen + 1
    end
    out[#out+1] = tostring(val)
  end

  if opts.c then
    out[#out+1] = tostring(#data)
  end

  return out
end

for i=1, #args, 1 do
  local ok, err = wc(path.canonical(args[i]))
  if not ok then
    io.stderr:write("wc: ", args[i], ": ", err, "\n")
    os.exit(1)
  else
    io.write(table.concat(ok, " "), " ", args[i], "\n")
  end
end
�� /bin/find.lua      f-- find --

local path = require("path")
local futil = require("futil")

local args, opts = require("argutil").parse(...)

if #args == 0 or opts.help then
  io.stderr:write([[
usage: find DIRECTORY ...
Print a tree of all files in DIRECTORY.  All
printed file paths are absolute.

ULOS Coreutils (c) 2021 Ocawesome101 under the
DSLv2.
]])
end

for i=1, #args, 1 do
  local tree, err = futil.tree(path.canonical(args[i]))
  
  if not tree then
    io.stderr:write("find: ", err, "\n")
    os.exit(1)
  end

  for i=1, #tree, 1 do
    io.write(tree[i], "\n")
    if i % 10 == 0 then coroutine.yield(0) end
  end
end
�� /bin/login.lua      -- coreutils: login

local users = require("users")
local process = require("process")
local readline = require("readline")

local gethostname = (package.loaded.network and package.loaded.network.hostname)
  or function() return "localhost" end

if (process.info().owner or 0) ~= 0 then
  io.stderr:write("login may only be run as root!\n")
  os.exit(1)
end

io.write("\27?0c\27[39;49m\n" .. _OSVERSION .. " (tty" .. io.stderr.tty .. ")\n\n")

local rlops = {noexit = true}

local function main()
  io.write("\27?0c", gethostname(), " login: ")
  local un = readline(rlops)
  io.write("password: \27[8m")
  local pw = io.read("l")
  io.write("\n\27[m\27?0c")
  local uid = users.get_uid(un)
  if not uid then
    io.write("no such user\n\n")
  else
    local ok, err = users.authenticate(uid, pw)
    if not ok then
      io.write(err, "\n\n")
    else
      local info = users.attributes(uid)
      local shell = info.shell or "/bin/sh"
      if not shell:match("%.lua$") then
        shell = string.format("%s.lua", shell)
      end
      io.write("\nLoading shell: " .. shell .. "\n")
      local shellf, sherr = loadfile(shell)
      if not shellf then
        io.write("failed loading shell: ", sherr, "\n\n")
      else
        local motd = io.open("/etc/motd.txt", "r")
        if motd then
          print((motd:read("a") or ""))
          motd:close()
        end

        os.setenv("HOSTNAME", gethostname())

        local exit, err = users.exec_as(uid, pw, function()return shellf("--login")end, shell,
          true)
        io.write("\27[2J\27[1;1H")
        if exit ~= 0 then
          print(exit, err)
        else
          io.write("\n")
        end
      end
    end
  end
end

while true do
  local ok, err = xpcall(main, debug.traceback)
  if not ok then
    io.stderr:write(err, "\n")
  end
end
�� /bin/echo.lua       �-- coreutils: echo --
-- may be overridden by the shell --

local args = {...}

for i=1, #args, 1 do
  args[i] = tostring(args[i])
end

print(table.concat(args, " "))
�� /boot/cynosure.lua     �-- Cynosure kernel.  Should (TM) be mostly drop-in compatible with Paragon. --
-- Might even be better.  Famous last words!
-- Copyright (c) 2021 i develop things under the DSLv1.

_G.k = { cmdline = table.pack(...) }
do
  local start = computer.uptime()
  function k.uptime()
    return computer.uptime() - start
  end
end
-- kernel arguments

do
  local arg_pattern = "^(.-)=(.+)$"
  local orig_args = k.cmdline
  k.__original_cmdline = orig_args
  k.cmdline = {}

  for i=1, #orig_args, 1 do
    local karg = orig_args[i]
    
    if karg:match(arg_pattern) then
      local ka, v = karg:match(arg_pattern)
    
      if ka and v then
        k.cmdline[ka] = tonumber(v) or v
      end
    else
      k.cmdline[karg] = true
    end
  end
end
--#include "base/args.lua"
-- kernel version info --

do
  k._NAME = "Cynosure"
  k._RELEASE = "1.8"
  k._VERSION = "2021.09.16-default"
  _G._OSVERSION = string.format("%s r%s-%s", k._NAME, k._RELEASE, k._VERSION)
end
--#include "base/version.lua"
-- object-based tty streams --

do
  local color_profiles = {
    { -- default VGA colors
      0x000000,
      0xaa0000,
      0x00aa00,
      0xaa5500,
      0x0000aa,
      0xaa00aa,
      0x00aaaa,
      0xaaaaaa,
      0x555555,
      0xff5555,
      0x55ff55,
      0xffff55,
      0x5555ff,
      0xff55ff,
      0x55ffff,
      0xffffff
    },
    { -- Breeze theme colors from Konsole
      0x232627,
      0xed1515,
      0x11d116,
      0xf67400,
      0x1d99f3,
      0x9b59b6,
      0x1abc9c,
      0xfcfcfc,
      -- intense variants
      0x7f8c8d,
      0xc0392b,
      0x1cdc9a,
      0xfdbc4b,
      0x3daee9,
      0x8e44ad,
      0x16a085,
      0xffffff
    },
    { -- Gruvbox
      0x282828,
      0xcc241d,
      0x98971a,
      0xd79921,
      0x458588,
      0xb16286,
      0x689d6a,
      0xa89984,
      0x928374,
      0xfb4934,
      0xb8bb26,
      0xfabd2f,
      0x83a598,
      0xd3869b,
      0x8ec07c,
      0xebdbb2
    },
    { -- Gruvbox light, for those crazy enough to want a light theme
      0xfbf1c7,
      0xcc241d,
      0x98971a,
      0xd79921,
      0x458588,
      0xb16286,
      0x689d6a,
      0x7c6f64,
      0x928374,
      0x9d0006,
      0x79740e,
      0xb57614,
      0x076678,
      0x8f3f71,
      0x427b58,
      0x3c3836
    },
    { -- PaperColor light
      0xeeeeee,
      0xaf0000,
      0x008700,
      0x5f8700,
      0x0087af,
      0x878787,
      0x005f87,
      0x444444,
      0xbcbcbc,
      0xd70000,
      0xd70087,
      0x8700af,
      0xd75f00,
      0xd75f00,
      0x005faf,
      0x005f87
    },
    { -- Pale Night
      0x292d3e,
      0xf07178,
      0xc3e88d,
      0xffcb6b,
      0x82aaff,
      0xc792ea,
      0x89ddff,
      0xd0d0d0,
      0x434758,
      0xff8b92,
      0xddffa7,
      0xffe585,
      0x9cc4ff,
      0xe1acff,
      0xa3f7ff,
      0xffffff,
    }
  }
  local colors = color_profiles[1]

  if type(k.cmdline["tty.profile"]) == "number" then
    colors = color_profiles[k.cmdline["tty.profile"]] or color_profiles[1]
  end

  if type(k.cmdline["tty.colors"]) == "string" then
    for color in k.cmdline["tty.colors"]:gmatch("[^,]+") do
      local idx, col = color:match("(%x):(%x%x%x%x%x%x)")
      if idx and col then
        idx = tonumber(idx, 16) + 1
        col = tonumber(col, 16)
        colors[idx] = col or colors[idx]
      end
    end
  end
  
  local len = unicode.len
  local sub = unicode.sub

  -- pop characters from the end of a string
  local function pop(str, n, u)
    local sub, len = string.sub, string.len
    if not u then sub = unicode.sub len = unicode.len end
    local ret = sub(str, 1, n)
    local also = sub(str, len(ret) + 1, -1)
 
    return also, ret
  end

  local function wrap_cursor(self)
    while self.cx > self.w do
    --if self.cx > self.w then
      self.cx, self.cy = math.max(1, self.cx - self.w), self.cy + 1
    end
    
    while self.cx < 1 do
      self.cx, self.cy = self.w + self.cx, self.cy - 1
    end
    
    while self.cy < 1 do
      self.cy = self.cy + 1
      self.gpu.copy(1, 1, self.w, self.h - 1, 0, 1)
      self.gpu.fill(1, 1, self.w, 1, " ")
    end
    
    while self.cy > self.h do
      self.cy = self.cy - 1
      self.gpu.copy(1, 2, self.w, self.h, 0, -1)
      self.gpu.fill(1, self.h, self.w, 1, " ")
    end
  end

  local function writeline(self, rline)
    local wrapped = false
    while #rline > 0 do
      local to_write
      rline, to_write = pop(rline, self.w - self.cx + 1)
      
      self.gpu.set(self.cx, self.cy, to_write)
      
      self.cx = self.cx + len(to_write)
      wrapped = self.cx > self.w
      
      wrap_cursor(self)
    end
    return wrapped
  end

  local function write(self, lines)
    if self.attributes.xoff then return end
    while #lines > 0 do
      local next_nl = lines:find("\n")

      if next_nl then
        local ln
        lines, ln = pop(lines, next_nl - 1, true)
        lines = lines:sub(2) -- take off the newline
        
        local w = writeline(self, ln)

        if not w then
          self.cx, self.cy = 1, self.cy + 1
        end

        wrap_cursor(self)
      else
        writeline(self, lines)
        break
      end
    end
  end

  local commands, control = {}, {}
  local separators = {
    standard = "[",
    control = "?"
  }

  -- move cursor up N[=1] lines
  function commands:A(args)
    local n = math.max(args[1] or 0, 1)
    self.cy = self.cy - n
  end

  -- move cursor down N[=1] lines
  function commands:B(args)
    local n = math.max(args[1] or 0, 1)
    self.cy = self.cy + n
  end

  -- move cursor right N[=1] lines
  function commands:C(args)
    local n = math.max(args[1] or 0, 1)
    self.cx = self.cx + n
  end

  -- move cursor left N[=1] lines
  function commands:D(args)
    local n = math.max(args[1] or 0, 1)
    self.cx = self.cx - n
  end

  -- incompatibility: terminal-specific command for calling advanced GPU
  -- functionality
  function commands:g(args)
    if #args < 1 then return end
    local cmd = table.remove(args, 1)
    if cmd == 0 then -- fill
      if #args < 4 then return end
      args[1] = math.max(1, math.min(args[1], self.w))
      args[2] = math.max(1, math.min(args[2], self.h))
      self.gpu.fill(args[1], args[2], args[3], args[4], " ")
    elseif cmd == 1 then -- copy
      if #args < 6 then return end
      self.gpu.copy(args[1], args[2], args[3], args[4], args[5], args[6])
    end
    -- TODO more commands
  end

  function commands:G(args)
    self.cx = math.max(1, math.min(self.w, args[1] or 1))
  end

  function commands:H(args)
    local y, x = 1, 1
    y = args[1] or y
    x = args[2] or x
  
    self.cx = math.max(1, math.min(self.w, x))
    self.cy = math.max(1, math.min(self.h, y))
    
    wrap_cursor(self)
  end

  -- clear a portion of the screen
  function commands:J(args)
    local n = args[1] or 0
    
    if n == 0 then
      self.gpu.fill(1, self.cy, self.w, self.h - self.cy, " ")
    elseif n == 1 then
      self.gpu.fill(1, 1, self.w, self.cy, " ")
    elseif n == 2 then
      self.gpu.fill(1, 1, self.w, self.h, " ")
    end
  end
  
  -- clear a portion of the current line
  function commands:K(args)
    local n = args[1] or 0
    
    if n == 0 then
      self.gpu.fill(self.cx, self.cy, self.w, 1, " ")
    elseif n == 1 then
      self.gpu.fill(1, self.cy, self.cx, 1, " ")
    elseif n == 2 then
      self.gpu.fill(1, self.cy, self.w, 1, " ")
    end
  end

  -- adjust some terminal attributes - foreground/background color and local
  -- echo.  for more control {ESC}?c may be desirable.
  function commands:m(args)
    args[1] = args[1] or 0
    local i = 1
    while i <= #args do
      local n = args[i]
      if n == 0 then
        self.fg = 7
        self.bg = 0
        self.fgp = true
        self.bgp = true
        self.gpu.setForeground(self.fg, true)
        self.gpu.setBackground(self.bg, true)
        self.attributes.echo = true
      elseif n == 8 then
        self.attributes.echo = false
      elseif n == 28 then
        self.attributes.echo = true
      elseif n > 29 and n < 38 then
        self.fg = n - 30
        self.fgp = true
        self.gpu.setForeground(self.fg, true)
      elseif n == 39 then
        self.fg = 7
        self.fgp = true
        self.gpu.setForeground(self.fg, true)
      elseif n > 39 and n < 48 then
        self.bg = n - 40
        self.bgp = true
        self.gpu.setBackground(self.bg, true)
      elseif n == 49 then
        self.bg = 0
        self.bgp = true
        self.gpu.setBackground(self.bg, true)
      elseif n > 89 and n < 98 then
        self.fg = n - 82
        self.fgp = true
        self.gpu.setForeground(self.fg, true)
      elseif n > 99 and n < 108 then
        self.bg = n - 92
        self.bgp = true
        self.gpu.setBackground(self.bg, true)
      elseif n == 38 then
        i = i + 1
        if not args[i] then return end
        local mode = args[i]
        if mode == 5 then -- 256-color mode
          -- TODO
        elseif mode == 2 then -- 24-bit color mode
          local r, g, b = args[i + 1], args[i + 2], args[i + 3]
          if not b then return end
          i = i + 3
          self.fg = (r << 16) + (g << 8) + b
          self.fgp = false
          self.gpu.setForeground(self.fg)
        end
      elseif n == 48 then
        i = i + 1
        if not args[i] then return end
        local mode = args[i]
        if mode == 5 then -- 256-color mode
          -- TODO
        elseif mode == 2 then -- 24-bit color mode
          local r, g, b = args[i + 1], args[i + 2], args[i + 3]
          if not b then return end
          i = i + 3
          self.bg = (r << 16) + (g << 8) + b
          self.bgp = false
          self.gpu.setBackground(self.bg)
        end
      end
      i = i + 1
    end
  end

  function commands:n(args)
    local n = args[1] or 0

    if n == 6 then
      self.rb = string.format("%s\27[%d;%dR", self.rb, self.cy, self.cx)
    end
  end

  function commands:S(args)
    local n = args[1] or 1
    self.gpu.copy(1, n, self.w, self.h, 0, -n)
    self.gpu.fill(1, self.h - o, self.w, n, " ")
  end

  function commands:T(args)
    local n = args[1] or 1
    self.gpu.copy(1, 1, self.w, self.h-n, 0, n)
    self.gpu.fill(1, 1, self.w, n, " ")
  end

  -- adjust more terminal attributes
  -- codes:
  --   - 0: reset
  --   - 1: enable echo
  --   - 2: enable line mode
  --   - 3: enable raw mode
  --   - 4: show cursor
  --   - 5: undo 15
  --   - 11: disable echo
  --   - 12: disable line mode
  --   - 13: disable raw mode
  --   - 14: hide cursor
  --   - 15: disable all input and output
  function control:c(args)
    args[1] = args[1] or 0
    
    for i=1, #args, 1 do
      local n = args[i]

      if n == 0 then -- (re)set configuration to sane defaults
        -- echo text that the user has entered?
        self.attributes.echo = true
        
        -- buffer input by line?
        self.attributes.line = true
        
        -- whether to send raw key input data according to the VT100 spec,
        -- rather than e.g. changing \r -> \n and capturing backspace
        self.attributes.raw = false

        -- whether to show the terminal cursor
        self.attributes.cursor = true
      elseif n == 1 then
        self.attributes.echo = true
      elseif n == 2 then
        self.attributes.line = true
      elseif n == 3 then
        self.attributes.raw = true
      elseif n == 4 then
        self.attributes.cursor = true
      elseif n == 5 then
        self.attributes.xoff = false
      elseif n == 11 then
        self.attributes.echo = false
      elseif n == 12 then
        self.attributes.line = false
      elseif n == 13 then
        self.attributes.raw = false
      elseif n == 14 then
        self.attributes.cursor = false
      elseif n == 15 then
        self.attributes.xoff = true
      end
    end
  end

  -- adjust signal behavior
  -- 0: reset
  -- 1: disable INT on ^C
  -- 2: disable keyboard STOP on ^Z
  -- 3: disable HUP on ^D
  -- 11: enable INT
  -- 12: enable STOP
  -- 13: enable HUP
  function control:s(args)
    args[1] = args[1] or 0
    for i=1, #args, 1 do
      local n = args[i]
      if n == 0 then
        self.disabled = {}
      elseif n == 1 then
        self.disabled.C = true
      elseif n == 2 then
        self.disabled.Z = true
      elseif n == 3 then
        self.disabled.D = true
      elseif n == 11 then
        self.disabled.C = false
      elseif n == 12 then
        self.disabled.Z = false
      elseif n == 13 then
        self.disabled.D = false
      end
    end
  end

  local _stream = {}

  local function temp(...)
    return ...
  end

  function _stream:write(...)
    checkArg(1, ..., "string")

    local str = (k.util and k.util.concat or temp)(...)

    if self.attributes.line and not k.cmdline.nottylinebuffer then
      self.wb = self.wb .. str
      if self.wb:find("\n") then
        local ln = self.wb:match(".+\n")
        if not ln then ln = self.wb:match(".-\n") end
        self.wb = self.wb:sub(#ln + 1)
        return self:write_str(ln)
      elseif len(self.wb) > 2048 then
        local ln = self.wb
        self.wb = ""
        return self:write_str(ln)
      end
    else
      return self:write_str(str)
    end
  end

  -- This is where most of the heavy lifting happens.  I've attempted to make
  -- this function fairly optimized, but there's only so much one can do given
  -- OpenComputers's call budget limits and wrapped string library.
  function _stream:write_str(str)
    local gpu = self.gpu
    local time = computer.uptime()
    
    -- TODO: cursor logic is a bit brute-force currently, there are certain
    -- TODO: scenarios where cursor manipulation is unnecessary
    if self.attributes.cursor then
      local c, f, b, pf, pb = gpu.get(self.cx, self.cy)
      if pf then
        gpu.setForeground(pb, true)
        gpu.setBackground(pf, true)
      else
        gpu.setForeground(b)
        gpu.setBackground(f)
      end
      gpu.set(self.cx, self.cy, c)
      gpu.setForeground(self.fg, self.fgp)
      gpu.setBackground(self.bg, self.bgp)
    end
    
    -- lazily convert tabs
    str = str:gsub("\t", "  ")
    
    while #str > 0 do
      --[[if computer.uptime() - time >= 4.8 then -- almost TLWY
        time = computer.uptime()
        computer.pullSignal(0) -- yield so we don't die
      end]]

      if self.in_esc then
        local esc_end = str:find("[a-zA-Z]")

        if not esc_end then
          self.esc = self.esc .. str
        else
          self.in_esc = false

          local finish
          str, finish = pop(str, esc_end, true)

          local esc = self.esc .. finish
          self.esc = ""

          local separator, raw_args, code = esc:match(
            "\27([%[%?])([%-%d;]*)([a-zA-Z])")
          raw_args = raw_args or "0"
          
          local args = {}
          for arg in raw_args:gmatch("([^;]+)") do
            args[#args + 1] = tonumber(arg) or 0
          end
          
          if separator == separators.standard and commands[code] then
            commands[code](self, args)
          elseif separator == separators.control and control[code] then
            control[code](self, args)
          end
          
          wrap_cursor(self)
        end
      else
        -- handle BEL and \r
        if str:find("\a") then
          computer.beep()
        end
        str = str:gsub("\a", "")
        str = str:gsub("\r", "\27[G")

        local next_esc = str:find("\27")
        
        if next_esc then
          self.in_esc = true
          self.esc = ""
        
          local ln
          str, ln = pop(str, next_esc - 1, true)
          
          write(self, ln)
        else
          write(self, str)
          str = ""
        end
      end
    end

    if self.attributes.cursor then
      c, f, b, pf, pb = gpu.get(self.cx, self.cy)
    
      if pf then
        gpu.setForeground(pb, true)
        gpu.setBackground(pf, true)
      else
        gpu.setForeground(b)
        gpu.setBackground(f)
      end
      gpu.set(self.cx, self.cy, c)
      if pf then
        gpu.setForeground(self.fg, self.fgp)
        gpu.setBackground(self.bg, self.bgp)
      end
    end
    
    return true
  end

  function _stream:flush()
    if #self.wb > 0 then
      self:write_str(self.wb)
      self.wb = ""
    end
    return true
  end

  -- aliases of key scan codes to key inputs
  local aliases = {
    [200] = "\27[A", -- up
    [208] = "\27[B", -- down
    [205] = "\27[C", -- right
    [203] = "\27[D", -- left
  }

  local sigacts = {
    D = 1, -- hangup, TODO: check this is correct
    C = 2, -- interrupt
    Z = 18, -- keyboard stop
  }

  function _stream:key_down(...)
    local signal = table.pack(...)

    if not self.keyboards[signal[2]] then
      return
    end

    if signal[3] == 0 and signal[4] == 0 then
      return
    end

    if self.xoff then
      return
    end
    
    local char = aliases[signal[4]] or
              (signal[3] > 255 and unicode.char or string.char)(signal[3])
    local ch = signal[3]
    local tw = char

    if ch == 0 and not aliases[signal[4]] then
      return
    end
    
    if len(char) == 1 and ch == 0 then
      char = ""
      tw = ""
    elseif char:match("\27%[[ABCD]") then
      tw = string.format("^[%s", char:sub(-1))
    elseif #char == 1 and ch < 32 then
      local tch = string.char(
          (ch == 0 and 32) or
          (ch < 27 and ch + 96) or
          (ch == 27 and 91) or -- [
          (ch == 28 and 92) or -- \
          (ch == 29 and 93) or -- ]
          (ch == 30 and 126) or
          (ch == 31 and 63) or ch
        ):upper()
    
      if sigacts[tch] and not self.disabled[tch] and k.scheduler.processes
          and not self.attributes.raw then
        -- fairly stupid method of determining the foreground process:
        -- find the highest PID associated with this TTY
        -- yeah, it's stupid, but it should work in most cases.
        -- and where it doesn't the shell should handle it.
        local mxp = 0

        for _k, v in pairs(k.scheduler.processes) do
          --k.log(k.loglevels.error, _k, v.name, v.io.stderr.tty, self.ttyn)
          if v.io.stderr.tty == self.tty then
            mxp = math.max(mxp, _k)
          elseif v.io.stdin.tty == self.tty then
            mxp = math.max(mxp, _k)
          elseif v.io.stdout.tty == self.tty then
            mxp = math.max(mxp, _k)
          end
        end

        --k.log(k.loglevels.error, "sending", sigacts[tch], "to", mxp == 0 and mxp or k.scheduler.processes[mxp].name)

        if mxp > 0 then
          k.scheduler.kill(mxp, sigacts[tch])
        end

        self.rb = ""
        if tch == "\4" then self.rb = tch end
        char = ""
      end

      tw = "^" .. tch
    end
    
    if not self.attributes.raw then
      if ch == 13 then
        char = "\n"
        tw = "\n"
      elseif ch == 8 then
        if #self.rb > 0 then
          tw = "\27[D \27[D"
          self.rb = self.rb:sub(1, -2)
        else
          tw = ""
        end
        char = ""
      end
    end
    
    if self.attributes.echo and not self.attributes.xoff then
      self:write_str(tw or "")
    end
    
    if not self.attributes.xoff then
      self.rb = self.rb .. char
    end
  end

  function _stream:clipboard(...)
    local signal = table.pack(...)

    for c in signal[3]:gmatch(".") do
      self:key_down(signal[1], signal[2], c:byte(), 0)
    end
  end
  
  function _stream:read(n)
    checkArg(1, n, "number")

    self:flush()

    local dd = self.disabled.D or self.attributes.raw

    if self.attributes.line then
      while (not self.rb:find("\n")) or (len(self.rb:sub(1, (self.rb:find("\n")))) < n)
          and not (self.rb:find("\4") and not dd) do
        coroutine.yield()
      end
    else
      while len(self.rb) < n and (self.attributes.raw or not
          (self.rb:find("\4") and not dd)) do
        coroutine.yield()
      end
    end

    if self.rb:find("\4") and not dd then
      self.rb = ""
      return nil
    end

    local data = sub(self.rb, 1, n)
    self.rb = sub(self.rb, n + 1)
    return data
  end

  local function closed()
    return nil, "stream closed"
  end

  function _stream:close()
    self:flush()
    self.closed = true
    self.read = closed
    self.write = closed
    self.flush = closed
    self.close = closed
    k.event.unregister(self.key_handler_id)
    k.event.unregister(self.clip_handler_id)
    if self.ttyn then k.sysfs.unregister("/dev/tty"..self.ttyn) end
    return true
  end

  local ttyn = 0

  -- this is the raw function for creating TTYs over components
  -- userspace gets somewhat-abstracted-away stuff
  function k.create_tty(gpu, screen)
    checkArg(1, gpu, "string", "table")
    checkArg(2, screen, "string", "nil")

    local proxy
    if type(gpu) == "string" then
      proxy = component.proxy(gpu)

      if screen then proxy.bind(screen) end
    else
      proxy = gpu
    end

    -- set the gpu's palette
    for i=1, #colors, 1 do
      proxy.setPaletteColor(i - 1, colors[i])
    end

    proxy.setForeground(7, true)
    proxy.setBackground(0, true)

    proxy.setDepth(proxy.maxDepth())
    -- optimizations for no color on T1
    if proxy.getDepth() == 1 then
      local fg, bg = proxy.setForeground, proxy.setBackground
      local f, b = 7, 0
      function proxy.setForeground(c)
        -- [[
        if c >= 0xAAAAAA or c <= 0x000000 and f ~= c then
          fg(c)
        end
        f = c
        --]]
      end
      function proxy.setBackground(c)
        -- [[
        if c >= 0xDDDDDD or c <= 0x000000 and b ~= c then
          bg(c)
        end
        b = c
        --]]
      end
      proxy.getBackground = function()return f end
      proxy.getForeground = function()return b end
    end

    -- userspace will never directly see this, so it doesn't really matter what
    -- we put in this table
    local new = setmetatable({
      attributes = {echo=true,line=true,raw=false,cursor=false,xoff=false}, -- terminal attributes
      disabled = {}, -- disabled signals
      keyboards = {}, -- all attached keyboards on terminal initialization
      in_esc = false, -- was a partial escape sequence written
      gpu = proxy, -- the associated GPU
      esc = "", -- the escape sequence buffer
      cx = 1, -- the cursor's X position
      cy = 1, -- the cursor's Y position
      fg = 7, -- the current foreground color
      bg = 0, -- the current background color
      fgp = true, -- whether the foreground color is a palette index
      bgp = true, -- whether the background color is a palette index
      rb = "", -- a buffer of characters read from the input
      wb = "", -- line buffering at its finest
    }, {__index = _stream})

    -- avoid gpu.getResolution calls
    new.w, new.h = proxy.maxResolution()

    proxy.setResolution(new.w, new.h)
    proxy.fill(1, 1, new.w, new.h, " ")
    
    if screen then
      -- register all keyboards attached to the screen
      for _, keyboard in pairs(component.invoke(screen, "getKeyboards")) do
        new.keyboards[keyboard] = true
      end
    end
    
    -- register a keypress handler
    new.key_handler_id = k.event.register("key_down", function(...)
      return new:key_down(...)
    end)

    new.clip_handler_id = k.event.register("clipboard", function(...)
      return new:clipboard(...)
    end)
    
    -- register the TTY with the sysfs
    if k.sysfs then
      k.sysfs.register(k.sysfs.types.tty, new, "/dev/tty"..ttyn)
      new.ttyn = ttyn
    end

    new.tty = ttyn

    if k.gpus then
      k.gpus[ttyn] = proxy
    end
    
    ttyn = ttyn + 1
    
    return new
  end
end
--#include "base/tty.lua"
-- event handling --

do
  local event = {}
  local handlers = {}

  function event.handle(sig)
    for _, v in pairs(handlers) do
      if v.signal == sig[1] then
        v.callback(table.unpack(sig))
      end
    end
    if sig ~= "*" then event.handle("*") end
  end

  local n = 0
  function event.register(sig, call)
    checkArg(1, sig, "string")
    checkArg(2, call, "function")
    
    n = n + 1
    handlers[n] = {signal=sig,callback=call}
    return n
  end

  function event.unregister(id)
    checkArg(1, id, "number")
    handlers[id] = nil
    return true
  end

  k.event = event
end
--#include "base/event.lua"
-- early boot logger

do
  local levels = {
    debug = 0,
    info = 1,
    warn = 64,
    error = 128,
    panic = 256,
  }
  k.loglevels = levels

  local lgpu = component.list("gpu", true)()
  local lscr = component.list("screen", true)()

  local function safe_concat(...)
    local args = table.pack(...)
    local msg = ""
  
    for i=1, args.n, 1 do
      msg = string.format("%s%s%s", msg, tostring(args[i]), i < args.n and " " or "")
    end
    return msg
  end

  if lgpu and lscr then
    k.logio = k.create_tty(lgpu, lscr)
    
    if k.cmdline.bootsplash then
      local lgpu = component.proxy(lgpu)
      function k.log() end

      local splash = {
{{0,0,"⠀⠀⠀"},{16711680,0,"⢀⣠⣴⣾⣿⣿⣿⣿⣶⣤⣀"},{0,0,"⠀⠀⠀⠀"}},{{0,0,"⠀"},{16711680,0,"⢀⣴⣿"},{16711680,16777215,"⠿"},{16711680,0,"⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣄"},{0,0,"⠀⠀"}},{{16711680,0,"⢀⣾⣿⣿"},{0,16777215,"⠀⠀"},{16711680,16777215,"⠉"},{16711680,0,"⣿⣿⣿"},{16711680,16777215,"⡇⠈⠙⢻"},{16711680,0,"⣿⣿⣆"},{0,0,"⠀"}},{{16711680,0,"⣾⣿⣿⣿"},{0,16777215,"⠀⠀⠀"},{16711680,0,"⣿⣿⣿"},{16711680,16777215,"⡇"},{0,16777215,"⠀⠀"},{16711680,16777215,"⢸"},{16711680,0,"⣿⣿⣿⡆"}},{{16711680,0,"⣿⣿⣿⣿"},{0,16777215,"⠀⠀⠀"},{16711680,0,"⣿⣿⣿"},{16711680,16777215,"⡇"},{0,16777215,"⠀⠀"},{16711680,16777215,"⢸"},{16711680,0,"⣿⣿⣿⡇"}},{{16711680,0,"⢻⣿⣿⣿"},{16711680,16777215,"⡄"},{0,16777215,"⠀⠀"},{16711680,16777215,"⠈⠛⠋"},{0,16777215,"⠀⠀⠀"},{16711680,16777215,"⣼"},{16711680,0,"⣿⣿⣿⠃"}},{{0,0,"⠀"},{16711680,0,"⢻⣿⣿⣿"},{16711680,16777215,"⣦⡀"},{0,16777215,"⠀⠀⠀⠀"},{16711680,16777215,"⣠⣾"},{16711680,0,"⣿⣿⣿⠃"},{0,0,"⠀"}},{{0,0,"⠀⠀"},{16711680,0,"⠙⢿⣿⣿⣿"},{16711680,16777215,"⣷⣶⣶"},{16711680,0,"⣿⣿⣿⣿⠟⠁"},{0,0,"⠀⠀"}},{{0,0,"⠀⠀⠀⠀"},{16711680,0,"⠈⠙⠻⠿⠿⠿⠿⠛⠉"},{0,0,"⠀⠀⠀⠀⠀"}},{},{{0xffffff,0,"       ULOS       "}},
        --#include "extra/bootsplash-ulos.lua"
      }

      local w, h = lgpu.maxResolution()
      local x, y = (w // 2) - 10, (h // 2) - (#splash // 2)
      lgpu.setResolution(w, h)
      lgpu.fill(1, 1, w, h, " ")
      for i, line in ipairs(splash) do
        local xo = 0
        for _, ent in ipairs(line) do
          lgpu.setForeground(ent[1])
          lgpu.setBackground(ent[2])
          lgpu.set(x + xo, y + i - 1, ent[3])
          xo = xo + utf8.len(ent[3])
        end
      end
    else
      function k.log(level, ...)
        local msg = safe_concat(...)
        msg = msg:gsub("\t", "  ")
  
        if k.util and not k.util.concat then
          k.util.concat = safe_concat
        end
      
        if (tonumber(k.cmdline.loglevel) or 1) <= level then
          k.logio:write(string.format("[\27[35m%4.4f\27[37m] %s\n", k.uptime(),
            msg))
        end
        return true
      end
    end
  else
    k.logio = nil
    function k.log()
    end
  end

  local raw_pullsignal = computer.pullSignal
  
  function k.panic(...)
    local msg = safe_concat(...)
  
    computer.beep(440, 0.25)
    computer.beep(380, 0.25)

    -- if there's no log I/O, just die
    if not k.logio then
      error(msg)
    end
    
    k.log(k.loglevels.panic, "-- \27[91mbegin stacktrace\27[37m --")
    
    local traceback = debug.traceback(msg, 2)
      :gsub("\t", "  ")
      :gsub("([^\n]+):(%d+):", "\27[96m%1\27[37m:\27[95m%2\27[37m:")
      :gsub("'([^']+)'\n", "\27[93m'%1'\27[37m\n")
    
    for line in traceback:gmatch("[^\n]+") do
      k.log(k.loglevels.panic, line)
    end

    k.log(k.loglevels.panic, "-- \27[91mend stacktrace\27[37m --")
    k.log(k.loglevels.panic, "\27[93m!! \27[91mPANIC\27[93m !!\27[37m")
    
    while true do raw_pullsignal() end
  end
end

k.log(math.huge, "Starting\27[93m", _OSVERSION, "\27[37m")
--#include "base/logger.lua"
-- kernel hooks

k.log(k.loglevels.info, "base/hooks")

do
  local hooks = {}
  k.hooks = {}
  
  function k.hooks.add(name, func)
    checkArg(1, name, "string")
    checkArg(2, func, "function")

    hooks[name] = hooks[name] or {}
    table.insert(hooks[name], func)
  end

  function k.hooks.call(name, ...)
    checkArg(1, name, "string")

    k.logio:write(":: calling hook " .. name .. "\n")
    if hooks[name] then
      for k, v in ipairs(hooks[name]) do
        v(...)
      end
    end
  end
end
--#include "base/hooks.lua"
-- some utilities --

k.log(k.loglevels.info, "base/util")

do
  local util = {}
  
  function util.merge_tables(a, b)
    for k, v in pairs(b) do
      if not a[k] then
        a[k] = v
      end
    end
  
    return a
  end

  -- here we override rawset() in order to properly protect tables
  local _rawset = rawset
  local blacklist = setmetatable({}, {__mode = "k"})
  
  function _G.rawset(t, k, v)
    if not blacklist[t] then
      return _rawset(t, k, v)
    else
      -- this will error
      t[k] = v
    end
  end

  local function protecc()
    error("attempt to modify a write-protected table")
  end

  function util.protect(tbl)
    local new = {}
    local mt = {
      __index = tbl,
      __newindex = protecc,
      __pairs = function() return pairs(tbl) end,
      __ipairs = function() return ipairs(tbl) end,
      __metatable = {}
    }
  
    return setmetatable(new, mt)
  end

  -- create hopefully memory-friendly copies of tables
  -- uses metatable magic
  -- this is a bit like util.protect except tables are still writable
  -- even i still don't fully understand how this works, but it works
  -- nonetheless
  --[[disabled due to some issues i was having
  if computer.totalMemory() < 262144 then
    -- if we have 256k or less memory, use the mem-friendly function
    function util.copy_table(tbl)
      if type(tbl) ~= "table" then return tbl end
      local shadow = {}
      local copy_mt = {
        __index = function(_, k)
          local item = rawget(shadow, k) or rawget(tbl, k)
          return util.copy(item)
        end,
        __pairs = function()
          local iter = {}
          for k, v in pairs(tbl) do
            iter[k] = util.copy(v)
          end
          for k, v in pairs(shadow) do
            iter[k] = v
          end
          return pairs(iter)
        end
        -- no __metatable: leaving this metatable exposed isn't a huge
        -- deal, since there's no way to access `tbl` for writing using any
        -- of the functions in it.
      }
      copy_mt.__ipairs = copy_mt.__pairs
      return setmetatable(shadow, copy_mt)
    end
  else--]] do
    -- from https://lua-users.org/wiki/CopyTable
    local function deepcopy(orig, copies)
      copies = copies or {}
      local orig_type = type(orig)
      local copy
    
      if orig_type == 'table' then
        if copies[orig] then
          copy = copies[orig]
        else
          copy = {}
          copies[orig] = copy
      
          for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key, copies)] = deepcopy(orig_value, copies)
          end
          
          setmetatable(copy, deepcopy(getmetatable(orig), copies))
        end
      else -- number, string, boolean, etc
        copy = orig
      end

      return copy
    end

    function util.copy_table(t)
      return deepcopy(t)
    end
  end

  function util.to_hex(str)
    local ret = ""
    
    for char in str:gmatch(".") do
      ret = string.format("%s%02x", ret, string.byte(char))
    end
    
    return ret
  end

  -- lassert: local assert
  -- removes the "init:123" from errors (fires at level 0)
  function util.lassert(a, ...)
    if not a then error(..., 0) else return a, ... end
  end

  -- pipes for IPC and shells and things
  do
    local _pipe = {}

    function _pipe:read(n)
      if self.closed and #self.rb == 0 then
        return nil
      end
      if not self.closed then
        while (not self.closed) and #self.rb < n do
          if self.from ~= 0 then
            k.scheduler.info().data.self.resume_next = self.from
          end
          coroutine.yield(1)
        end
      end
      local data = self.rb:sub(1, n)
      self.rb = self.rb:sub(n + 1)
      return data
    end

    function _pipe:write(dat)
      if self.closed then
        k.scheduler.kill(nil, k.scheduler.signals.pipe)
        return nil, "broken pipe"
      end
      self.rb = self.rb .. dat
      return true
    end

    function _pipe:flush()
      return true
    end

    function _pipe:close()
      self.closed = true
      return true
    end

    function util.make_pipe()
      local new = k.create_fstream(setmetatable({
        from = 0, -- the process providing output
        to = 0, -- the process reading input
        rb = "",
      }, {__index = _pipe}), "rw")
      new.buffer_mode = "pipe"
      return new
    end

    k.hooks.add("sandbox", function()
      k.userspace.package.loaded.pipe = {
        create = util.make_pipe
      }
    end)
  end

  k.util = util
end
--#include "base/util.lua"
-- some security-related things --

k.log(k.loglevels.info, "base/security")

k.security = {}

-- users --

k.log(k.loglevels.info, "base/security/users")

-- from https://github.com/philanc/plc iirc

k.log(k.loglevels.info, "base/security/sha3.lua")

do
-- sha3 / keccak

local char	= string.char
local concat	= table.concat
local spack, sunpack = string.pack, string.unpack

-- the Keccak constants and functionality

local ROUNDS = 24

local roundConstants = {
0x0000000000000001,
0x0000000000008082,
0x800000000000808A,
0x8000000080008000,
0x000000000000808B,
0x0000000080000001,
0x8000000080008081,
0x8000000000008009,
0x000000000000008A,
0x0000000000000088,
0x0000000080008009,
0x000000008000000A,
0x000000008000808B,
0x800000000000008B,
0x8000000000008089,
0x8000000000008003,
0x8000000000008002,
0x8000000000000080,
0x000000000000800A,
0x800000008000000A,
0x8000000080008081,
0x8000000000008080,
0x0000000080000001,
0x8000000080008008
}

local rotationOffsets = {
-- ordered for [x][y] dereferencing, so appear flipped here:
{0, 36, 3, 41, 18},
{1, 44, 10, 45, 2},
{62, 6, 43, 15, 61},
{28, 55, 25, 21, 56},
{27, 20, 39, 8, 14}
}



-- the full permutation function
local function keccakF(st)
	local permuted = st.permuted
	local parities = st.parities
	for round = 1, ROUNDS do
--~ 		local permuted = permuted
--~ 		local parities = parities

		-- theta()
		for x = 1,5 do
			parities[x] = 0
			local sx = st[x]
			for y = 1,5 do parities[x] = parities[x] ~ sx[y] end
		end
		--
		-- unroll the following loop
		--for x = 1,5 do
		--	local p5 = parities[(x)%5 + 1]
		--	local flip = parities[(x-2)%5 + 1] ~ ( p5 << 1 | p5 >> 63)
		--	for y = 1,5 do st[x][y] = st[x][y] ~ flip end
		--end
		local p5, flip, s
		--x=1
		p5 = parities[2]
		flip = parities[5] ~ (p5 << 1 | p5 >> 63)
		s = st[1]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=2
		p5 = parities[3]
		flip = parities[1] ~ (p5 << 1 | p5 >> 63)
		s = st[2]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=3
		p5 = parities[4]
		flip = parities[2] ~ (p5 << 1 | p5 >> 63)
		s = st[3]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=4
		p5 = parities[5]
		flip = parities[3] ~ (p5 << 1 | p5 >> 63)
		s = st[4]
		for y = 1,5 do s[y] = s[y] ~ flip end
		--x=5
		p5 = parities[1]
		flip = parities[4] ~ (p5 << 1 | p5 >> 63)
		s = st[5]
		for y = 1,5 do s[y] = s[y] ~ flip end

		-- rhopi()
		for y = 1,5 do
			local py = permuted[y]
			local r
			for x = 1,5 do
				s, r = st[x][y], rotationOffsets[x][y]
				py[(2*x + 3*y)%5 + 1] = (s << r | s >> (64-r))
			end
		end

		local p, p1, p2
		--x=1
		s, p, p1, p2 = st[1], permuted[1], permuted[2], permuted[3]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=2
		s, p, p1, p2 = st[2], permuted[2], permuted[3], permuted[4]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=3
		s, p, p1, p2 = st[3], permuted[3], permuted[4], permuted[5]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=4
		s, p, p1, p2 = st[4], permuted[4], permuted[5], permuted[1]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end
		--x=5
		s, p, p1, p2 = st[5], permuted[5], permuted[1], permuted[2]
		for y = 1,5 do s[y] = p[y] ~ (~ p1[y]) & p2[y] end

		-- iota()
		st[1][1] = st[1][1] ~ roundConstants[round]
	end
end


local function absorb(st, buffer)

	local blockBytes = st.rate / 8
	local blockWords = blockBytes / 8

	-- append 0x01 byte and pad with zeros to block size (rate/8 bytes)
	local totalBytes = #buffer + 1
	-- SHA3:
	buffer = buffer .. ( '\x06' .. char(0):rep(blockBytes - (totalBytes % blockBytes)))
	totalBytes = #buffer

	--convert data to an array of u64
	local words = {}
	for i = 1, totalBytes - (totalBytes % 8), 8 do
		words[#words + 1] = sunpack('<I8', buffer, i)
	end

	local totalWords = #words
	-- OR final word with 0x80000000 to set last bit of state to 1
	words[totalWords] = words[totalWords] | 0x8000000000000000

	-- XOR blocks into state
	for startBlock = 1, totalWords, blockWords do
		local offset = 0
		for y = 1, 5 do
			for x = 1, 5 do
				if offset < blockWords then
					local index = startBlock+offset
					st[x][y] = st[x][y] ~ words[index]
					offset = offset + 1
				end
			end
		end
		keccakF(st)
	end
end


-- returns [rate] bits from the state, without permuting afterward.
-- Only for use when the state will immediately be thrown away,
-- and not used for more output later
local function squeeze(st)
	local blockBytes = st.rate / 8
	local blockWords = blockBytes / 4
	-- fetch blocks out of state
	local hasht = {}
	local offset = 1
	for y = 1, 5 do
		for x = 1, 5 do
			if offset < blockWords then
				hasht[offset] = spack("<I8", st[x][y])
				offset = offset + 1
			end
		end
	end
	return concat(hasht)
end


-- primitive functions (assume rate is a whole multiple of 64 and length is a whole multiple of 8)

local function keccakHash(rate, length, data)
	local state = {	{0,0,0,0,0},
					{0,0,0,0,0},
					{0,0,0,0,0},
					{0,0,0,0,0},
					{0,0,0,0,0},
	}
	state.rate = rate
	-- these are allocated once, and reused
	state.permuted = { {}, {}, {}, {}, {}, }
	state.parities = {0,0,0,0,0}
	absorb(state, data)
	return squeeze(state):sub(1,length/8)
end

-- output raw bytestrings
local function keccak256Bin(data) return keccakHash(1088, 256, data) end
local function keccak512Bin(data) return keccakHash(576, 512, data) end

k.sha3 = {
	sha256 = keccak256Bin,
	sha512 = keccak512Bin,
}
end
--#include "base/security/sha3.lua"

do
  local api = {}

  -- default root data so we can at least run init as root
  -- the kernel should overwrite this with `users.prime()`
  -- and data from /etc/passwd later on
  -- but for now this will suffice
  local passwd = {
    [0] = {
      name = "root",
      home = "/root",
      shell = "/bin/sh",
      acls = 8191,
      pass = k.util.to_hex(k.sha3.sha256("root")),
    }
  }

  k.hooks.add("shutdown", function()
    -- put this here so base/passwd_init can have it
    k.passwd = passwd
  end)

  function api.prime(data)
    checkArg(1, data, "table")
 
    api.prime = nil
    passwd = data
    k.passwd = data
    
    return true
  end

  function api.authenticate(uid, pass)
    checkArg(1, uid, "number")
    checkArg(2, pass, "string")
    
    pass = k.util.to_hex(k.sha3.sha256(pass))
    
    local udata = passwd[uid]
    
    if not udata then
      os.sleep(1)
      return nil, "no such user"
    end
    
    if pass == udata.pass then
      return true
    end
    
    os.sleep(1)
    return nil, "invalid password"
  end

  function api.exec_as(uid, pass, func, pname, wait, stdio)
    checkArg(1, uid, "number")
    checkArg(2, pass, "string")
    checkArg(3, func, "function")
    checkArg(4, pname, "string", "nil")
    checkArg(5, wait, "boolean", "nil")
    checkArg(6, stdio, "FILE*", "nil")
    
    if k.scheduler.info().owner ~= 0 then
      if not k.security.acl.user_has_permission(k.scheduler.info().owner,
          k.security.acl.permissions.user.SUDO) then
        return nil, "permission denied: no permission"
      end
    
      if not api.authenticate(uid, pass) then
        return nil, "permission denied: bad login"
      end
    end
    
    local new = {
      func = func,
      name = pname or tostring(func),
      owner = uid,
      input = stdio,
      output = stdio,
      stdin = stdio,
      stdout = stdio,
      stderr = stdio,
      env = {
        USER = passwd[uid].name,
        UID = tostring(uid),
        SHELL = passwd[uid].shell,
        HOME = passwd[uid].home,
      }
    }
    
    local p = k.scheduler.spawn(new)
    
    if not wait then return p.pid end

    -- this is the only spot in the ENTIRE kernel where process.await is used
    return k.userspace.package.loaded.process.await(p.pid)
  end

  function api.get_uid(uname)
    checkArg(1, uname, "string")
    
    for uid, udata in pairs(passwd) do
      if udata.name == uname then
        return uid
      end
    end
    
    return nil, "no such user"
  end

  function api.attributes(uid)
    checkArg(1, uid, "number")
    
    local udata = passwd[uid]
    
    if not udata then
      return nil, "no such user"
    end
    
    return {
      name = udata.name,
      home = udata.home,
      shell = udata.shell,
      acls = udata.acls
    }
  end

  function api.usermod(attributes)
    checkArg(1, attributes, "table")
    attributes.uid = tonumber(attributes.uid) or (#passwd + 1)

    k.log(k.loglevels.debug, "changing attributes for user " .. attributes.uid)
    
    local current = k.scheduler.info().owner or 0
    
    if not passwd[attributes.uid] then
      assert(attributes.name, "usermod: a username is required")
      assert(attributes.pass, "usermod: a password is required")
      assert(attributes.acls, "usermod: ACL data is required")
      assert(type(attributes.acls) == "table","usermod: ACL data must be a table")
    else
      if attributes.pass and current ~= 0 and current ~= attributes.uid then
        -- only root can change someone else's password
        return nil, "cannot change password: permission denied"
      end
      for k, v in pairs(passwd[attributes.uid]) do
        attributes[k] = attributes[k] or v
      end
    end

    attributes.home = attributes.home or "/home/" .. attributes.name
    k.log(k.loglevels.debug, "shell = " .. attributes.shell)
    attributes.shell = (attributes.shell or "/bin/lsh"):gsub("%.lua$", "")
    k.log(k.loglevels.debug, "shell = " .. attributes.shell)

    local acl = k.security.acl
    if type(attributes.acls) == "table" then
      local acls = 0
      
      for k, v in pairs(attributes.acls) do
        if acl.permissions.user[k] and v then
          acls = acls | acl.permissions.user[k]
          if not acl.user_has_permission(current, acl.permissions.user[k])
              and current ~= 0 then
            return nil, k .. ": ACL permission denied"
          end
        else
          return nil, k .. ": no such ACL"
        end
      end

      attributes.acls = acls
    end

    passwd[tonumber(attributes.uid)] = attributes

    return true
  end

  function api.remove(uid)
    checkArg(1, uid, "number")
    if not passwd[uid] then
      return nil, "no such user"
    end

    if not k.security.acl.user_has_permission(k.scheduler.info().owner,
        k.security.acl.permissions.user.MANAGE_USERS) then
      return nil, "permission denied"
    end

    passwd[uid] = nil
    
    return true
  end
  
  k.security.users = api
end
--#include "base/security/users.lua"
-- access control lists, mostly --

k.log(k.loglevels.info, "base/security/access_control")

do
  -- this implementation of ACLs is fairly basic.
  -- it only supports boolean on-off permissions rather than, say,
  -- allowing users only to log on at certain times of day.
  local permissions = {
    user = {
      SUDO = 1,
      MOUNT = 2,
      OPEN_UNOWNED = 4,
      COMPONENTS = 8,
      HWINFO = 16,
      SETARCH = 32,
      MANAGE_USERS = 64,
      BOOTADDR = 128,
      HOSTNAME = 256,
    },
    file = {
      OWNER_READ = 1,
      OWNER_WRITE = 2,
      OWNER_EXEC = 4,
      GROUP_READ = 8,
      GROUP_WRITE = 16,
      GROUP_EXEC = 32,
      OTHER_READ = 64,
      OTHER_WRITE = 128,
      OTHER_EXEC = 256
    }
  }

  local acl = {}

  acl.permissions = permissions

  function acl.user_has_permission(uid, permission)
    checkArg(1, uid, "number")
    checkArg(2, permission, "number")
  
    local attributes, err = k.security.users.attributes(uid)
    
    if not attributes then
      return nil, err
    end
    
    return acl.has_permission(attributes.acls, permission)
  end

  function acl.has_permission(perms, permission)
    checkArg(1, perms, "number")
    checkArg(2, permission, "number")
    
    return perms & permission ~= 0
  end

  k.security.acl = acl
end
--#include "base/security/access_control.lua"
--#include "base/security.lua"
-- some shutdown related stuff

k.log(k.loglevels.info, "base/shutdown")

do
  local shutdown = computer.shutdown
  
  function k.shutdown(rbt)
    k.is_shutting_down = true
    k.hooks.call("shutdown", rbt)
    k.log(k.loglevels.info, "shutdown: shutting down")
    shutdown(rbt)
  end

  computer.shutdown = k.shutdown
end
--#include "base/shutdown.lua"
-- some component API conveniences

k.log(k.loglevels.info, "base/component")

do
  function component.get(addr, mkpx)
    checkArg(1, addr, "string")
    checkArg(2, mkpx, "boolean", "nil")
    
    for k, v in component.list() do
      if k:sub(1, #addr) == addr then
        return mkpx and component.proxy(k) or k
      end
    end
    
    return nil, "no such component"
  end

  setmetatable(component, {
    __index = function(t, k)
      local addr = component.list(k)()
      if not addr then
        error(string.format("no component of type '%s'", k))
      end
    
      return component.proxy(addr)
    end
  })
end
--#include "base/component.lua"
-- fsapi: VFS and misc filesystem infrastructure

k.log(k.loglevels.info, "base/fsapi")

do
  local fs = {}

  -- common error codes
  fs.errors = {
    file_not_found = "no such file or directory",
    is_a_directory = "is a directory",
    not_a_directory = "not a directory",
    read_only = "target is read-only",
    failed_read = "failed opening file for reading",
    failed_write = "failed opening file for writing",
    file_exists = "file already exists"
  }

  -- standard file types
  fs.types = {
    file = 1,
    directory = 2,
    link = 3,
    special = 4
  }

  -- This VFS should support directory overlays, fs mounting, and directory
  --    mounting, hopefully all seamlessly.
  -- mounts["/"] = { node = ..., children = {["bin"] = "usr/bin", ...}}
  local mounts = {}
  fs.mounts = mounts

  local function split(path)
    local segments = {}
    
    for seg in path:gmatch("[^/]+") do
      if seg == ".." then
        segments[#segments] = nil
      elseif seg ~= "." then
        segments[#segments + 1] = seg
      end
    end
    
    return segments
  end

  fs.split = split

  -- "clean" a path
  local function clean(path)
    return table.concat(split(path), "/")
  end

  fs.clean = clean

  local faux = {children = mounts}
  local resolving = {}

  local function resolve(path, must_exist)
    if resolving[path] then
      return nil, "recursive mount detected"
    end
    
    path = clean(path)
    resolving[path] = true

    local current, parent = mounts["/"] or faux

    if not mounts["/"] then
      resolving[path] = nil
      return nil, "root filesystem is not mounted!"
    end

    if path == "" or path == "/" then
      resolving[path] = nil
      return mounts["/"], nil, ""
    end
    
    if current.children[path] then
      resolving[path] = nil
      return current.children[path], nil, ""
    end
    
    local segments = split(path)
    
    local base_n = 1 -- we may have to traverse multiple mounts
    
    for i=1, #segments, 1 do
      local try = table.concat(segments, "/", base_n, i)
    
      if current.children[try] then
        base_n = i + 1 -- we are now at this stage of the path
        local next_node = current.children[try]
      
        if type(next_node) == "string" then
          local err
          next_node, err = resolve(next_node)
        
          if not next_node then
            resolving[path] = false
            return nil, err
          end
        end
        
        parent = current
        current = next_node
      elseif not current.node:stat(try) then
        resolving[path] = false

        return nil, fs.errors.file_not_found
      end
    end
    
    resolving[path] = false
    local ret = "/"..table.concat(segments, "/", base_n, #segments)
    
    if must_exist and not current.node:stat(ret) then
      return nil, fs.errors.file_not_found
    end
    
    return current, parent, ret
  end

  local registered = {partition_tables = {}, filesystems = {}}

  local _managed = {}
  function _managed:info()
    return {
      read_only = self.node.isReadOnly(),
      address = self.node.address
    }
  end

  function _managed:stat(file)
    checkArg(1, file, "string")

    if not self.node.exists(file) then
      return nil, fs.errors.file_not_found
    end
    
    local info = {
      permissions = self:info().read_only and 365 or 511,
      type        = self.node.isDirectory(file) and fs.types.directory or fs.types.file,
      isDirectory = self.node.isDirectory(file),
      owner       = -1,
      group       = -1,
      lastModified= self.node.lastModified(file),
      size        = self.node.size(file)
    }

    if file:sub(1, -4) == ".lua" then
      info.permissions = info.permissions | k.security.acl.permissions.file.OWNER_EXEC
      info.permissions = info.permissions | k.security.acl.permissions.file.GROUP_EXEC
      info.permissions = info.permissions | k.security.acl.permissions.file.OTHER_EXEC
    end

    return info
  end

  function _managed:touch(file, ftype)
    checkArg(1, file, "string")
    checkArg(2, ftype, "number", "nil")
    
    if self.node.isReadOnly() then
      return nil, fs.errors.read_only
    end
    
    if self.node.exists(file) then
      return nil, fs.errors.file_exists
    end
    
    if ftype == fs.types.file or not ftype then
      local fd = self.node.open(file, "w")
    
      if not fd then
        return nil, fs.errors.failed_write
      end
      
      self.node.write(fd, "")
      self.node.close(fd)
    elseif ftype == fs.types.directory then
      local ok, err = self.node.makeDirectory(file)
      
      if not ok then
        return nil, err or "unknown error"
      end
    elseif ftype == fs.types.link then
      return nil, "unsupported operation"
    end
    
    return true
  end
  
  function _managed:remove(file)
    checkArg(1, file, "string")
    
    if not self.node.exists(file) then
      return nil, fs.errors.file_not_found
    end
    
    if self.node.isDirectory(file) and #(self.node.list(file) or {}) > 0 then
      return nil, fs.errors.is_a_directory
    end
    
    return self.node.remove(file)
  end

  function _managed:list(path)
    checkArg(1, path, "string")
    
    if not self.node.exists(path) then
      return nil, fs.errors.file_not_found
    elseif not self.node.isDirectory(path) then
      return nil, fs.errors.not_a_directory
    end
    
    local files = self.node.list(path) or {}
    
    return files
  end
  
  local function fread(s, n)
    return s.node.read(s.fd, n)
  end

  local function fwrite(s, d)
    return s.node.write(s.fd, d)
  end

  local function fseek(s, w, o)
    return s.node.seek(s.fd, w, o)
  end

  local function fclose(s)
    return s.node.close(s.fd)
  end

  function _managed:open(file, mode)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
    
    if (mode == "r" or mode == "a") and not self.node.exists(file) then
      return nil, fs.errors.file_not_found
    end
    
    local handle, err = self.node.open(file, mode or "r")
    if not handle then return nil, err or "failed opening file" end

    local fd = {
      fd = handle,
      node = self.node,
      read = fread,
      write = fwrite,
      seek = fseek,
      close = fclose
    }
    
    return fd
  end
  
  local fs_mt = {__index = _managed}
  local function create_node_from_managed(proxy)
    return setmetatable({node = proxy}, fs_mt)
  end

  local function create_node_from_unmanaged(proxy)
    local fs_superblock = proxy.readSector(1)
    
    for k, v in pairs(registered.filesystems) do
      if v.is_valid_superblock(superblock) then
        return v.new(proxy)
      end
    end
    
    return nil, "no compatible filesystem driver available"
  end

  fs.PARTITION_TABLE = "partition_tables"
  fs.FILESYSTEM = "filesystems"
  
  function fs.register(category, driver)
    if not registered[category] then
      return nil, "no such category: " .. category
    end
  
    table.insert(registered[category], driver)
    return true
  end

  function fs.get_partition_table_driver(filesystem)
    checkArg(1, filesystem, "string", "table")
    
    if type(filesystem) == "string" then
      filesystem = component.proxy(filesystem)
    end
    
    if filesystem.type == "filesystem" then
      return nil, "managed filesystem has no partition table"
    else -- unmanaged drive - perfect
      for k, v in pairs(registered.partition_tables) do
        if v.has_valid_superblock(proxy) then
          return v.create(proxy)
        end
      end
    end
    
    return nil, "no compatible partition table driver available"
  end

  function fs.get_filesystem_driver(filesystem)
    checkArg(1, filesystem, "string", "table")
    
    if type(filesystem) == "string" then
      filesystem = component.proxy(filesystem)
    end
    
    if filesystem.type == "filesystem" then
      return create_node_from_managed(filesystem)
    else
      return create_node_from_unmanaged(filesystem)
    end
  end

  -- actual filesystem API now
  fs.api = {}
  
  function fs.api.open(file, mode)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
  
    mode = mode or "r"

    if mode:match("[wa]") then
      fs.api.touch(file)
    end

    local node, err, path = resolve(file)
    if not node then
      return nil, err
    end
    
    local data = node.node:stat(path)
    local user = (k.scheduler.info() or {owner=0}).owner
    -- TODO: groups
    
    do
      local perms = k.security.acl.permissions.file
      local rperm, wperm
    
      if data.owner ~= user then
        rperm = perms.OTHER_READ
        wperm = perms.OTHER_WRITE
      else
        rperm = perms.OWNER_READ
        wperm = perms.OWNER_WRITE
      end
      
      if ((mode == "r" and not
          k.security.acl.has_permission(data.permissions, rperm)) or
          ((mode == "w" or mode == "a") and not
          k.security.acl.has_permission(data.permissions, wperm))) and not
          k.security.acl.user_has_permission(user,
          k.security.acl.permissions.user.OPEN_UNOWNED) then
        return nil, "permission denied"
      end
    end
    
    return node.node:open(path, mode)
  end

  function fs.api.stat(file)
    checkArg(1, file, "string")
    
    local node, err, path = resolve(file)
    
    if not node then
      return nil, err
    end

    return node.node:stat(path)
  end

  function fs.api.touch(file, ftype)
    checkArg(1, file, "string")
    checkArg(2, ftype, "number", "nil")
    
    ftype = ftype or fs.types.file
    
    local root, base = file:match("^(/?.+)/([^/]+)/?$")
    root = root or "/"
    base = base or file
    
    local node, err, path = resolve(root)
    
    if not node then
      return nil, err
    end
    
    return node.node:touch(path .. "/" .. base, ftype)
  end

  local n = {}
  function fs.api.list(path)
    checkArg(1, path, "string")
    
    local node, err, fpath = resolve(path, true)

    if not node then
      return nil, err
    end

    local ok, err = node.node:list(fpath)
    if not ok and err then
      return nil, err
    end

    ok = ok or {}
    local used = {}
    for _, v in pairs(ok) do used[v] = true end

    if node.children then
      for k in pairs(node.children) do
        if not k:match(".+/.+") then
          local info = fs.api.stat(path.."/"..k)
          if (info or n).isDirectory then
            k = k .. "/"
          end
          if info and not used[k] then
            ok[#ok + 1] = k
          end
        end
      end
    end
   
    return ok
  end

  function fs.api.remove(file)
    checkArg(1, file, "string")
    
    local node, err, path = resolve(file)
    
    if not node then
      return nil, err
    end
    
    return node.node:remove(path)
  end

  local mounted = {}

  fs.api.types = {
    RAW = 0,
    NODE = 1,
    OVERLAY = 2,
  }
  
  function fs.api.mount(node, fstype, path)
    checkArg(1, node, "string", "table")
    checkArg(2, fstype, "number")
    checkArg(2, path, "string")
    
    local device, err = node
    
    if fstype ~= fs.api.types.RAW then
      -- TODO: properly check object methods first
      goto skip
    end
    
    device, err = fs.get_filesystem_driver(node)
    if not device then
      local sdev, serr = k.sysfs.retrieve(node)
      if not sdev then return nil, serr end
      device, err = fs.get_filesystem_driver(sdev)
    end
    
    ::skip::

    if type(device) == "string" and fstype ~= fs.types.OVERLAY then
      device = component.proxy(device)
      if (not device) then
        return nil, "no such component"
      elseif device.type ~= "filesystem" and device.type ~= "drive" then
        return nil, "component is not a drive or filesystem"
      end

      if device.type == "filesystem" then
        device = create_node_from_managed(device)
      else
        device = create_node_from_unmanaged(device)
      end
    end

    if not device then
      return nil, err
    end

    if device.type == "filesystem" then
    end
    
    path = clean(path)
    if path == "" then path = "/" end
    
    local root, fname = path:match("^(/?.+)/([^/]+)/?$")
    root = root or "/"
    fname = fname or path
    
    local pnode, err, rpath
    
    if path == "/" then
      mounts["/"] = {node = device, children = {}}
      mounted["/"] = (device.node and device.node.getLabel
        and device.node.getLabel()) or device.node
        and device.node.address or "unknown"
      return true
    else
      pnode, err, rpath = resolve(root)
    end

    if not pnode then
      return nil, err
    end
    
    local full = clean(string.format("%s/%s", rpath, fname))
    if full == "" then full = "/" end

    if type(device) == "string" then
      pnode.children[full] = device
    else
      pnode.children[full] = {node=device, children={}}
      mounted[path]=(device.node and device.node.getLabel
        and device.node.getLabel()) or device.node
        and device.node.address or "unknown"
    end
    
    return true
  end

  function fs.api.umount(path)
    checkArg(1, path, "string")
    
    path = clean(path)
    
    local root, fname = path:match("^(/?.+)/([^/]+)/?$")
    root = root or "/"
    fname = fname or path
    
    local node, err, rpath = resolve(root)
    
    if not node then
      return nil, err
    end
    
    local full = clean(string.format("%s/%s", rpath, fname))
    node.children[full] = nil
    mounted[path] = nil
    
    return true
  end

  function fs.api.mounts()
    local new = {}
    -- prevent programs from meddling with these
    for k,v in pairs(mounted) do new[("/"..k):gsub("[\\/]+", "/")] = v end
    return new
  end

  k.fs = fs
end
--#include "base/fsapi.lua"
-- the Lua standard library --

-- stdlib: os

do
  function os.execute()
    error("os.execute must be implemented by userspace", 0)
  end

  function os.setenv(K, v)
    local info = k.scheduler.info()
    if not info then return end
    info.data.env[K] = v
  end

  function os.getenv(K)
    local info = k.scheduler.info()

    if not info then return end
    
    if not K then
      return info.data.env
    end

    return info.data.env[K]
  end

  function os.sleep(n)
    checkArg(1, n, "number")

    local max = computer.uptime() + n
    repeat
      coroutine.yield(max - computer.uptime())
    until computer.uptime() >= max

    return true
  end

  function os.exit(n)
    checkArg(1, n, "number", "nil")
    n = n or 0
    coroutine.yield("__internal_process_exit", n)
  end
end
--#include "base/stdlib/os.lua"
-- implementation of the FILE* API --

k.log(k.loglevels.info, "base/stdlib/FILE*")

do
  local buffer = {}
 
  function buffer:read_byte()
    if __internal_yield then __internal_yield(1) end
    if self.buffer_mode ~= "none" and self.buffer_mode ~= "pipe" then
      if (not self.read_buffer) or #self.read_buffer == 0 then
        self.read_buffer = self.base:read(self.buffer_size)
      end
  
      if not self.read_buffer then
        self.closed = true
        return nil
      end
      
      local dat = self.read_buffer:sub(1,1)
      self.read_buffer = self.read_buffer:sub(2, -1)
      
      return dat
    else
      return self.base:read(1)
    end
  end

  function buffer:write_byte(byte)
    if self.buffer_mode ~= "none" and self.buffer_mode ~= "pipe" then
      if #self.write_buffer >= self.buffer_size then
        self.base:write(self.write_buffer)
        self.write_buffer = ""
      end
      
      self.write_buffer = string.format("%s%s", self.write_buffer, byte)
    else
      return self.base:write(byte)
    end

    return true
  end

  function buffer:read_line()
    local line = ""
    
    repeat
      local c = self:read_byte()
      line = line .. (c or "")
    until c == "\n" or not c
    
    return line
  end

  local valid = {
    a = true,
    l = true,
    L = true,
    n = true
  }

  function buffer:read_formatted(fmt)
    checkArg(1, fmt, "string", "number")
    
    if type(fmt) == "number" then
      if fmt == 0 then return "" end
      local read = ""
    
      repeat
        local byte = self:read_byte()
        read = read .. (byte or "")
      until #read >= fmt or not byte
      
      return read
    else
      fmt = fmt:gsub("%*", ""):sub(1,1)
      
      if #fmt == 0 or not valid[fmt] then
        error("bad argument to 'read' (invalid format)")
      end
      
      if fmt == "l" or fmt == "L" then
        local line = self:read_line()
      
        if #line == 0 then
          return nil
        end

        if fmt == "l" then
          line = line:gsub("\n", "")
        end
        
        return line
      elseif fmt == "a" then
        local read = ""
        
        repeat
          local byte = self:read_byte()
          read = read .. (byte or "")
        until not byte
        
        return read
      elseif fmt == "n" then
        local read = ""
        
        repeat
          local byte = self:read_byte()
          if not tonumber(byte) then
            -- TODO: this breaks with no buffering
            self.read_buffer = byte .. self.read_buffer
          else
            read = read .. (byte or "")
          end
        until not tonumber(byte)
        
        return tonumber(read)
      end

      error("bad argument to 'read' (invalid format)")
    end
  end

  function buffer:read(...)
    if self.buffer_mode == "pipe" then
      if self.closed and #self.base.rb == 0 then
        return nil, "bad file descriptor"
      end
    elseif self.closed or not self.mode.r then
      return nil, "bad file descriptor"
    end
    
    local args = table.pack(...)
    if args.n == 0 then args[1] = "l" args.n = 1 end
    
    local read = {}
    for i=1, args.n, 1 do
      read[i] = self:read_formatted(args[i])
    end
    
    return table.unpack(read)
  end

  function buffer:lines(format)
    format = format or "l"
    
    return function()
      return self:read(format)
    end
  end

  function buffer:write(...)
    if self.closed and self.buffer_mode ~= "pipe" then
      return nil, "bad file descriptor"
    end
    
    local args = table.pack(...)
    local write = ""
    
    for i=1, #args, 1 do
      checkArg(i, args[i], "string", "number")
    
      args[i] = tostring(args[i])
      write = string.format("%s%s", write, args[i])
    end
    
    if self.buffer_mode == "none" then
      -- a-ha! performance shortcut!
      -- because writing in a chunk is much faster
      return self.base:write(write)
    end

    for i=1, #write, 1 do
      local char = write:sub(i,i)
      self:write_byte(char)
    end

    return true
  end

  function buffer:seek(whence, offset)
    checkArg(1, whence, "string")
    checkArg(2, offset, "number")
    
    if self.closed then
      return nil, "bad file descriptor"
    end
    
    self:flush()
    return self.base:seek()
  end

  function buffer:flush()
    if self.closed then
      return nil, "bad file descriptor"
    end
    
    if #self.write_buffer > 0 then
      self.base:write(self.write_buffer)
      self.write_buffer = ""
    end

    if self.base.flush then
      self.base:flush()
    end
    
    return true
  end

  function buffer:close()
    self:flush()
    self.base:close()
    self.closed = true
  end

  local fmt = {
    __index = buffer,
    -- __metatable = {},
    __name = "FILE*"
  }

  function k.create_fstream(base, mode)
    checkArg(1, base, "table")
    checkArg(2, mode, "string")
  
    local new = {
      base = base,
      buffer_size = 512,
      read_buffer = "",
      write_buffer = "",
      buffer_mode = "standard", -- standard, line, none
      closed = false,
      mode = {}
    }
    
    for c in mode:gmatch(".") do
      new.mode[c] = true
    end
    
    setmetatable(new, fmt)
    return new
  end

  k.hooks.add("sandbox", function()
    k.userspace.package.loaded.fstream = {
      create = k.create_fstream
    }
  end)
end
--#include "base/stdlib/FILE.lua"
-- io library --

k.log(k.loglevels.info, "base/stdlib/io")

do
  local fs = k.fs.api
  local im = {stdin = 0, stdout = 1, stderr = 2}
 
  local mt = {
    __index = function(t, f)
      if not k.scheduler then return k.logio end
      local info = k.scheduler.info()
  
      if info and info.data and info.data.io then
        return info.data.io[f]
      end
      
      return nil
    end,
    __newindex = function(t, f, v)
      local info = k.scheduler.info()
      if not info then return nil end
      info.data.io[f] = v
      info.data.handles[im[f]] = v
    end
  }

  _G.io = {}

  local function makePathCanonical(path)
    if path:sub(1,1) ~= "/" then
      path = k.fs.clean((os.getenv("PWD") or "/") .. "/" .. path)
    end
    return path
  end
  
  function io.open(file, mode)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")

    file = makePathCanonical(file)
  
    mode = mode or "r"

    local handle, err = fs.open(file, mode)
    if not handle then
      return nil, err
    end

    local fstream = k.create_fstream(handle, mode)

    local info = k.scheduler.info()
    if info then
      info.data.handles[#info.data.handles + 1] = fstream
      fstream.n = #info.data.handles
      
      local close = fstream.close
      function fstream:close()
        close(self)
        info.data.handles[self.n] = nil
      end
    end
    
    return fstream
  end

  -- popen should be defined in userspace so the shell can handle it.
  -- tmpfile should be defined in userspace also.
  -- it turns out that defining things PUC Lua can pass off to the shell
  -- *when you don't have a shell* is rather difficult and so, instead of
  -- weird hacks like in Paragon or Monolith, I just leave it up to userspace.
  function io.popen()
    return nil, "io.popen unsupported at kernel level"
  end

  function io.tmpfile()
    return nil, "io.tmpfile unsupported at kernel level"
  end

  function io.read(...)
    return io.input():read(...)
  end

  function io.write(...)
    return io.output():write(...)
  end

  function io.lines(file, fmt)
    file = file or io.stdin

    if type(file) == "string" then
      file = assert(io.open(file, "r"))
    end
    
    checkArg(1, file, "FILE*")
    
    return file:lines(fmt)
  end

  local function stream(kk)
    return function(v)
      if v then checkArg(1, v, "FILE*", "string") end
      if type(v) == "string" then
        local hd, err = io.open(v, kk == "input" and "r" or "w")
        if not err then
          error("cannot open file '" .. v .. "' (" .. err .. ")")
        end
        v = hd
      end

      if not k.scheduler.info() then
        return k.logio
      end
      local t = k.scheduler.info().data.io
    
      if v then
        t[kk] = v
      end
      
      return t[kk]
    end
  end

  io.input = stream("input")
  io.output = stream("output")

  function io.type(stream)
    assert(stream, "bad argument #1 (value expected)")
    
    if type(stream) == "FILE*" then
      if stream.closed then
        return "closed file"
      end
    
      return "file"
    end

    return nil
  end

  function io.flush(s)
    s = s or io.stdout
    checkArg(1, s, "FILE*")

    return s:flush()
  end

  function io.close(stream)
    checkArg(1, stream, "FILE*")

    if stream == io.stdin or stream == io.stdout or stream == io.stderr then
      return nil, "cannot close standard file"
    end
    
    return stream:close()
  end

  setmetatable(io, mt)
  k.hooks.add("sandbox", function()
    setmetatable(k.userspace.io, mt)
  end)

  function _G.print(...)
    local args = table.pack(...)
   
    for i=1, args.n, 1 do
      args[i] = tostring(args[i])
    end
    
    return (io.stdout or io.output()):write(
      table.concat(args, "  ", 1, args.n), "\n")
  end
end
--#include "base/stdlib/io.lua"
-- package API.  this is probably the lib i copy-paste the most. --

k.log(k.loglevels.info, "base/stdlib/package")

do
  _G.package = {}
 
  local loaded = {
    os = os,
    io = io,
    math = math,
    string = string,
    table = table,
    users = k.users,
    sha3 = k.sha3,
    unicode = unicode
  }
  
  package.loaded = loaded
  package.path = "/lib/?.lua;/lib/lib?.lua;/lib/?/init.lua;/usr/lib/?.lua;/usr/lib/lib?.lua;/usr/lib/?/init.lua"
  
  local fs = k.fs.api

  local function libError(name, searched)
    local err = "module '%s' not found:\n\tno field package.loaded['%s']"
    err = err .. ("\n\tno file '%s'"):rep(#searched)
  
    return string.format(err, name, name, table.unpack(searched))
  end

  function package.searchpath(name, path, sep, rep)
    checkArg(1, name, "string")
    checkArg(2, path, "string")
    checkArg(3, sep, "string", "nil")
    checkArg(4, rep, "string", "nil")
    
    sep = "%" .. (sep or ".")
    rep = rep or "/"
    
    local searched = {}
    
    name = name:gsub(sep, rep)
    
    for search in path:gmatch("[^;]+") do
      search = search:gsub("%?", name)
    
      if fs.stat(search) then
        return search
      end
      
      searched[#searched + 1] = search
    end

    return nil, libError(name, searched)
  end

  package.protect = k.util.protect

  function package.delay(lib, file)
    local mt = {
      __index = function(tbl, key)
        setmetatable(lib, nil)
        setmetatable(lib.internal or {}, nil)
        ; -- this is just in case, because Lua is weird
        (k.userspace.dofile or dofile)(file)
    
        return tbl[key]
      end
    }

    if lib.internal then
      setmetatable(lib.internal, mt)
    end
    
    setmetatable(lib, mt)
  end

  -- let's define this here because WHY NOT
  -- now with shebang support!
  local shebang_pattern = "^#!(/.-)\n"
  local ldf_loading = {}
  local ldf_cache = {}
  local ldf_mem_thresh = tonumber(k.cmdline["loadcache.gc_threshold"]) or 4096
  local ldf_max_age = tonumber(k.cmdline["loadcache.max_age"]) or 60

  k.event.register("*", function()
    for k, v in pairs(ldf_cache) do
      if ldf.time < computer.uptime() - ldf_max_age then
        ldf_cache[k] = nil
      end
    end
    if computer.freeMemory() <= ldf_mem_thresh then
      ldf_cache = {}
    end
  end)

  function _G.loadfile(file, mode, env)
    checkArg(1, file, "string")
    checkArg(2, mode, "string", "nil")
    checkArg(3, env, "table", "nil")

    if ldf_loading[file] then
      return nil, "file is already loading, likely due to a shebang error"
    end

    file = k.fs.clean(file)

    local fstat, err = k.fs.api.stat(file)
    if not fstat then
      return nil, err
    end

    if ldf_cache[file]and fstat.lastModified<=ldf_cache[file].lastModified then
      ldf_cache[file].time = computer.uptime()
      return ldf_cache[file].func
    end
    
    local handle, err = io.open(file, "r")
    if not handle then
      return nil, err
    end

    ldf_loading[file] = true
    
    local data = handle:read("a")
    handle:close()

    local shebang = data:match(shebang_pattern) 
    if shebang then
      if not shebang:match("lua") then
        if k.fsapi.stat(shebang .. ".lua") then shebang = shebang .. ".lua" end
        local ok, err = loadfile(shebang)
        ldf_loading[file] = false
        if not ok and err then
          return nil, "error loading interpreter: " .. err
        end
        return function(...) return ok(file, ...) end
      else
        data = data:gsub(shebang_pattern, "")
      end
    end

    ldf_loading[file] = false

    local ok, err = load(data, "="..file, "bt", env or k.userspace or _G)
    if ok then
      ldf_cache[file] = {
        func = ok,
        time = computer.uptime(),
        lastModified = fstat.lastModified
      }
    end
    return ok, err
  end

  function _G.dofile(file)
    checkArg(1, file, "string")
    
    local ok, err = loadfile(file)
    if not ok then
      error(err, 0)
    end
    
    local stat, ret = xpcall(ok, debug.traceback)
    if not stat and ret then
      error(ret, 0)
    end
    
    return ret
  end

  local k = k
  k.hooks.add("sandbox", function()
    k.userspace.k = nil
    
    local acl = k.security.acl
    local perms = acl.permissions
    
    local function wrap(f, p)
      return function(...)
        if not acl.user_has_permission(k.scheduler.info().owner,
            p) then
          error("permission denied", 0)
        end
    
        return f(...)
      end
    end

    k.userspace.component = nil
    k.userspace.computer = nil
    k.userspace.unicode = nil

    k.userspace.package.loaded.component = {}
    
    for f,v in pairs(component) do
      k.userspace.package.loaded.component[f] = wrap(v,
        perms.user.COMPONENTS)
    end
    
    k.userspace.package.loaded.computer = {
      getDeviceInfo = wrap(computer.getDeviceInfo, perms.user.HWINFO),
      setArchitecture = wrap(computer.setArchitecture, perms.user.SETARCH),
      addUser = wrap(computer.addUser, perms.user.MANAGE_USERS),
      removeUser = wrap(computer.removeUser, perms.user.MANAGE_USERS),
      setBootAddress = wrap(computer.setBootAddress, perms.user.BOOTADDR),
      pullSignal = coroutine.yield,
      pushSignal = function(...)
        return k.scheduler.info().data.self:push_signal(...)
      end
    }
    
    for f, v in pairs(computer) do
      k.userspace.package.loaded.computer[f] =
        k.userspace.package.loaded.computer[f] or v
    end
    
    k.userspace.package.loaded.unicode = k.util.copy_table(unicode)
    k.userspace.package.loaded.filesystem = k.util.copy_table(k.fs.api)
    
    local ufs = k.userspace.package.loaded.filesystem
    ufs.mount = wrap(k.fs.api.mount, perms.user.MOUNT)
    ufs.umount = wrap(k.fs.api.umount, perms.user.MOUNT)
    
    k.userspace.package.loaded.filetypes = k.util.copy_table(k.fs.types)

    k.userspace.package.loaded.users = k.util.copy_table(k.security.users)

    k.userspace.package.loaded.acls = k.util.copy_table(k.security.acl.permissions)

    local blacklist = {}
    for k in pairs(k.userspace.package.loaded) do blacklist[k] = true end

    local shadow = k.userspace.package.loaded
    k.userspace.package.loaded = setmetatable({}, {
      __newindex = function(t, k, v)
        if shadow[k] and blacklist[k] then
          error("cannot override protected library " .. k, 0)
        else
          shadow[k] = v
        end
      end,
      __index = shadow,
      __pairs = shadow,
      __ipairs = shadow,
      __metatable = {}
    })

    local loaded = k.userspace.package.loaded
    local loading = {}
    function k.userspace.require(module)
      if loaded[module] then
        return loaded[module]
      elseif not loading[module] then
        local library, status, step
  
        step, library, status = "not found",
            package.searchpath(module, package.path)
  
        if library then
          step, library, status = "loadfile failed", loadfile(library)
        end
  
        if library then
          loading[module] = true
          step, library, status = "load failed", pcall(library, module)
          loading[module] = false
        end
  
        assert(library, string.format("module '%s' %s:\n%s",
            module, step, status))
  
        loaded[module] = status
        return status
      else
        error("already loading: " .. module .. "\n" .. debug.traceback(), 2)
      end
    end
  end)
end
--#include "base/stdlib/package.lua"
--#include "base/stdlib.lua"
-- custom types

k.log(k.loglevels.info, "base/types")

do
  local old_type = type
  function _G.type(obj)
    if old_type(obj) == "table" then
      local s, mt = pcall(getmetatable, obj)
      
      if not s and mt then
        -- getting the metatable failed, so it's protected.
        -- instead, we should tostring() it - if the __name
        -- field is set, we can let the Lua VM get the
        -- """type""" for us.
        local t = tostring(obj):gsub(" [%x+]$", "")
        return t
      end
       
      -- either there is a metatable or ....not. If
      -- we have gotten this far, the metatable was
      -- at least not protected, so we can carry on
      -- as normal.  And yes, i have put waaaay too
      -- much effort into making this comment be
      -- almost a rectangular box :)
      mt = mt or {}
 
      return mt.__name or mt.__type or old_type(obj)
    else
      return old_type(obj)
    end
  end

  -- ok time for cursed shit: aliasing one type to another
  -- i will at least blacklist the default Lua types
  local cannot_alias = {
    string = true,
    number = true,
    boolean = true,
    ["nil"] = true,
    ["function"] = true,
    table = true,
    userdata = true
  }
  local defs = {}
  
  -- ex. typedef("number", "int")
  function _G.typedef(t1, t2)
    checkArg(1, t1, "string")
    checkArg(2, t2, "string")
  
    if cannot_alias[t2] then
      error("attempt to override default type")
    end

    if defs[t2] then
      error("cannot override existing typedef")
    end
    
    defs[t2] = t1
    
    return true
  end

  -- copied from machine.lua, with modifications
  function _G.checkArg(n, have, ...)
    have = type(have)
    
    local function check(want, ...)
      if not want then
        return false
      else
        return have == want or defs[want] == have or check(...)
      end
    end
    
    if type(n) == "number" then n = string.format("#%d", n)
    else n = "'"..tostring(n).."'" end
    if not check(...) then
      local name = debug.getinfo(3, 'n').name
      local msg = string.format("bad argument %s to '%s' (%s expected, got %s)",
                                n, name, table.concat(table.pack(...), " or "),
                                have)
      error(msg, 2)
    end
  end
end
--#include "base/types.lua"
-- binary struct
-- note that to make something unsigned you ALWAYS prefix the type def with
-- 'u' rather than 'unsigned ' due to Lua syntax limitations.
-- ex:
-- local example = struct {
--   uint16("field_1"),
--   string[8]("field_2")
-- }
-- local copy = example "\0\14A string"
-- yes, there is lots of metatable hackery behind the scenes

k.log(k.loglevels.info, "ksrc/struct")

do
  -- step 1: change the metatable of _G so we can have convenient type notation
  -- without technically cluttering _G
  local gmt = {}
  
  local types = {
    int = "i",
    uint = "I",
    bool = "b", -- currently booleans are just signed 8-bit values because reasons
    short = "h",
    ushort = "H",
    long = "l",
    ulong = "L",
    size_t = "T",
    float = "f",
    double = "d",
    lpstr = "s",
  }

  -- char is a special case:
  --   - the user may want a single byte (char("field"))
  --   - the user may also want a fixed-length string (char[42]("field"))
  local char = {}
  setmetatable(char, {
    __call = function(field)
      return {fmtstr = "B", field = field}
    end,
    __index = function(t, k)
      if type(k) == "number" then
        return function(value)
          return {fmtstr = "c" .. k, field = value}
        end
      else
        error("invalid char length specifier")
      end
    end
  })

  function gmt.__index(t, k)
    if k == "char" then
      return char
    else
      local tp
  
      for t, v in pairs(types) do
        local match = k:match("^"..t)
        if match then tp = t break end
      end
      
      if not tp then return nil end
      
      return function(value)
        return {fmtstr = types[tp] .. tonumber(k:match("%d+$") or "0")//8,
          field = value}
      end
    end
  end

  -- step 2: change the metatable of string so we can have string length
  -- notation.  Note that this requires a null-terminated string.
  local smt = {}

  function smt.__index(t, k)
    if type(k) == "number" then
      return function(value)
        return {fmtstr = "z", field = value}
      end
    end
  end

  -- step 3: apply these metatable hacks
  setmetatable(_G, gmt)
  setmetatable(string, smt)

  -- step 4: ???

  -- step 5: profit

  function struct(fields, name)
    checkArg(1, fields, "table")
    checkArg(2, name, "string", "nil")
    
    local pat = "<"
    local args = {}
    
    for i=1, #fields, 1 do
      local v = fields[i]
      pat = pat .. v.fmtstr
      args[i] = v.field
    end
  
    return setmetatable({}, {
      __call = function(_, data)
        assert(type(data) == "string" or type(data) == "table",
          "bad argument #1 to struct constructor (string or table expected)")
    
        if type(data) == "string" then
          local set = table.pack(string.unpack(pat, data))
          local ret = {}
        
          for i=1, #args, 1 do
            ret[args[i]] = set[i]
          end
          
          return ret
        elseif type(data) == "table" then
          local set = {}
          
          for i=1, #args, 1 do
            set[i] = data[args[i]]
          end
          
          return string.pack(pat, table.unpack(set))
        end
      end,
      __len = function()
        return string.packsize(pat)
      end,
      __name = name or "struct"
    })
  end
end
--#include "base/struct.lua"
-- system log API hook for userspace

k.log(k.loglevels.info, "base/syslog")

do
  local mt = {
    __name = "syslog"
  }

  local syslog = {}
  local open = {}

  function syslog.open(pname)
    checkArg(1, pname, "string", "nil")

    pname = pname or k.scheduler.info().name

    local n = math.random(1, 999999999)
    open[n] = pname
    
    return n
  end

  function syslog.write(n, ...)
    checkArg(1, n, "number")
    
    if not open[n] then
      return nil, "bad file descriptor"
    end
    
    k.log(k.loglevels.info, open[n] .. ":", ...)

    return true
  end

  function syslog.close(n)
    checkArg(1, n, "number")
    
    if not open[n] then
      return nil, "bad file descriptor"
    end
    
    open[n] = nil

    return true
  end

  k.hooks.add("sandbox", function()
    k.userspace.package.loaded.syslog = k.util.copy_table(syslog)
  end)
end
--#include "base/syslog.lua"
-- wrap load() to forcibly insert yields --

k.log(k.loglevels.info, "base/load")

if (not k.cmdline.no_force_yields) then
  local patterns = {
    --[[
    { "if([ %(])(.-)([ %)])then([ \n])", "if%1%2%3then%4__internal_yield() " },
    { "elseif([ %(])(.-)([ %)])then([ \n])", "elseif%1%2%3then%4__internal_yield() " },
    { "([ \n])else([ \n])", "%1else%2__internal_yield() " },--]]
    { "([%);\n ])do([ \n%(])", "%1do%2__internal_yield() "},
    { "([%);\n ])repeat([ \n%(])", "%1repeat%2__internal_yield() " },
  }

  local old_load = load

  local max_time = tonumber(k.cmdline.max_process_time) or 0.1

  local function process_section(s)
    for i=1, #patterns, 1 do
      s = s:gsub(patterns[i][1], patterns[i][2])
    end
    return s
  end

  local function process(chunk)
    local i = 1
    local ret = ""
    local nq = 0
    local in_blocks = {}
    while true do
      local nextquote = chunk:find("[^\\][\"']", i)
      if nextquote then
        local ch = chunk:sub(i, nextquote)
        i = nextquote + 1
        nq = nq + 1
        if nq % 2 == 1 then
          ch = process_section(ch)
        end
        ret = ret .. ch
      else
        local nbs, nbe = chunk:find("%[=*%[", i)
        if nbs and nbe then
          ret = ret .. process_section(chunk:sub(i, nbs - 1))
          local match = chunk:find("%]" .. ("="):rep((nbe - nbs) - 1) .. "%]")
          if not match then
            -- the Lua parser will error here, no point in processing further
            ret = ret .. chunk:sub(nbs)
            break
          end
          local ch = chunk:sub(nbs, match)
          ret = ret .. ch --:sub(1,-2)
          i = match + 1
        else
          ret = ret .. process_section(chunk:sub(i))
          i = #chunk
          break
        end
      end
    end

    if i < #chunk then ret = ret .. process_section(chunk:sub(i)) end

    return ret
  end

  function _G.load(chunk, name, mode, env)
    checkArg(1, chunk, "function", "string")
    checkArg(2, name, "string", "nil")
    checkArg(3, mode, "string", "nil")
    checkArg(4, env, "table", "nil")

    local data = ""
    if type(chunk) == "string" then
      data = chunk
    else
      repeat
        local ch = chunk()
        data = data .. (ch or "")
      until not ch
    end

    chunk = process(chunk)

    if k.cmdline.debug_load then
      local handle = io.open("/load.txt", "a")
      handle:write(" -- load: ", name or "(no name)", " --\n", chunk)
      handle:close()
    end

    env = env or k.userspace or _G

    local ok, err = old_load(chunk, name, mode, env)
    if not ok then
      return nil, err
    end
    
    local ysq = {}
    return function(...)
      local last_yield = computer.uptime()
      local old_iyield = env.__internal_yield
      local old_cyield = env.coroutine.yield
      
      env.__internal_yield = function(tto)
        if computer.uptime() - last_yield >= (tto or max_time) then
          last_yield = computer.uptime()
          local msg = table.pack(old_cyield(0.05))
          if msg.n > 0 then ysq[#ysq+1] = msg end
        end
      end
      
      env.coroutine.yield = function(...)
        if #ysq > 0 then
          return table.unpack(table.remove(ysq, 1))
        end
        last_yield = computer.uptime()
        local msg = table.pack(old_cyield(...))
        ysq[#ysq+1] = msg
        return table.unpack(table.remove(ysq, 1))
      end
      
      local result = table.pack(ok(...))
      env.__internal_yield = old_iyield
      env.coroutine.yield = old_cyield

      return table.unpack(result)
    end
  end
end
--#include "base/load.lua"
-- thread: wrapper around coroutines

k.log(k.loglevels.info, "base/thread")

do
  local function handler(err)
    return debug.traceback(err, 3)
  end

  local old_coroutine = coroutine
  local _coroutine = {}
  _G.coroutine = _coroutine
  if k.cmdline.no_wrap_coroutine then
    k.hooks.add("sandbox", function()
      k.userspace.coroutine = old_coroutine
    end)
  end
  
  function _coroutine.create(func)
    checkArg(1, func, "function")
  
    return setmetatable({
      __thread = old_coroutine.create(function()
        return select(2, k.util.lassert(xpcall(func, handler)))
      end)
    }, {
      __index = _coroutine,
      __name = "thread"
    })
  end

  function _coroutine.wrap(fnth)
    checkArg(1, fnth, "function", "thread")
    
    if type(fnth) == "function" then fnth = _coroutine.create(fnth) end
    
    return function(...)
      return select(2, fnth:resume(...))
    end
  end

  function _coroutine:resume(...)
    return old_coroutine.resume(self.__thread, ...)
  end

  function _coroutine:status()
    return old_coroutine.status(self.__thread)
  end

  for k,v in pairs(old_coroutine) do
    _coroutine[k] = _coroutine[k] or v
  end
end
--#include "base/thread.lua"
-- processes
-- mostly glorified coroutine sets

k.log(k.loglevels.info, "base/process")

do
  local process = {}
  local proc_mt = {
    __index = process,
    __name = "process"
  }

  function process:resume(...)
    local result
    for k, v in ipairs(self.threads) do
      result = result or table.pack(v:resume(...))
  
      if v:status() == "dead" then
        table.remove(self.threads, k)
      
        if not result[1] then
          self:push_signal("thread_died", v.id)
        
          return nil, result[2]
        end
      end
    end

    if not next(self.threads) then
      self.dead = true
    end
    
    return table.unpack(result)
  end

  local id = 0
  function process:add_thread(func)
    checkArg(1, func, "function")
    
    local new = coroutine.create(func)
    
    id = id + 1
    new.id = id
    
    self.threads[#self.threads + 1] = new
    
    return id
  end

  function process:status()
    return self.coroutine:status()
  end

  local c_pushSignal = computer.pushSignal
  
  function process:push_signal(...)
    local signal = table.pack(...)
    table.insert(self.queue, signal)
    return true
  end

  -- there are no timeouts, the scheduler manages that
  function process:pull_signal()
    if #self.queue > 0 then
      return table.remove(self.queue, 1)
    end
  end

  local pid = 0

  -- default signal handlers
  local defaultHandlers = {
    [0] = function() end,
    [1] = function(self) self.pstatus = "got SIGHUP" self.dead = true end,
    [2] = function(self) self.pstatus = "interrupted" self.dead = true end,
    [3] = function(self) self.pstatus = "got SIGQUIT" self.dead = true end,
    [9] = function(self) self.pstatus = "killed" self.dead = true end,
    [13] = function(self) self.pstatus = "broken pipe" self.dead = true end,
    [18] = function(self) self.stopped = true end,
  }
  
  function k.create_process(args)
    pid = pid + 1
  
    local new
    new = setmetatable({
      name = args.name,
      pid = pid,
      io = {
        stdin = args.stdin or {},
        input = args.input or args.stdin or {},
        stdout = args.stdout or {},
        output = args.output or args.stdout or {},
        stderr = args.stderr or args.stdout or {}
      },
      queue = {},
      threads = {},
      waiting = true,
      stopped = false,
      handles = {},
      coroutine = {},
      cputime = 0,
      deadline = 0,
      env = args.env and k.util.copy_table(args.env) or {},
      signal = setmetatable({}, {
        __call = function(_, self, s)
          -- don't block SIGSTOP or SIGCONT
          if s == 17 or s == 19 then
            self.stopped = s == 17
            return true
          end
          -- and don't block SIGKILL, unless we're init
          if self.pid ~= 1 and s == 9 then
            self.pstatus = "killed" self.dead = true return true end
          if self.signal[s] then
            return self.signal[s](self)
          else
            return (defaultHandlers[s] or defaultHandlers[0])(self)
          end
        end,
        __index = defaultHandlers
      })
    }, proc_mt)
    
    args.stdin, args.stdout, args.stderr,
                  args.input, args.output = nil, nil, nil, nil, nil
    
    for k, v in pairs(args) do
      new[k] = v
    end

    new.handles[0] = new.stdin
    new.handles[1] = new.stdout
    new.handles[2] = new.stderr
    
    new.coroutine.status = function(self)
      if self.dead then
        return "dead"
      elseif self.stopped then
        return "stopped"
      elseif self.waiting then
        return "waiting"
      else
        return "running"
      end
    end
    
    return new
  end
end
--#include "base/process.lua"
-- scheduler

k.log(k.loglevels.info, "base/scheduler")

do
  local globalenv = {
    UID = 0,
    USER = "root",
    TERM = "cynosure",
    PWD = "/",
    HOSTNAME = "localhost"
  }

  local processes = {}
  local current

  local api = {}

  api.signals = {
    hangup = 1,
    interrupt = 2,
    quit = 3,
    kill = 9,
    pipe = 13,
    stop = 17,
    kbdstop = 18,
    continue = 19
  }

  function api.spawn(args)
    checkArg(1, args.name, "string")
    checkArg(2, args.func, "function")
    
    local parent = processes[current or 0] or
      (api.info() and api.info().data.self) or {}
    
    local new = k.create_process {
      name = args.name,
      parent = parent.pid or 0,
      stdin = args.stdin or parent.stdin or (io and io.input()),
      stdout = args.stdout or parent.stdout or (io and io.output()),
      stderr = args.stderr or parent.stderr or (io and io.stderr),
      input = args.input or parent.stdin or (io and io.input()),
      output = args.output or parent.stdout or (io and io.output()),
      owner = args.owner or parent.owner or 0,
      env = args.env or {}
    }

    for k, v in pairs(parent.env or globalenv) do
      new.env[k] = new.env[k] or v
    end

    new:add_thread(args.func)
    processes[new.pid] = new
    
    assert(k.sysfs.register(k.sysfs.types.process, new, "/proc/"..math.floor(
        new.pid)))
    
    return new
  end

  function api.info(pid)
    checkArg(1, pid, "number", "nil")
    
    pid = pid or current
    
    local proc = processes[pid]
    if not proc then
      return nil, "no such process"
    end

    local info = {
      pid = proc.pid,
      name = proc.name,
      waiting = proc.waiting,
      stopped = proc.stopped,
      deadline = proc.deadline,
      n_threads = #proc.threads,
      status = proc:status(),
      cputime = proc.cputime,
      owner = proc.owner
    }
    
    if proc.pid == current then
      info.data = {
        io = proc.io,
        self = proc,
        handles = proc.handles,
        coroutine = proc.coroutine,
        env = proc.env
      }
    end
    
    return info
  end

  function api.kill(proc, signal)
    checkArg(1, proc, "number", "nil")
    checkArg(2, signal, "number")
    
    proc = proc or (processes[current] or {}).pid
    
    if not processes[proc] then
      return nil, "no such process"
    end
    
    processes[proc]:signal(signal)
    
    return true
  end

  -- XXX: this is specifically for kernel use ***only*** - userspace does NOT
  -- XXX: get this function.  it is incredibly dangerous and should be used with
  -- XXX: the utmost caution.
  api.processes = processes
  function api.get(pid)
    checkArg(1, pid, "number", current and "nil")
    pid = pid or current
    if not processes[pid] then
      return nil, "no such process"
    end
    return processes[pid]
  end

  local function closeFile(file)
    if file.close and file.buffer_mode ~= "pipe" and not file.tty then
      pcall(file.close, file) end
  end

  local function handleDeath(proc, exit, err, ok)
    local exit = err or 0
    err = err or ok

    if type(err) == "string" then
      exit = 127
    else
      exit = err or 0
      err = proc.pstatus or "exited"
    end

    err = err or "died"
    if (k.cmdline.log_process_death and
        k.cmdline.log_process_death ~= 0) then
      -- if we can, put the process death info on the same stderr stream
      -- belonging to the process that died
      if proc.io.stderr and proc.io.stderr.write then
        local old_logio = k.logio
        k.logio = proc.io.stderr
        k.log(k.loglevels.info, "process died:", proc.pid, exit, err)
        k.logio = old_logio
      else
        k.log(k.loglevels.warn, "process died:", proc.pid, exit, err)
      end
    end

    computer.pushSignal("process_died", proc.pid, exit, err)

    for k, v in pairs(proc.handles) do
      pcall(v.close, v)
    end
    for k,v in pairs(proc.io) do closeFile(v) end

    local ppt = "/proc/" .. math.floor(proc.pid)
    k.sysfs.unregister(ppt)
    
    processes[proc.pid] = nil
  end

  local pullSignal = computer.pullSignal
  function api.loop()
    while next(processes) do
      local to_run = {}
      local going_to_run = {}
      local min_timeout = math.huge
    
      for _, v in pairs(processes) do
        if not v.stopped then
          min_timeout = math.min(min_timeout, v.deadline - computer.uptime())
        end
      
        if min_timeout <= 0 then
          min_timeout = 0
          break
        end
      end
      
      --k.log(k.loglevels.info, min_timeout)
      
      local sig = table.pack(pullSignal(min_timeout))
      k.event.handle(sig)

      for _, v in pairs(processes) do
        if (v.deadline <= computer.uptime() or #v.queue > 0 or sig.n > 0) and
            not (v.stopped or going_to_run[v.pid] or v.dead) then
          to_run[#to_run + 1] = v
      
          if v.resume_next then
            to_run[#to_run + 1] = v.resume_next
            going_to_run[v.resume_next.pid] = true
          end
        elseif v.dead then
          handleDeath(v, v.exit_code or 1, v.status or "killed")
        end
      end

      for i, proc in ipairs(to_run) do
        local psig = sig
        current = proc.pid
      
        if #proc.queue > 0 then
          -- the process has queued signals
          -- but we don't want to drop this signal
          proc:push_signal(table.unpack(sig))
          
          psig = proc:pull_signal() -- pop a signal
        end
        
        local start_time = computer.uptime()
        local aok, ok, err = proc:resume(table.unpack(psig))

        if proc.dead or ok == "__internal_process_exit" or not aok then
          if ok == "__internal_process_exit" then proc.pstatus = "exited" end
          handleDeath(proc, exit, err, ok)
        else
          proc.cputime = proc.cputime + computer.uptime() - start_time
          proc.deadline = computer.uptime() + (tonumber(ok) or tonumber(err)
            or math.huge)
        end
      end
    end

    if not k.is_shutting_down then
      -- !! PANIC !!
      k.panic("all user processes died")
    end
  end

  k.scheduler = api

  k.hooks.add("shutdown", function()
    if not k.is_shutting_down then
      return
    end

    k.log(k.loglevels.info, "shutdown: sending shutdown signal")

    for pid, proc in pairs(processes) do
      proc:resume("shutdown")
    end

    k.log(k.loglevels.info, "shutdown: waiting 1s for processes to exit")
    os.sleep(1)

    k.log(k.loglevels.info, "shutdown: killing all processes")

    for pid, proc in pairs(processes) do
      if pid ~= current then -- hack to make sure shutdown carries on
        proc.dead = true
      end
    end

    coroutine.yield(0) -- clean up
  end)
  
  -- sandbox hook for userspace 'process' api
  k.hooks.add("sandbox", function()
    local p = {}
    k.userspace.package.loaded.process = p
    
    function p.spawn(args)
      checkArg(1, args, "table")
      checkArg("name", args.name, "string")
      checkArg("func", args.func, "function")
      checkArg("env", args.env, "table", "nil")
      checkArg("stdin", args.stdin, "FILE*", "nil")
      checkArg("stdout", args.stdout, "FILE*", "nil")
      checkArg("stderr", args.stderr, "FILE*", "nil")
      checkArg("input", args.input, "FILE*", "nil")
      checkArg("output", args.output, "FILE*", "nil")
    
      local sanitized = {
        func = args.func,
        name = args.name,
        stdin = args.stdin,
        stdout = args.stdout,
        input = args.input,
        output = args.output,
        stderr = args.stderr,
        env = args.env
      }
      
      local new = api.spawn(sanitized)
      
      return new.pid
    end
    
    function p.kill(pid, signal)
      checkArg(1, pid, "number", "nil")
      checkArg(2, signal, "number")
      
      local cur = processes[current]
      local atmp = processes[pid]
      
      if not atmp then
        return true
      end
      
      if (atmp or {owner=processes[current].owner}).owner ~= cur.owner and
         cur.owner ~= 0 then
        return nil, "permission denied"
      end
      
      return api.kill(pid, signal)
    end
    
    function p.list()
      local pr = {}
      
      for k, v in pairs(processes) do
        pr[#pr+1]=k
      end
      
      table.sort(pr)
      return pr
    end

    -- this is not provided at the kernel level
    -- largely because there is no real use for it
    -- returns: exit status, exit message
    function p.await(pid)
      checkArg(1, pid, "number")
      
      local signal = {}
      
      if not processes[pid] then
        return nil, "no such process"
      end
      
      repeat
        -- busywait until the process dies
        signal = table.pack(coroutine.yield())
      until signal[1] == "process_died" and signal[2] == pid
      
      return signal[3], signal[4]
    end
    
    p.info = api.info

    p.signals = k.util.copy_table(api.signals)
  end)
end
--#include "base/scheduler.lua"
-- sysfs API --

k.log(k.loglevels.info, "sysfs/sysfs")

do
  local cmdline = table.concat(k.__original_cmdline, " ") .. "\n"
  local tree = {
    dir = true,
    components = {
      dir = true,
      ["by-address"] = {dir = true},
      ["by-type"] = {dir = true}
    },
    proc = {dir = true},
    dev = {
      dir = true,
      stdin = {
        dir = false,
        open = function()
          return io.stdin
        end
      },
      stdout = {
        dir = false,
        open = function()
          return io.stdout
        end
      },
      stderr = {
        dir = false,
        open = function()
          return io.stderr
        end
      },
      null = {
        dir = false,
        read = function(_, n)
          return nil
        end,
        write = function() return true end
      }
    },
    mounts = {
      dir = false,
      read = function(h)
        if h.__read then
          return nil
        end

        local mounts = k.fs.api.mounts()
        local ret = ""
        
        for k, v in pairs(mounts) do
          ret = string.format("%s%s\n", ret, k..": "..v)
        end
        
        h.__read = true
        
        return ret
      end,
      write = function()
        return nil, "bad file descriptor"
      end
    },
    cmdline = {
      dir = false,
      read = function(self, n)
        self.__ptr = self.__ptr or 0
        if self.__ptr >= #cmdline then
          return nil
        else
          self.__ptr = self.__ptr + n
          return cmdline:sub(self.__ptr - n, self.__ptr)
        end
      end
    }
  }

  local function find(f)
    if f == "/" or f == "" then
      return tree
    end

    local s = k.fs.split(f)
    local c = tree
    
    for i=1, #s, 1 do
      if s[i] == "dir" then
        return nil, k.fs.errors.file_not_found
      end
    
      if not c[s[i]] then
        return nil, k.fs.errors.file_not_found
      end

      c = c[s[i]]
    end

    return c
  end

  local obj = {}

  function obj:stat(f)
    checkArg(1, f, "string")
    
    local n, e = find(f)
    
    if n then
      return {
        permissions = 365,
        owner = 0,
        group = 0,
        lastModified = 0,
        size = 0,
        isDirectory = not not n.dir,
        type = n.dir and k.fs.types.directory or k.fs.types.special
      }
    else
      return nil, e
    end
  end

  function obj:touch()
    return nil, k.fs.errors.read_only
  end

  function obj:remove()
    return nil, k.fs.errors.read_only
  end

  function obj:list(d)
    local n, e = find(d)
    
    if not n then return nil, e end
    if not n.dir then return nil, k.fs.errors.not_a_directory end
    
    local f = {}
    
    for k, v in pairs(n) do
      if k ~= "dir" then
        f[#f+1] = tostring(k)
      end
    end
    
    return f
  end

  local function ferr()
    return nil, "bad file descriptor"
  end

  local function fclose(self)
    if self.closed then
      return ferr()
    end
    
    self.closed = true
  end

  function obj:open(f, m)
    checkArg(1, f, "string")
    checkArg(2, m, "string")
    
    local n, e = find(f)
    
    if not n then return nil, e end
    if n.dir then return nil, k.fs.errors.is_a_directory end

    if n.open then return n.open(m) end
    
    return {
      read = n.read or ferr,
      write = n.write or ferr,
      seek = n.seek or ferr,
      flush = n.flush,
      close = n.close or fclose
    }
  end

  obj.node = {getLabel = function() return "sysfs" end}

  -- now here's the API
  local api = {}
  api.types = {
    generic = "generic",
    process = "process",
    directory = "directory"
  }
  typedef("string", "SYSFS_NODE")

  local handlers = {}

  function api.register(otype, node, path)
    checkArg(1, otype, "SYSFS_NODE")
    assert(type(node) ~= "nil", "bad argument #2 (value expected, got nil)")
    checkArg(3, path, "string")

    if not handlers[otype] then
      return nil, string.format("sysfs: node type '%s' not handled", otype)
    end

    local segments = k.fs.split(path)
    local nname = segments[#segments]
    local n, e = find(table.concat(segments, "/", 1, #segments - 1))

    if not n then
      return nil, e
    end

    local nn, ee = handlers[otype](node)
    if not nn then
      return nil, ee
    end

    n[nname] = nn

    return true
  end

  function api.retrieve(path)
    checkArg(1, path, "string")
    return find(path)
  end

  function api.unregister(path)
    checkArg(1, path, "string")
    
    local segments = k.fs.split(path)
    local ppath = table.concat(segments, "/", 1, #segments - 1)
    
    local node = segments[#segments]
    if node == "dir" then
      return nil, k.fs.errors.file_not_found
    end

    local n, e = find(ppath)
    if not n then
      return nil, e
    end

    if not n[node] then
      return nil, fs.errors.file_not_found
    end

    n[node] = nil

    return true
  end
  
  function api.handle(otype, mkobj)
    checkArg(1, otype, "SYSFS_NODE")
    checkArg(2, mkobj, "function")

    api.types[otype] = otype
    handlers[otype] = mkobj

    return true
  end
  
  k.sysfs = api

  -- we have to hook this here since the root filesystem isn't mounted yet
  -- when the kernel reaches this point.
  k.hooks.add("sandbox", function()
    assert(k.fs.api.mount(obj, k.fs.api.types.NODE, "sys"))
    -- Adding the sysfs API to userspace is probably not necessary for most
    -- things.  If it does end up being necessary I'll do it.
    --k.userspace.package.loaded.sysfs = k.util.copy_table(api)
  end)
end

-- sysfs handlers

k.log(k.loglevels.info, "sysfs/handlers")

do
  local util = {}
  function util.mkfile(data)
    local data = data
    return {
      dir = false,
      read = function(self, n)
        self.__ptr = self.__ptr or 0
        if self.__ptr >= #data then
          return nil
        else
          self.__ptr = self.__ptr + n
          return data:sub(self.__ptr - n, self.__ptr)
        end
      end
    }
  end

  function util.fmkfile(tab, k, w)
    return {
      dir = false,
      read = function(self)
        if self.__read then
          return nil
        end

        self.__read = true
        return tostring(tab[k])
      end,
      write = w and function(self, d)
        tab[k] = tonumber(d) or d
      end or nil
    }
  end

  function util.fnmkfile(r, w)
    return {
      dir = false,
      read = function(s)
        if s.__read then
          return nil
        end

        s.__read = true
        return r()
      end,
      write = w
    }
  end

-- sysfs: Generic component handler

k.log(k.loglevels.info, "sysfs/handlers/generic")

do
  local function mknew(addr)
    return {
      dir = true,
      address = util.mkfile(addr),
      type = util.mkfile(component.type(addr)),
      slot = util.mkfile(tostring(component.slot(addr)))
    }
  end

  k.sysfs.handle("generic", mknew)
end
--#include "sysfs/handlers/generic.lua"
-- sysfs: Directory generator

k.log(k.loglevels.info, "sysfs/handlers/directory")

do
  local function mknew()
    return { dir = true }
  end

  k.sysfs.handle("directory", mknew)
end
--#include "sysfs/handlers/directory.lua"
-- sysfs: Process handler

k.log(k.loglevels.info, "sysfs/handlers/process")

do
  local function mknew(proc)
    checkArg(1, proc, "process")
    
    local base = {
      dir = true,
      handles = {
        dir = true,
      },
      cputime = util.fmkfile(proc, "cputime"),
      name = util.mkfile(proc.name),
      threads = util.fmkfile(proc, "threads"),
      owner = util.mkfile(tostring(proc.owner)),
      deadline = util.fmkfile(proc, "deadline"),
      stopped = util.fmkfile(proc, "stopped"),
      waiting = util.fmkfile(proc, "waiting"),
      status = util.fnmkfile(function() return proc.coroutine.status(proc) end)
    }

    local mt = {
      __index = function(t, k)
        k = tonumber(k) or k
        if not proc.handles[k] then
          return nil, k.fs.errors.file_not_found
        else
          return {dir = false, open = function(m)
            -- you are not allowed to access other
            -- people's files!
            return nil, "permission denied"
          end}
        end
      end,
      __pairs = function()
        return pairs(proc.handles)
      end
    }
    mt.__ipairs = mt.__pairs

    setmetatable(base.handles, mt)

    return base
  end

  k.sysfs.handle("process", mknew)
end
--#include "sysfs/handlers/process.lua"
-- sysfs: TTY device handling

k.log(k.loglevels.info, "sysfs/handlers/tty")

do
  local function mknew(tty)
    return {
      dir = false,
      read = function(_, n)
        return tty:read(n)
      end,
      write = function(_, d)
        return tty:write(d)
      end,
      flush = function() return tty:flush() end
    }
  end

  k.sysfs.handle("tty", mknew)

  k.sysfs.register("tty", k.logio, "/dev/console")
  k.sysfs.register("tty", k.logio, "/dev/tty0")
end
--#include "sysfs/handlers/tty.lua"

-- component-specific handlers
-- sysfs: GPU hander

k.log(k.loglevels.info, "sysfs/handlers/gpu")

do
  local function mknew(addr)
    local proxy = component.proxy(addr)
    local new = {
      dir = true,
      address = util.mkfile(addr),
      slot = util.mkfile(proxy.slot),
      type = util.mkfile(proxy.type),
      resolution = util.fnmkfile(
        function()
          return string.format("%d %d", proxy.getResolution())
        end,
        function(_, s)
          local w, h = s:match("(%d+) (%d+)")
        
          w = tonumber(w)
          h = tonumber(h)
        
          if not (w and h) then
            return nil
          end

          proxy.setResolution(w, h)
        end
      ),
      foreground = util.fnmkfile(
        function()
          return tostring(proxy.getForeground())
        end,
        function(_, s)
          s = tonumber(s)
          if not s then
            return nil
          end

          proxy.setForeground(s)
        end
      ),
      background = util.fnmkfile(
        function()
          return tostring(proxy.getBackground())
        end,
        function(_, s)
          s = tonumber(s)
          if not s then
            return nil
          end

          proxy.setBackground(s)
        end
      ),
      maxResolution = util.fnmkfile(
        function()
          return string.format("%d %d", proxy.maxResolution())
        end
      ),
      maxDepth = util.fnmkfile(
        function()
          return tostring(proxy.maxDepth())
        end
      ),
      depth = util.fnmkfile(
        function()
          return tostring(proxy.getDepth())
        end,
        function(_, s)
          s = tonumber(s)
          if not s then
            return nil
          end

          proxy.setDepth(s)
        end
      ),
      screen = util.fnmkfile(
        function()
          return tostring(proxy.getScreen())
        end,
        function(_, s)
          if not component.type(s) == "screen" then
            return nil
          end

          proxy.bind(s)
        end
      )
    }

    return new
  end

  k.sysfs.handle("gpu", mknew)
end
--#include "sysfs/handlers/gpu.lua"
-- sysfs: filesystem handler

k.log(k.loglevels.info, "sysfs/handlers/filesystem")

do
  local function mknew(addr)
    local proxy = component.proxy(addr)
    
    local new = {
      dir = true,
      address = util.mkfile(addr),
      slot = util.mkfile(proxy.slot),
      type = util.mkfile(proxy.type),
      label = util.fnmkfile(
        function()
          return proxy.getLabel() or "unlabeled"
        end,
        function(_, s)
          proxy.setLabel(s:match("^(.-)\n"))
        end
      ),
      spaceUsed = util.fnmkfile(
        function()
          return string.format("%d", proxy.spaceUsed())
        end
      ),
      spaceTotal = util.fnmkfile(
        function()
          return string.format("%d", proxy.spaceTotal())
        end
      ),
      isReadOnly = util.fnmkfile(
        function()
          return tostring(proxy.isReadOnly())
        end
      ),
      mounts = util.fnmkfile(
        function()
          local mounts = k.fs.api.mounts()
          local ret = ""
          for k,v in pairs(mounts) do
            if v == addr then
              ret = ret .. k .. "\n"
            end
          end
          return ret
        end
      )
    }

    return new
  end

  k.sysfs.handle("filesystem", mknew)
end
--#include "sysfs/handlers/filesystem.lua"

-- component event handler
-- sysfs: component event handlers

k.log(k.loglevels.info, "sysfs/handlers/component")

do
  local n = {}
  local gpus, screens = {}, {}
  gpus[k.logio.gpu.address] = true
  screens[k.logio.gpu.getScreen()] = true

  local function update_ttys(a, c)
    if c == "gpu" then
      gpus[a] = gpus[a] or false
    elseif c == "screen" then
      screens[a] = screens[a] or false
    else
      return
    end

    for gk, gv in pairs(gpus) do
      if not gpus[gk] then
        for sk, sv in pairs(screens) do
          if not screens[sk] then
            k.log(k.loglevels.info, string.format(
              "Creating TTY on [%s:%s]", gk:sub(1, 8), (sk:sub(1, 8))))
            k.create_tty(gk, sk)
            gpus[gk] = true
            screens[sk] = true
            gv, sv = true, true
          end
        end
      end
    end
  end

  local function added(_, addr, ctype)
    n[ctype] = n[ctype] or 0

    k.log(k.loglevels.info, "Detected component:", addr .. ", type", ctype)
    
    local path = "/components/by-address/" .. addr:sub(1, 6)
    local path_ = "/components/by-type/" .. ctype
    local path2 = "/components/by-type/" .. ctype .. "/" .. n[ctype]
    
    n[ctype] = n[ctype] + 1

    if not k.sysfs.retrieve(path_) then
      k.sysfs.register("directory", true, path_)
    end

    local s = k.sysfs.register(ctype, addr, path)
    if not s then
      s = k.sysfs.register("generic", addr, path)
      k.sysfs.register("generic", addr, path2)
    else
      k.sysfs.register(ctype, addr, path2)
    end

    if ctype == "gpu" or ctype == "screen" then
      update_ttys(addr, ctype)
    end
    
    return s
  end

  local function removed(_, addr, ctype)
    local path = "/sys/components/by-address/" .. addr
    local path2 = "/sys/components/by-type/" .. addr
    k.sysfs.unregister(path2)
    return k.sysfs.unregister(path)
  end

  k.event.register("component_added", added)
  k.event.register("component_removed", removed)
end
--#include "sysfs/handlers/component.lua"

end -- sysfs handlers: Done
--#include "sysfs/handlers.lua"
--#include "sysfs/sysfs.lua"
-- base networking --

k.log(k.loglevels.info, "extra/net/base")

do
  local protocols = {}
  k.net = {}

  local ppat = "^(.-)://(.+)"

  function k.net.socket(url, ...)
    checkArg(1, url, "string")
    local proto, rest = url:match(ppat)
    if not proto then
      return nil, "protocol unspecified"
    elseif not protocols[proto] then
      return nil, "bad protocol: " .. proto
    end

    return protocols[proto].socket(proto, rest, ...)
  end

  function k.net.request(url, ...)
    checkArg(1, url, "string")
    local proto, rest = url:match(ppat)
    if not proto then
      return nil, "protocol unspecified"
    elseif not protocols[proto] then
      return nil, "bad protocol: " .. proto
    end

    return protocols[proto].request(proto, rest, ...)
  end

  function k.net.listen(url, ...)
    checkArg(1, url, "string")
    local proto, rest = url:match(ppat)
    if not proto then
      return nil, "protocol unspecified"
    elseif not protocols[proto] then
      return nil, "bad protocol: " .. proto
    elseif not protocols[proto].listen then
      return nil, "protocol does not support listening"
    end

    return protocols[proto].listen(proto, rest, ...)
  end

  local hostname = "localhost"

  function k.net.hostname()
    return hostname
  end

  function k.net.sethostname(hn)
    checkArg(1, hn, "string")
    local perms = k.security.users.attributes(k.scheduler.info().owner).acls
    if not k.security.acl.has_permission(perms,
        k.security.acl.permissions.user.HOSTNAME) then
      return nil, "insufficient permission"
    end
    hostname = hn
    for k, v in pairs(protocols) do
      if v.sethostname then
        v.sethostname(hn)
      end
    end
    return true
  end

  k.hooks.add("sandbox", function()
    k.userspace.package.loaded.network = k.util.copy_table(k.net)
  end)

-- internet component for the 'net' api --

k.log(k.loglevels.info, "extra/net/internet")

do
  local proto = {}

  local iaddr, ipx
  local function get_internet()
    if not (iaddr and component.methods(iaddr)) then
      iaddr = component.list("internet")()
    end
    if iaddr and ((ipx and ipx.address ~= iaddr) or not ipx) then
      ipx = component.proxy(iaddr)
    end
    return ipx
  end

  local _base_stream = {}

  function _base_stream:read(n)
    checkArg(1, n, "number")
    if not self.base then
      return nil, "_base_stream is closed"
    end
    local data, iter = "", 0
    repeat
      local chunk = self.base.read(n - #data)
      data = data .. (chunk or "")
      if chunk and #chunk == 0 then iter = iter + 1 os.sleep(0) end
    until (not chunk) or #data == n or iter > 10
    if #data == 0 then return nil end
    return data
  end

  function _base_stream:write(data)
    checkArg(1, data, "string")
    if not self.base then
      return nil, "_base_stream is closed"
    end
    while #data > 0 do
      local written, err = self.base.write(data)
      if not written then
        return nil, err
      end
      data = data:sub(written + 1)
    end
    return true
  end

  function _base_stream:close()
    if self._base_stream then
      self._base_stream.close()
      self._base_stream = nil
    end
    return true
  end

  function proto:socket(url, port)
    local inetcard = get_internet()
    if not inetcard then
      return nil, "no internet card installed"
    end
    local base, err = inetcard._base_stream(self .. "://" .. url, port)
    if not base then
      return nil, err
    end
    return setmetatable({base = base}, {__index = _base_stream})
  end

  function proto:request(url, data, headers, method)
    checkArg(1, url, "string")
    checkArg(2, data, "string", "table", "nil")
    checkArg(3, headers, "table", "nil")
    checkArg(4, method, "string", "nil")

    local inetcard = get_internet()
    if not inetcard then
      return nil, "no internet card installed"
    end

    local post
    if type(data) == "string" then
      post = data
    elseif type(data) == "table" then
      for k,v in pairs(data) do
        post = (post and (post .. "&") or "")
          .. tostring(k) .. "=" .. tostring(v)
      end
    end

    local base, err = inetcard.request(self .. "://" .. url, post, headers, method)
    if not base then
      return nil, err
    end

    local ok, err
    repeat
      ok, err = base.finishConnect()
    until ok or err
    if not ok then return nil, err end

    return setmetatable({base = base}, {__index = _base_stream})
  end

  protocols.https = proto
  protocols.http = proto
end
  --#include "extra/net/internet.lua"
-- minitel driver --
-- code credit goes to Izaya - i've just adapted his OpenOS code --

k.log(k.loglevels.info, "extra/net/minitel")

do
  local listeners = {}
  local debug = k.cmdline["minitel.debug"] and k.cmdline["minitel.debug"] ~= 0
  local port = tonumber(k.cmdline["minitel.port"]) or 4096
  local retry = tonumber(k.cmdline["minitel.retries"]) or 10
  local route = true
  local sroutes = {}
  local rcache = setmetatable({}, {__index = sroutes})
  local rctime = 15

  local hostname = computer.address():sub(1, 8)

  local pqueue = {}
  local pcache = {}
  local pctime = 30

  local function dprint(...)
    if debug then
      k.log(k.loglevels.debug, ...)
    end
  end

  local modems = {}
  for addr, ct in component.list("modem") do
    modems[#modems+1] = component.proxy(addr)
  end
  for k, v in ipairs(modems) do
    v.open(port)
  end
  for addr, ct in component.list("tunnel") do
    modems[#modems+1] = component.proxy(addr)
  end

  local function genPacketID()
    local npID = ""
    for i=1, 16, 1 do
      npID = npID .. string.char(math.random(32, 126))
    end
    return npID
  end

  -- i've done my best to make this readable...
  local function sendPacket(packetID, packetType, dest, sender,
      vPort, data, repeatingFrom)
    if rcache[dest] then
      dprint("Cached", rcache[dest][1], "send", rcache[dest][2],
        cfg.port, packetID, packetType, dest, sender, vPort, data)

      if component.type(rcache[dest][1]) == "modem" then
        component.invoke(rcache[dest][1], "send", rcache[dest][2],
          cfg.port, packetID, packetType, dest, sender, vPort, data)
      elseif component.type(rcache[dest][1]) == "tunnel" then
        component.invoke(rcache[dest][1], "send", packetID, packetType, dest,
          sender, vPort, data)
      end
    else
      dprint("Not cached", cfg.port, packetID, packetType, dest,
        sender, vPort,data)
      for k, v in pairs(modems) do
        -- do not send message back to the wired or linked modem it came from
        -- the check for tunnels is for short circuiting `v.isWireless()`, which does not exist for tunnels
        if v.address ~= repeatingFrom or (v.type ~= "tunnel"
            and v.isWireless()) then
          if v.type == "modem" then
            v.broadcast(cfg.port, packetID, packetType, dest,
              sender, vPort, data)
            v.send(packetID, packetType, dest, sender, vPort, data)
          end
        end
      end
    end
  end

  local function pruneCache()
    for k,v in pairs(rcache) do
      dprint(k,v[3],computer.uptime())
      if v[3] < computer.uptime() then
        rcache[k] = nil
        dprint("pruned "..k.." from routing cache")
      end
    end
    for k,v in pairs(pcache) do
      if v < computer.uptime() then
        pcache[k] = nil
        dprint("pruned "..k.." from packet cache")
      end
    end
  end

  local function checkPCache(packetID)
    dprint(packetID)
    for k,v in pairs(pcache) do
      dprint(k)
      if k == packetID then return true end
    end
    return false
  end

  local function processPacket(_,localModem,from,pport,_,packetID,packetType,dest,sender,vPort,data)
    pruneCache()
    if pport == cfg.port or pport == 0 then -- for linked cards
    dprint(cfg.port,vPort,packetType,dest)
    if checkPCache(packetID) then return end
      if dest == hostname then
        if packetType == 1 then
          sendPacket(genPacketID(),2,sender,hostname,vPort,packetID)
        end
        if packetType == 2 then
          dprint("Dropping "..data.." from queue")
          pqueue[data] = nil
          computer.pushSignal("net_ack",data)
        end
        if packetType ~= 2 then
          computer.pushSignal("net_msg",sender,vPort,data)
        end
      elseif dest:sub(1,1) == "~" then -- broadcasts start with ~
        computer.pushSignal("net_broadcast",sender,vPort,data)
      elseif cfg.route then -- repeat packets if route is enabled
        sendPacket(packetID,packetType,dest,sender,vPort,data,localModem)
      end
      if not rcache[sender] then -- add the sender to the rcache
        dprint("rcache: "..sender..":", localModem,from,computer.uptime())
        rcache[sender] = {localModem,from,computer.uptime()+cfg.rctime}
      end
      if not pcache[packetID] then -- add the packet ID to the pcache
        pcache[packetID] = computer.uptime()+cfg.pctime
      end
    end
  end

  local function queuePacket(_,ptype,to,vPort,data,npID)
    npID = npID or genPacketID()
    if to == hostname or to == "localhost" then
      computer.pushSignal("net_msg",to,vPort,data)
      computer.pushSignal("net_ack",npID)
      return
    end
    pqueue[npID] = {ptype,to,vPort,data,0,0}
    dprint(npID,table.unpack(pqueue[npID]))
  end

  local function packetPusher()
    for k,v in pairs(pqueue) do
      if v[5] < computer.uptime() then
        dprint(k,v[1],v[2],hostname,v[3],v[4])
        sendPacket(k,v[1],v[2],hostname,v[3],v[4])
        if v[1] ~= 1 or v[6] == cfg.retrycount then
          pqueue[k] = nil
        else
          pqueue[k][5]=computer.uptime()+cfg.retry
          pqueue[k][6]=pqueue[k][6]+1
        end
      end
    end
  end

  k.event.register("modem_message", function(...)
    packetPusher()pruneCache()processPacket(...)end)
  
  k.event.register("*", function(...)
    packetPusher()
    pruneCache()
  end)

  -- now, the minitel API --
  
  local mtapi = {}
  local streamdelay = tonumber(k.cmdline["minitel.streamdelay"]) or 30
  local mto = tonumber(k.cmdline["minitel.mtu"]) or 4096
  local openports = {}

  -- layer 3: packets

  function mtapi.usend(to, port, data, npid)
    queuePacket(nil, 0, to, port, data, npid)
  end

  function mtapi.rsend(to, port, data, noblock)
     local pid, stime = genPacketID(), computer.uptime() + streamdelay
     queuePacket(nil, 1, to, port, data, pid)
     if noblock then return pid end
     local sig, rpid
     repeat
       sig, rpid = coroutine.yield(0.5)
     until (sig == "net_ack" and rpid == pid) or computer.uptime() > stime
     if not rpid then return false end
     return true
  end

  -- layer 4: ordered packets

  function mtapi.send(to, port, ldata)
    local tdata = {}
    if #ldata > mtu then
      for i=1, #ldata, mtu do
        tdata[#tdata+1] = ldata:sub(1, mtu)
        ldata = ldata:sub(mtu + 1)
      end
    else
      tdata = {ldata}
    end
    for k, v in ipairs(tdata) do
      if not mtapi.rsend(to, port, v) then
        return false
      end
    end
    return true
  end

  -- layer 5: sockets

  local _sock = {}

  function _sock:write(self, data)
    if self.state == "open" then
      if not mtapi.send(self.addr, self.port, data) then
        self:close()
        return nil, "timed out"
      end
    else
      return nil, "socket is closed"
    end
  end

  function _sock:read(self, length)
    length = length or "\n"
    local rdata = ""
    if type(length) == "number" then
      rdata = self.rbuffer:sub(1, length)
      self.rbuffer = self.rbuffer:sub(length + 1)
      return rdata
    elseif type(length) == "string" then
      if length:sub(1,1) == "a" or length:sub(1,2) == "*a" then
        rdata = self.rbuffer
        self.rbuffer = ""
        return rdata
      elseif #length == 1 then
        local pre, post = self.rbuffer:match("(.-)"..length.."(.*)")
        if pre and post then
          self.rbuffer = post
          return pre
        end
        return nil
      end
    end
  end

  local function socket(addr, port, sclose)
    local conn = setmetatable({
      addr = addr,
      port = tonumber(port),
      rbuffer = "",
      state = "open",
      sclose = sclose
    }, {__index = _sock})

    local function listener(_, f, p, d)
      if f == conn.addr and p == conn.port then
        if d == sclose then
          conn:close()
        else
          conn.rbuffer = conn.rbuffer .. d
        end
      end
    end

    local id = k.event.register("net_msg", listener)
    function conn:close()
      k.event.unregister(id)
      self.state = "closed"
      mtapi.rsend(addr, port, sclose)
    end

    return conn
  end
  
  k.hooks.add("sandbox", function()
    k.userspace.package.loaded["network.minitel"] = k.util.copy_table(mtapi)
  end)

  local proto = {}
  
  function proto.sethostname(hn)
    hostname = hn
  end
  
  -- extension: 'file' argument passed to 'openstream'
  local function open_socket(to, port, file)
    if not mtapi.rsend(to, port, "openstream", file) then
      return nil, "no ack from host"
    end
    local st = computer.uptime() + streamdelay
    local est = false
    local _, from, rport, data
    while true do
      repeat
        _, from, rport, data = coroutine.yield(streamdelay)
      until _ == "net_msg" or computer.uptime() > st
      
      if to == from and rport == port then
        if tonumber(data) then
          est = true
        end
        break
      end

      if st < computer.uptime() then
        return nil, "timed out"
      end
    end

    if not est then
      return nil, "refused"
    end

    data = tonumber(data)
    sclose = ""
    local _, from, nport, sclose
    repeat
      _, from, nport, sclose = coroutine.yield()
    until _ == "net_msg" and from == to and nport == data
    return socket(to, data, sclose)
  end


  function proto:listen(url, handler, unregisterOnSuccess)
    local hn, port = url:match("(.-):(%d+)")
    if hn ~= "localhost" or not (hn and port) then
      return nil, "bad URL: expected 'localhost:port'"
    end

    if handler then
      local id = 0

      local function listener(_, from, rport, data, data2)
        if rport == port and data == "openstream" then
          local nport = math.random(32768, 65535)
          local sclose = genPacketID()
          mtapi.rsend(from, rport, tostring(nport))
          mtapi.rsend(from, nport, sclose)
          if unregisterOnSuccess then k.event.unregister(id) end
          handler(socket(from, nport, sclose), data2)
        end
      end

      id = k.event.register("net_msg", listener)
      return true
    else
      local _, from, rport, data
      repeat
        _, from, rport, data = coroutine.yield()
      until _ == "net_msg"
      local nport = math.random(32768, 65535)
      local sclose = genPacketID()
      mtapi.rsend(from, rport, tostring(nport))
      mtapi.rsend(from, nport, sclose)
      return socket(from, nport, sclose)
    end
  end

  -- url format:
  -- hostname:port
  function proto:socket(url)
    local to, port = url:match("^(.-):(%d+)")
    if not (to and port) then
      return nil, "bad URL: expected 'hostname:port', got " .. url
    end
    return open_socket(to, tonumber(port))
  end

  -- hostname:port/path/to/file
  function proto:request(url)
    local to, port, file = url:match("^(.-):(%d+)/(.+)")
    if not (to and port and file) then
      return nil, "bad URL: expected 'hostname:port/file'"
    end
    return open_socket(to, tonumber(port), file)
  end

  protocols.mt = proto
  protocols.mtel = proto
  protocols.minitel = proto
end
  --#include "extra/net/minitel.lua"
end
--#include "extra/net/base.lua"
-- getgpu - get the gpu associated with a tty --

k.log(k.loglevels.info, "extra/ustty")

do
  k.gpus = {}
  local deletable = {}

  k.gpus[0] = k.logio.gpu

  k.hooks.add("sandbox", function()
    k.userspace.package.loaded.tty = {
      -- get the GPU associated with a TTY
      getgpu = function(id)
        checkArg(1, id, "number")

        if not k.gpus[id] then
          return nil, "terminal not registered"
        end

        return k.gpus[id]
      end,

      -- create a TTY on top of a GPU and optional screen
      create = function(gpu, screen)
        if type(gpu) == "table" then screen = screen or gpu.getScreen() end
        local raw = k.create_tty(gpu, screen)
        deletable[raw.ttyn] = raw
        local prox = io.open(string.format("/sys/dev/tty%d", raw.ttyn), "rw")
        prox.tty = raw.ttyn
        prox.buffer_mode = "none"
        return prox
      end,

      -- cleanly delete a user-created TTY
      delete = function(id)
        checkArg(1, id, "number")
        if not deletable[id] then
          return nil, "tty " .. id
            .. " is not user-created and cannot be deregistered"
        end
        deletable[id]:close()
        return true
      end
    }
  end)
end
--#include "extra/ustty.lua"
--#include "includes.lua"
-- load /etc/passwd, if it exists

k.log(k.loglevels.info, "base/passwd_init")

k.hooks.add("rootfs_mounted", function()
  local p1 = "(%d+):([^:]+):([0-9a-fA-F]+):(%d+):([^:]+):([^:]+)"
  local p2 = "(%d+):([^:]+):([0-9a-fA-F]+):(%d+):([^:]+)"
  local p3 = "(%d+):([^:]+):([0-9a-fA-F]+):(%d+)"

  k.log(k.loglevels.info, "Reading /etc/passwd")

  local handle, err = io.open("/etc/passwd", "r")
  if not handle then
    k.log(k.loglevels.info, "Failed opening /etc/passwd:", err)
  else
    local data = {}
    
    for line in handle:lines("l") do
      -- user ID, user name, password hash, ACLs, home directory,
      -- preferred shell
      local uid, uname, pass, acls, home, shell
      uid, uname, pass, acls, home, shell = line:match(p1)
      if not uid then
        uid, uname, pass, acls, home = line:match(p2)
      end
      if not uid then
        uid, uname, pass, acls = line:match(p3)
      end
      uid = tonumber(uid)
      if not uid then
        k.log(k.loglevels.info, "Invalid line:", line, "- skipping")
      else
        data[uid] = {
          name = uname,
          pass = pass,
          acls = tonumber(acls),
          home = home,
          shell = shell
        }
      end
    end
  
    handle:close()
  
    k.log(k.loglevels.info, "Registering user data")
  
    k.security.users.prime(data)

    k.log(k.loglevels.info,
      "Successfully registered user data from /etc/passwd")
  end

  k.hooks.add("shutdown", function()
    k.log(k.loglevels.info, "Saving user data to /etc/passwd")
    local handle, err = io.open("/etc/passwd", "w")
    if not handle then
      k.log(k.loglevels.warn, "failed saving /etc/passwd:", err)
      return
    end
    for k, v in pairs(k.passwd) do
      local data = string.format("%d:%s:%s:%d:%s:%s\n",
        k, v.name, v.pass, v.acls, v.home or ("/home/"..v.name),
        v.shell or "/bin/lsh")
      handle:write(data)
    end
    handle:close()
  end)
end)
--#include "base/passwd_init.lua"
-- load init, i guess

k.log(k.loglevels.info, "base/load_init")

-- we need to mount the root filesystem first
do
  if _G.__mtar_fs_tree then
    k.log(k.loglevels.info, "using MTAR filesystem tree as rootfs")
    k.fs.api.mount(__mtar_fs_tree, k.fs.api.types.NODE, "/")
  else
    local root, reftype = nil, "UUID"
    
    if k.cmdline.root then
      local rtype, ref = k.cmdline.root:match("^(.-)=(.+)$")
      reftype = rtype:upper() or "UUID"
      root = ref or k.cmdline.root
    elseif not computer.getBootAddress then
      -- still error, but slightly less hard
      k.panic("Cannot determine root filesystem!")
    else
      k.log(k.loglevels.warn,
        "\27[101;97mWARNING\27[39;49m use of computer.getBootAddress to detect the root filesystem is discouraged.")
      k.log(k.loglevels.warn,
        "\27[101;97mWARNING\27[39;49m specify root=UUID=<address> on the kernel command line to suppress this message.")
      root = computer.getBootAddress()
      reftype = "UUID"
    end
  
    local ok, err
    
    if reftype ~= "LABEL" then
      if reftype ~= "UUID" then
        k.log(k.loglevels.warn, "invalid rootspec type (expected LABEL or UUID, got ", reftype, ") - assuming UUID")
      end
    
      if not component.list("filesystem")[root] then
        for k, v in component.list("drive", true) do
          local ptable = k.fs.get_partition_table_driver(k)
      
          if ptable then
            for i=1, #ptable:list(), 1 do
              local part = ptable:partition(i)
          
              if part and (part.address == root) then
                root = part
                break
              end
            end
          end
        end
      end
  
      ok, err = k.fs.api.mount(root, k.fs.api.types.RAW, "/")
    elseif reftype == "LABEL" then
      local comp
      
      for k, v in component.list() do
        if v == "filesystem" then
          if component.invoke(k, "getLabel") == root then
            comp = root
            break
          end
        elseif v == "drive" then
          local ptable = k.fs.get_partition_table_driver(k)
      
          if ptable then
            for i=1, #ptable:list(), 1 do
              local part = ptable:partition(i)
          
              if part then
                if part.getLabel() == root then
                  comp = part
                  break
                end
              end
            end
          end
        end
      end
  
      if not comp then
        k.panic("Could not determine root filesystem from root=", k.cmdline.root)
      end
      
      ok, err = k.fs.api.mount(comp, k.fs.api.types.RAW, "/")
    end
  
    if not ok then
      k.panic(err)
    end
  end

  k.log(k.loglevels.info, "Mounted root filesystem")
  
  k.hooks.call("rootfs_mounted")

  -- mount the tmpfs
  k.fs.api.mount(component.proxy(computer.tmpAddress()), k.fs.api.types.RAW, "/tmp")
end

-- register components with the sysfs, if possible
do
  for k, v in component.list("carddock") do
    component.invoke(k, "bindComponent")
  end

  k.log(k.loglevels.info, "Registering components")
  for kk, v in component.list() do
    computer.pushSignal("component_added", kk, v)
   
    repeat
      local x = table.pack(computer.pullSignal())
      k.event.handle(x)
    until x[1] == "component_added"
  end
end

do
  k.log(k.loglevels.info, "Creating userspace sandbox")
  
  local sbox = k.util.copy_table(_G)
  setmetatable(sbox, {})
  setmetatable(sbox.string, {})
  sbox.struct = nil
  
  k.userspace = sbox
  sbox._G = sbox
  
  k.hooks.call("sandbox", sbox)

  k.log(k.loglevels.info, "Loading init from",
                               k.cmdline.init or "/sbin/init.lua")
  
  local ok, err = loadfile(k.cmdline.init or "/sbin/init.lua")
  
  if not ok then
    k.panic(err)
  end
  
  local ios = k.create_fstream(k.logio, "rw")
  ios.buffer_mode = "none"
  ios.tty = 0
  
  k.scheduler.spawn {
    name = "init",
    func = ok,
    input = ios,
    output = ios,
    stdin = ios,
    stdout = ios,
    stderr = ios
  }

  k.log(k.loglevels.info, "Starting scheduler loop")
  k.scheduler.loop()
end
--#include "base/load_init.lua"
k.panic("Premature exit!")
�� /usr/lib/tui.lua      i-- basic TUI scheme --

local termio = require("termio")

local inherit
inherit = function(t, ...)
  t = t or {}
  local new = setmetatable({}, {__index = t, __call = inherit})
  if new.init then new:init(...) end
  return new
end

local function class(t)
  return setmetatable(t or {}, {__call = inherit})
end

local tui = {}

tui.Text = class {
  selectable = false,

  init = function(self, t)
    local text = require("text").wrap(t.text, (t.width or 80) - 2)
    self.text = {}
    for line in text:gmatch("[^\n]+") do
      self.text[#self.text+1] = line
    end
    self.x = t.x or 1
    self.y = t.y or 1
    self.width = t.width or 80
    self.height = t.height or 25
    self.scroll = 0
  end,

  refresh = function(self, x, y)
    local wbuf = "\27[34;47m"
    for i=self.scroll+1, self.height - 2, 1 do
      if self.text[i] then
        wbuf = wbuf .. (string.format("\27[%d;%dH%s", y+self.y+i-1, x+self.x,
          require("text").padLeft(self.width - 2, self.text[i] or "")))
      end
    end
    return wbuf
  end
}

tui.List = class {
  init = function(self, t)
    self.elements = t.elements
    self.selected = t.selected or 1
    self.scroll = 0
    self.width = t.width or 80
    self.height = t.height or 25
    self.x = t.x or 1
    self.y = t.y or 1
    self.bg = t.bg or 47
    self.fg = t.fg or 30
    self.bg_sel = t.bg_sel or 31
    self.fg_sel = t.fg_sel or 37
  end,

  refresh = function(self, x, y)
    local wbuf
    for i=self.y, self.y + self.height, 1 do
      wbuf = wbuf .. (string.format("\27[%d;%dH", i, x+self.x-1))
    end
  end
}

tui.Selectable = class {
  selectable = true,

  init = function(self, t)
    self.x = t.x or 1
    self.y = t.y or 1
    self.text = t.text or "---"
    self.fg = t.fg or 30
    self.bg = t.bg or 47
    self.fgs = t.fgs or 37
    self.bgs = t.bgs or 41
    self.selected = not not t.selected
  end,

  refresh = function(self, x, y)
    if y == 0 then return "" end
    return (string.format("\27[%d;%dH\27[%d;%dm%s",
      self.y+y-1, self.x+x-1,
      self.selected and self.fgs or self.fg,
      self.selected and self.bgs or self.bg,
      self.text))
  end
}

return tui
�� /usr/lib/gpuproxy.lua      �-- wrap a gpu proxy so that all functions called on the wrapper are redirected to a buffer --

local blacklist = {
  setActiveBuffer = true,
  getActiveBuffer = true,
  --setForeground = true,
  --getForeground = true,
  --setBackground = true,
  --getBackground = true,
  allocateBuffer = true,
  setDepth = true,
  getDepth = true,
  maxDepth = true,
  setResolution = true,
  getResolution = true,
  maxResolution = true,
  totalMemory = true,
  buffers = true,
  getBufferSize = true,
  freeAllBuffers = true,
  freeMemory = true,
  getScreen = true,
  bind = true
}

return {
  buffer = function(px, bufi, wo, ho)
    local new = {}
  
    local w, h = px.getBufferSize(bufi)
    w = math.max(1, math.min(w, wo or w))
    h = math.max(1, math.min(h, ho or h))
    
    for k, v in pairs(px) do
      if not blacklist[k] then
        new[k] = function(...)
          px.setActiveBuffer(bufi)
          local result = table.pack(pcall(v, ...))
          px.setActiveBuffer(0)
          if not result[1] then
            return nil, result[2]
          else
            return table.unpack(result, 2)
          end
        end
      else
        new[k] = v
      end
    end

    function new.getResolution()
      return w, h
    end
    new.maxResolution = new.getResolution
    new.setResolution = function() end

    new.isProxy = true

    return new
  end,

  area = function(px, x, y, w, h)
    local wrap = setmetatable({}, {__index = px})
    function wrap.getResolution() return w, h - 1 end
    wrap.maxResolution = wrap.getResolution
    wrap.setResolution = function() end
    wrap.set = function(_x, _y, t, v) return px.set(
      x + _x - 1, y + _y - 1,
      t:sub(0, (v and h or w) - (v and _y or _x)), v) end
    wrap.get = function(_x, _y) return px.get(x + _x - 1, y + _y - 1) end
    wrap.fill = function(_x, _y, _w, _h, c) return px.fill(
      x + _x - 1, y + _y - 1, math.min(w - _x, _w), math.min(h - _y, _h), c) end
    wrap.copy = function(_x, _y, _w, _h, rx, ry) return px.copy(
      x + _x - 1, y + _y - 1,
      math.min(w - _x + 1, _w), math.min(h - _y + 1, _h),
      rx, ry) end

    wrap.getScreen = px.getScreen

    wrap.isProxy = true

    return wrap
  end
}
�� /usr/bin/installer.lua      l-- fancy TUI installer --

local component = require("component")
local computer = require("computer")
local termio = require("termio")
local tui = require("tui")

local w, h = termio.getTermSize()
local div = true
if w == 50 and h == 16 then div = false end
local page, sel = 1, 2
local pages = {
  { -- [1] intro
    tui.Text {
      x = (div and w // 8) or 1,
      y = (div and h // 8) or 1,
      width = (div and (w // 2) + (w // 4)) or w,
      height = ((div and (h // 2) + (h // 4)) or h) - 1,
      text = [[
Welcome to the ULOS installer.  This program will help you
install ULOS on your computer, set up a user account, and
install extra programs.  Use the arrow keys to navigate
and ENTER to select.]]
    },
    tui.Selectable {
      x = (div and (w // 8 + math.floor(w * 0.75)) or w) - 8,
      y = (div and (h - (h // 8) - 4)) or (h - 1),
      text = " Next ",
      selected = true
    }
  },
  { -- [2] disk selection
    tui.Text {
      x = (div and w // 8) or 1,
      y = (div and h // 8) or 1,
      width = (div and (w // 2) + (w // 4)) or w,
      height = ((div and (h // 2) + (h // 4)) or h) - 1,
      text = "Please select the disk on which you would like to install ULOS:"
    },
    tui.Selectable {
      x = (div and (w // 8 + math.floor(w * 0.75)) or w) - 8,
      y = (div and (h - (h // 8) - 4)) or (h - 1),
      text = " Back ",
      selected = false
    },
  },
  { -- [3] installation method
    tui.Text {
      x = (div and w // 8) or 1,
      y = (div and h // 8) or 1,
      width = (div and (w // 2) + (w // 4)) or w,
      height = ((div and (h // 2) + (h // 4)) or h) - 1,
      text = "Select your desired installation method."
    },
    tui.Selectable {
      x = (div and w // 8 or 0) + 2,
      y = (div and h // 8 or 1) + 3,
      text = require("text").padLeft(math.floor(w * 0.75) - 4,
        "Online (recommended, requires internet card)")
    },
    tui.Selectable {
      x = (div and w // 8 or 0) + 2,
      y = (div and h // 8 or 1) + 4,
      text = require("text").padLeft(math.floor(w * 0.75) - 4,
        "Offline")
    }
  },
  { -- [4] finished!
    tui.Text {
      x = (div and w // 8) or 1,
      y = (div and h // 8) or 1,
      width = (div and math.floor(w * 0.75)) or w,
      height = ((div and math.floor(h * 0.75)) or h) - 1,
      text = "The ULOS Installation process is now complete.  Remove the installation medium and reboot."
    },
  }
}

do
  local _fs = component.list("filesystem")

  for k, v in pairs(_fs) do
    if k ~= computer.tmpAddress() then
      table.insert(pages[2], tui.Selectable {
        x = (div and w // 8 or 0) + 2,
        y = (div and h // 8 or 1) + #pages[2] + 2,
        text = require("text").padLeft(math.floor(w * 0.75) - 4, k)
      })
    end
  end
end

local function clear()
  io.write("\27[44;97m\27[2J\27[" .. math.floor(h) .. ";1HUP/DOWN select or scroll / ENTER selects")
  if div then
    local x, y, W, H = w // 8, h // 8, math.floor(w * 0.75),
      math.floor(h * 0.75)
    io.write(string.format("\27[40m\27[0;%d;%d;%d;%dg", x+2, y+1, W, H))
    io.write(string.format("\27[47m\27[0;%d;%d;%d;%dg", x, y, W, H))
  end
end

local function refresh()
  local wrbuf = ""
  for i, obj in ipairs(pages[page]) do
    obj.selected = sel == i
    wrbuf = wrbuf .. obj:refresh(1, 1)
  end
  io.write(wrbuf)
end

local sel_fs
local function preinstall()
  os.execute("mount -u /mnt")
  os.execute("mount " .. sel_fs .. " /mnt")
  
  -- this is the easiest way to do this
  local gpuproxy = require("gpuproxy")
  local tty = require("tty")
  local __gpu = tty.getgpu(io.stderr.tty)
  local wrapped

  if div then
    wrapped = gpuproxy.area(__gpu, w // 8 + 1, h // 8 + 1,
      math.floor(w * 0.75) - 1, math.floor(h * 0.75) - 1)
  else
    wrapped = gpuproxy.area(__gpu, 2, 2, w - 2, h - 2)
  end

  local new = tty.create(wrapped)
  io.write("\27?15c")
  io.flush()
  new:write("\27?4c")
  
  return new
end

local function wdofile(ios, file, ...)
  local func = loadfile(file)
  local process = require("process")

  local args = table.pack(...)

  -- error handling taken from lsh
  local function proc()
    local ok, err, ret = xpcall(func, debug.traceback,
      table.unpack(args, 1, args.n))

    if (not ok and err) or (not err and ret) then
      io.stderr:write(file, ": ", err or ret, "\n")
      os.exit(127)
    end

    os.exit(0)
  end

  local pid = process.spawn {
    func = proc,
    name = file,
    stdin = ios,
    stdout = ios,
    stderr = ios,
    input = ios,
    output = ios
  }

  local es, er = process.await(pid)
  
  if es == 0 then
    return true
  else
    return false
  end
end

local function postinstall(wrapped)
  os.execute("mkdir -p /mnt/root")
  wdofile(wrapped, "/usr/bin/mkpasswd.lua", "-i", "/mnt/etc/passwd")
  wdofile(wrapped, "/usr/bin/hnsetup.lua")

  io.write("\27?5c")
  io.flush()

  require("tty").delete(wrapped.tty)
end

local function install_online(wrapped)
  local pklist = {
    "cynosure",
    "usysd",
    "coreutils",
    "corelibs",
    "upm",
    "cldr",
  }
  local ok = wdofile(wrapped, "/bin/upm.lua", "update", "--root=/mnt")
  if ok then
    ok = wdofile(wrapped, "/bin/upm.lua", "install", "-fy",
      "--root=/mnt", table.unpack(pklist))
  end
  return ok
end

local function install_offline(wrapped)
  local dirs = {
    "bin",
    "etc",
    "lib",
    "sbin",
    "usr",
    "init.lua"
  }

  for i, dir in ipairs(dirs) do
    if not wdofile(wrapped, "/bin/cp.lua", "-rv", dir,
        "/mnt/" .. dir) then
      return false
    end
  end

  wrapped:write("Removing installer-specific configuration\n")
  
  if package.loaded.sv then
    wdofile(wrapped, "/bin/cp.lua", "-rfv", "/usr/share/installer/rf.cfg",
    "/mnt/etc/rf.cfg")
    wdofile(wrapped, "/bin/rm.lua", "-rfv", "/mnt/etc/rf/startinst.lua")
  elseif package.loaded.usysd then
    local h = io.open("/mnt/etc/usysd/autostart", "w")
    h:write("login@tty0\n")
    h:close()
  end

  return true
end

clear()
while true do
  refresh()
  local key, flags = termio.readKey()
  if flags.ctrl then
    if key == "q" then
      io.write("\27[m\27[2J\27[1;1H")
      os.exit()
    elseif key == "m" then
      if page == 1 then
        if sel == 2 then
          page = page + 1
          clear()
        end
      elseif page == 2 then
        if sel == 2 then
          page = page - 1
          clear()
        elseif sel > 2 then
          sel_fs = pages[2][sel].text:gsub(" +", "")
          page = page + 1
          sel = 2
          clear()
        end
      elseif page == 3 then
        if sel == 2 then
          local wrap = preinstall()
          if install_online(wrap) then
            postinstall(wrap)
            page = page + 1
            clear()
          else
            os.sleep(5)
            clear()
          end
        elseif sel == 3 then
          local wrap = preinstall()
          if install_offline(wrap) then
            postinstall(wrap)
            page = page + 1
            clear()
          else
            os.sleep(5)
            clear()
          end
        end
      elseif page == 4 then
      end
    end
  elseif key == "up" then
    if sel > 1 then
      sel = sel - 1
    end
  elseif key == "down" then
    if sel < #pages[page] then
      sel = sel + 1
    end
  end
end
�� /usr/bin/minstall.lua      	�-- install to a writable medium. --

local args, opts = require("argutil").parse(...)

if opts.help then
  io.stderr:write([[
usage: install
Install ULOS to a writable medium.

ULOS Installer (c) 2021 Ocawesome101 under the
DSLv2.
]])
  os.exit(1)
end

local component = require("component")
local computer = require("computer")

local fs = {}
do
  local _fs = component.list("filesystem")

  for k, v in pairs(_fs) do
    if k ~= computer.tmpAddress() then
      fs[#fs+1] = k
    end
  end
end

print("Available filesystems:")
for k, v in ipairs(fs) do
  print(string.format("%d. %s", k, v))
end

print("Please input your selection.")

local choice
repeat
  io.write("> ")
  choice = io.read("l")
until fs[tonumber(choice) or 0]

os.execute("mount -u /mnt")
os.execute("mount " .. fs[tonumber(choice)] .. " /mnt")

local online, full = false, false
if component.list("internet")() then
  io.write("Perform an online installation? [Y/n]: ")
  local choice
  repeat
    io.write(choice and "Please enter 'y' or 'n': " or "")
    choice = io.read():gsub("\n", "")
  until choice == "y" or choice == "n" or choice == ""
  online = (choice == "y" or #choice == 0)
  if online then
    io.write("Install the full system (manual pages, TLE)?  [Y/n]: ")
    local choice
    repeat
      io.write(choice and "Please enter 'y' or 'n': " or "")
      choice = io.read():gsub("\n", "")
    until choice == "y" or choice == "n" or choice == ""
    full = (choice == "y" or #choice == 0)
    if full then
      print("Installing the full system from the internet")
    else
      print("Installing the base system from the internet")
    end
  else
    print("Copying the system from the installer medium")
  end
else
  print("No internet card installed, defaulting to offline installation")
end

if online then
  os.execute("upm update --root=/mnt")
  local pklist = {
    "cynosure",
    "usysd",
    "coreutils",
    "corelibs",
    "upm",
    "cldr",
  }
  if full then
    pklist[#pklist+1] = "tle"
    pklist[#pklist+1] = "manpages"
  end
  os.execute("upm install -fy --root=/mnt " .. table.concat(pklist, " "))
else
-- TODO: do this some way other than hard-coding it
  local dirs = {
    "bin",
    "etc",
    "lib",
    "sbin",
    "usr",
    "init.lua", -- copy this last for safety reasons
  }

  for i, dir in ipairs(dirs) do
    os.execute("cp -rv /"..dir.." /mnt/"..dir)
  end

  os.execute("rm /mnt/bin/install.lua")
end

print("The base system has now been installed.")

os.execute("mkpasswd -i /mnt/etc/passwd")
os.execute("hnsetup")
�� /usr/bin/hnsetup.lua      5-- hnsetup: set system hostname during installation --

local hn
repeat
  io.write("Enter a hostname for the installed system: ")
  hn = io.read("l")
until #hn > 0

local handle = assert(io.open("/mnt/etc/hostname", "w"))
print("Setting installed system's hostname to " .. hn)
handle:write(hn)
handle:close()
�� /usr/bin/mkpasswd.lua      �-- mkpasswd: generate a /etc/passwd file --

local acl = require("acls")
local sha = require("sha3").sha256
local readline = require("readline")
local acls = {}
do
  local __acls, __k = {}, {}
  for k, v in pairs(acl.user) do
    __acls[#__acls + 1] = v
    __k[v] = k
  end
  table.sort(__acls)
  for i, v in ipairs(__acls) do
    acls[i] = {__k[v], v}
  end
end

local args, opts = require("argutil").parse(...)

if #args < 1 or opts.help then
  io.stderr:write([[
usage: mkpasswd OUTPUT
Generate a file for use as /etc/passwd.  Writes
the generated file to OUTPUT.  Will not behave
correctly on a running system;  use passwd(1)
instead.

ULOS Installer copyright (c) 2021 Ocawesome101
under the DSLv2.
]])
  os.exit(1)
end

-- passwd line format:
-- uid:username:passwordhash:acls:homedir:shell

local function hex(dat)
  return dat:gsub(".", function(c) return string.format("%02x", c:byte()) end)
end

local function prompt(txt, opts, default)
  print(txt)
  local c
  if opts then
    repeat
      io.write("-> ")
      c = readline()
    until opts[c] or c == ""
    if c == "" then return default or opts.default end
  else
    repeat
      io.write("-> ")
      c = readline()
    until (default and c == "") or #c > 0
    if c == "" then return default end
  end
  return c
end

local function pwprompt(text)
  local ipw = ""
  repeat
    io.write(text or "password: ", "\27[8m")
    ipw = io.read("l")
  until #ipw > 1
  io.write("\27[28m\n")
  return hex(sha(ipw))
end

local prompts = {
  main = {
    text = "Available actions:\
  \27[96m[C]\27[37mreate a new user\
  \27[96m[l]\27[37mist created users\
  \27[96m[e]\27[37mdit a created user\
  \27[96m[w]\27[37mrite file and exit",
    opts = {c=true,l=true,e=true,w=true,default="c"}
  },
  uattr = {
    text = "Change them?\
  \27[96m[N]\27[37mo, continue\
  \27[96m[u]\27[37m - change username\
  \27[96m[a]\27[37m - change ACLs\
  \27[96m[s]\27[37m - set login shell\
  \27[96m[h]\27[37m - set home directory",
    opts = {n=true,u=true,i=true,a=true,c=true,d=true,s=true,h=true,default="n"}
  },
}

local function getACLs()
  io.write("ACL map:\n")
  for i, v in ipairs(acls) do
    io.write(string.format("  %d) %s\n", i, v[1]))
  end
  local inp = "A"
  while inp:match("[^%d,]") do
    inp = prompt("Enter a comma-separated list (e.g. 1,2,5,9)")
  end
  local n = 0
  for _n in inp:gmatch("[^,]+") do
    n = n | acls[tonumber(_n)][2]
  end
  return n
end

print("ULOS Installer Account Setup Utility v0.5.0 (c) Ocawesome101 under the DSLv2.")

local added = {
  [0] = {
    0,
    "root",
    (function() return pwprompt(
      "Enter a root password for the new system: ") end)(),
    8191,
    "/root",
    "/bin/lsh.lua"
  }
}

local function getAttributes()
  local uid = #added + 1
  local name = prompt("Enter a username")
  local pass = pwprompt("New password: ")
  local acls = getACLs()
  local homedir = "/home/"..name
  homedir = prompt("Set home directory [" .. homedir .. "]", nil, homedir)
  shell = "/bin/lsh.lua"
  return {uid, name, pass, acls, homedir, shell}
end

local function modAttributes(uid)
  local attr = added[uid]
  while true do
    print("Attributes for "..uid..": [" .. table.concat(attr, ", ", 2) .. "]")
    local opt = prompt(prompts.uattr.text, prompts.uattr.opts)
    if opt == "n" then return
    elseif opt == "u" then
      attr[2] = prompt("New username:")
    elseif opt == "a" then
      attr[4] = getACLs()
    elseif opt == "s" then
      attr[6] = prompt("Enter the absolute path of a shell (ex. /bin/lsh.lua)",
        nil, "/bin/lsh.lua")
    elseif opt == "h" then
      attr[5] = prompt("Enter a new home directory", nil, attr[5])
    end
  end
end

while true do
  local opt = prompt(prompts.main.text, prompts.main.opts)
  if opt == "c" then
    local attr = getAttributes()
    added[attr[1]] = attr
    modAttributes(attr[1])
  elseif opt == "l" then
    for i=0, #added, 1 do
      print(string.format("UID %d has name %s", i, added[i][2]))
    end
  elseif opt == "e" then
    local uid
    repeat
      io.write("UID: ")
      uid = tonumber(io.read("l"))
    until uid
    if not added[uid] then
      print("UID not added")
    else
      modAttributes(uid)
    end
  elseif opt == "w" then
    break
  end
end

print("Saving changes")
local handle = assert(io.open(args[1], "w"))
for i=0, #added, 1 do
  print("Writing user data for " .. added[i][2])
  handle:write(string.format("%d:%s:%s:%d:%s:%s\n",
    table.unpack(added[i])))
  if opts.i then
    os.execute("mkdir -p " .. added[i][5])
  end
end
print("Done!")
�� /usr/man/1/upm      �*{NAME}
  upm - the ULOS Package Manager

*{SYNOPSIS}
  ${upm} [*{options}] *{COMMAND} [*{...}]

*{DESCRIPTION}
  ${upm} is the ULOS package manager.  It requires a means of communication with a server from which to download packages, but can download them from anywhere as long as the protocol is supported by the kernel *{network}(*{2}) API.

  Available commands:
    *{install PACKAGE} [*{...}]
      Install the specified *{PACKAGE}(s), if found in the local package lists.

    *{remove PACKAGE} [*{...}]
      Remove the specified *{PACKAGE}(s), if installed.

    *{upgrade}
      Upgrade all local packages whose version is less than that offered by the remote repositories.

    *{update}
      Refresh the local package lists from each repository specified in the configuration file (see *{CONFIGURATION} below).

    *{search PACKAGE} [*{...}]
      For each *{PACKAGE}, search the local package lists and print information about that package.

    *{list} [*{TARGET}]
      List packages.

      If *{TARGET} is specified, it must be one of the following:
        *{installed} (default)
          List all installed packages.

        *{all}
          List all packages in the remote repositories.

        <*{repository}>
          List all packages in the specified repository.

      Other values of *{TARGET} will result in an error.

    *{help}
      See *{--help} below.

  Available options:
    *{-q}
      Suppresses all log output except errors.

    *{-v}
      Be verbose;  overrides *{-q}.

    *{-f}
      Skip checks for package installation status and package version differences.  Useful for reinstalling packages.

    *{-y}
      Assume 'yes' for all prompts;  do not present prompts.

    *{--root}=*{PATH}
      Specify *{PATH} to be treated as the root directory, rather than #{/}.  This is mainly useful for bootstrapping another ULOS system, or for installing packages on another disk.

    *{--help}
      Print the built-in help text.

*{CONFIGURATION}
  ${upm}'s configuration is stored in #{/etc/upm.cfg}.  It should be fairly self-explanatory.

*{COPYRIGHT}
  ULOS Package Manager copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� /usr/man/1/bsh      *{NAME}
  bsh - Better Shell

*{SYNOPSIS}
  ${bsh} *{-l}|*{--login}
  ${bsh}

*{DESCRIPTION}
  ${bsh} is a Bourne-like shell.  It is a significantly improved, and in fact rewritten, version of the *{sh} shell shipped with ULOS prior to Release 1.7.  It supports piping, input/output redirection, command aliases, basic glob expansion, and substitution.

  ${bsh} is prioritized over *{lsh}(*{1}) by the *{sh}(*{1}) utility, if it is installed.  *{lsh} is still available, and may be set as a user's default shell with the *{passwd}(*{1}) utility.

*{SYNTAX}
  This section contains explanations of the syntax of ${bsh}.  It should be familiar to those familiar with the Bourne shell.

  *{Environment Variable Substitution}
  Environment variables may be subsituted with the *{$}*{{}*{VARIABLE_NAME}*{}} syntax for variables whose names contain characters outside of the *{[0-9a-zA-z_]} range, and *{$VARIABLE_NAME} for those variables whose names do not contain such characters.  For example, the variable *{foo-bar} must be substituted with *{$}*{{}*{foo-bar}*{}}, whereas the variable *{baz} may be substituted with *{$baz}.

  *{Command Aliases}
  Aliases may be defined with the *{alias} builtin;  see *{BUILTINS} below.

  *{Glob Expansion}
  Globs with the *{*} character are supported in place of a filename, or the end of a filename at the end of a path specifier, or in place of a directory name anywhere else.  Thus, the following cases are valid:

    #{/bin/}*{*}
    #{/lib/}*{*}#{/test}
    #{/tmp/part*}

  The following case is not valid and will result in undefined behavior:

    #{/example/part}*{*}#{/foo}

  *{Piping}
  ${bsh} supports piping the output of program *{foo} into the input of program *{bar} with the following syntax:
    
    ${foo} *{|} ${bar}

  These chains may be extended indefinitely.

  *{I/O Redirection}
  A program *{foo}'s input may be directed to an arbitrary file #{f}, where replacing the single *{>} with a double *{>>} will append to the file #{f} rather than overwriting it.

    ${foo} *{>} #{f}

  Similarly, a program *{bar}'s output may be pointed to a file #{f} with the *{<} operator:

    ${bar} *{<} #{f}

  *{Comments}
  Comments extend from the first *{#} found in a line to the end of that line.

  *{Command Chains}
  ${bsh} supports the *{&&} operator for conditional program execution.  Combined with input/output redirection and piping (see the corresponding sections above) this can be quite powerful.  Program invocations may be separated with a *{;}, as such:

    ${foo}*{;} ${bar} a b c*{;} ${baz}

*{SHELL BUILTINS}
  ${bsh} contains a small set of built-in commands.  It will only create a process for a builtin command if that command's input or output is being redirected.

  The following is a short description of each builtin command:

    *{builtins}
      Print each available built-in command.

    *{cd}
      Change the current working directory.  If no argument is given, changes to *{$HOME};  if the argument given is *{-}, changes to *{$OLDPWD}.

    *{set}
      If no arguments are provided, prints the value of all environment variables.  Otherwise, for each argument matching *{key}=*{value}, sets the environment variable *{key}'s value to *{value}.
      
    *{unset}
      Unsets each provided environment variable.

    *{alias}
      If no arguments are provided, prints all aliases specified in the current shell.  Otherwise, for each argument, if that argument matches *{key}=*{value}, aliases *{key} to *{value};  otherwise, if the argument is a valid alias, prints it and its value.

    *{unalias}
      Unsets each provided alias.

    *{kill}
      Kills processes.  Valid options are: *{sighup}, *{sigint}, *{sigquit}, *{sigpipe}, *{sigstop}, *{sigcont}, or otherwise any signal defined by the *{process}(*{3}) library.

    *{exit}
      Exits the current ${bsh} session.  The shell's exit status is 0 or, if present, the first argument converted to a number.

    *{logout}
      Exits a login shell.

    *{pwd}
      Prints the current working directory (i.e. the value of *{$PWD}).

    *{true}
      Exits with a status of 0.

    *{false}
      Exits with a status of 1.

*{COPYRIGHT}
  Better Shell copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Please report bugs at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� /usr/man/1/usysd      �*{NAME}
  usysd - manage services under the USysD init system

*{SYNOPSIS}
  ${usysd} <*{start}|*{stop}> *{SERVICE}[@tty*{N}]
  ${usysd} <*{enable}|*{disable}> [*{--now}] *{SERVICE}[@tty*{N}]
  ${usysd} *{list} [*{--enabled}|*{--running}]

*{DESCRIPTION}
  ${usysd} is the command-line service management interface for USysD.  It takes inspiration from SystemD's *{systemctl} command in semantics and options.

  Available commands:
    
    *{start}
      Starts the specified service.

    *{stop}
      Stops the specified service.

    *{enable}
      Enables the specified service to be automatically started on the next system startup.  If *{--now} is specified, starts it.

    *{disable}
      Disables the specified service from starting on the next system startup.  If *{--now} is specified, stops it.

    *{list}

  When specifying a service, you may add *{@tty}magenta{N} to the end of its name to specify that it should start on ttymagenta{N}.  This is useful, for example, for starting multiple login instances using the same service.

*{COPYRIGHT}
  USysD is copyright (c) 2021 Ocawesome101 under the DSLv2.

*{SEE ALSO}
  *{usysd}(*{3}), *{usysd}(*{7})

*{REPORTING BUGS}
  Please report bugs at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� /usr/man/3/semver      &*{NAME}
  semver - semantic versioning parser

*{DESCRIPTION}
  ${semver} is a fairly strict parser for semantic versioning *{2.0.0}.  A brief summary of the semantic versioning specification, as taken from @{https://semver.org/spec/v2.0.0.html}:

    Given a version number *{MAJOR}.*{MINOR}.*{PATCH}, increment the:
      1. *{MAJOR} version when you make incompatible API changes;
      2. *{MINOR} version when you add functionality in a backwards compatible manner, and
      3. *{PATCH} version when you make backwards compatible bug fixes.
    Addiional labels for pre-release and build metadata are available as extensions to the *{MAJOR}.*{MINOR}.*{PATCH} format.

  The basic format for a semver-compliant version is

    MAJOR*{.}MINOR*{.}PATCH*{-}pre-release information*{+}build metadata.  The *{pre-release information} and *{build metadata} fields are optional.

*{FUNCTIONS}
  Following Lua convention, functions will in the case of failure return magenta{nil} and a red{string} describing the error.

  Several functions in the ${semver} library expect one or more green{version} objects as an argument.
  
  green{version} object format:
    A green{version} object is a table with the following fields (entries surrounded with square brackets [] are optional.

      green{{}
        *{major} = magenta{number},
        *{minor} = magenta{number},
        *{patch} = magenta{number},
        [*{prerelease} = red{string} or green{table},]
        [*{build} = red{string} or green{table}]
      green{}}

  blue{build}(green{version}): red{string}
    Converts the provided green{version} into a human-readable red{string} form.  If the yellow{prerelease} or yellow{build} fields are a green{table}, they will be concatenated with a red{"."}.  In all cases, if present and not empty, they will be concatenated to the end of the returned version string following their corresponding separator (*{-} for pre-release information, and *{+} for build metadata).

  blue{parse}(*{version}:red{string}): green{version}
    Deconstructs the provided red{version} string, and returns a green{version} object matching it.  If no yellow{prerelease} or yellow{build} information is abailable, the corresponding tables will be empty.

  blue{isGreater}(*{ver1}:green{version}, *{ver2}:green{version}): magenta{boolean}
    Checks whether the provided green{ver1} is greater than the provided green{ver2} and returns a boolean accordingly.

*{COPYRIGHT}
  Semantic version parsing library copyright (c) 2021 Ocawesome101 under the DSlv2.  Semantic versioning specification copyright (c) Tom Preston-Werner under Creative Commons -- CC BY 3.0.

*{REPORTING BUGS}
  Please report bugs with the ${semver} library at @{https://github.com/ocawesome101/oc-ulos/issues}.  Leave feedback on semantic versioning at @{https://github.com/semver/semver/issues}.
�� /usr/man/3/usysd      L*{NAME}
  usysd - the USysD API

*{DESCRIPTION}
  This API provides facilities for service management under *{USysD}.

*{COPYRIGHT}
  USysD is copyright (c) 2021 Ocawesome101 under the DSLv2.

*{SEE ALSO}
  *{usysd}(*{1}), *{usysd}(*{7})

*{REPORTING BUGS}
  Please report bugs at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� /usr/man/3/gpuproxy       *{NAME}
  gpuproxy - library for creating virtual GPUs out of real GPUs

*{DESCRIPTION}
  ${gpuproxy} is a library that provides a few utility functions perhaps useful in window management.

*{FUNCTIONS}
  blue{buffer}(*{gpu}:green{table}, *{buffer}:magenta{number}): green{table}
    Creates a virtual GPU on which all calls are redirected to the specified buffer.

  blue{area}(*{gpu}:green{table}, *{x}:magenta{number}, *{y}:magenta{number}, *{w}:magenta{number}, *{h}:magenta{number}): green{table}
    Creates a virtual GPU on which all calls are confined to the specified rectangle.

*{COPYRIGHT}
  ULOS Libraries copyright (c) 2021 Ocawesome101 under the DSLv2.

*{REPORTING BUGS}
  Bugs should be reported at @{https://github.com/ocawesome101/oc-ulos/issues}.
�� /usr/man/7/usysd      �*{NAME}
  USysD - the ULOS System Daemon

*{DESCRIPTION}
  ${usysd} is a fairly advanced init system written for ULOS.  It is the spiritual successor to Refinement.

  ${usysd}'s design draws somewhat from the real-world *{SystemD} init system.  Its advantages over Refinement are:
    
    * Service configuration is not monolithic
    * Service management with the *{usysd}(*{1}) command is 
�� /usr/share/usysd/installer.lua       0loadfile("/bin/lsh.lua")("--exec", "installer")
�� 
/etc/bshrc       �PS1="\e[92m\u\e[37m@\e[92m\h\e[37m: \e[94m\w\e[37m\$ "
alias components="lshw --openos"
alias reboot="shutdown -r"
alias poweroff="shutdown -p"
�� /etc/upm/installed.list      �{
["main/cldr"]={info={version=0,mtar="pkg/main/cldr.mtar"},files={"/init.lua",}},["main/cynosure"]={info={version=0,mtar="pkg/main/cynosure.mtar"},files={"/boot/cynosure.lua",}},["main/usysd"]={info={version=0,mtar="pkg/main/usysd.mtar"},files={"/sbin/init.lua","/sbin/usysd.lua","/usr/man/1/usysd","/usr/man/3/usysd","/usr/man/7/usysd","/etc/usysd/autostart","/etc/usysd/services/login",}},["main/coreutils"]={info={version=0,mtar="pkg/main/coreutils.mtar"},files={"/sbin/sudo.lua","/sbin/shutdown.lua","/bin/clear.lua","/bin/lshw.lua","/bin/rm.lua","/bin/free.lua","/bin/cp.lua","/bin/sh.lua","/bin/cat.lua","/bin/passwd.lua","/bin/hostname.lua","/bin/lua.lua","/bin/edit.lua","/bin/ps.lua","/bin/mkdir.lua","/bin/lsh.lua","/bin/ls.lua","/bin/tfmt.lua","/bin/more.lua","/bin/mv.lua","/bin/mount.lua","/bin/less.lua","/bin/file.lua","/bin/libm.lua","/bin/uname.lua","/bin/env.lua","/bin/pwd.lua","/bin/touch.lua","/bin/df.lua","/bin/wc.lua","/bin/find.lua","/bin/login.lua","/bin/echo.lua","/etc/os-release",}},["main/corelibs"]={info={version=0,mtar="pkg/main/corelibs.mtar"},files={"/lib/path.lua","/lib/termio/xterm-256color.lua","/lib/termio/cynosure.lua","/lib/size.lua","/lib/termio.lua","/lib/futil.lua","/lib/serializer.lua","/lib/tokenizer.lua","/lib/argutil.lua","/lib/lfs.lua","/lib/readline.lua","/lib/text.lua","/lib/config.lua","/lib/mtar.lua",}},["main/gpuproxy"]={info={version=0,mtar="pkg/main/gpuproxy.mtar"},files={"/usr/lib/gpuproxy.lua","/usr/man/3/gpuproxy",}},["main/installer"]={info={version=0,mtar="pkg/main/installer.mtar"},files={"/usr/lib/tui.lua","/usr/bin/installer.lua","/usr/bin/minstall.lua","/usr/bin/hnsetup.lua","/usr/bin/mkpasswd.lua","/usr/share/usysd/installer.lua","/etc/usysd/services/installer",}},["main/upm"]={info={version=0,mtar="pkg/main/upm.mtar"},files={"/lib/semver.lua","/lib/upm.lua","/bin/upm.lua","/usr/man/1/upm","/usr/man/3/semver","/etc/upm/cache/.keepme",}},["main/bsh"]={info={version=0,mtar="pkg/main/bsh.mtar"},files={"/bin/bsh.lua","/usr/man/1/bsh","/etc/bshrc",}},}
�� /etc/upm/cache/.keepme        �� /etc/usysd/autostart       login@tty0
�� /etc/usysd/services/login       2[usysd-service]
file = /bin/login.lua
user = root
�� /etc/usysd/services/installer       B[usysd-service]
file = /usr/share/usysd/installer.lua
user = root
�� /etc/motd.txt       �Welcome to ULOS!

Manual pages are available in the `manpages` package.  Most utilities are in /bin and /sbin.  The recommended editor is `tle`.

You can change this message by editing /etc/motd.txt.
�� /etc/os-release       �NAME="ULOS"
ANSI_COLOR="38;2;102;182;255"
PRETTY_NAME="The Unix-Like Operating System"
BUG_REPORT_URL="https://github.com/ocawesome101/oc-ulos/issues"
VERSION="ULOS 21.09-1.7"
BUILD_ID="21.09"
VERSION_ID="1.7"
]=======]
