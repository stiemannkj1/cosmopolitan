--[=[ Safe process spawning for redbean, built on unix.posix_spawn.

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
     opts.stdout   'tmpfile' (default), 'pipe', 'null' or 'inherit'
     opts.stderr   'tmpfile' (default), 'pipe', 'null', 'inherit' or 'stdout'
     opts.shutdownTimeout  milliseconds a child still running at collection
                   time gets to exit after SIGTERM, default 10
     opts.shutdownSleep    milliseconds between looks during that time,
                   default 10

     The default captures stdout and stderr into two separate anonymous
     temporary files, so a child can write any amount without ever
     blocking on a full pipe, and nothing needs draining.  The files have
     no name, live in $TMPDIR and vanish when the process object is
     collected or redbean exits, however it exits.  Because a file has no
     end of file signal, p:readStdout() waits for the child to exit and
     then returns everything it wrote, and p:readStdout(n) polls the file
     in naps of up to 10ms, since nothing tells a program that a file grew.
     Choose 'pipe' to read output while the child runs, and to get a
     wakeup the moment output arrives.  A child that writes without limit
     fills the disk under 'tmpfile' and memory under 'pipe'.

     Waiting never reaps the child and never signals it.  It uses waitid
     with WNOWAIT, so the exit status stays available for as long as the
     object lives, and calling wait again is always safe.  The child is
     reaped, and killed if it is still running, only when the object is
     garbage collected.  Waiting does not read pipes either.  A child that
     fills a stdout or stderr pipe blocks until the script reads it, so a
     script that waits on a child with pipes reads them while it waits, for
     example with p:readStdout(n, timeout).

     The child never outlives the script, short of SIGKILL.  When the
     object is collected, which also happens when the Lua state is closed
     at shutdown, its pipes are closed, and a child that is still running
     is sent SIGTERM, given shutdownTimeout milliseconds to exit, and then
     killed with SIGKILL, and finally reaped.  The first spawn also makes
     os.exit and unix.exit close the Lua state first, and installs handlers
     for SIGTERM, SIGHUP and SIGINT that exit that way, at the next safe
     point of the script, so those signals clean up too.  Nothing can run when
     Lua is killed with SIGKILL, by the out of memory killer or by a crash, and
     then the child is orphaned. A grandchild is never signaled.

     Meant for simple scripts, which is redbean -i.  The first spawn raises
     an error if SIGTERM or SIGHUP already has a handler, which is the case
     inside a running redbean server, or if SIGINT has a Lua function
     handler, or if SIGCHLD is set to ignore, which would make the kernel
     reap children itself.  Never set SIGCHLD to ignore in a script that
     uses this module.  It also raises on systems without waitid, which is
     OpenBSD.  Not compatible with redbean's -S flags or with unix.pledge
     and unix.unveil.  Under them spawn fails closed, returning nil and an
     EPERM or EACCES error.  Pledge a script without passing
     unix.PLEDGE_PENALTY_RETURN_EPERM and the kernel kills it instead.

     Process object, all methods are called with a colon.

     p.pid                the child's process id
     p.shutdownTimeoutMs  see opts.shutdownTimeout, may be changed
     p.shutdownSleepMs    see opts.shutdownSleep, may be changed
     p:writeStdin(s)      writes all of s, true or nil, Errno
     p:closeStdin()       sends end of file to the child
     p:readStdout([n[, ms]])  reads to end of file, or at most n bytes,
                          waiting up to ms milliseconds for the first byte
     p:readStderr([n[, ms]])  same, for standard error
     p:wait([ms[, sleepMs]])  exit status, see below
     p:exitValue()        p:wait(0, 0), a single look

     p:readStdout(n, ms) waits up to ms milliseconds for data.  A negative
     ms waits forever and zero looks once.  It returns the data, an empty
     string at end of file, or false if the time ran out first.  Giving ms
     without n raises an error.  Without ms the call blocks as before and
     never returns false.

     p:wait(ms, sleepMs) returns the exit code, plus the signal number as a
     second value if the child was killed by a signal, in which case the
     first value is 128 plus the signal, so that a child that really
     exited with 143 can be told from one killed by SIGTERM.  It returns -1
     if the child is still running.  A negative ms, the default, blocks in
     waitid until the child has stopped.  Zero looks once.  A positive ms
     looks again every sleepMs milliseconds, default 10, until the child
     has stopped or ms have passed.  A sleepMs of 0 does not sleep at all.
     Calling wait or exitValue on a process that is not our child, which is
     a copy made by fork, raises an error.

     The second value of a failed method is a unix.Errno when the system
     call failed and a plain message string when the stream was never
     captured or is already closed, so test it before calling :errno()
     on it.  spawn.spawn returns a message string if no temporary file
     could be created.

     With 'pipe' streams every blocking read or write also drains the other
     pipes into memory while it waits, so a child that fills one pipe while
     the parent reads another can never deadlock.  The cost is that output
     nobody reads stays buffered until the object is collected. ]=]

