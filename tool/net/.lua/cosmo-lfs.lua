--[[ LuaFileSystem 1.8.0 work-alike for redbean, written in pure Lua on top
     of the unix module.

       local lfs = require 'cosmo-lfs'

     Every function documented by LuaFileSystem 1.8.0 is present and keeps
     the upstream calling convention, including the (nil, message, errno)
     failure convention and the exact error strings, so that code written
     against the real lfs runs unmodified.

     One thing behaves differently from the C module, and cannot be fixed
     from Lua.  Calling next() on a closed directory through a tail call
     reports the argument error without knowing it was a method call,
     because a tail-called Lua frame has lost its call site where a C
     function would not have.  Every other call shape, the plain method
     call and the generic for among them, produces the message upstream
     produces.

     Two further things surprise people, but are not differences from the
     C module, which was measured doing exactly the same.

     lfs.setmode always reports "binary".  Upstream compiles it as a no-op
     wherever _WIN32 is undefined, and cosmopolitan's stdio never
     translates line endings, so this differs only from LFS built with
     MSVC.

     lfs.chdir cannot enter /zip, because the zip store is not a working
     directory.  Both implementations end up in chdir(2) and both get
     ENOTSUP.  lfs.dir and lfs.attributes read /zip happily. ]]

local unix = require 'unix'

-- captured once rather than looked up per call, so that a later
-- `debug = nil` cannot break an already loaded module
local getinfo = debug and debug.getinfo
local setmeta = debug and debug.setmetatable
local setuv = debug and debug.setuservalue
local getuv = debug and debug.getuservalue

local lfs = {
   _COPYRIGHT = 'Copyright (C) 2003-2017 Kepler Project',
   _DESCRIPTION = 'LuaFileSystem is a Lua library developed to complement ' ..
      'the set of functions related to file systems offered by the standard ' ..
      'Lua distribution',
   _VERSION = 'LuaFileSystem 1.8.0',
}

-- cosmopolitan's strerror appends the windows error code whenever it is
-- set and differs from the errno, and lfs messages are strerror output, so
-- the same suffix is reproduced here rather than reporting the bare text
local function strerror(err)
   local winerr = err:winerr()
   if winerr and winerr ~= 0 and winerr ~= err:errno() then
      return string.format('%s (win32 error %d)', err:doc(), winerr)
   end
   return err:doc()
end

-- unix reports failure as (nil, Errno) where Errno:doc() is the strerror
-- text and Errno:errno() the number.  lfs reports it as (nil, msg, errno).
local function pusherror(err, info)
   if info then
      return nil, string.format('%s: %s', info, strerror(err)), err:errno()
   end
   return nil, strerror(err), err:errno()
end

local function pushresult(ok, err)
   if ok == nil then return pusherror(err) end
   return true
end

-- luaL_argerror renumbers the arguments and changes its wording when the
-- function was called as a method, which is observable in the messages lfs
-- produces, so the same rule is applied here.  a lua function reached by a
-- tail call has lost its call site, and with it the name and the knowledge
-- of whether it was a method, where a C function would still have both, so
-- the caller supplies the name as a fallback.
local function argerror(arg, extramsg, fallbackname)
   local info = getinfo and getinfo(2, 'n')
   local name = (info and info.name) or fallbackname or '?'
   if info and info.namewhat == 'method' then
      arg = arg - 1
      if arg == 0 then
         error(string.format("calling '%s' on bad self (%s)", name, extramsg),
               3)
      end
   end
   error(string.format("bad argument #%d to '%s' (%s)", arg, name, extramsg),
         3)
end

--------------------------------------------------------------- directories

function lfs.currentdir()
   local cwd, err = unix.getcwd()
   if not cwd then return pusherror(err) end
   return cwd
end

function lfs.chdir(path)
   local ok, err = unix.chdir(path)
   if not ok then
      return nil, string.format(
         "Unable to change working directory to '%s'\n%s\n", path, strerror(err))
   end
   return true
end

-- upstream creates directories 0777 and lets the umask trim it, whereas
-- unix.mkdir defaults to 0755, so the mode is passed explicitly
function lfs.mkdir(dirname)
   return pushresult(unix.mkdir(dirname, tonumber('777', 8)))
end

function lfs.rmdir(dirname)
   return pushresult(unix.rmdir(dirname))
end

------------------------------------------------------------- object boxes

