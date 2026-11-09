-- Functional tests for unix.posix_spawn(p) and the cosmo-spawn wrapper.
--
--   o/x86_64/tool/net/redbean -i test/tool/net/cosmo_spawn_test.lua
--   qemu-aarch64 o/aarch64/tool/net/redbean -i test/tool/net/cosmo_spawn_test.lua
--   wine o/redbean.com -i test/tool/net/cosmo_spawn_test.lua
--
-- Child programs are redbean itself running test/tool/net/cosmo_spawn_helper.lua,
-- so the suite needs no coreutils and runs unchanged on Windows.  On
-- other systems a few extra cases also run the real touch(1).  The suite
-- only creates files inside a fresh temporary directory.

local unix = require 'unix'
local spawn = require 'cosmo-spawn'

local WINDOWS = os.getenv('OS') == 'Windows_NT'

local function absolute(p)
   if p:find('^/') or p:find('^%a:') then return p end
   return unix.getcwd() .. '/' .. p
end

local EXE = absolute(os.getenv('REDBEAN') or arg[-1])
local HELPER = absolute((arg[0]:gsub('[^/\\]*$', '')) .. 'cosmo_spawn_helper.lua')

local function H(...)
   return {EXE, '-i', HELPER, ...}
end

local passed, failed = 0, 0
local function check(name, cond, detail)
   if cond then
      passed = passed + 1
      if os.getenv('VERBOSE') then io.stderr:write('ok   ', name, '\n') end
   else
      failed = failed + 1
      print('FAIL ' .. name .. (detail ~= nil and (': ' .. tostring(detail)) or ''))
   end
end

local function raises(name, f, pattern)
   local ok, err = pcall(f)
   check(name, not ok and tostring(err):find(pattern, 1, true), err)
end

local startdir = unix.getcwd()
local tmp = absolute(('cosmo-spawn-test-%d-%d'):format(unix.getpid(), unix.clock_gettime()))
assert(unix.mkdir(tmp, tonumber('700', 8)))
local function exists(p) return unix.stat(tmp .. '/' .. p) ~= nil end

