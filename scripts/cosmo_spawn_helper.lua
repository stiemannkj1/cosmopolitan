-- Exits through os.exit(code, true) rather than unix.exit, which is _Exit and
-- would skip the Lua state close that cosmo-spawn relies on for cleanup.
--
-- Child program used by cosmo_spawn_test.lua so the same tests can run on
-- platforms without coreutils.  Run as: redbean -i this.lua MODE [ARG...]
local unix = require 'unix'
local mode = arg[1]

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
   unix.nanosleep(tonumber(arg[2]) or 60, 0)
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
elseif mode == 'pid' then
   -- prints the pid of a grandchild that sleeps, then exits at once
   local spawn = require 'cosmo-spawn'
   local p = assert(spawn.spawn({arg[-1], '-i', arg[0], 'sleep', '60'}))
   io.stdout:write(p.pid, '\n')
   io.stdout:flush()
end
io.stdout:flush()
os.exit(0, true)
