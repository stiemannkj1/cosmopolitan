-- Exits through os.exit(code, true) so the Lua state is closed and every
-- finalizer runs, which is what cosmo-spawn relies on for cleanup.
--
-- Child program used by cosmo_spawn_test.lua so the same tests can run on
-- platforms without coreutils.  Run as: redbean -i this.lua MODE [ARG...]
local unix = require 'unix'
local mode = arg[1]

-- Sleeps for the given seconds.  When HB_DIR is set, the process also
-- writes a counter to HB_DIR/hb-PID every 50ms for as long as it lives, so
-- that a test can tell on any system, Windows included, whether it is still
-- running.  Sleeping in short naps is also what lets a signal handler run.
local function nap(seconds)
   local dir = os.getenv('HB_DIR')
   if not dir then
      unix.nanosleep(seconds, 0)
      return
   end
   local path = dir .. '/hb-' .. unix.getpid()
   local stop = unix.clock_gettime() + seconds
   local n = 0
   while unix.clock_gettime() < stop do
      n = n + 1
      local f = io.open(path, 'w')
      if f then f:write(n) f:close() end
      unix.nanosleep(0, 50 * 1000 * 1000)
   end
end

local function rest()
   return table.move(arg, 2, #arg, 1, {})
end

if mode == 'argv' then
   -- prints each argument on a line of its own, argv[0] excluded
   for _, a in ipairs(rest()) do io.stdout:write(a, '\n') end
elseif mode == 'touch' then
   -- creates an empty file per argument, like touch with no options
   local failed = 0
   for _, a in ipairs(rest()) do
      local f = io.open(a, 'a')
      if f then f:close() else failed = 1 end
   end
   io.stdout:flush()
   os.exit(failed, true)
elseif mode == 'cat' then
   -- forwards whatever has arrived without waiting for a full buffer
   while true do
      local d = unix.read(0, 4096)
      if not d or d == '' then break end
      io.stdout:write(d)
      io.stdout:flush()
   end
elseif mode == 'sortr' then
   local lines = {}
   for l in io.stdin:lines() do lines[#lines + 1] = l end
   table.sort(lines, function(a, b) return a > b end)
   for _, l in ipairs(lines) do io.stdout:write(l, '\n') end
elseif mode == 'env' then
   local e = unix.environ()
   table.sort(e)
   for _, v in ipairs(e) do io.stdout:write(v, '\n') end
elseif mode == 'exit' then
   os.exit(tonumber(arg[2]), true)
elseif mode == 'stderr' then
   io.stderr:write(arg[2])
   io.stdout:flush()
   os.exit(3, true)
elseif mode == 'flood' then
   local z = string.rep('\0', 65536)
   -- flood [n] stops after n blocks of 64KB, default is to never stop
   local n = tonumber(arg[2])
   while not n or n > 0 do
      io.stdout:write(z)
      if n then n = n - 1 end
   end
elseif mode == 'sleep' then
   nap(tonumber(arg[2]) or 60)
elseif mode == 'pledged' or mode == 'unveiled' then
   -- applies an irreversible sandbox that should forbid running programs,
   -- then reports what the wrapper does when asked to spawn one
   if mode == 'pledged' then
      assert(unix.pledge('stdio rpath', nil, unix.PLEDGE_PENALTY_RETURN_EPERM))
   else
      assert(unix.unveil(unix.getcwd(), 'r'))
      assert(unix.unveil(nil, nil))
   end
   -- null streams, so that no temporary file is needed and the refusal that
   -- comes from the sandbox is the one that gets reported
   local p, err = require('cosmo-spawn').spawn({arg[-1], '-i', arg[0], 'exit', '0'},
                                               {stdout = 'null', stderr = 'null'})
   if p then
      p:wait()
      io.stdout:write('spawned\n')
   else
      io.stdout:write('blocked ', err:doc(), '\n')
   end
elseif mode == 'delayecho' then
   -- delayecho SECONDS TEXT, writes TEXT after waiting
   unix.nanosleep(tonumber(arg[2]), 0)
   io.stdout:write(arg[3])
   io.stdout:flush()
elseif mode == 'trapterm' then
   -- trapterm MARKER, creates MARKER when told to stop and then stops
   unix.sigaction(unix.SIGTERM, function()
      local f = io.open(arg[2], 'w')
      if f then f:close() end
      os.exit(0, true)
   end)
   unix.write(1, 'r')
   while true do nap(60) end
elseif mode == 'ignoreterm' then
   unix.sigaction(unix.SIGTERM, unix.SIG_IGN)
   unix.write(1, 'r')
   while true do nap(60) end
elseif mode == 'pipeblock' then
   -- ignores SIGTERM and writes until the pipe is full, then blocks.  It
   -- only ends if the pipe is closed, which breaks the write
   unix.sigaction(unix.SIGTERM, unix.SIG_IGN)
   unix.write(1, 'r')
   local z = string.rep('\0', 65536)
   local dir = os.getenv('HB_DIR')
   local path = dir and dir .. '/hb-' .. unix.getpid()
   local n = 0
   while true do
      n = n + 1
      if path then
         local f = io.open(path, 'w')
         if f then f:write(n) f:close() end
      end
      if not unix.write(1, z) then os.exit(1, true) end
   end
elseif mode == 'exitonstdin' then
   -- exitonstdin CODE, waits for end of file on stdin and then exits
   while true do
      local d = unix.read(0, 4096)
      if not d or d == '' then break end
   end
   os.exit(tonumber(arg[2]), true)
elseif mode == 'forkcopy' then
   -- a copy of the process made by fork does not own the child
   local spawn = require 'cosmo-spawn'
   local p = assert(spawn.spawn({arg[-1], '-i', arg[0], 'exitonstdin', '5'}))
   local pid = assert(unix.fork())
   if pid == 0 then
      local ok, err = pcall(p.exitValue, p)
      local what = ok and 'returned' or (tostring(err):find('not a child', 1, true)
                                         and 'raised not a child' or 'raised ' .. tostring(err))
      io.stdout:write('copy: ', what, '\n')
      io.stdout:flush()
      os.exit(0, true)  -- finalizes the copy, which must not touch the child
   end
   unix.wait(pid)
   io.stdout:write('parent: ', p:exitValue() == -1 and 'running' or 'gone', '\n')
   p:closeStdin()
   io.stdout:write('parent: exited ', tostring(p:wait()), '\n')
elseif mode == 'refuse' then
   -- sets up something spawn will not run beside, then tries to spawn
   local how = arg[2]
   if how == 'sigchld' then
      unix.sigaction(unix.SIGCHLD, unix.SIG_IGN)
   else
      unix.sigaction(unix[how == 'sigterm' and 'SIGTERM' or how == 'sighup' and 'SIGHUP'
                          or 'SIGINT'], function() end)
   end
   local ok, err = pcall(require('cosmo-spawn').spawn, {arg[-1], '-i', arg[0], 'exit', '0'})
   io.stdout:write(ok and 'spawned' or 'raised ', ok and '' or tostring(err), '\n')
elseif mode == 'plainsigint' then
   local p = assert(require('cosmo-spawn').spawn({arg[-1], '-i', arg[0], 'exit', '0'}))
   p:wait()
   io.stdout:write('ok\n')
elseif mode == 'parentexit' then
   -- starts a child that sleeps, reports its pid, then leaves the way asked
   local spawn = require 'cosmo-spawn'
   local p = assert(spawn.spawn({arg[-1], '-i', arg[0], 'sleep', '60'}, {env = unix.environ()}))
   io.stdout:write(p.pid, '\n')
   io.stdout:flush()
   local how = arg[2]
   if how == 'osexit' then
      os.exit(0)
   elseif how == 'osexitclose' then
      os.exit(0, true)
   elseif how == 'unixexit' then
      unix.exit(0)
   elseif how == 'error' then
      error('boom')
   elseif how == 'end' then
      do return end
   end
elseif mode == 'signal' then
   -- signal MODE, starts children and then sits in the kind of wait MODE
   -- names, until a signal comes
   local spawn = require 'cosmo-spawn'
   local how = arg[2]
   local child = {arg[-1], '-i', arg[0], 'sleep', '60'}
   if how == 'gc' then
      -- two children that ignore SIGTERM, collected while a signal arrives
      local list = {}
      for i = 1, 2 do
         local p = assert(spawn.spawn({arg[-1], '-i', arg[0], 'ignoreterm'},
                                      {stdout = 'pipe', shutdownTimeout = 2000,
                                       env = unix.environ()}))
         assert(p:readStdout(1, 30000) == 'r')
         list[i] = p
      end
      io.stdout:write(list[1].pid, '\n', list[2].pid, '\n')
      io.stdout:flush()
      list = nil
      collectgarbage()
      collectgarbage()
      -- reached only if no signal came
      nap(60)
   end
   local p = assert(spawn.spawn(child, {env = unix.environ(),
                                        stdout = how == 'read' and 'pipe' or nil}))
   io.stdout:write(p.pid, '\n')
   io.stdout:flush()
   if how == 'wait' then
      p:wait()
   elseif how == 'timed' then
      while p:wait(60000, 10) == -1 do end
   elseif how == 'read' then
      p:readStdout(1, 60000)
   else
      while true do nap(60) end
   end
end
io.stdout:flush()
os.exit(0, true)
