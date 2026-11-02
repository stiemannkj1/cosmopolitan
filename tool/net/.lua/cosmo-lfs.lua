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
--
-- when the call site has no name of its own, luaL_argerror falls back to
-- pushglobalfuncname(), which hunts the function down in package.loaded
-- and reports it qualified.  that is why pcall(lfs.touch, ...) names the
-- module while a direct lfs.touch(...) names only the field.
local function globalfuncname(f)
   for modname, mod in pairs(package.loaded) do
      if type(mod) == 'table' then
         for k, v in pairs(mod) do
            if v == f and type(k) == 'string' then
               return modname == '_G' and k or modname .. '.' .. k
            end
         end
      end
   end
end

-- `depth` counts frames from this function's caller up to the one being
-- blamed, so 1 means the caller itself and 2 means its caller.  this is
-- the only place an argument error is formatted.
local function argerror(arg, extramsg, depth, fallbackname)
   depth = depth or 1
   local info = getinfo and getinfo(depth + 1, 'nf')
   local name = (info and info.name)
      or (info and info.func and globalfuncname(info.func))
      or fallbackname or '?'
   if info and info.namewhat == 'method' then
      arg = arg - 1
      if arg == 0 then
         error(string.format("calling '%s' on bad self (%s)", name, extramsg),
               depth + 2)
      end
   end
   error(string.format("bad argument #%d to '%s' (%s)", arg, name, extramsg),
         depth + 2)
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
   -- pcall() returns two values, so this has to be unpacked rather than
   -- folded into the `and` chain, which would truncate it to the status
   -- and throw the probe's answer away
   local ok = false
   if mint and setmeta and setuv and getuv then
      local called, works = pcall(function()
         local probe = mint()
         setuv(probe, {})
         return getuv(probe) ~= nil
      end)
      ok = called and works
   end

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
      argerror(1, 'closed directory', 1, 'next')
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
   -- upstream tests this with lua_isstring(), which accepts a number and
   -- converts it, so lfs.attributes(p, 42) reports an invalid attribute
   -- name rather than quietly handing back the whole table
   local key = (type(aname) == 'string' or type(aname) == 'number')
      and tostring(aname)
   if key then
      local get = MEMBERS[key]
      if not get then
         error(string.format("invalid attribute name '%s'", key), 3)
      end
      return get(st)
   end
   local t = type(aname) == 'table' and aname or {}
   for name, get in pairs(MEMBERS) do t[name] = get(st) end
   return t
end

-- deliberately not a tail call.  fileinfo() raises at level 3 so that the
-- caller of lfs.attributes() is blamed, and a tail call would drop this
-- frame and blame the caller's caller instead
function lfs.attributes(filepath, aname)
   local info, msg, errno = fileinfo(filepath, aname)
   if info == nil then return nil, msg, errno end
   return info
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
--
-- upstream reads the times with luaL_optnumber(), so nil means the default
-- while anything that will not convert to a number is an argument error.
-- silently treating it as zero would move the file's timestamps to 1970.
local function opttime(v, argn, default)
   if v == nil then return default end
   local n = tonumber(v)
   if not n then
      argerror(argn, 'number expected, got ' .. type(v), 2, 'touch')
   end
   return math.floor(n)
end

function lfs.touch(filepath, ...)
   if select('#', ...) == 0 then
      return pushresult(unix.utimensat(filepath))
   end
   local atime = opttime((select(1, ...)), 2, 0)
   local mtime = atime
   if select('#', ...) > 1 then
      mtime = opttime((select(2, ...)), 3, atime)
   end
   return pushresult(unix.utimensat(filepath, atime, 0, mtime, 0))
end

------------------------------------------------------------------- locking

-- upstream's check_file(): the handle must be a FILE*, and a closed one
-- is reported on its own rather than as an argument error.  `depth` counts
-- frames from here up to the function being blamed, which makes the raise
-- level depth + 2 and the argerror depth depth + 1.
local function checkfile(f, funcname, supplied, depth)
   if io.type(f) == 'file' then return f end
   if io.type(f) == 'closed file' then
      error(string.format('%s: closed file', funcname), depth + 2)
   end
   argerror(1, 'FILE* expected, got ' ..
            (supplied and type(f) or 'no value'), depth + 1, funcname)
end

local function tofd(f, funcname, supplied, depth)
   if math.type(f) == 'integer' then return f end
   checkfile(f, funcname, supplied, depth + 1)
   if not unix.fileno then
      error(funcname .. ': this redbean predates unix.fileno, so a stdio' ..
            ' handle cannot be locked, pass a descriptor instead', depth + 2)
   end
   local fd, err = unix.fileno(f)
   if not fd then
      error(string.format('%s: %s', funcname, strerror(err)), depth + 2)
   end
   return fd
end

local LOCKTYPE = {
   r = unix.F_RDLCK, w = unix.F_WRLCK, u = unix.F_UNLCK,
}

-- upstream validates the handle before the mode, so a bad first argument
-- is reported as such rather than as an invalid mode
local function filelock(supplied, f, mode, start, len, funcname)
   local fd = tofd(f, funcname, supplied, 2)
   local ltype = type(mode) == 'string' and LOCKTYPE[mode:sub(1, 1)]
   if not ltype then
      error(string.format('%s: invalid mode', funcname), 3)
   end
   return unix.fcntl(fd, unix.F_SETLK, ltype, start or 0, len or 0,
                     unix.SEEK_SET)
end

-- declared vararg so that an omitted handle can be told apart from an
-- explicit nil, which is upstream's "no value" versus "nil"
function lfs.lock(...)
   local f, mode, start, len = ...
   local ok, err = filelock(select('#', ...) > 0, f, mode, start, len, 'lock')
   if not ok then return nil, strerror(err) end
   return true
end

function lfs.unlock(...)
   local f, start, len = ...
   local ok, err = filelock(select('#', ...) > 0, f, 'u', start, len, 'unlock')
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
function lfs.setmode(...)
   local f, mode = ...
   if math.type(f) ~= 'integer' then
      checkfile(f, 'setmode', select('#', ...) > 0, 1)
   end
   -- upstream raises this through luaL_checkoption, which is an ordinary
   -- argument error rather than a message of its own
   if mode ~= 'binary' and mode ~= 'text' then
      argerror(2, string.format("invalid option '%s'", tostring(mode)), 1,
               'setmode')
   end
   return true, 'binary'
end

return lfs