-- lfs hands out userdata, and lua cannot create userdata.  unix.Sigset()
-- mints one that owns no operating system resource and carries no
-- finalizer of its own, debug.setmetatable() re-tags it, and the object's
-- state lives in its uservalue, so what callers get really is userdata and
-- type() agrees with the C module.  the unix.Dir handle is deliberately
-- not re-tagged, because its own methods check their metatable by
-- identity and would stop working.
--
-- if the debug library has been removed the objects fall back to tables,
-- which changes nothing except what type() reports.
local newobject, stateof

do
   local mint = unix.Sigset
   local ok = mint and setmeta and setuv and getuv and pcall(function()
      local probe = mint()
      setuv(probe, {})
      return getuv(probe) ~= nil
   end)

   if ok then
      newobject = function(meta, state)
         local o = mint()
         setuv(o, state)
         setmeta(o, meta)
         return o
      end
      stateof = function(o)
         if type(o) == 'userdata' then return getuv(o) end
         return o
      end
   else
      newobject = function(meta, state) return setmetatable(state, meta) end
      stateof = function(o) return o end
   end
end

----------------------------------------------------------------- iteration

-- unix.Dir reads four values per entry and has read/rewind/tell/close,
-- while lfs yields the name alone from an object with next/close that
-- refuses to be used once closed
local Dir = {}
Dir.__index = Dir
Dir.__name = 'directory metatable'

function Dir:next()
   local d = stateof(self)
   if d.closed then
      argerror(1, 'closed directory', 'next')
   end
   local name = d.handle:read()
   if name == nil then
      self:close()
      return nil
   end
   return name
end

function Dir:close()
   local d = stateof(self)
   if not d.closed then
      d.closed = true
      d.handle:close()
   end
end

Dir.__call = Dir.next
Dir.__close = Dir.close
Dir.__gc = Dir.close

function lfs.dir(path)
   local handle, err = unix.opendir(path)
   if not handle then
      error(string.format('cannot open %s: %s', path, strerror(err)), 2)
   end
   local d = newobject(Dir, {handle = handle, closed = false})
   -- the fourth value is what lua 5.4's generic for closes on exit
   return Dir.next, d, nil, d
end

---------------------------------------------------------------- attributes

local function mode2string(mode)
   if unix.S_ISREG(mode) then return 'file'
   elseif unix.S_ISDIR(mode) then return 'directory'
   elseif unix.S_ISLNK(mode) then return 'link'
   elseif unix.S_ISSOCK(mode) then return 'socket'
   elseif unix.S_ISFIFO(mode) then return 'named pipe'
   elseif unix.S_ISCHR(mode) then return 'char device'
   elseif unix.S_ISBLK(mode) then return 'block device'
   else return 'other' end
end

-- redbean exports the S_IS* predicates but not the permission bits, so the
-- posix values are spelled out.  upstream ignores setuid, setgid and
-- sticky, giving nine characters of rwx and dashes and nothing else.
local PERMBITS = {
   {tonumber('400', 8), 'r'}, {tonumber('200', 8), 'w'},
   {tonumber('100', 8), 'x'}, {tonumber('040', 8), 'r'},
   {tonumber('020', 8), 'w'}, {tonumber('010', 8), 'x'},
   {tonumber('004', 8), 'r'}, {tonumber('002', 8), 'w'},
   {tonumber('001', 8), 'x'},
}

local function perm2string(mode)
   local out = {}
   for i = 1, 9 do
      local bit, ch = PERMBITS[i][1], PERMBITS[i][2]
      out[i] = (mode & bit) ~= 0 and ch or '-'
   end
   return table.concat(out)
end

-- the extra parentheses truncate atim/mtim/ctim to their seconds, since
-- they return a (seconds, nanoseconds) pair and lfs wants a single integer
local MEMBERS = {
   mode = function(st) return mode2string(st:mode()) end,
   dev = function(st) return st:dev() end,
   ino = function(st) return st:ino() end,
   nlink = function(st) return st:nlink() end,
   uid = function(st) return st:uid() end,
   gid = function(st) return st:gid() end,
   rdev = function(st) return st:rdev() end,
   access = function(st) return (st:atim()) end,
   modification = function(st) return (st:mtim()) end,
   change = function(st) return (st:ctim()) end,
   size = function(st) return st:size() end,
   permissions = function(st) return perm2string(st:mode()) end,
   blocks = function(st) return st:blocks() end,
   blksize = function(st) return st:blksize() end,
}

