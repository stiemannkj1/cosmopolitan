--[[ Functional test for the luaposix and LuaFileSystem modules compiled
     into this cosmopolitan lua.  Run it with the binary under test:

       o/x86_64/third_party/lua/lua scripts/luaext_test.lua
       qemu-aarch64 o/aarch64/third_party/lua/lua scripts/luaext_test.lua
       wine o/lua.com scripts/luaext_test.lua

     Calls that fail with ENOSYS, ENOTSUP or EPERM are reported as
     unsupported rather than failed, because the same binary is expected
     to run on platforms that genuinely lack them.  Anything else is a
     failure.  Exit status is 0 only when nothing failed. ]]

local lfs = require 'lfs'
local posix = require 'posix'
local E = require 'posix.errno'
local F = require 'posix.fcntl'
local U = require 'posix.unistd'
local St = require 'posix.sys.stat'
local S = require 'posix.sys.socket'
local D = require 'posix.dirent'
local P = require 'posix.poll'
local T = require 'posix.time'
local Sl = require 'posix.stdlib'
local Sig = require 'posix.signal'
local W = require 'posix.sys.wait'

local npass, nfail, nskip = 0, 0, 0
local failed = {}

local UNSUPPORTED = {
   [E.ENOSYS] = true, [E.EPERM] = true, [E.ENOTSUP] = true,
   [E.EOPNOTSUPP] = true, [E.EAFNOSUPPORT] = true, [E.EPROTONOSUPPORT] = true,
}

local function skip(why)
   error({skip = why or 'unsupported'}, 0)
end

-- unwraps the (value) or (nil, message, errnum) convention: an errnum
-- that means "this platform does not have it" turns into a skip.
local function must(what, v, err, errnum)
   if v == nil then
      if errnum and UNSUPPORTED[errnum] then
         skip(string.format('%s: %s', what, err))
      end
      error(string.format('%s: %s (errno %s)', what, tostring(err),
                          tostring(errnum)), 0)
   end
   return v
end

local function want(cond, fmt, ...)
   if not cond then
      error(select('#', ...) > 0 and string.format(fmt, ...)
            or (fmt or 'assertion failed'), 0)
   end
end