-- children that sleep write a heartbeat file into tmp while HB_DIR is set,
-- see the helper, which is how liveness is told on Windows
local HBENV = {HB_DIR = tmp}
local ENV = unix.environ()
ENV[#ENV + 1] = 'HB_DIR=' .. tmp

local function listing(dirpath)
   local names = {}
   local dir = assert(unix.opendir(dirpath or tmp))
   for name in dir do
      if name ~= '.' and name ~= '..' then names[#names + 1] = name end
   end
   dir:close()
   table.sort(names)
   return names
end

--------------------------------------------------------------------------
-- base API

do
   local pid = assert(unix.posix_spawn(EXE, H('touch', 'base1'), {},
                                       {actions = {{'chdir', tmp}}}))
   local _, ws = unix.wait(pid)
   check('base: touch via chdir action', unix.WIFEXITED(ws) and
         unix.WEXITSTATUS(ws) == 0 and exists('base1'))

   pid = assert(unix.posix_spawn(EXE, H('argv', 'hi'), {}, {actions = {
      {'open', 1, tmp .. '/base2', unix.O_WRONLY | unix.O_CREAT, tonumber('600', 8)},
   }}))
   unix.wait(pid)
   local fd = unix.open(tmp .. '/base2', unix.O_RDONLY)
   check('base: open action redirects stdout', fd and unix.read(fd) == 'hi\n')
   if fd then unix.close(fd) end

   local r, w = assert(unix.pipe(unix.O_CLOEXEC))
   pid = assert(unix.posix_spawn(EXE, H('argv', 'piped'), {},
                                 {actions = {{'dup2', w, 1}, {'close', r}}}))
   unix.close(w)
   unix.wait(pid)
   check('base: dup2 action feeds pipe', unix.read(r) == 'piped\n')
   unix.close(r)

   local p, err = unix.posix_spawn('/nonexistent/prog', {'x'}, {})
   check('base: missing program fails', p == nil and err ~= nil)  -- errno differs on Windows
   p, err = unix.posix_spawn(EXE, H('exit', '0'), {}, {actions = {{'bogus'}}})
   check('base: unknown action is EINVAL', p == nil and err:errno() == unix.EINVAL)
   pid = assert(unix.posix_spawn(EXE, H('exit', '7'), unix.environ()))
   _, ws = unix.wait(pid)
   check('base: default env and exit code', unix.WEXITSTATUS(ws) == 7)
end

--------------------------------------------------------------------------
-- wrapper: argument validation

raises('argv must be table', function() spawn.spawn('ls') end, 'argv must be a table')
raises('argv not empty', function() spawn.spawn({}) end, 'must not be empty')
raises('argv strings only', function() spawn.spawn({'ls', 5}) end, 'must be a string')
raises('argv no NUL', function() spawn.spawn({'ls', 'a\0b'}) end, 'NUL')
raises('argv plain list', function() spawn.spawn({'ls', x = 'y'}) end, 'plain list')
raises('argv[1] nonempty', function() spawn.spawn({''}) end, 'must not be empty')
raises('env needs =', function() spawn.spawn({'ls'}, {env = {'NOEQ'}}) end, 'K=V')
raises('env key no =', function() spawn.spawn({'ls'}, {env = {['A=B'] = 'x'}}) end, 'bad env key')
raises('bad stdout mode', function() spawn.spawn({'ls'}, {stdout = 'x'}) end, 'stdout must be')
raises('cwd string', function() spawn.spawn({'ls'}, {cwd = 1}) end, 'cwd must be')
raises('path no NUL', function() spawn.spawn({'ls'}, {path = 'a\0b'}) end, 'NUL')

--------------------------------------------------------------------------
-- wrapper: malicious input

do
   -- shell operators, a second program name and -c are only ever
   -- arguments to the program that was asked for
   local evil = {'foo', '&&', '/bin/sh', '-c', 'touch bad-stuff.txt'}
   local p = assert(spawn.spawn(H('argv', table.unpack(evil))))
   check('evil argv arrives verbatim',
         p:readStdout() == table.concat(evil, '\n') .. '\n')
   p:wait()

   -- /bin/sh is swapped for a name inside the sandbox directory here,
   -- since the touch helper really does open each argument
   p = assert(spawn.spawn(H('touch', 'foo', '&&', 'x-sh', '-c', 'touch bad-stuff.txt'),
                          {cwd = tmp}))
   p:wait()
   check('evil argv made literal files', exists('foo') and exists('&&') and
         exists('x-sh') and exists('-c') and exists('touch bad-stuff.txt'),
         table.concat(listing(), ','))
   check('evil argv ran nothing', not exists('bad-stuff.txt'))

   -- the same thing smuggled in as one string
   local one = "touch foo2 && /bin/sh -c 'touch bad-stuff.txt'"
   local q, err = spawn.spawn({one})
   check('command string is not a program', q == nil and err ~= nil)
   q, err = spawn.spawn({one}, {search = true, cwd = tmp})
   check('command string is not searched either', q == nil and err ~= nil)
   q, err = spawn.spawn({'sh', '-c', one}, {path = one, cwd = tmp})
   check('command string as path fails', q == nil and err ~= nil)

   p = assert(spawn.spawn(H('argv', one)))
   check('command string as argument is one argument', p:readStdout() == one .. '\n')
   p:wait()
   p = assert(spawn.spawn(H('touch', one), {cwd = tmp}))
   p:wait()
   check('command string as argument ran nothing', not exists('bad-stuff.txt') and
         not exists('foo2'))

   -- substitution and quoting syntax stays inert in args and in env
   local junk = {'$(touch bad-stuff.txt)', '`touch bad-stuff.txt`', '; touch bad-stuff.txt',
                 '| touch bad-stuff.txt', '> bad-stuff.txt', '\'"', '%PATH%', '*'}
   p = assert(spawn.spawn(H('argv', table.unpack(junk))))
   check('shell syntax in args is inert', p:readStdout() == table.concat(junk, '\n') .. '\n')
   p:wait()
   local envval = 'A=$(touch bad-stuff.txt); touch bad-stuff.txt'
   p = assert(spawn.spawn(H('env'), {env = {envval}}))
   check('shell syntax in env is inert', p:readStdout():find(envval, 1, true) ~= nil)
   p:wait()

   check('nothing named bad-stuff.txt anywhere', not exists('bad-stuff.txt') and
         not unix.stat(startdir .. '/bad-stuff.txt'))

   -- the same attacks against the real touch(1), where it exists
   if not WINDOWS and unix.getuid() ~= 0 and unix.commandv('touch') then
      local sub = tmp .. '/real'
      assert(unix.mkdir(sub, tonumber('700', 8)))
      -- POSIXLY_CORRECT keeps GNU touch from treating the -c as an option
      p = assert(spawn.spawn({'touch', 'foo', '&&', '/bin/sh', '-c', 'touch bad-stuff.txt'},
                             {search = true, cwd = sub, env = {POSIXLY_CORRECT = '1'}}))
      p:wait()
      check('real touch: arguments became files', unix.stat(sub .. '/foo') and
            unix.stat(sub .. '/&&') and unix.stat(sub .. '/-c') and
            unix.stat(sub .. '/touch bad-stuff.txt'), table.concat(listing(sub), ','))
      check('real touch: nothing ran', not unix.stat(sub .. '/bad-stuff.txt'))
      p = assert(spawn.spawn({'touch', one}, {search = true, cwd = sub}))
      p:wait()
      check('real touch: string with slashes created nothing',
            not unix.stat(sub .. '/bad-stuff.txt') and not unix.stat(sub .. '/foo2'))
      q = spawn.spawn({one}, {search = true, cwd = sub})
      check('real touch: string is not a program', q == nil)
      for _, name in ipairs(listing(sub)) do unix.unlink(sub .. '/' .. name) end
      unix.rmdir(sub)
   end
end

--------------------------------------------------------------------------
-- wrapper: behavior

do
   local p = assert(spawn.spawn(H('touch', 'wrap1'), {cwd = tmp}))
   check('touch exit code', p:wait() == 0)
   check('touch created file', exists('wrap1'))
   check('wait is repeatable', p:wait() == 0)

   local q = assert(spawn.spawn({'not-a-program', '-i', HELPER, 'touch', 'wrap3'},
                                {path = EXE, cwd = tmp}))
   q:wait()
   check('path option runs program, not argv[1]', exists('wrap3') and
         not exists('not-a-program'))

   p = assert(spawn.spawn(H('env'), {env = {}}))
   local out = p:readStdout()
   p:wait()
   check('empty env stays empty', WINDOWS or out == '', out)
   p = assert(spawn.spawn(H('env'), {env = {FOO = 'bar'}}))
   out = p:readStdout()
   p:wait()
   check('env map', out:find('FOO=bar\n', 1, true) ~= nil, out)
   p = assert(spawn.spawn(H('env'), {env = {'A=1', 'B=2'}}))
   out = p:readStdout()
   p:wait()
   check('env list', out:find('A=1\nB=2\n', 1, true) ~= nil, out)

   p = assert(spawn.spawn(H('sortr')))
   check('write stdin', p:writeStdin('a\nb\nc\n'))
   p:closeStdin()
   check('read stdout', p:readStdout() == 'c\nb\na\n')
   check('stderr empty', p:readStderr() == '')
   check('sortr exit', p:wait() == 0)

   p = assert(spawn.spawn(H('stderr', 'boom')))
   check('stderr captured', p:readStderr() == 'boom')
   check('stdout empty', p:readStdout() == '')
   check('nonzero exit', p:wait() == 3)

   p = assert(spawn.spawn(H('stderr', 'boom'), {stderr = 'stdout'}))
   check('stderr merged into stdout', p:readStdout() == 'boom')
   check('merged stderr is not a pipe', p:readStderr() == nil)
   p:wait()

   p = assert(spawn.spawn(H('stderr', 'boom'),
                          {stderr = 'null', stdout = 'null', stdin = 'null'}))
   check('null modes', p:wait() == 3 and p:readStdout() == nil)

   p = assert(spawn.spawn(H('exit', '1')))
   check('exit code propagates', p:wait() == 1)

   -- a megabyte through cat fills every pipe in both directions, which
   -- deadlocks unless the wrapper drains while it writes
   local big = string.rep('0123456789abcdef', 65536)
   p = assert(spawn.spawn(H('cat')))
   check('large write completes', p:writeStdin(big))
   p:closeStdin()
   check('large read matches', p:readStdout() == big)
   check('cat exit', p:wait() == 0)

   p = assert(spawn.spawn(H('cat')))
   p:writeStdin('abcdef')
   check('bounded read', p:readStdout(2) == 'ab')
   check('bounded read leftover', p:readStdout(100) == 'cdef')
   p:closeStdin()
   check('read at eof is empty', p:readStdout(5) == '')
   p:wait()

   -- reading with a timeout on a pipe, false when it runs out
   local function ms()
      local sec, nsec = unix.clock_gettime(unix.CLOCK_MONOTONIC)
      return sec * 1000 + nsec / 1e6
   end
   p = assert(spawn.spawn(H('cat'), {stdout = 'pipe'}))
   local t0 = ms()
   check('pipe read timeout returns false', p:readStdout(10, 120) == false)
   local waited = ms() - t0
   check('pipe read timeout really waits', waited >= 100 and waited < 3000, waited)
   check('pipe read zero is a look', p:readStdout(10, 0) == false)
   p:writeStdin('x')
   check('pipe read timeout returns data at once', p:readStdout(10, 10000) == 'x')
   p:closeStdin()
   check('pipe read timeout at eof is empty', p:readStdout(10, 10000) == '')
   check('cat exits', p:wait() == 0)
   raises('timeout needs n', function() p:readStdout(nil, 100) end, 'timeout needs n')
   raises('timeout must be a number', function() p:readStdout(1, 'x') end, 'timeout must be')
   raises('timeout must be finite', function() p:readStdout(1, math.huge) end, 'timeout must be')

   -- the same on a temporary file, which has no end of file signal
   p = assert(spawn.spawn(H('delayecho', '1', 'late')))
   t0 = ms()
   check('file read timeout returns false', p:readStdout(10, 150) == false)
   waited = ms() - t0
   check('file read timeout really waits', waited >= 100 and waited < 900, waited)
   check('file read timeout returns data when it arrives', p:readStdout(10, 10000) == 'late')
   check('file read timeout at eof is empty', p:readStdout(10, 10000) == '')
   p:wait()

   -- stderr takes the same arguments
   p = assert(spawn.spawn(H('cat'), {stderr = 'pipe'}))
   check('stderr read timeout returns false', p:readStderr(10, 50) == false)
   p:closeStdin()
   p:wait()
   check('stderr read timeout at eof is empty', p:readStderr(10, 50) == '')

   p = assert(spawn.spawn(H('flood', '64')))
   check('tmpfile captures a flood', #p:readStdout() == 64 * 65536)
   check('tmpfile flood exit', p:wait() == 0)
   check('tmpfile second read is empty', p:readStdout() == '')

   -- stdout and stderr go to two different files
   p = assert(spawn.spawn(H('stderr', 'to-stderr')))
   check('separate stderr file', p:readStderr() == 'to-stderr')
   check('separate stdout file', p:readStdout() == '')
   check('stderr helper exit', p:wait() == 3)

   -- a pipe flood is read through readStdout while waiting
   p = assert(spawn.spawn(H('flood', '64'), {stdout = 'pipe', stderr = 'null'}))
   local got, deadline = 0, ms() + 60000
   while ms() < deadline do
      local d = p:readStdout(65536, 100)
      if d == '' then break end
      if d then got = got + #d end
   end
   check('pipe flood read with timeouts', got == 64 * 65536, got)
   check('pipe flood exit', p:wait() == 0)
end

--------------------------------------------------------------------------
-- waiting: wait(ms, sleepMs) and exitValue() look with waitid and never
-- reap, so the answer stays the same however often it is asked for

do
   local function ms()
      local sec, nsec = unix.clock_gettime(unix.CLOCK_MONOTONIC)
      return sec * 1000 + nsec / 1e6
   end

   local p = assert(spawn.spawn(H('sleep', '5')))
   check('exitValue is -1 while running', p:exitValue() == -1)
   check('exitValue repeats', p:exitValue() == -1)
   check('wait(0) is -1 while running', p:wait(0) == -1)
   check('wait(0, 0) is exitValue', p:wait(0, 0) == -1)
   local t0 = ms()
   check('timed wait is -1 on timeout', p:wait(200, 20) == -1)
   local waited = ms() - t0
   check('timed wait waits for its timeout', waited >= 150 and waited < 3000, waited)
   t0 = ms()
   check('spinning wait is -1 on timeout', p:wait(100, 0) == -1)
   waited = ms() - t0
   check('spinning wait waits for its timeout', waited >= 80 and waited < 3000, waited)
   t0 = ms()
   check('wait with a long sleep is cut at the timeout', p:wait(100, 5000) == -1)
   waited = ms() - t0
   check('wait never sleeps past its timeout', waited >= 80 and waited < 2500, waited)
   unix.kill(p.pid, unix.SIGKILL)
   local code, sig = p:wait()
   check('killed child reports 128 plus the signal', code == 128 + unix.SIGKILL and
         sig == unix.SIGKILL, tostring(code) .. ' ' .. tostring(sig))
   code, sig = p:exitValue()
   check('exitValue repeats after exit', code == 128 + unix.SIGKILL and sig == unix.SIGKILL)
   code, sig = p:wait(0, 0)
   check('wait(0) repeats after exit', code == 128 + unix.SIGKILL and sig == unix.SIGKILL)
   code, sig = p:wait(1000, 10)
   check('timed wait repeats after exit', code == 128 + unix.SIGKILL and sig == unix.SIGKILL)

   -- the child stays a zombie, so waiting never reaped it
   if not WINDOWS and unix.stat('/proc/self/stat') then
      local f = io.open('/proc/' .. p.pid .. '/stat')
      local line = f and f:read('a')
      if f then f:close() end
      check('waiting leaves the zombie', line and line:match('^%d+ %b() (%a)') == 'Z', line)
   end

   -- a program that exits with 128 plus a signal is not that signal
   p = assert(spawn.spawn(H('exit', '143')))
   code, sig = p:wait()
   check('real exit 143 has no signal', code == 143 and sig == nil, tostring(code) .. ' ' .. tostring(sig))

   -- a blocking wait sleeps until the child is done
   p = assert(spawn.spawn(H('sleep', '1')))
   t0 = ms()
   check('blocking wait returns the exit code', p:wait(-1) == 0)
   waited = ms() - t0
   check('blocking wait waited for the child', waited >= 700 and waited < 6000, waited)
   check('wait with no arguments blocks too', assert(spawn.spawn(H('exit', '4'))):wait() == 4)

   -- killed first, then waited for without a timeout, both while the
   -- process is fresh and long after it died
   p = assert(spawn.spawn(H('sleep', '60')))
   unix.kill(p.pid, unix.SIGKILL)
   t0 = ms()
   code, sig = p:wait(-1)
   check('wait right after a kill returns', code == 128 + unix.SIGKILL and sig == unix.SIGKILL,
         tostring(code))
   check('wait right after a kill is prompt', ms() - t0 < 5000, ms() - t0)
   p = assert(spawn.spawn(H('sleep', '60')))
   unix.kill(p.pid, unix.SIGKILL)
   unix.nanosleep(0, 300 * 1000 * 1000)
   t0 = ms()
   code = p:wait(-1)
   check('wait long after a kill returns', code == 128 + unix.SIGKILL, tostring(code))
   check('wait long after a kill is prompt', ms() - t0 < 3000, ms() - t0)

   raises('wait rejects text', function() p:wait('x') end, 'timeout must be')
   raises('wait rejects nan', function() p:wait(0 / 0) end, 'timeout must be')
   raises('wait rejects infinity', function() p:wait(math.huge) end, 'timeout must be')
   raises('wait rejects text sleep', function() p:wait(1, 'x') end, 'sleepMs must be')
   raises('wait rejects negative sleep', function() p:wait(1, -1) end, 'sleepMs must not')
   raises('negative shutdownTimeout is rejected', function() spawn.spawn(H('exit', '0'), {shutdownTimeout = -1}) end, 'must not be negative')
   raises('shutdownTimeout is a number', function() spawn.spawn(H('exit', '0'), {shutdownTimeout = 'x'}) end, 'shutdownTimeout must be')
   raises('shutdownSleep is a number', function() spawn.spawn(H('exit', '0'), {shutdownSleep = 0 / 0}) end, 'shutdownSleep must be')
   raises('the sleep option is gone', function() spawn.spawn(H('exit', '0'), {sleep = 20}) end, 'unknown option')
   check('there is no kill', assert(spawn.spawn(H('exit', '0'))).kill == nil)

   -- there is no wait on a pid that is not ours, which is what a copy of
   -- the parent made by fork has
   local p2 = assert(spawn.spawn(H('forkcopy'), {env = ENV, stdin = 'null'}))
   local out = p2:readStdout()
   check('fork copy sees its own errors', out:find('copy: raised not a child\n', 1, true) ~= nil, out)
   check('fork copy close reports nothing', out:find('copy: close returned 0 values\n', 1, true) ~= nil, out)
   check('fork copy left the child alone', out:find('parent: running\n', 1, true) ~= nil, out)
   check('fork copy parent got the exit code', out:find('parent: exited 5\n', 1, true) ~= nil, out)
   check('forkcopy exit', p2:wait() == 0)
end

--------------------------------------------------------------------------
-- collection kills and reaps, politely first

-- On Windows a signal 0 only finds the shared memory file a cosmo process
-- leaves behind, which outlives it, and killing a dead process may report
-- success under wine.  So there a process is alive if its heartbeat file is
-- still changing.
local function beat(pid)
   local f = io.open(tmp .. '/hb-' .. pid)
   local v = f and f:read('a')
   if f then f:close() end
   return v
end

local function alive(pid)
   if not WINDOWS then return unix.kill(pid, 0) == true end
   local a = beat(pid)
   if a == nil then return false end
   unix.nanosleep(0, 250 * 1000 * 1000)
   return beat(pid) ~= a
end

local function ms()
   local sec, nsec = unix.clock_gettime(unix.CLOCK_MONOTONIC)
   return sec * 1000 + nsec / 1e6
end

local function gc()
   collectgarbage() collectgarbage()
end

do
   local pid, t0
   do
      local p = assert(spawn.spawn(H('sleep', '60'), {env = HBENV}))
      pid = p.pid
      unix.nanosleep(0, 400 * 1000 * 1000)
      check('child alive before gc', alive(pid))
   end
   gc()
   check('gc kills and reaps child at once', not alive(pid))

   -- a child that exits by itself is reaped too
   do
      local p = assert(spawn.spawn(H('exit', '0')))
      pid = p.pid
      p:wait()
      check('exited child is a zombie until gc', alive(pid) or WINDOWS)
   end
   gc()
   check('gc reaps an exited child', not alive(pid))

   -- SIGTERM first, and the child gets to clean up
   local marker = tmp .. '/graceful'
   do
      local p = assert(spawn.spawn(H('trapterm', marker),
                                   {stdout = 'pipe', shutdownTimeout = 5000, env = HBENV}))
      check('trapterm child is ready', p:readStdout(1, 20000) == 'r')
      pid = p.pid
   end
   t0 = ms()
   gc()
   check('gc waited for the child to say goodbye', exists('graceful'))
   check('gracefully ended child is gone', not alive(pid))
   check('graceful gc did not use the whole timeout', ms() - t0 < 4500, ms() - t0)

   -- ignoring SIGTERM costs the whole shutdown timeout, then SIGKILL
   do
      local p = assert(spawn.spawn(H('ignoreterm'), {stdout = 'pipe', shutdownTimeout = 300, env = HBENV}))
      check('ignoreterm child is ready', p:readStdout(1, 20000) == 'r')
      pid = p.pid
   end
   t0 = ms()
   gc()
   local took = ms() - t0
   check('stubborn child is gone', not alive(pid))
   check('stubborn child got its shutdown time', took >= 250, took)
   check('stubborn child did not get much more', took < 4000, took)

   -- the default timeout is short
   do
      local p = assert(spawn.spawn(H('ignoreterm'), {stdout = 'pipe', env = HBENV}))
      check('default shutdownTimeoutMs', p.shutdownTimeoutMs == 10 and p.shutdownSleepMs == 10)
      check('ignoreterm child is ready again', p:readStdout(1, 20000) == 'r')
      pid = p.pid
      p.shutdownTimeoutMs = 50
   end
   t0 = ms()
   gc()
   check('shutdown fields can be changed', not alive(pid) and ms() - t0 < 3000)

   -- pipes close first, so a child blocked writing dies of the broken pipe
   -- at once, instead of using up its shutdown time
   do
      local p = assert(spawn.spawn(H('pipeblock'), {stdout = 'pipe', shutdownTimeout = 20000, env = HBENV}))
      check('pipeblock child is ready', p:readStdout(1, 20000) == 'r')
      unix.nanosleep(0, 300 * 1000 * 1000)  -- let it fill the pipe
      pid = p.pid
   end
   t0 = ms()
   gc()
   -- a child blocked in a write has no heartbeat to judge it by on Windows
   if not WINDOWS then check('child blocked on a full pipe is gone', not alive(pid)) end
   check('child blocked on a full pipe did not need the timeout', ms() - t0 < 10000, ms() - t0)
end

do
   local before = assert(unix.dup(0))
   unix.close(before)
   for _ = 1, 50 do
      local p = assert(spawn.spawn(H('exit', '0')))
      p:wait()
   end
   gc()
   local after = assert(unix.dup(0))
   unix.close(after)
   check('gc closes descriptors', after <= before + 1, after)
end

--------------------------------------------------------------------------
-- close, <close> and the closed flag

do
   local t0
   -- a child that already exited, closed after reading its output
   local p = assert(spawn.spawn(H('exit', '4')))
   check('closed starts false', p.closed == nil or p.closed == false)
   check('read before close', p:readStdout() == '')
   local code, sig = p:close()
   check('close returns the exit code', code == 4 and sig == nil, tostring(code) .. ' ' .. tostring(sig))
   check('closed is set', p.closed == true)
   check('second close does nothing', select('#', p:close()) == 0)

   -- every other method refuses a closed process
   for name, f in pairs({
      wait = function() p:wait() end, exitValue = function() p:exitValue() end,
      readStdout = function() p:readStdout() end, readStderr = function() p:readStderr(1) end,
      writeStdin = function() p:writeStdin('x') end, closeStdin = function() p:closeStdin() end}) do
      raises(name .. ' after close raises', f, 'process is closed')
   end

   -- a child that is still running is stopped, and its status reported
   p = assert(spawn.spawn(H('sleep', '60'), {env = HBENV}))
   local pid = p.pid
   unix.nanosleep(0, 400 * 1000 * 1000)
   check('child runs before close', alive(pid))
   t0 = ms()
   code, sig = p:close()
   check('close stopped the child', not alive(pid))
   if WINDOWS then
      check('close of a running child reports a failure', code ~= nil and code ~= 0, tostring(code))
   else
      check('close of a running child reports SIGTERM', code == 128 + unix.SIGTERM and
            sig == unix.SIGTERM, tostring(code) .. ' ' .. tostring(sig))
   end
   check('close of a running child was quick', ms() - t0 < 5000, ms() - t0)

   -- a child that ignores SIGTERM gets the timeout and then SIGKILL
   p = assert(spawn.spawn(H('ignoreterm'), {stdout = 'pipe', shutdownTimeout = 200, env = HBENV}))
   check('stubborn child is ready', p:readStdout(1, 20000) == 'r')
   pid = p.pid
   code, sig = p:close()
   check('stubborn child is gone after close', not alive(pid))
   if not WINDOWS then
      check('stubborn child reports SIGKILL', code == 128 + unix.SIGKILL and sig == unix.SIGKILL,
            tostring(code) .. ' ' .. tostring(sig))
   end

   -- a to-be-closed variable cleans up at the end of its scope
   do
      local q <close> = assert(spawn.spawn(H('sleep', '60'), {env = HBENV}))
      pid = q.pid
      unix.nanosleep(0, 400 * 1000 * 1000)
      check('scoped child runs inside the scope', alive(pid))
   end
   check('scoped child is gone after the scope', not alive(pid))

   -- also when the scope is left by an error
   local ok = pcall(function()
      local q <close> = assert(spawn.spawn(H('sleep', '60'), {env = HBENV}))
      pid = q.pid
      unix.nanosleep(0, 400 * 1000 * 1000)
      error('leaving')
   end)
   check('the error got out', not ok)
   check('scoped child is gone after an error', not alive(pid))

   -- once closed, collection must leave the pid alone, since by then it
   -- may belong to another child.  Point a closed object at a live one and
   -- collect it
   local decoy = assert(spawn.spawn(H('sleep', '60'), {env = HBENV}))
   unix.nanosleep(0, 400 * 1000 * 1000)
   do
      local r = assert(spawn.spawn(H('exit', '0')))
      r:close()
      r.pid = decoy.pid
   end
   gc()
   check('collecting a closed object does not touch another process', alive(decoy.pid))
   check('and the other process is still ours', decoy:exitValue() == -1)
   decoy:close()
   check('decoy closes', not alive(decoy.pid))

   -- closing then collecting is the same as closing
   do
      local q = assert(spawn.spawn(H('sleep', '60'), {env = HBENV}))
      pid = q.pid
      unix.nanosleep(0, 400 * 1000 * 1000)
      q:close()
   end
   gc()
   check('close then collection leaves nothing behind', not alive(pid))
end

--------------------------------------------------------------------------
-- spawn refuses to run where it cannot keep its promises

for _, how in ipairs({'sigchld', 'sigterm', 'sighup', 'sigint'}) do
   local p = assert(spawn.spawn(H('refuse', how), {env = ENV, stdin = 'null'}))
   local out = p:readStdout()
   check('refuse ' .. how .. ' exits', p:wait() == 0, out)
   check('refuse ' .. how .. ' raises', out:find('raised ', 1, true) == 1 and
         out:find('cosmo-spawn: ', 1, true) ~= nil, out)
   check('refuse ' .. how .. ' says why', out:find(how == 'sigchld' and 'SIGCHLD is ignored'
         or 'already has a handler', 1, true) ~= nil, out)
end

do
   -- a C handler on SIGINT, which is what script mode has, is allowed
   local p = assert(spawn.spawn(H('plainsigint'), {env = ENV, stdin = 'null'}))
   check('plain script mode is accepted', p:readStdout() == 'ok\n')
   p:wait()
end

--------------------------------------------------------------------------
-- pledge and unveil forbid spawning
--
-- Both are one way, so each runs in a child process.  Where the host does
-- not enforce them, such as under qemu-user and wine, the spawn simply
-- succeeds, which is reported and not counted as a failure.

for _, mode in ipairs({'pledged', 'unveiled'}) do
   local p = assert(spawn.spawn(H(mode), {env = ENV}))
   local out = p:readStdout()
   local code = p:wait()
   if out:find('^blocked ') then
      check(mode .. ': spawn is refused and fails closed', code == 0, out)
   elseif out == 'spawned\n' then
      print('note ' .. mode .. ': not enforced on this host, spawn was allowed')
      check(mode .. ': helper ran to completion', code == 0)
   else
      check(mode .. ': unexpected result', false, out .. ' (exit ' .. tostring(code) .. ')')
   end
end

--------------------------------------------------------------------------
-- children die when redbean leaves, however it leaves

local function pids(p, n)
   local out, text = {}, ''
   local deadline = ms() + 30000
   while ms() < deadline and select(2, text:gsub('\n', '')) < n do
      local d = p:readStdout(100, 200)
      if d == '' then break end
      if d then text = text .. d end
   end
   for l in text:gmatch('[^\n]+') do out[#out + 1] = tonumber(l) end
   return out
end

-- waits for every child to be running, so that a test that expects them
-- to be gone afterwards cannot pass because they never started
local function allup(list)
   for _ = 1, 100 do
      local up = true
      for _, pid in ipairs(list) do if not alive(pid) then up = false end end
      if up then return true end
      unix.nanosleep(0, 100 * 1000 * 1000)
   end
   return false
end

local function allgone(list)
   for _ = 1, 150 do
      local any = false
      for _, pid in ipairs(list) do if alive(pid) then any = true end end
      if not any then return true end
      unix.nanosleep(0, 20 * 1000 * 1000)
   end
   return false
end

for _, how in ipairs({'end', 'osexit', 'osexitclose', 'unixexit', 'error'}) do
   local p = assert(spawn.spawn(H('parentexit', how),
                                {env = ENV, stdin = 'null', stdout = 'pipe'}))
   local list = pids(p, 1)
   p:wait()
   check('parent leaving by ' .. how .. ' reported its child', #list == 1)
   check('child is killed when its parent leaves by ' .. how, allgone(list))
   for _, pid in ipairs(list) do if alive(pid) then unix.kill(pid, unix.SIGKILL) end end
end

-- signals that would kill the script now close it first.  The status is
-- 128 plus the signal, and a blocked wait, a timed wait loop and a read
-- with a timeout all let the handler run
local signals = {{'SIGTERM', unix.SIGTERM}, {'SIGINT', unix.SIGINT}}
if not WINDOWS then signals[#signals + 1] = {'SIGHUP', unix.SIGHUP} end
for _, sg in ipairs(signals) do
   for _, mode in ipairs({'wait', 'timed', 'read', 'idle'}) do
      local name = 'signal ' .. sg[1] .. ' during ' .. mode
      local p = assert(spawn.spawn(H('signal', mode),
                                   {env = ENV, stdin = 'null', stdout = 'pipe'}))
      local list = pids(p, 1)
      check(name .. ' reported its child', #list == 1)
      check(name .. ' child is running', allup(list))
      unix.kill(p.pid, sg[2])
      local code = p:wait(30000, 20)
      check(name .. ' ended the script with 128 plus the signal', code == 128 + sg[2], tostring(code))
      check(name .. ' killed the child', allgone(list))
      for _, pid in ipairs(list) do if alive(pid) then unix.kill(pid, unix.SIGKILL) end end
   end
end

-- a signal that arrives while a collection is waiting out its child does
-- not leave that child behind, the collection finishes first
do
   local p = assert(spawn.spawn(H('signal', 'gc'),
                                {env = ENV, stdin = 'null', stdout = 'pipe'}))
   local list = pids(p, 2)
   check('gc signal test reported two children', #list == 2)
   check('gc signal test children are running', allup(list))
   unix.kill(p.pid, unix.SIGTERM)
   local code = p:wait(60000, 20)
   check('signal during collection ended the script', code == 128 + unix.SIGTERM, tostring(code))
   check('signal during collection left no child', allgone(list))
   for _, pid in ipairs(list) do if alive(pid) then unix.kill(pid, unix.SIGKILL) end end
end

-- SIGKILL cannot be handled, so there the child is orphaned.  That is
-- the documented limit, and the test cleans up after it
do
   local p = assert(spawn.spawn(H('signal', 'wait'),
                                {env = ENV, stdin = 'null', stdout = 'pipe'}))
   local list = pids(p, 1)
   check('orphan test child is running', allup(list))
   unix.kill(p.pid, unix.SIGKILL)
   p:wait()
   unix.nanosleep(0, 300 * 1000 * 1000)
   check('SIGKILL of the parent orphans the child, as documented', #list == 1 and alive(list[1]))
   for _, pid in ipairs(list) do unix.kill(pid, unix.SIGKILL) end
end

--------------------------------------------------------------------------
-- waiting must sleep in the kernel and not in a loop. os.clock counts only
-- this process, so the child's own sleep costs nothing here. The bound is
-- loose enough for emulators, a busy loop would use the whole wall time.

do
   local function cpu(label, opts, wait)
      local p = assert(spawn.spawn(H('sleep', '2'), opts))
      local c0, t0 = os.clock(), ms()
      wait(p)
      local wall, used = ms() - t0, (os.clock() - c0) * 1000
      print(('cpu %-34s wall %5.0fms  cpu %6.1fms'):format(label, wall, used))
      check('cpu ' .. label .. ' waited', wall >= 1500, wall)
      check('cpu ' .. label .. ' sleeps in the kernel', used < wall * 0.25, used)
      p:wait()
   end
   cpu('wait()', nil, function(p) p:wait() end)
   cpu('wait(-1)', {stdout = 'pipe'}, function(p) p:wait(-1) end)
   cpu('wait(10000, 50)', nil, function(p) p:wait(10000, 50) end)
   cpu('wait(100) loop', nil, function(p) while p:wait(100) == -1 do end end)
   cpu('readStdout()', {stdout = 'pipe'}, function(p) p:readStdout() end)
   cpu('readStdout(1, 100) loop', {stdout = 'pipe'},
       function(p) while p:readStdout(1, 100) == false do end end)
   cpu('tmpfile readStdout()', nil, function(p) p:readStdout() end)
end

--------------------------------------------------------------------------

for _, name in ipairs(listing()) do
   unix.unlink(tmp .. '/' .. name)
end
unix.rmdir(tmp)

print(('%d passed, %d failed'):format(passed, failed))
unix.exit(failed == 0 and 0 or 1)