local function fileinfo(filepath, aname, flags)
   local st, err = unix.stat(filepath, flags)
   if not st then
      return nil, string.format(
         "cannot obtain information from file '%s': %s", filepath, strerror(err)),
         err:errno()
   end
   if type(aname) == 'string' then
      local get = MEMBERS[aname]
      if not get then
         error(string.format("invalid attribute name '%s'", aname), 3)
      end
      return get(st)
   end
   local t = type(aname) == 'table' and aname or {}
   for name, get in pairs(MEMBERS) do t[name] = get(st) end
   return t
end

function lfs.attributes(filepath, aname)
   return fileinfo(filepath, aname)
end

function lfs.symlinkattributes(filepath, aname)
   if aname == 'target' then
      local target, err = unix.readlink(filepath, unix.AT_FDCWD)
      if not target then
         return pusherror(err, 'could not obtain link target')
      end
      return target
   end
   local info, msg, errno = fileinfo(filepath, aname,
                                     unix.AT_SYMLINK_NOFOLLOW)
   if info == nil then return nil, msg, errno end
   if type(info) == 'table' then
      local target = unix.readlink(filepath, unix.AT_FDCWD)
      if target then info.target = target end
   end
   return info
end

--------------------------------------------------------------------- links

function lfs.link(old, new, symbolic)
   if symbolic then return pushresult(unix.symlink(old, new)) end
   return pushresult(unix.link(old, new))
end

--------------------------------------------------------------------- times

-- unix.utimensat takes a (seconds, nanoseconds) pair per timestamp and
-- defaults the nanoseconds to UTIME_NOW, so an explicit zero is required
-- whenever a time is actually being set
function lfs.touch(filepath, ...)
   if select('#', ...) == 0 then
      return pushresult(unix.utimensat(filepath))
   end
   local atime = math.floor(tonumber((select(1, ...))) or 0)
   local given = select(2, ...)
   local mtime = given ~= nil and math.floor(tonumber(given) or 0) or atime
   return pushresult(unix.utimensat(filepath, atime, 0, mtime, 0))
end

------------------------------------------------------------------- locking

local function tofd(f, funcname)
   if math.type(f) == 'integer' then return f end
   if io.type(f) == 'file' then
      if not unix.fileno then
         error(funcname .. ': this redbean predates unix.fileno, so a stdio' ..
               ' handle cannot be locked, pass a descriptor instead', 3)
      end
      local fd, err = unix.fileno(f)
      if not fd then
         error(string.format('%s: %s', funcname, strerror(err)), 3)
      end
      return fd
   end
   error(string.format('%s: not a file', funcname), 3)
end

local LOCKTYPE = {
   r = unix.F_RDLCK, w = unix.F_WRLCK, u = unix.F_UNLCK,
}

local function filelock(f, mode, start, len, funcname)
   local ltype = type(mode) == 'string' and LOCKTYPE[mode:sub(1, 1)]
   if not ltype then
      error(string.format('%s: invalid mode', funcname), 3)
   end
   local fd = tofd(f, funcname)
   return unix.fcntl(fd, unix.F_SETLK, ltype, start or 0, len or 0,
                     unix.SEEK_SET)
end

function lfs.lock(f, mode, start, len)
   local ok, err = filelock(f, mode, start, len, 'lock')
   if not ok then return nil, strerror(err) end
   return true
end

function lfs.unlock(f, start, len)
   local ok, err = filelock(f, 'u', start, len, 'unlock')
   if not ok then return nil, strerror(err) end
   return true
end

-- upstream implements the directory lock as a symlink, so this is the same
-- mechanism rather than an imitation of it, and the two interoperate
local Lock = {}
Lock.__index = Lock
Lock.__name = 'lock metatable'

function Lock:free()
   local l = stateof(self)
   if l.ln then
      unix.unlink(l.ln)
      l.ln = nil
   end
end

Lock.__close = Lock.free
Lock.__gc = Lock.free

function lfs.lock_dir(path)
   local ln = path .. '/lockfile.lfs'
   local ok, err = unix.symlink('lock', ln)
   if not ok then return nil, strerror(err) end
   return newobject(Lock, {ln = ln})
end

------------------------------------------------------------------ no-ops

-- cosmopolitan stdio never translates line endings on any platform, which
-- makes this the same no-op upstream compiles on every non-Windows build
function lfs.setmode(f, mode)
   if io.type(f) ~= 'file' and math.type(f) ~= 'integer' then
      error("setmode: not a file", 2)
   end
   if mode ~= 'binary' and mode ~= 'text' then
      error(string.format(
         "bad argument #2 to 'lfs.setmode' (invalid option '%s')",
         tostring(mode)), 2)
   end
   return true, 'binary'
end

return lfs