local function test(name, fn)
   local ok, err = pcall(fn)
   if ok then
      npass = npass + 1
      io.write(string.format('  ok        %s\n', name))
   elseif type(err) == 'table' and err.skip then
      nskip = nskip + 1
      io.write(string.format('  unsup     %s  (%s)\n', name, err.skip))
   else
      nfail = nfail + 1
      failed[#failed + 1] = name
      io.write(string.format('  FAIL      %s  (%s)\n', name, tostring(err)))
   end
end

local function group(name)
   io.write(string.format('\n%s\n', name))
end

-- a scratch directory next to this script, wiped on entry and exit
local here = (arg[0] or ''):match('^(.*)[/\\][^/\\]+$') or '.'
local WORK = here .. '/work'

local function rmtree(dir)
   if lfs.attributes(dir, 'mode') ~= 'directory' then return end
   for f in lfs.dir(dir) do
      if f ~= '.' and f ~= '..' then
         local p = dir .. '/' .. f
         if lfs.attributes(p, 'mode') == 'directory' then
            rmtree(p)
         else
            os.remove(p)
         end
      end
   end
   lfs.rmdir(dir)
end

local function path(name)
   return WORK .. '/' .. name
end

local function writefile(p, data)
   local fh = assert(io.open(p, 'wb'))
   fh:write(data)
   fh:close()
end

rmtree(WORK)
assert(lfs.mkdir(WORK))

io.write(string.format('%s  %s  posix %s  lfs %s\n', _VERSION,
                       jit and 'luajit' or 'puc', require 'posix.version',
                       lfs._VERSION))

--------------------------------------------------------------------- files

group('files and descriptors')

test('fcntl.open + unistd.write/read/lseek/close', function()
   local p = path('hello.txt')
   local fd = must('open', F.open(p, F.O_CREAT | F.O_RDWR | F.O_TRUNC, 420))
   want(must('write', U.write(fd, 'hello cosmo')) == 11, 'short write')
   must('lseek', U.lseek(fd, 0, U.SEEK_SET) or 0)
   want(must('read', U.read(fd, 5)) == 'hello', 'read mismatch')
   must('close', U.close(fd))
end)

test('unistd.ftruncate + fsync + fdatasync', function()
   local fd = must('open', F.open(path('hello.txt'), F.O_RDWR, 420))
   must('ftruncate', U.ftruncate(fd, 5))
   must('fsync', U.fsync(fd))
   local ok, err, errnum = U.fdatasync(fd)
   if ok == nil and not UNSUPPORTED[errnum] then error(err, 0) end
   U.close(fd)
   want(St.stat(path('hello.txt')).st_size == 5, 'truncate had no effect')
end)

test('sys.stat.stat fields + S_ISREG/S_ISDIR', function()
   local st = must('stat', St.stat(path('hello.txt')))
   want(St.S_ISREG(st.st_mode) ~= 0, 'not a regular file')
   want(st.st_size == 5, 'wrong size')
   want(type(st.st_mtime) == 'number', 'no mtime')
   want(St.S_ISDIR(must('stat', St.stat(WORK)).st_mode) ~= 0, 'not a dir')
end)

test('sys.stat.chmod + unistd.access', function()
   local p = path('hello.txt')
   must('chmod', St.chmod(p, 384))  -- 0600
   must('access', U.access(p, 'r'))
   want(U.access(path('nope'), 'f') == nil, 'access saw a missing file')
end)

test('sys.stat.mkdir + unistd.rmdir', function()
   local d = path('subdir')
   must('mkdir', St.mkdir(d))
   want(St.S_ISDIR(St.stat(d).st_mode) ~= 0, 'not a directory')
   must('rmdir', U.rmdir(d))
end)

test('sys.stat.umask', function()
   local old = must('umask', St.umask(18))  -- 0022
   want(type(old) == 'number', 'umask did not return a mode')
   St.umask(old)
end)

test('dirent.dir + dirent.files', function()
   local names = must('dir', D.dir(WORK))
   local seen = {}
   for _, n in ipairs(names) do seen[n] = true end
   want(seen['hello.txt'], 'dir() missed hello.txt')
   want(seen['.'] and seen['..'], 'dir() missed dot entries')
   local n = 0
   for _ in D.files(WORK) do n = n + 1 end
   want(n == #names, 'files() and dir() disagree')
end)

test('stdlib.mkdtemp + mkstemp + realpath', function()
   local dir = must('mkdtemp', Sl.mkdtemp(path('tmpXXXXXX')))
   want(lfs.attributes(dir, 'mode') == 'directory', 'mkdtemp made no dir')
   local fd, p = Sl.mkstemp(dir .. '/fileXXXXXX')
   must('mkstemp', fd)
   U.close(fd)
   want(must('realpath', Sl.realpath(p)):find('file'), 'realpath lost the name')
   os.remove(p)
   lfs.rmdir(dir)
end)

test('unistd.link hard + readlink of a soft link', function()
   local src, hard, soft = path('hello.txt'), path('hard.txt'), path('soft.txt')
   must('link', U.link(src, hard))
   want(St.stat(hard).st_size == 5, 'hard link has wrong size')
   os.remove(hard)
   local ok, err, errnum = U.link(src, soft, true)
   if ok == nil then
      if UNSUPPORTED[errnum] then skip('symlink: ' .. tostring(err)) end
      error(err, 0)
   end
   want(must('readlink', U.readlink(soft)):find('hello.txt'), 'bad readlink')
   os.remove(soft)
end)

test('utime.utime + stat mtime', function()
   local Ut = require 'posix.utime'
   local p = path('hello.txt')
   must('utime', Ut.utime(p, 1000000000, 1000000000))
   want(St.stat(p).st_mtime == 1000000000, 'mtime did not stick')
end)

test('sys.stat.mkfifo', function()
   local p = path('fifo')
   must('mkfifo', St.mkfifo(p))
   want(St.S_ISFIFO(St.stat(p).st_mode) ~= 0, 'not a fifo')
   os.remove(p)
end)

test('fcntl.fcntl F_SETLK/F_GETLK', function()
   local fd = must('open', F.open(path('hello.txt'), F.O_RDWR, 420))
   local r, err, errnum = F.fcntl(fd, F.F_SETLK, {
      l_type = F.F_WRLCK, l_whence = U.SEEK_SET, l_start = 0, l_len = 0,
   })
   U.close(fd)
   must('fcntl F_SETLK', r, err, errnum)
end)

test('fcntl.posix_fadvise', function()
   local fd = must('open', F.open(path('hello.txt'), F.O_RDONLY, 420))
   local r, err, errnum = F.posix_fadvise(fd, 0, 0, F.POSIX_FADV_NORMAL)
   U.close(fd)
   must('posix_fadvise', r, err, errnum)
end)

------------------------------------------------------------------- sockets

group('sockets')

test('socket + bind + listen + connect + accept + send + recv', function()
   local srv = must('socket', S.socket(S.AF_INET, S.SOCK_STREAM, 0))
   must('setsockopt SO_REUSEADDR', S.setsockopt(srv, S.SOL_SOCKET,
                                                S.SO_REUSEADDR, 1))
   must('bind', S.bind(srv, {family = S.AF_INET, addr = '127.0.0.1', port = 0}))
   must('listen', S.listen(srv, 4))
   local sa = must('getsockname', S.getsockname(srv))
   want(sa.port and sa.port > 0, 'no ephemeral port')

   local cli = must('socket', S.socket(S.AF_INET, S.SOCK_STREAM, 0))
   must('connect', S.connect(cli, {family = S.AF_INET, addr = '127.0.0.1',
                                   port = sa.port}))
   local conn, peer = S.accept(srv)
   must('accept', conn)
   want(peer and peer.addr == '127.0.0.1', 'unexpected peer address')

   want(must('send', S.send(cli, 'ping')) == 4, 'short send')
   want(must('recv', S.recv(conn, 16)) == 'ping', 'payload mismatch')
   must('send back', S.send(conn, 'pong'))
   want(must('recv back', S.recv(cli, 16)) == 'pong', 'reply mismatch')

   local pn = must('getpeername', S.getpeername(cli))
   want(pn.port == sa.port, 'getpeername returned the wrong port')
   must('shutdown', S.shutdown(cli, S.SHUT_RDWR))
   U.close(conn) U.close(cli) U.close(srv)
end)

test('UDP sendto + recvfrom', function()
   local fd = must('socket', S.socket(S.AF_INET, S.SOCK_DGRAM, 0))
   must('bind', S.bind(fd, {family = S.AF_INET, addr = '127.0.0.1', port = 0}))
   local sa = must('getsockname', S.getsockname(fd))
   local to = {family = S.AF_INET, addr = '127.0.0.1', port = sa.port}
   want(must('sendto', S.sendto(fd, 'datagram', to)) == 8, 'short sendto')
   local data, from = S.recvfrom(fd, 32)
   must('recvfrom', data)
   want(data == 'datagram', 'datagram mismatch')
   want(from.addr == '127.0.0.1', 'wrong source address')
   U.close(fd)
end)

test('socketpair + bidirectional traffic', function()
   local a, b = S.socketpair(S.AF_UNIX, S.SOCK_STREAM, 0)
   must('socketpair', a, b, type(b) == 'number' and nil or b)
   must('send a', S.send(a, 'left'))
   want(must('recv b', S.recv(b, 8)) == 'left', 'a to b failed')
   must('send b', S.send(b, 'right'))
   want(must('recv a', S.recv(a, 8)) == 'right', 'b to a failed')
   U.close(a) U.close(b)
end)

test('setsockopt SO_RCVTIMEO makes recv time out', function()
   local fd = must('socket', S.socket(S.AF_INET, S.SOCK_DGRAM, 0))
   must('bind', S.bind(fd, {family = S.AF_INET, addr = '127.0.0.1', port = 0}))
   must('setsockopt', S.setsockopt(fd, S.SOL_SOCKET, S.SO_RCVTIMEO, 0, 50000))
   local r, err, errnum = S.recv(fd, 8)
   U.close(fd)
   want(r == nil, 'recv should have timed out')
   want(errnum == E.EAGAIN or errnum == E.EWOULDBLOCK or errnum == E.ETIMEDOUT,
        'unexpected errno %s (%s)', tostring(errnum), tostring(err))
end)

-- a connected TCP pair on loopback, for the flag tests below.  a
-- socketpair would be the obvious choice, but cosmopolitan emulates
-- those with named pipes on windows, and named pipes reject the MSG_*
-- flags with EINVAL.
local function tcp_pair()
   local srv = must('socket', S.socket(S.AF_INET, S.SOCK_STREAM, 0))
   must('bind', S.bind(srv, {family = S.AF_INET, addr = '127.0.0.1', port = 0}))
   must('listen', S.listen(srv, 2))
   local port = must('getsockname', S.getsockname(srv)).port
   local cli = must('socket', S.socket(S.AF_INET, S.SOCK_STREAM, 0))
   must('connect', S.connect(cli, {family = S.AF_INET, addr = '127.0.0.1',
                                   port = port}))
   local con = must('accept', S.accept(srv))
   U.close(srv)
   return cli, con
end

test('MSG_NOSIGNAL turns a write to a closed peer into EPIPE', function()
   want(type(S.MSG_NOSIGNAL) == 'number', 'MSG_NOSIGNAL is not bound')
   -- with SIGPIPE at its default disposition, a send() without the flag
   -- would kill this process rather than return
   Sig.signal(Sig.SIGPIPE, Sig.SIG_DFL)
   local cli, con = tcp_pair()
   U.close(con)
   -- the first write after the peer's FIN still succeeds, the error
   -- arrives once the RST comes back
   local r, err, errnum
   for _ = 1, 50 do
      r, err, errnum = S.send(cli, 'into the void', S.MSG_NOSIGNAL)
      if r == nil then break end
      T.nanosleep({tv_sec = 0, tv_nsec = 10000000})
   end
   U.close(cli)
   want(r == nil, 'writes to a closed peer never failed')
   want(errnum == E.EPIPE or errnum == E.ECONNRESET,
        'unexpected errno %s (%s)', tostring(errnum), tostring(err))
end)

test('MSG_PEEK leaves the data in the buffer', function()
   local cli, con = tcp_pair()
   must('send', S.send(cli, 'peekable'))
   want(must('peek', S.recv(con, 32, S.MSG_PEEK)) == 'peekable', 'peek failed')
   want(must('recv', S.recv(con, 32)) == 'peekable', 'peek consumed the data')
   must('send plain', S.send(cli, 'plain'))  -- flags stay optional
   want(must('recv plain', S.recv(con, 32)) == 'plain', 'two-arg form broke')
   U.close(cli) U.close(con)
end)

test('getsockopt SO_TYPE', function()
   local fd = must('socket', S.socket(S.AF_INET, S.SOCK_STREAM, 0))
   local v = must('getsockopt', S.getsockopt(fd, S.SOL_SOCKET, S.SO_TYPE))
   U.close(fd)
   want(v == S.SOCK_STREAM, 'SO_TYPE was %s', tostring(v))
end)

test('getaddrinfo on a numeric address', function()
   local res = must('getaddrinfo', S.getaddrinfo('127.0.0.1', '80',
                    {family = S.AF_INET, socktype = S.SOCK_STREAM}))
   want(#res > 0, 'no results')
   want(res[1].addr == '127.0.0.1', 'got %s', tostring(res[1].addr))
   want(res[1].port == 80, 'wrong port')
end)

test('AF_INET6 socket + loopback round trip', function()
   local fd, err, errnum = S.socket(S.AF_INET6, S.SOCK_DGRAM, 0)
   must('socket inet6', fd, err, errnum)
   local r, berr, bnum = S.bind(fd, {family = S.AF_INET6, addr = '::1', port = 0})
   if r == nil then U.close(fd) end
   must('bind inet6', r, berr, bnum)
   local sa = must('getsockname', S.getsockname(fd))
   must('sendto', S.sendto(fd, 'v6', {family = S.AF_INET6, addr = '::1',
                                      port = sa.port}))
   want(must('recvfrom', S.recvfrom(fd, 8)) == 'v6', 'v6 payload mismatch')
   U.close(fd)
end)

--------------------------------------------------------------------- poll

group('poll')

test('poll reports a readable socket', function()
   local a, b = S.socketpair(S.AF_UNIX, S.SOCK_STREAM, 0)
   must('socketpair', a, type(b) == 'number' and nil or b)
   local fds = {[b] = {events = {IN = true}}}
   want(must('poll empty', P.poll(fds, 0)) == 0, 'poll saw data too early')
   S.send(a, 'x')
   want(must('poll', P.poll(fds, 500)) == 1, 'poll missed the data')
   want(fds[b].revents.IN, 'IN not set in revents')
   U.close(a) U.close(b)
end)

test('rpoll on a pipe', function()
   local rd, wr = U.pipe()
   must('pipe', rd, type(wr) == 'number' and nil or wr)
   want(must('rpoll empty', P.rpoll(rd, 0)) == 0, 'rpoll saw data too early')
   U.write(wr, 'y')
   want(must('rpoll', P.rpoll(rd, 500)) == 1, 'rpoll missed the data')
   want(U.read(rd, 1) == 'y', 'pipe payload mismatch')
   U.close(rd) U.close(wr)
end)

----------------------------------------------------------------- processes

group('processes')

test('unistd.getpid/getppid/getuid/getgid', function()
   want(must('getpid', U.getpid()) > 0, 'bad pid')
   want(type(U.getppid()) == 'number', 'bad ppid')
   want(type(U.getuid()) == 'number', 'bad uid')
   want(type(U.getgid()) == 'number', 'bad gid')
end)

test('fork + _exit + wait reports the exit status', function()
   local pid, err, errnum = U.fork()
   must('fork', pid, err, errnum)
   if pid == 0 then
      U._exit(7)
   end
   local wpid, how, status = W.wait(pid)
   must('wait', wpid, how, status)
   want(how == 'exited', 'child %s instead of exiting', tostring(how))
   want(status == 7, 'exit status was %s', tostring(status))
end)

test('pipe + fork passes data between processes', function()
   local rd, wr = U.pipe()
   must('pipe', rd, type(wr) == 'number' and nil or wr)
   local pid = must('fork', U.fork())
   if pid == 0 then
      U.close(rd)
      U.write(wr, 'from the child')
      U.close(wr)
      U._exit(0)
   end
   U.close(wr)
   want(U.read(rd, 32) == 'from the child', 'pipe payload mismatch')
   U.close(rd)
   W.wait(pid)
end)

test('unistd.dup2 redirects a descriptor', function()
   local p = path('dup2.txt')
   local fd = must('open', F.open(p, F.O_CREAT | F.O_RDWR | F.O_TRUNC, 420))
   local copy = must('dup', U.dup(fd))
   must('dup2', U.dup2(fd, copy))
   U.write(copy, 'duplicated')
   U.close(copy) U.close(fd)
   want(St.stat(p).st_size == 10, 'write through the dup did not land')
end)

test('unistd.isatty + sysconf + pathconf', function()
   want(type(U.isatty(0)) == 'number' or U.isatty(0) == nil, 'odd isatty')
   want(must('sysconf', U.sysconf(U._SC_PAGESIZE)) > 0, 'bad page size')
   want(must('pathconf', U.pathconf('.', U._PC_PATH_MAX)) > 0, 'bad PATH_MAX')
end)

------------------------------------------------------------------- signals

group('signals')

test('signal handler runs on raise', function()
   local got
   must('signal', Sig.signal(Sig.SIGUSR1, function(sig) got = sig end))
   must('raise', Sig.raise(Sig.SIGUSR1))
   for _ = 1, 200000 do end  -- luaposix defers to a lua hook
   want(got == Sig.SIGUSR1, 'handler did not run (got %s)', tostring(got))
   Sig.signal(Sig.SIGUSR1, Sig.SIG_DFL)
end)

test('kill self with an ignored signal', function()
   must('signal', Sig.signal(Sig.SIGUSR2, Sig.SIG_IGN))
   must('kill', Sig.kill(U.getpid(), Sig.SIGUSR2))
   Sig.signal(Sig.SIGUSR2, Sig.SIG_DFL)
end)

---------------------------------------------------------------------- time

group('time')

test('clock_gettime + clock_getres + time', function()
   if not T.clock_gettime then skip('no POSIX timers in this build') end
   want(must('clock_getres', T.clock_getres(T.CLOCK_REALTIME)) ~= nil, 'res')
   local ts = must('clock_gettime', T.clock_gettime(T.CLOCK_REALTIME))
   want(ts.tv_sec > 1600000000, 'clock looks wrong')
   want(math.abs(must('time', T.time()) - ts.tv_sec) < 5, 'time disagrees')
end)

test('gmtime + strftime', function()
   local tm = must('gmtime', T.gmtime(0))
   want(tm.tm_year + 1900 == 1970, 'epoch is not 1970')
   want(must('strftime', T.strftime('%Y-%m-%d', tm)) == '1970-01-01',
        'strftime mismatch')
end)

test('nanosleep actually sleeps', function()
   if not T.clock_gettime then skip('no POSIX timers in this build') end
   local t0 = T.clock_gettime(T.CLOCK_MONOTONIC)
   must('nanosleep', T.nanosleep({tv_sec = 0, tv_nsec = 20000000}))
   local t1 = T.clock_gettime(T.CLOCK_MONOTONIC)
   local dt = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9
   want(dt >= 0.015, 'slept only %.3fs', dt)
end)

-------------------------------------------------------------------- system

group('system information')

test('sys.utsname.uname', function()
   local u = must('uname', require('posix.sys.utsname').uname())
   want(type(u.sysname) == 'string' and #u.sysname > 0, 'no sysname')
end)

test('pwd.getpwuid + grp.getgrgid', function()
   local pw = must('getpwuid', require('posix.pwd').getpwuid(U.getuid()))
   want(type(pw.pw_name) == 'string', 'no pw_name')
   local gr, err, errnum = require('posix.grp').getgrgid(U.getgid())
   -- a nil with no errno is POSIX for "no such entry", which is what a
   -- host without a group database answers
   if gr == nil and errnum == nil then skip('no group database') end
   must('getgrgid', gr, err, errnum)
   want(type(gr.gr_name) == 'string', 'no gr_name')
end)

test('sys.resource.getrlimit', function()
   local R = require 'posix.sys.resource'
   local rl, err, errnum = R.getrlimit(R.RLIMIT_NOFILE)
   -- windows has no rlimits, and cosmo answers EINVAL for the resource id
   if rl == nil and errnum == E.EINVAL then
      skip('RLIMIT_NOFILE: ' .. tostring(err))
   end
   must('getrlimit', rl, err, errnum)
   want(rl.rlim_cur and rl.rlim_cur > 0, 'bad soft limit')
end)

test('sys.statvfs.statvfs', function()
   local v = must('statvfs', require('posix.sys.statvfs').statvfs('.'))
   want(v.f_bsize > 0, 'bad block size')
end)

test('sys.times.times', function()
   local t = must('times', require('posix.sys.times').times())
   want(type(t.elapsed) == 'number', 'no elapsed')
end)

test('sys.time.gettimeofday', function()
   local tv = must('gettimeofday', require('posix.sys.time').gettimeofday())
   want(tv.tv_sec > 1600000000, 'clock looks wrong')
end)

test('termio.tcgetattr on a pipe fails with ENOTTY', function()
   local rd, wr = U.pipe()
   local r, err, errnum = require('posix.termio').tcgetattr(rd)
   U.close(rd) U.close(wr)
   want(r == nil, 'a pipe should not be a terminal')
   want(errnum == E.ENOTTY or errnum == E.EINVAL,
        'unexpected errno %s', tostring(errnum))
end)

------------------------------------------------------------ strings, paths

group('strings and paths')

test('libgen.basename + dirname', function()
   local L = require 'posix.libgen'
   want(L.basename('/a/b/c.txt') == 'c.txt', 'basename')
   want(L.dirname('/a/b/c.txt') == '/a/b', 'dirname')
end)

test('fnmatch.fnmatch', function()
   local Fn = require 'posix.fnmatch'
   want(Fn.fnmatch('*.txt', 'hello.txt') == 0, 'should match')
   want(Fn.fnmatch('*.txt', 'hello.md') ~= 0, 'should not match')
end)

test('glob.glob finds the scratch files', function()
   local G = require 'posix.glob'
   local hits = must('glob', G.glob(WORK .. '/*.txt', 0))
   want(#hits > 0, 'glob found nothing')
end)

test('ctype classification', function()
   local C = require 'posix.ctype'
   -- posix.ctype binds only the two predicates upstream exposes
   want(C.isgraph('x') ~= 0 and C.isgraph(' ') == 0, 'isgraph')
   want(C.isprint('x') ~= 0 and C.isprint('\7') == 0, 'isprint')
end)

test('errno round trip', function()
   local msg, num = E.errno(E.ENOENT)
   want(type(msg) == 'string' and #msg > 0, 'no message')
   want(num == E.ENOENT, 'errnum mismatch')
end)

test('stdlib.setenv + getenv', function()
   must('setenv', Sl.setenv('LUAEXT_TEST', 'yes'))
   want(Sl.getenv('LUAEXT_TEST') == 'yes', 'getenv mismatch')
   Sl.setenv('LUAEXT_TEST', nil)
end)

----------------------------------------------------------------------- lfs

group('luafilesystem')

test('lfs.currentdir + chdir round trip', function()
   local cwd = must('currentdir', lfs.currentdir())
   must('chdir', lfs.chdir(WORK))
   want(must('currentdir', lfs.currentdir()):find('work'), 'chdir did nothing')
   must('chdir back', lfs.chdir(cwd))
end)

test('lfs.mkdir + rmdir', function()
   local d = path('lfsdir')
   must('mkdir', lfs.mkdir(d))
   want(lfs.attributes(d, 'mode') == 'directory', 'not a directory')
   must('rmdir', lfs.rmdir(d))
end)

test('lfs.attributes fields and single-field form', function()
   local p = path('attr.txt')
   writefile(p, 'four')
   local a = must('attributes', lfs.attributes(p))
   want(a.mode == 'file', 'mode was %s', tostring(a.mode))
   want(a.size == 4, 'size was %s', tostring(a.size))
   want(type(a.modification) == 'number', 'no modification time')
   want(lfs.attributes(p, 'size') == 4, 'single-field form disagrees')
end)

test('lfs.dir iterates the scratch directory', function()
   local n, seen = 0, false
   for f in lfs.dir(WORK) do
      n = n + 1
      if f == 'attr.txt' then seen = true end
   end
   want(n > 2, 'only %d entries', n)
   want(seen, 'lfs.dir missed attr.txt')
end)

test('lfs.touch sets mtime', function()
   local p = path('attr.txt')
   must('touch', lfs.touch(p, 1234567890))
   want(lfs.attributes(p, 'modification') == 1234567890, 'mtime did not stick')
end)

test('lfs.link + symlinkattributes', function()
   local dst = path('lfslink')
   local r, err = lfs.link('attr.txt', dst, true)
   if not r then
      if tostring(err):find('not supported') or tostring(err):find('perm') then
         skip(tostring(err))
      end
      error(tostring(err), 0)
   end
   want(must('symlinkattributes', lfs.symlinkattributes(dst)).mode == 'link',
        'not seen as a link')
   want(lfs.attributes(dst, 'size') == 4, 'link does not follow to the target')
   os.remove(dst)
end)

test('lfs.lock + unlock on an open file', function()
   local p = path('locked.txt')
   writefile(p, 'lock me')
   local fh = assert(io.open(p, 'r+'))
   local r, err = lfs.lock(fh, 'w')
   if not r then fh:close() error(tostring(err), 0) end
   must('unlock', lfs.unlock(fh))
   fh:close()
end)

test('lfs.lock_dir', function()
   local d = path('lockdir')
   lfs.mkdir(d)
   local lock, err = lfs.lock_dir(d)
   -- lock_dir is a symlink underneath, which a windows account without
   -- the create-symlink right cannot do
   if not lock and tostring(err):find('not permitted') then
      rmtree(d)
      skip(tostring(err))
   end
   if not lock then rmtree(d) error(tostring(err), 0) end
   lock:free()
   rmtree(d)
end)

test('lfs.setmode', function()
   local fh = assert(io.open(path('attr.txt'), 'r'))
   local r, err = lfs.setmode(fh, 'binary')
   fh:close()
   want(r, tostring(err))
end)

----------------------------------------------------------- aggregate posix

group('the pure-Lua posix module from the zip store')

test('posix.basename/dirname via the aggregate', function()
   want(posix.basename('/a/b/c') == 'c', 'basename')
   want(posix.dirname('/a/b/c') == '/a/b', 'dirname')
end)

test('posix.euidaccess or posix.access on a real file', function()
   local fn = posix.euidaccess or posix.access
   want(fn ~= nil, 'neither euidaccess nor access is exported')
   want(must('access', fn(path('attr.txt'), 'r')) ~= nil, 'cannot read')
end)

test('posix.mkstemp + posix.close via the aggregate', function()
   local fd, p = posix.mkstemp(path('aggXXXXXX'))
   must('mkstemp', fd, p)
   posix.close(fd)
   os.remove(p)
end)

test('posix.timeradd on two timevals', function()
   if not posix.timeradd then skip('not exported by this release') end
   local r = posix.timeradd({tv_sec = 1, tv_usec = 500000},
                            {tv_sec = 2, tv_usec = 600000})
   want(r.sec == 4 and r.usec == 100000, 'timeradd arithmetic (got %s/%s)',
        tostring(r.sec), tostring(r.usec))
end)

test("cosmo's own unix module still works alongside", function()
   local unix = require 'unix'
   want(unix.getpid() == U.getpid(), 'unix and posix disagree about the pid')
end)

---------------------------------------------------------------------- done

rmtree(WORK)

io.write(string.format('\n%d passed, %d unsupported, %d failed\n',
                       npass, nskip, nfail))
if nfail > 0 then
   io.write('failed: ' .. table.concat(failed, ', ') .. '\n')
   os.exit(1)
end
os.exit(0)
