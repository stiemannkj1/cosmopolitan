--[[ Safe process spawning for redbean, built on unix.posix_spawn.

       local spawn = require 'cosmo-spawn'

       local p = assert(spawn.spawn({'sort', '-r'}, {search = true}))
       p:writeStdin('a\nb\nc\n')
       p:closeStdin()
       print(p:readStdout())     --> c\nb\na\n
       print(p:wait())           --> 0

     No shell is ever involved.  The program and every argument reach the
     child exactly as given, so there is nothing to quote or escape.

     spawn.spawn(argv[, opts]) returns a process object, or nil and a
     unix.Errno if the program could not be started.  Invalid arguments
     raise an error, since they are bugs in the caller and never depend on
     the environment.  argv must be a non empty list of strings without
     NUL bytes.  By default argv[1] is used as the path of the program.

     opts.search   look argv[1] up in $PATH, default false
     opts.path     program to run when it differs from argv[1]
     opts.env      environment, either {'K=V', ...} or {K = 'V', ...}.
                   Default is empty.  Pass unix.environ() to inherit.
     opts.cwd      directory the child starts in
     opts.stdin    'pipe' (default), 'null' or 'inherit'
     opts.stdout   'pipe' (default), 'null' or 'inherit'
     opts.stderr   'pipe' (default), 'null', 'inherit' or 'stdout'

     Not compatible with redbean's -S flags or with unix.pledge and
     unix.unveil.  Under them spawn fails closed, returning nil and an
     EPERM or EACCES error.  Pledge a script without passing
     unix.PLEDGE_PENALTY_RETURN_EPERM and the kernel kills it instead.

     Process object, all methods are called with a colon.

     p.pid                the child's process id
     p:writeStdin(s)      writes all of s, true or nil, Errno
     p:closeStdin()       sends end of file to the child
     p:readStdout([n])    reads to end of file, or at most n bytes
     p:readStderr([n])    same, for standard error
     p:wait([nohang])     exit status, false if nohang and still running
     p:kill([sig])        sends sig, default SIGTERM

     Every blocking call also drains the other pipes into memory while it
     waits, so a child that fills one pipe while the parent waits on
     another can never deadlock.  The cost is that output nobody reads
     stays buffered until the object is collected.

     p:wait() returns the exit code, plus the signal number as a second
     value if the child was killed by a signal, in which case the first
     value is 128 plus the signal.

     When the object is garbage collected, which also happens when the Lua
     state is closed at shutdown, its file descriptors are closed and a
     child that is still running is sent SIGKILL.  Neither step waits for
     the child, so collection and shutdown never block.  Shutdown cleanup
     happens when the Lua state closes, so it does not run if the script
     leaves through unix.exit, which is _Exit, or if redbean is killed
     outright. ]]

local unix = require 'unix'

local SIGKILL, SIGTERM = unix.SIGKILL, unix.SIGTERM
local POLLIN, POLLOUT = unix.POLLIN, unix.POLLOUT
local POLLHUP, POLLERR = unix.POLLHUP, unix.POLLERR
local EINTR, EPIPE = unix.EINTR, unix.EPIPE
local O_CLOEXEC, O_RDONLY, O_WRONLY = unix.O_CLOEXEC, unix.O_RDONLY, unix.O_WRONLY
local WNOHANG = unix.WNOHANG
local PIPE_BUF = 4096

-- Writing to a pipe whose reader is gone raises SIGPIPE, which kills the
-- process unless ignored.  Redbean's server ignores it already, but a
-- script run another way would not, so make writeStdin report EPIPE
-- instead, unless the script has installed a handler of its own.
do
   local old = unix.sigaction(unix.SIGPIPE)
   if old == unix.SIG_DFL then unix.sigaction(unix.SIGPIPE, unix.SIG_IGN) end
end

local spawn = {}

local Process = {}
Process.__index = Process

-- killed children that were not yet reapable when their handle went away
local orphans = {}

local function sweep()
   for pid in pairs(orphans) do
      local r, _, _ = unix.wait(pid, WNOHANG)
      if r ~= 0 then orphans[pid] = nil end
   end
end

local function fail(msg)
   error('cosmo-spawn: ' .. msg, 3)
end

local function checkstring(s, what)
   if type(s) ~= 'string' then fail(what .. ' must be a string') end
   if s:find('\0', 1, true) then fail(what .. ' must not contain NUL') end
   return s
end

