-- unix.waitid() looks at a child without reaping it. It is separate from
-- lunix_test.lua because that one cannot run under wine, and the New
-- Technology has its own waitid. Children never sleep, they block on a
-- pipe, since fork() plus a sleep is a crash on wine.

-- OpenBSD cannot look at a zombie, so there it only reports ENOSYS
do
   local pid, err = unix.waitid(-1, unix.WNOHANG)
   if pid == nil and err:errno() == unix.ENOSYS then
      print('unixwaitid_test ok (no waitid here)')
      return
   end
end

-- forks a child that exits with `code`. With gate, the child first blocks
-- until the parent writes to (or closes) the returned writer end.
local function spawn(code, gate)
   local reader, writer
   if gate then reader, writer = assert(unix.pipe()) end
   local pid = assert(unix.fork())
   if pid == 0 then
      if gate then
         unix.close(writer)
         unix.read(reader, 1)
      end
      unix.exit(code)
   end
   if gate then unix.close(reader) end
   return pid, writer
end

local function release(writer)
   assert(unix.write(writer, 'x'))
   assert(unix.close(writer))
end

local PEEK = unix.WNOWAIT

-- peeking leaves the child waitable
do
   local pid = spawn(7)
   local p, code, status = assert(unix.waitid(pid, PEEK))
   assert(p == pid and code == unix.CLD_EXITED and status == 7)
   p, code, status = assert(unix.waitid(pid, PEEK))
   assert(p == pid and code == unix.CLD_EXITED and status == 7)
   p, code, status = assert(unix.waitid(-1, PEEK | unix.WNOHANG))
   assert(p == pid and status == 7)
   local rp, ws = assert(unix.wait(pid))
   assert(rp == pid and unix.WIFEXITED(ws) and unix.WEXITSTATUS(ws) == 7)
   local nope, err = unix.waitid(pid, PEEK)
   assert(nope == nil and err:errno() == unix.ECHILD)
end

-- without WNOWAIT it reaps
do
   local pid = spawn(3)
   local p, code, status = assert(unix.waitid(pid))
   assert(p == pid and code == unix.CLD_EXITED and status == 3)
   local nope, err = unix.wait(pid)
   assert(nope == nil and err:errno() == unix.ECHILD)
end

-- WNOHANG on a running child answers pid 0, a blocking peek waits for it
do
   local pid, gate = spawn(0, true)
   local p = assert(unix.waitid(pid, PEEK | unix.WNOHANG))
   assert(p == 0)
   release(gate)
   local code, status
   p, code, status = assert(unix.waitid(pid, PEEK))
   assert(p == pid and code == unix.CLD_EXITED and status == 0)
   assert(unix.waitid(pid))
end

-- killed, then waited for with no timeout, and killed long before
for _, delay in ipairs({0, 150}) do
   local pid, gate = spawn(0, true)
   assert(unix.kill(pid, unix.SIGKILL))
   if delay > 0 then unix.nanosleep(0, delay * 1000 * 1000) end
   local p, code, status = assert(unix.waitid(pid, PEEK))
   assert(p == pid and code == unix.CLD_KILLED and status == unix.SIGKILL)
   assert(unix.waitid(pid))
   unix.close(gate)
end

-- not our child
do
   local nope, err = unix.waitid(1, unix.WNOHANG)
   assert(nope == nil and err:errno() == unix.ECHILD)
   nope, err = unix.waitid(unix.getpid(), unix.WNOHANG)
   assert(nope == nil and err:errno() == unix.ECHILD)
end

print('unixwaitid_test ok')
