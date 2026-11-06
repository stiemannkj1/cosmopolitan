-- Functional tests for unix.posix_spawn(p) and the cosmo-spawn wrapper.
--
--   o/x86_64/tool/net/redbean -i scripts/cosmo_spawn_test.lua
--   qemu-aarch64 o/aarch64/tool/net/redbean -i scripts/cosmo_spawn_test.lua
--   wine o/redbean.com -i scripts/cosmo_spawn_test.lua
--
-- Child programs are redbean itself running scripts/cosmo_spawn_helper.lua,
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

   p = assert(spawn.spawn(H('flood'), {stderr = 'null'}))
   check('flood read bounded', #p:readStdout(1000) > 0)
   check('kill returns true', p:kill() == true)
   local code, sig = p:wait()
   if WINDOWS then
      check('killed child reports failure', code ~= 0, code)
   else
      check('killed by SIGTERM', sig == unix.SIGTERM and code == 128 + unix.SIGTERM,
            tostring(code) .. ' ' .. tostring(sig))
   end
   check('kill after exit is false', p:kill() == false)

   -- polling wait(true) must drain, or a child writing more than the pipe
   -- buffer would block forever while the caller spins
   p = assert(spawn.spawn(H('flood', '64'), {stderr = 'null'}))
   local done
   local deadline = unix.clock_gettime() + 30
   while unix.clock_gettime() < deadline do
      done = p:wait(true)
      if done ~= false then break end
      unix.nanosleep(0, 5000000)
   end
   if done == false then p:kill() p:wait() end  -- never hang on failure
   check('nohang polling drains and finishes', done == 0, tostring(done))
   check('nohang drained output intact', done ~= 0 or #p:readStdout() == 64 * 65536)

   p = assert(spawn.spawn(H('cat')))
   check('wait nohang while running', p:wait(true) == false)
   p:closeStdin()
   check('wait after stdin closed', p:wait() == 0)

   p = assert(spawn.spawn(H('sleep', '60'), {stdout = 'null'}))
   p:kill(unix.SIGKILL)
   p:wait()
   local ok, err = p:writeStdin('x')
   check('write to dead child fails cleanly', ok == nil and err ~= nil)

   raises('write requires string', function() p:writeStdin(5) end, 'must be a string')
end

--------------------------------------------------------------------------
-- cleanup on collection

local function alive(pid)
   return unix.kill(pid, 0) == true
end

do
   local pid
   do
      local p = assert(spawn.spawn(H('sleep', '60')))
      pid = p.pid
      check('child alive before gc', alive(pid))
   end
   collectgarbage() collectgarbage()
   local gone = false
   for _ = 1, 150 do
      local q = assert(spawn.spawn(H('exit', '0')))  -- sweeps orphans
      q:wait()
      if not alive(pid) then gone = true break end
      unix.nanosleep(0, 20 * 1000 * 1000)
   end
   check('gc kills and reaps child', gone)
end

do
   local before = assert(unix.dup(0))
   unix.close(before)
   for _ = 1, 50 do
      local p = assert(spawn.spawn(H('exit', '0')))
      p:wait()
   end
   collectgarbage() collectgarbage()
   local after = assert(unix.dup(0))
   unix.close(after)
   check('gc closes descriptors', after <= before + 1, after)
end

--------------------------------------------------------------------------
-- pledge and unveil forbid spawning
--
-- Both are one way, so each runs in a child process.  Where the host does
-- not enforce them, such as under qemu-user and wine, the spawn simply
-- succeeds, which is reported and not counted as a failure.

for _, mode in ipairs({'pledged', 'unveiled'}) do
   local p = assert(spawn.spawn(H(mode), {env = unix.environ()}))
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
-- children die when redbean shuts down, and shutdown does not block

do
   local t0 = unix.clock_gettime()
   local p = assert(spawn.spawn(H('pid'), {env = unix.environ(), stdin = 'null'}))
   local pid = tonumber(p:readStdout())
   p:wait()
   check('grandchild pid reported', pid ~= nil)
   local gone = false
   for _ = 1, 150 do
      if not alive(pid) then gone = true break end
      unix.nanosleep(0, 20 * 1000 * 1000)
   end
   check('shutdown kills child', gone)
   check('shutdown does not block', unix.clock_gettime() - t0 < 30)
end

--------------------------------------------------------------------------

for _, name in ipairs(listing()) do
   unix.unlink(tmp .. '/' .. name)
end
unix.rmdir(tmp)

print(('%d passed, %d failed'):format(passed, failed))
unix.exit(failed == 0 and 0 or 1)