local function checkargv(argv)
   if type(argv) ~= 'table' then fail('argv must be a table') end
   local n = #argv
   if n == 0 then fail('argv must not be empty') end
   local count = 0
   for k, v in pairs(argv) do
      count = count + 1
      if math.type(k) ~= 'integer' or k < 1 or k > n then
         fail('argv must be a plain list of strings')
      end
      checkstring(v, 'argv[' .. k .. ']')
   end
   if count ~= n then fail('argv must be a plain list of strings') end
   if argv[1] == '' then fail('argv[1] must not be empty') end
end

local function checkenv(env)
   if env == nil then return {} end
   if type(env) ~= 'table' then fail('env must be a table') end
   local out = {}
   if #env > 0 then
      for i = 1, #env do
         local e = checkstring(env[i], 'env[' .. i .. ']')
         if not e:find('=', 2, true) then fail('env[' .. i .. '] must be K=V') end
         out[i] = e
      end
   else
      for k, v in pairs(env) do
         checkstring(k, 'env key')
         checkstring(v, 'env value')
         if k == '' or k:find('=', 1, true) then fail('bad env key ' .. k) end
         out[#out + 1] = k .. '=' .. v
      end
   end
   return out
end

local function choose(v, default, allowed, what)
   if v == nil then return default end
   for _, a in ipairs(allowed) do
      if v == a then return v end
   end
   fail(what .. " must be one of '" .. table.concat(allowed, "', '") .. "'")
end

-- moves fd above stdio so that a closed stdin cannot make a pipe end
-- collide with the descriptors we are about to dup2 onto
local function high(fd)
   if fd > 2 then return fd end
   local nfd, err = unix.dup(fd, -1, O_CLOEXEC, 3)
   unix.close(fd)
   return nfd, err
end

local function pipe()
   local r, w = unix.pipe(O_CLOEXEC)
   if not r then return nil, w end
   local err
   r, err = high(r)
   if not r then unix.close(w) return nil, err end
   w, err = high(w)
   if not w then unix.close(r) return nil, err end
   return r, w
end

function spawn.spawn(argv, opts)
   checkargv(argv)
   opts = opts or {}
   if type(opts) ~= 'table' then fail('opts must be a table') end
   local env = checkenv(opts.env)
   local prog = opts.path and checkstring(opts.path, 'path') or argv[1]
   if opts.cwd ~= nil then checkstring(opts.cwd, 'cwd') end
   local modes = {
      stdin = choose(opts.stdin, 'pipe', {'pipe', 'null', 'inherit'}, 'stdin'),
      stdout = choose(opts.stdout, 'pipe', {'pipe', 'null', 'inherit'}, 'stdout'),
      stderr = choose(opts.stderr, 'pipe', {'pipe', 'null', 'inherit', 'stdout'}, 'stderr'),
   }

   sweep()

   local actions = {}
   local mine = {}    -- our ends of the pipes, name -> fd
   local theirs = {}  -- child's ends, closed in the parent after spawning
   local function cleanup()
      for _, fd in pairs(mine) do unix.close(fd) end
      for _, fd in pairs(theirs) do unix.close(fd) end
   end

   local order = {{'stdin', 0}, {'stdout', 1}, {'stderr', 2}}
   for _, s in ipairs(order) do
      local name, target = s[1], s[2]
      local mode = modes[name]
      if mode == 'pipe' then
         local r, w = pipe()
         if not r then cleanup() return nil, w end
         local child, parent = r, w
         if target ~= 0 then child, parent = w, r end
         theirs[name], mine[name] = child, parent
         actions[#actions + 1] = {'dup2', child, target}
      elseif mode == 'null' then
         actions[#actions + 1] = {'open', target, '/dev/null',
                                  target == 0 and O_RDONLY or O_WRONLY}
      elseif mode == 'stdout' then
         actions[#actions + 1] = {'dup2', 1, 2}
      end
   end
   if opts.cwd then actions[#actions + 1] = {'chdir', opts.cwd} end

   local call = opts.search and unix.posix_spawnp or unix.posix_spawn
   local pid, err = call(prog, argv, env, {actions = actions})
   if not pid then cleanup() return nil, err end
   for _, fd in pairs(theirs) do unix.close(fd) end

   return setmetatable({
      pid = pid,
      fds = {['in'] = mine.stdin, out = mine.stdout, err = mine.stderr},
      piped = {['in'] = mine.stdin ~= nil, out = mine.stdout ~= nil,
               err = mine.stderr ~= nil},
      buf = {out = {}, err = {}},
   }, Process)
end

-- Polls every open stream once, moving readable data into the buffers.
-- Returns true if stdin became writable, false if it broke and nil
-- otherwise.  timeout is in milliseconds, nil blocks.
local function pump(self, wantwrite, timeout)
   local fds = self.fds
   local set, any = {}, false
   if fds.out then set[fds.out] = POLLIN any = true end
   if fds.err then set[fds.err] = POLLIN any = true end
   if wantwrite and fds['in'] then set[fds['in']] = POLLOUT any = true end
   if not any then return nil end
   local ready, err = unix.poll(set, timeout)
   if not ready then
      if err:errno() == EINTR then return nil end
      return nil, err
   end
   for _, name in ipairs({'out', 'err'}) do
      local fd = fds[name]
      if fd and ready[fd] and ready[fd] ~= 0 then
         local data, rerr = unix.read(fd, 65536)
         if data == nil then
            if rerr:errno() ~= EINTR then
               unix.close(fd)
               fds[name] = nil
            end
         elseif data == '' then
            unix.close(fd)
            fds[name] = nil
         else
            local b = self.buf[name]
            b[#b + 1] = data
         end
      end
   end
   local w = fds['in']
   if wantwrite and w and ready[w] and ready[w] ~= 0 then
      if ready[w] & (POLLERR | POLLHUP) ~= 0 then return false end
      return true
   end
   return nil
end

local function take(self, name, n)
   local b = self.buf[name]
   local s = table.concat(b)
   if n and #s > n then
      self.buf[name] = {s:sub(n + 1)}
      return s:sub(1, n)
   end
   self.buf[name] = {}
   return s
end

local function readstream(self, name, n)
   if not self.piped[name] then
      return nil, (name == 'out' and 'stdout' or 'stderr') .. ' is not a pipe'
   end
   if n ~= nil and (math.type(n) ~= 'integer' or n < 1) then
      error('cosmo-spawn: n must be a positive integer', 3)
   end
   if n then
      while #self.buf[name] == 0 and self.fds[name] do
         local _, err = pump(self)
         if err then return nil, err end
      end
   else
      while self.fds[name] do
         local _, err = pump(self)
         if err then return nil, err end
      end
   end
   return take(self, name, n)
end

function Process:readStdout(n) return readstream(self, 'out', n) end
function Process:readStderr(n) return readstream(self, 'err', n) end

function Process:writeStdin(s)
   checkstring(s, 'data')
   if not self.piped['in'] then return nil, 'stdin is not a pipe' end
   local off = 1
   while off <= #s do
      local fd = self.fds['in']
      if not fd then return nil, 'stdin is closed' end
      local ok, err = pump(self, true)
      if err then return nil, err end
      if ok == false then
         return nil, 'stdin is broken, the child closed its end'
      end
      if ok then
         -- POLLOUT promises at least PIPE_BUF bytes, so this cannot block
         local n, werr = unix.write(fd, s:sub(off, off + PIPE_BUF - 1))
         if not n then
            if werr:errno() ~= EINTR then return nil, werr end
         else
            off = off + n
         end
      end
   end
   return true
end

function Process:closeStdin()
   local fd = self.fds['in']
   if fd then
      unix.close(fd)
      self.fds['in'] = nil
   end
   return true
end

local function result(self)
   local ws = self.status
   if unix.WIFEXITED(ws) then
      return unix.WEXITSTATUS(ws)
   end
   local sig = unix.WTERMSIG(ws)
   return 128 + sig, sig
end

function Process:wait(nohang)
   if self.status then return result(self) end
   while true do
      local pid, ws = unix.wait(self.pid, WNOHANG)
      if pid == nil then
         if ws:errno() ~= EINTR then return nil, ws end
      elseif pid ~= 0 then
         self.status = ws
         orphans[self.pid] = nil
         return result(self)
      elseif nohang then
         return false
      end
      if not (self.fds.out or self.fds.err) then
         if not nohang then
            local p2, ws2 = unix.wait(self.pid)
            if p2 == nil then
               if ws2:errno() ~= EINTR then return nil, ws2 end
            else
               self.status = ws2
               return result(self)
            end
         end
      else
         -- keep the pipes drained so the child can never block on them
         local _, err = pump(self, false, nohang and 0 or 50)
         if err then return nil, err end
      end
   end
end

function Process:kill(sig)
   if self.status then return false end
   return unix.kill(self.pid, sig or SIGTERM)
end

Process.__gc = function(self)
   for name, fd in pairs(self.fds) do
      unix.close(fd)
      self.fds[name] = nil
   end
   if not self.status then
      unix.kill(self.pid, SIGKILL)
      local r, ws = unix.wait(self.pid, WNOHANG)
      if r == nil or r == 0 then
         orphans[self.pid] = true
      else
         self.status = ws
      end
   end
end

return spawn