local unix = require 'unix'

local SIGKILL, SIGTERM = unix.SIGKILL, unix.SIGTERM
local POLLIN, POLLOUT = unix.POLLIN, unix.POLLOUT
local POLLHUP, POLLERR = unix.POLLHUP, unix.POLLERR
local EINTR, EPIPE, ECHILD = unix.EINTR, unix.EPIPE, unix.ECHILD
local O_CLOEXEC, O_RDONLY, O_WRONLY = unix.O_CLOEXEC, unix.O_RDONLY, unix.O_WRONLY
local WNOHANG, WNOWAIT = unix.WNOHANG, unix.WNOWAIT
local CLD_EXITED = unix.CLD_EXITED
local PIPE_BUF = 4096

-- Writing to a pipe whose reader is gone raises SIGPIPE, which kills the
-- process unless ignored.  Redbean's server ignores it already, but a
-- script run another way would not, so make writeStdin report EPIPE
-- instead, unless the script has installed a handler of its own.
do
   local old = unix.sigaction(unix.SIGPIPE)
   if old == unix.SIG_DFL then unix.sigaction(unix.SIGPIPE, unix.SIG_IGN) end
end

-- posix_spawn keeps an ignored signal ignored in the child unless the
-- signal is named in sigdefault.  Our own SIGPIPE above, and redbean's,
-- would otherwise be inherited by every child, so a program that expects
-- to die on a broken pipe would see write errors instead.
local SIGPIPE_DEFAULT = unix.Sigset(unix.SIGPIPE)

local OPTIONS = {search = true, path = true, env = true, cwd = true,
                 stdin = true, stdout = true, stderr = true,
                 shutdownTimeout = true, shutdownSleep = true}

local spawn = {}

local Process = {}
Process.__index = Process

-- sleeps for ms milliseconds, which may be fractional or above a second
local function sleep_ms(ms)
   if ms <= 0 then return end
   local sec = math.floor(ms / 1000)
   unix.nanosleep(sec, math.floor((ms - sec * 1000) * 1e6))
end

local function monotonic_ms()
   local sec, nsec = unix.clock_gettime(unix.CLOCK_MONOTONIC)
   return sec * 1000 + nsec / 1e6
end

-- `depth` counts frames from fail's caller up to the public function the
-- caller should be blamed for, so 1 is spawn.spawn raising directly, 2 a
-- validator it calls and 3 a validator nested inside another one.  without
-- this every message points at a line inside this module instead of the
-- line that called it.
local function fail(msg, depth)
   error('cosmo-spawn: ' .. msg, (depth or 1) + 2)
end

local function checkstring(s, what, depth)
   depth = depth or 2
   if type(s) ~= 'string' then fail(what .. ' must be a string', depth) end
   if s:find('\0', 1, true) then
      fail(what .. ' must not contain NUL', depth)
   end
   return s
end

local function checkargv(argv)
   if type(argv) ~= 'table' then fail('argv must be a table', 2) end
   local n = #argv
   if n == 0 then fail('argv must not be empty', 2) end
   local count = 0
   for k, v in pairs(argv) do
      count = count + 1
      if math.type(k) ~= 'integer' or k < 1 or k > n then
         fail('argv must be a plain list of strings', 2)
      end
      checkstring(v, 'argv[' .. k .. ']', 3)
   end
   if count ~= n then fail('argv must be a plain list of strings', 2) end
   if argv[1] == '' then fail('argv[1] must not be empty', 2) end
end

local function checkenv(env)
   if env == nil then return {} end
   if type(env) ~= 'table' then fail('env must be a table', 2) end
   local out = {}
   local n = #env
   if n > 0 then
      local count = 0
      for k in pairs(env) do
         count = count + 1
         if math.type(k) ~= 'integer' or k < 1 or k > n then
            fail('env must be a list of K=V strings or a map, not both', 2)
         end
      end
      if count ~= n then fail('env must be a plain list of K=V strings', 2) end
      for i = 1, n do
         local e = checkstring(env[i], 'env[' .. i .. ']', 3)
         if not e:find('=', 2, true) then
            fail('env[' .. i .. '] must be K=V', 2)
         end
         out[i] = e
      end
   else
      for k, v in pairs(env) do
         checkstring(k, 'env key', 3)
         checkstring(v, 'env value', 3)
         if k == '' or k:find('=', 1, true) then fail('bad env key ' .. k, 2) end
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
   fail(what .. " must be one of '" .. table.concat(allowed, "', '") .. "'", 2)
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

local function checkms(v, what, depth)
   if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then
      fail(what .. ' must be a finite number of milliseconds', depth or 2)
   end
   return v
end

-- Everything that must happen when the script dies is done by the finalizer
-- of each Process, and lua_close runs every finalizer.  So all that signals
-- and exits have to do is close the Lua state.  Done once, by the first
-- spawn, and only in a script that would otherwise die without cleaning up.
local installed
local function install()
   if installed then return end
   local pid, code = unix.waitid(-1, WNOHANG)
   if pid == nil and code:errno() == unix.ENOSYS then
      error('cosmo-spawn: this system has no waitid', 3)
   end
   for _, name in ipairs({'SIGTERM', 'SIGHUP'}) do
      if unix.sigaction(unix[name]) ~= unix.SIG_DFL then
         error('cosmo-spawn: ' .. name .. ' already has a handler, and this ' ..
               'module is only for simple scripts', 3)
      end
   end
   -- script mode keeps a C handler on SIGINT, Lua's own interrupt hook, which
   -- is fine to replace.  Only a handler written in Lua is somebody's choice
   if type(unix.sigaction(unix.SIGINT)) == 'function' then
      error('cosmo-spawn: SIGINT already has a handler, and this module is ' ..
            'only for simple scripts', 3)
   end
   if unix.sigaction(unix.SIGCHLD) == unix.SIG_IGN then
      error('cosmo-spawn: SIGCHLD is ignored, so the kernel would reap ' ..
            'children before they can be waited for', 3)
   end
   installed = true
   local owner = unix.getpid()
   local os_exit, unix_exit = os.exit, unix.exit
   -- a copy made by fork owns no children, and unix.exit exists so that
   -- such a copy can leave without running exit handlers, so leave it be
   os.exit = function(code, close)
      if unix.getpid() ~= owner then return os_exit(code, close) end
      return os_exit(code, true)
   end
   unix.exit = function(code)
      if unix.getpid() ~= owner then return unix_exit(code) end
      return os_exit(code, true)
   end
   -- Lunix runs a Lua handler inside the signal handler itself, wherever the
   -- script happened to be, possibly inside malloc or the collector.  Closing
   -- the state from there could deadlock, so the handler only arms a hook,
   -- which Lua calls before the next instruction of the script, at a safe
   -- point.  Lua does not call hooks while a finalizer runs, so a collection
   -- that is in the middle of reaping a child always finishes first.  The
   -- hook functions are made now so that the handler allocates nothing.
   local hooks = {}
   for _, name in ipairs({'SIGTERM', 'SIGHUP', 'SIGINT'}) do
      local sig = unix[name]
      hooks[sig] = function()
         debug.sethook()
         os_exit(128 + sig, true)
      end
      unix.sigaction(sig, function() debug.sethook(hooks[sig], '', 1) end)
   end
end

function spawn.spawn(argv, opts)
   checkargv(argv)
   opts = opts or {}
   if type(opts) ~= 'table' then fail('opts must be a table') end
   for k in pairs(opts) do
      if not OPTIONS[k] then fail('unknown option ' .. tostring(k)) end
   end
   local env = checkenv(opts.env)
   local prog = opts.path and checkstring(opts.path, 'path') or argv[1]
   if opts.cwd ~= nil then checkstring(opts.cwd, 'cwd') end
   local modes = {
      stdin = choose(opts.stdin, 'pipe', {'pipe', 'null', 'inherit'}, 'stdin'),
      stdout = choose(opts.stdout, 'tmpfile', {'tmpfile', 'pipe', 'null', 'inherit'}, 'stdout'),
      stderr = choose(opts.stderr, 'tmpfile', {'tmpfile', 'pipe', 'null', 'inherit', 'stdout'}, 'stderr'),
   }

   local shutdownTimeout, shutdownSleep = 10, 10
   if opts.shutdownTimeout ~= nil then
      shutdownTimeout = checkms(opts.shutdownTimeout, 'shutdownTimeout')
      if shutdownTimeout < 0 then fail('shutdownTimeout must not be negative') end
   end
   if opts.shutdownSleep ~= nil then
      shutdownSleep = checkms(opts.shutdownSleep, 'shutdownSleep')
      if shutdownSleep < 0 then fail('shutdownSleep must not be negative') end
   end

   install()

   local actions = {}
   local mine = {}    -- our ends of the pipes, name -> fd
   local theirs = {}  -- child's ends, closed in the parent after spawning
   local files = {}   -- anonymous temporary files, name -> {fd, off}
   local function cleanup()
      for _, fd in pairs(mine) do unix.close(fd) end
      for _, fd in pairs(theirs) do unix.close(fd) end
      for _, st in pairs(files) do unix.close(st.fd) end
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
      elseif mode == 'tmpfile' then
         local f, emsg = io.tmpfile()
         if not f then cleanup() return nil, emsg end
         -- the stdio file is only used to make the file.  We keep our own
         -- duplicate with close on exec, so that no later child inherits it
         local fd0 = unix.fileno(f)
         local fd, derr
         if fd0 then fd, derr = unix.dup(fd0, -1, O_CLOEXEC, 3) end
         pcall(f.close, f)
         if not fd then
            cleanup()
            return nil, derr or 'could not get a temporary file descriptor'
         end
         files[name == 'stdout' and 'out' or 'err'] = {fd = fd, off = 0}
         actions[#actions + 1] = {'dup2', fd, target}
      elseif mode == 'null' then
         actions[#actions + 1] = {'open', target, '/dev/null',
                                  target == 0 and O_RDONLY or O_WRONLY}
      elseif mode == 'stdout' then
         actions[#actions + 1] = {'dup2', 1, 2}
      end
   end
   if opts.cwd then actions[#actions + 1] = {'chdir', opts.cwd} end

   local call = opts.search and unix.posix_spawnp or unix.posix_spawn
   local pid, err = call(prog, argv, env,
                         {actions = actions, sigdefault = SIGPIPE_DEFAULT})
   if not pid then
      cleanup()
      return nil, err
   end
   for _, fd in pairs(theirs) do unix.close(fd) end

   local self = setmetatable({
      pid = pid,
      shutdownTimeoutMs = shutdownTimeout,
      shutdownSleepMs = shutdownSleep,
      fds = {['in'] = mine.stdin, out = mine.stdout, err = mine.stderr},
      piped = {['in'] = mine.stdin ~= nil,
               out = mine.stdout ~= nil or files.out ~= nil,
               err = mine.stderr ~= nil or files.err ~= nil},
      files = files,
      buf = {out = {}, err = {}},
   }, Process)
   return self
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

-- One look at the child that neither blocks nor reaps.  Returns its exit
-- code and the signal that killed it, if any, or nil while it runs, or
-- false and an Errno on failure.  A process that is not our child raises,
-- since this API is only for children.  `flags` is WNOHANG to look without
-- blocking, and 0 to block until the child has stopped.
local function look(self, flags, depth)
   while true do
      local pid, code, status = unix.waitid(self.pid, WNOWAIT | flags)
      if pid == nil then
         if code:errno() == ECHILD then
            fail('process ' .. self.pid .. ' is not a child of this process', depth)
         elseif code:errno() ~= EINTR then
            return false, code
         end
      elseif pid ~= 0 then
         if code == CLD_EXITED then return status end
         return 128 + status, status
      elseif flags & WNOHANG ~= 0 then
         return nil
      end
   end
end

-- Reads a captured temporary file.  pread is used because the child
-- shares the file offset, and moving it would corrupt what it writes.
-- timeout is in milliseconds, nil blocks, and false means it ran out.
local function readfile(self, name, n, timeout)
   local st = self.files[name]
   if n == nil then
      -- no end of file signal exists for a file, so the child exiting is it
      local code, err = self:wait()
      if code == nil then return nil, err end
      local parts = {}
      while true do
         local data, rerr = unix.read(st.fd, 1 << 20, st.off)
         if data == nil then
            if rerr:errno() ~= EINTR then return nil, rerr end
         elseif data == '' then
            break
         else
            parts[#parts + 1] = data
            st.off = st.off + #data
         end
      end
      return table.concat(parts)
   end
   local deadline = timeout and timeout >= 0 and monotonic_ms() + timeout
   local nap = 1
   while true do
      -- look at the child first, so that a final write is never missed
      local exited, err = look(self, WNOHANG, 2)
      if exited == false then return nil, err end
      exited = exited ~= nil
      local data, rerr = unix.read(st.fd, n, st.off)
      if data == nil then
         if rerr:errno() ~= EINTR then return nil, rerr end
      elseif #data > 0 then
         st.off = st.off + #data
         return data
      elseif exited then
         return ''
      end
      local step = nap
      if deadline then
         local remaining = deadline - monotonic_ms()
         if remaining <= 0 then return false end
         step = math.min(step, remaining)
      end
      sleep_ms(step)
      nap = math.min(nap * 2, 10)
   end
end

local function readstream(self, name, n, timeout)
   if not self.piped[name] then
      return nil, (name == 'out' and 'stdout' or 'stderr') .. ' is not captured'
   end
   if n ~= nil and (math.type(n) ~= 'integer' or n < 1) then
      error('cosmo-spawn: n must be a positive integer', 3)
   end
   if timeout ~= nil then
      if n == nil then error('cosmo-spawn: a timeout needs n', 3) end
      checkms(timeout, 'timeout', 3)
   end
   if self.files[name] then return readfile(self, name, n, timeout) end
   if n then
      local deadline = timeout and timeout >= 0 and monotonic_ms() + timeout
      while #self.buf[name] == 0 and self.fds[name] do
         local wait
         if deadline then
            wait = deadline - monotonic_ms()
            if wait < 0 then wait = 0 end
         elseif timeout then
            wait = nil
         end
         local _, err = pump(self, false, wait and math.ceil(wait))
         if err then return nil, err end
         if deadline and #self.buf[name] == 0 and self.fds[name] and
            monotonic_ms() >= deadline then
            return false
         end
      end
   else
      while self.fds[name] do
         local _, err = pump(self)
         if err then return nil, err end
      end
   end
   return take(self, name, n)
end

function Process:readStdout(n, timeout) return readstream(self, 'out', n, timeout) end
function Process:readStderr(n, timeout) return readstream(self, 'err', n, timeout) end

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

-- code, signal for a child that stopped, -1 while it runs, nil and an
-- Errno if the call failed
local function finish(code, sig)
   if code == nil then return -1 end
   if code == false then return nil, sig end
   return code, sig
end

-- Waits with waitid, which looks at the exit without collecting it.
function Process:wait(timeout, sleepMs)
   if timeout == nil then timeout = -1 end
   checkms(timeout, 'timeout', 1)
   if sleepMs == nil then sleepMs = 10 end
   checkms(sleepMs, 'sleepMs', 1)
   if sleepMs < 0 then fail('sleepMs must not be negative', 1) end
   if timeout < 0 then return finish(look(self, 0, 2)) end
   local deadline = monotonic_ms() + timeout
   while true do
      local code, sig = look(self, WNOHANG, 2)
      if code ~= nil then return finish(code, sig) end
      local remaining = deadline - monotonic_ms()
      if remaining <= 0 then return -1 end
      sleep_ms(math.min(sleepMs, remaining))
   end
end

function Process:exitValue()
   return finish(look(self, WNOHANG, 2))
end

-- Collection.  Closes the pipes first, so a child blocked writing to one
-- gets SIGPIPE, then makes sure the child is gone and reaped.  Nothing is
-- signaled unless waitid says the process is our own child and still
-- running, which keeps a copy made by fork harmless.  Lua runs a finalizer
-- once per object, also from lua_close, so no state is kept.
Process.__gc = function(self)
   for name, fd in pairs(self.fds) do
      unix.close(fd)
      self.fds[name] = nil
   end
   pcall(function()
      local pid
      repeat
         local err
         pid, err = unix.waitid(self.pid, WNOHANG | WNOWAIT)
         if pid == nil and err:errno() ~= EINTR then return end
      until pid ~= nil
      if pid == 0 then
         unix.kill(self.pid, SIGTERM)
         if self:wait(self.shutdownTimeoutMs, self.shutdownSleepMs) == -1 then
            unix.kill(self.pid, SIGKILL)
            self:wait()
         end
      end
      repeat
         local err
         pid, err = unix.waitid(self.pid)
      until pid ~= nil or err:errno() ~= EINTR
   end)
   for name, st in pairs(self.files) do
      unix.close(st.fd)
      self.files[name] = nil
   end
end

return spawn
