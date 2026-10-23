--[[ cqueues.socket, reimplemented in pure Lua over luaposix.

     Upstream is a C buffered-socket layer wired directly to OpenSSL.
     This provides the same object protocol over luaposix, with TLS
     delegated to third_party/luatls when a caller asks for it.

     The methods implemented here are the ones lua-http uses, which is
     xread, xwrite, unget, fill, pending, flush, setmode, setvbuf,
     setmaxline, seterror, clearerr, error, onerror, eof, shutdown,
     close, connect, listen, accept, localname, peername, pollfd,
     events, timeout, starttls and checktls.

     Every blocking point goes through wait_io, which yields to the
     cqueues scheduler when there is one and polls directly when there is
     not, so a socket works the same in a plain script as inside a
     controller. ]]

local cqueues = require 'cqueues'
local ce = require 'cqueues.errno'
local P = require 'posix.poll'
local S = require 'posix.sys.socket'
local U = require 'posix.unistd'
local F = require 'posix.fcntl'

local monotime = cqueues.monotime

local EAGAIN = ce.EAGAIN
local EWOULDBLOCK = ce.EWOULDBLOCK or EAGAIN
local EINTR = ce.EINTR
local ETIMEDOUT = ce.ETIMEDOUT
local EINPROGRESS = ce.EINPROGRESS
local MSG_NOSIGNAL = S.MSG_NOSIGNAL or 0

local READ_SIZE = 65536

local methods = {}
local mt = {
   __index = methods,
   __name = 'cqueues.socket',
}

local M = {}

M.AF_UNSPEC = S.AF_UNSPEC
M.AF_INET = S.AF_INET
M.AF_INET6 = S.AF_INET6
M.AF_UNIX = S.AF_UNIX
M.SOCK_STREAM = S.SOCK_STREAM
M.SOCK_DGRAM = S.SOCK_DGRAM

function M.type(o)
   if getmetatable(o) == mt then
      return 'socket'
   end
   return nil
end

local function default_onerror(_sock, op, why, _lvl)
   return string.format('%s: %s', op, ce.strerror(why)), why
end

local function newsocket(fd)
   return setmetatable({
      fd = fd,
      ibuf = '',
      obuf = {},
      olen = 0,
      rerr = nil,
      werr = nil,
      reof = false,
      weof = false,
      rmode = 'b',
      wmode = 'bn',  -- unbuffered until a caller says otherwise
      bufsize = math.huge,
      maxline = math.huge,
      want = 'r',
      onerror_fn = default_onerror,
      tls = nil,
   }, mt)
end

local function nonblock(fd)
   local flags = F.fcntl(fd, F.F_GETFL)
   if flags then
      F.fcntl(fd, F.F_SETFL, flags | F.O_NONBLOCK)
   end
end

--[[ Records an error against the socket and runs it through the
     caller's onerror hook, which is how lua-http turns an errno into
     the message it wants. ]]
local function fail(self, op, why)
   if op == 'fill' or op == 'read' or op == 'xread' or op == 'accept' then
      self.rerr = why
   elseif op == 'flush' or op == 'write' or op == 'xwrite' then
      self.werr = why
   else
      self.rerr, self.werr = why, why
   end
   local handler = self.onerror_fn
   if handler then
      local msg, code = handler(self, op, why, 2)
      return nil, msg, code or why
   end
   return nil, ce.strerror(why), why
end

--[[ Waits for the descriptor, through the scheduler when one is running
     and directly when not.  Answers false when the deadline passed. ]]
local function wait_io(self, dir, deadline)
   if self.fd == nil then
      return false
   end
   local timeout = nil
   if deadline then
      timeout = deadline - monotime()
      if timeout <= 0 then
         return false
      end
   end
   if cqueues.running() and coroutine.isyieldable() then
      local prev = self.want
      self.want = dir
      local which = cqueues.poll(self, timeout)
      self.want = prev
      return which == self
   end
   local fds = {[self.fd] = {events = {IN = dir:find('r') ~= nil,
                                       OUT = dir:find('w') ~= nil}}}
   local ms = timeout and math.max(0, math.floor(timeout * 1000 + 0.5)) or -1
   local n, _, errnum = P.poll(fds, ms)
   if n == nil then
      return errnum == EINTR
   end
   return n > 0
end

------------------------------------------------------------------ raw layer

function methods:_recv(n)
   if self.tls then
      return self.tls:read(n)
   end
   return S.recv(self.fd, n)
end

function methods:_send(data)
   if self.tls then
      return self.tls:write(data)
   end
   return S.send(self.fd, data, MSG_NOSIGNAL)
end

--[[ Pulls one helping of bytes into the read buffer.  Answers true when
     it got some, false at end of file, or nil plus an errno. ]]
local function fill_once(self, deadline)
   while true do
      if self.connecting then
         local ok, err, errnum = self:connect(
            deadline and math.max(0, deadline - monotime()) or nil)
         if not ok then
            return nil, errnum or err
         end
      end
      local s, _, errnum = self:_recv(READ_SIZE)
      if s == nil then
         if errnum == EAGAIN or errnum == EWOULDBLOCK then
            if not wait_io(self, 'r', deadline) then
               return nil, ETIMEDOUT
            end
         elseif errnum == EINTR then -- retry
         elseif errnum == 'want_read' then
            if not wait_io(self, 'r', deadline) then
               return nil, ETIMEDOUT
            end
         elseif errnum == 'want_write' then
            if not wait_io(self, 'w', deadline) then
               return nil, ETIMEDOUT
            end
         else
            return nil, errnum
         end
      elseif s == '' then
         self.reof = true
         return false
      else
         self.ibuf = self.ibuf .. s
         return true
      end
   end
end

--------------------------------------------------------------------- reading

function methods:pending()
   return #self.ibuf
end

function methods:unget(s)
   if s and #s > 0 then
      self.ibuf = s .. self.ibuf
   end
   return true
end

--[[ At end of file this answers a bare nil, with no message and no
     errno, which is upstream's way of saying the peer closed cleanly.
     lua-http's server depends on the distinction: an error value here
     means something went wrong, a bare nil means the client went away
     and the connection should just be retired.  The EPIPE is still
     recorded, so socket:error("r") reports it. ]]
function methods:fill(n, timeout)
   local deadline = timeout and (monotime() + timeout) or nil
   n = n or 1
   while #self.ibuf < n do
      if self.reof then
         self.rerr = ce.EPIPE
         return nil
      end
      local ok, why = fill_once(self, deadline)
      if ok == nil then
         return fail(self, 'fill', why)
      elseif ok == false then
         self.rerr = ce.EPIPE
         return nil
      end
   end
   return true
end

--[[ The "*h" format reads one MIME header, unfolding continuation
     lines, and answers nil without an error when what comes next is not
     a header, which is how a caller detects the blank line that ends a
     header block.  lua-http's read_header depends on exactly that
     distinction: a nil with no error means "end of headers", a nil with
     an error means the read failed. ]]
local HEADER_NAME = "^[!#$%%&'*+%-.^_`|~%w]+:"

local function read_mime_header(self, keep_newline)
   local buf = self.ibuf
   local first = buf:find('\n', 1, true)
   if not first then
      return nil, 'incomplete'
   end
   if not buf:sub(1, first):match(HEADER_NAME) then
      return nil, 'notheader'
   end
   local last = first
   while true do
      local nxt = buf:sub(last + 1, last + 1)
      if nxt ~= ' ' and nxt ~= '\t' then
         break
      end
      local nl = buf:find('\n', last + 1, true)
      if not nl then
         return nil, 'incomplete'
      end
      last = nl
   end
   local raw = buf:sub(1, last)
   self.ibuf = buf:sub(last + 1)
   if keep_newline then
      return raw
   end
   -- unfold: every newline plus its leading whitespace becomes one space
   return (raw:gsub('\r?\n$', ''):gsub('\r?\n[ \t]+', ' '))
end

local function take(self, n)
   local s = self.ibuf:sub(1, n)
   self.ibuf = self.ibuf:sub(n + 1)
   return s
end

--[[ The read formats lua-http asks for: a byte count, "*L" for a line
     with its newline kept, "*a" for everything, and "*h" for a header
     block.  "*l" is supported too since it costs nothing. ]]
function methods:xread(what, mode, timeout)
   if type(mode) == 'number' or (mode == nil and type(timeout) == 'nil') then
      timeout, mode = mode, nil
   end
   local deadline = timeout and (monotime() + timeout) or nil
   what = what or '*L'
   while true do
      if type(what) == 'number' then
         if what == 0 then
            return ''
         elseif what < 0 then
            --[[ a negative count is upstream's non-greedy read: hand
                 back whatever is there, up to that many bytes, once
                 there is anything at all ]]
            if #self.ibuf > 0 then
               return take(self, math.min(#self.ibuf, -what))
            end
         elseif #self.ibuf >= what then
            return take(self, what)
         end
      elseif what == '*L' or what == '*l' then
         local i = self.ibuf:find('\n', 1, true)
         if i then
            local line = take(self, i)
            if what == '*l' then
               line = line:gsub('\r?\n$', '')
            end
            return line
         end
         if #self.ibuf >= self.maxline then
            return take(self, self.maxline)
         end
      elseif what == '*h' or what == '*H' then
         local header, why = read_mime_header(self, what == '*H')
         if header then
            return header
         elseif why == 'notheader' then
            return nil
         end
      elseif what ~= '*a' then
         error('unsupported read format ' .. tostring(what), 2)
      end
      if self.reof then
         -- end of file: hand back whatever is left, or nil when the
         -- buffer is empty, which is how callers detect the end
         if #self.ibuf > 0 then
            return take(self, #self.ibuf)
         end
         return nil
      end
      local ok, why = fill_once(self, deadline)
      if ok == nil then
         return fail(self, 'read', why)
      end
   end
end

function methods:read(...)
   return self:xread(...)
end

--------------------------------------------------------------------- writing

function methods:flush(mode, timeout)
   if type(mode) == 'number' then
      timeout, mode = mode, nil
   end
   local deadline = timeout and (monotime() + timeout) or nil
   if self.connecting then
      local ok, err, errnum = self:connect(
         deadline and math.max(0, deadline - monotime()) or nil)
      if not ok then
         return nil, err, errnum
      end
   end
   local buf = table.concat(self.obuf)
   self.obuf, self.olen = {}, 0
   while #buf > 0 do
      local n, _, errnum = self:_send(buf)
      if n == nil then
         if errnum == EAGAIN or errnum == EWOULDBLOCK
            or errnum == 'want_write' then
            if not wait_io(self, 'w', deadline) then
               self.obuf, self.olen = {buf}, #buf
               return fail(self, 'flush', ETIMEDOUT)
            end
         elseif errnum == 'want_read' then
            if not wait_io(self, 'r', deadline) then
               self.obuf, self.olen = {buf}, #buf
               return fail(self, 'flush', ETIMEDOUT)
            end
         elseif errnum == EINTR then -- retry
         else
            self.obuf, self.olen = {buf}, #buf
            return fail(self, 'flush', errnum)
         end
      else
         buf = buf:sub(n + 1)
      end
   end
   return true
end

--[[ The mode letters are buffering disciplines, the same ones setvbuf
     uses, not flush flags: "n" is unbuffered and so writes through
     immediately, "l" is line buffered, and "f" is fully buffered and so
     only accumulates.  lua-http leans on this hard, buffering a whole
     header block with "f" writes and then pushing it out with a single
     "n" write of the blank line that ends it. ]]
function methods:xwrite(data, mode, timeout)
   if type(mode) == 'number' then
      timeout, mode = mode, nil
   end
   mode = mode or self.wmode
   if data ~= nil and #data > 0 then
      self.obuf[#self.obuf + 1] = data
      self.olen = self.olen + #data
   end
   if mode:find('n', 1, true) then
      return self:flush(mode, timeout)
   end
   if mode:find('l', 1, true) and data and data:find('\n', 1, true) then
      return self:flush(mode, timeout)
   end
   if self.olen >= self.bufsize then
      return self:flush(mode, timeout)
   end
   return true
end

function methods:write(...)
   return self:xwrite(...)
end

-------------------------------------------------------------------- settings

function methods:setvbuf(mode, size)
   local old, oldsize = self.vbufmode or 'full', self.bufsize
   self.vbufmode = mode
   if mode == 'no' or mode == 'none' then
      self.bufsize = 0
   elseif size then
      self.bufsize = size
   end
   return old, oldsize
end

function methods:setmode(r, w)
   local oldr, oldw = self.rmode, self.wmode
   if r then self.rmode = r end
   if w then self.wmode = w end
   return oldr, oldw
end

function methods:setmaxline(n)
   local old = self.maxline
   if n then self.maxline = n end
   return old
end

function methods:onerror(fn)
   local old = self.onerror_fn
   if fn ~= nil then
      self.onerror_fn = fn
   end
   return old
end

function methods:error(which)
   if which == 'w' then
      return self.werr
   elseif which == 'r' then
      return self.rerr
   end
   return self.rerr or self.werr
end

function methods:seterror(which, why)
   if which == 'r' then
      self.rerr = why
   elseif which == 'w' then
      self.werr = why
   else
      self.rerr, self.werr = which, which
   end
   return true
end

function methods:clearerr(which)
   local old
   if which == 'r' then
      old, self.rerr = self.rerr, nil
   elseif which == 'w' then
      old, self.werr = self.werr, nil
   else
      old = self.rerr or self.werr
      self.rerr, self.werr = nil, nil
   end
   return old
end

function methods:eof(which)
   if which == 'r' then
      return self.reof
   elseif which == 'w' then
      return self.weof
   end
   return self.reof and self.weof
end

------------------------------------------------------------------- pollable

function methods:pollfd()
   return self.fd
end

function methods:events()
   if self.connecting then
      return 'w'
   end
   return self.want
end

function methods:timeout()
   return nil
end

------------------------------------------------------------------ lifecycle

--[[ The handshake was already started by the constructor, so finishing
     it means waiting for the socket to become writable and then asking
     it how it went.  That is the portable way, and on Windows it is the
     only way: calling connect() a second time there answers a win32
     error rather than EISCONN. ]]
function methods:connect(timeout)
   if self.pending_connect_error then
      self.connecting = false
      return fail(self, 'connect', self.pending_connect_error)
   end
   if not self.connecting then
      return true
   end
   local deadline = timeout and (monotime() + timeout) or nil
   while true do
      if not wait_io(self, 'w', deadline) then
         return fail(self, 'connect', ETIMEDOUT)
      end
      local soerr = S.getsockopt(self.fd, S.SOL_SOCKET, S.SO_ERROR)
      if soerr == nil or soerr == 0 then
         self.connecting = false
         return true
      end
      if soerr ~= EINPROGRESS and soerr ~= ce.EALREADY then
         self.connecting = false
         return fail(self, 'connect', soerr)
      end
   end
end

function methods:listen(_timeout)
   return true
end

--[[ accept([options][, timeout])

     Note the error convention, which is not the one the read and write
     methods use.  Upstream answers a bare errno here rather than the
     (nil, message, errno) triple, and lua-http's accept loop reads the
     second return value as an errno and compares it against ETIMEDOUT,
     so a message in that slot would send it down the wrong branch. ]]
function methods:accept(opts, timeout)
   if type(opts) == 'number' then
      opts, timeout = nil, opts
   end
   if timeout == nil and type(opts) == 'table' then
      timeout = opts.timeout
   end
   local deadline = timeout and (monotime() + timeout) or nil
   while true do
      local fd, _, errnum = S.accept(self.fd)
      if fd then
         nonblock(fd)
         local s = newsocket(fd)
         s.onerror_fn = self.onerror_fn
         if type(opts) == 'table' and opts.nodelay then
            S.setsockopt(fd, S.IPPROTO_TCP, S.TCP_NODELAY, 1)
         end
         return s
      end
      if errnum == EAGAIN or errnum == EWOULDBLOCK then
         if not wait_io(self, 'r', deadline) then
            self.rerr = ETIMEDOUT
            return nil, ETIMEDOUT
         end
      elseif errnum ~= EINTR then
         self.rerr = errnum
         return nil, errnum
      end
   end
end

function methods:shutdown(dir)
   dir = dir or 'rw'
   local how
   if dir == 'r' then
      how, self.reof = S.SHUT_RD, true
   elseif dir == 'w' then
      how, self.weof = S.SHUT_WR, true
   else
      how, self.reof, self.weof = S.SHUT_RDWR, true, true
   end
   if self.olen > 0 and dir ~= 'r' then
      self:flush(nil, 0)
   end
   if self.fd then
      S.shutdown(self.fd, how)
   end
   return true
end

function methods:close()
   if self.fd then
      if self.olen > 0 then
         self:flush(nil, 0)
      end
      if self.tls and self.tls.close then
         self.tls:close()
      end
      U.close(self.fd)
      self.fd = nil
      self.reof, self.weof = true, true
   end
   return true
end

function methods:localname()
   if self.fd == nil then
      return nil, ce.EBADF
   end
   local sa = S.getsockname(self.fd)
   if sa == nil then
      return nil, ce.EBADF
   end
   return sa.family, sa.addr or sa.path, sa.port
end

function methods:peername()
   if self.fd == nil then
      return nil, ce.EBADF
   end
   local sa, _, errnum = S.getpeername(self.fd)
   if sa == nil then
      return nil, errnum or ce.ENOTCONN
   end
   return sa.family, sa.addr or sa.path, sa.port
end

------------------------------------------------------------------------ tls

function methods:checktls()
   return self.tls
end

function methods:starttls(ctx, timeout)
   local ok, tlslib = pcall(require, 'cqueues.socket.tls')
   if not ok then
      return fail(self, 'starttls', ce.ENOTSUP)
   end
   local deadline = timeout and (monotime() + timeout) or nil
   if self.connecting then
      local c, err, errnum = self:connect(
         deadline and math.max(0, deadline - monotime()) or nil)
      if not c then
         return nil, err, errnum
      end
   end
   -- anything already buffered for writing has to go out in the clear
   -- before the handshake starts
   if self.olen > 0 then
      local f, err, errnum = self:flush(nil,
         deadline and math.max(0, deadline - monotime()) or nil)
      if not f then
         return nil, err, errnum
      end
   end
   local conn, err = tlslib.wrap(self, ctx)
   if not conn then
      return fail(self, 'starttls', err or ce.ENOTSUP)
   end
   self.tls = conn
   while true do
      --[[ the engine answers (nil, message, reason), where reason is
           either "want_read", "want_write" or an mbedtls error code ]]
      local done, msg, why = conn:handshake()
      if done then
         return true
      end
      if why == 'want_read' then
         if not wait_io(self, 'r', deadline) then
            return fail(self, 'starttls', ETIMEDOUT)
         end
      elseif why == 'want_write' then
         if not wait_io(self, 'w', deadline) then
            return fail(self, 'starttls', ETIMEDOUT)
         end
      else
         self.tls = nil
         return fail(self, 'starttls', msg or why or ce.ECONNABORTED)
      end
   end
end

----------------------------------------------------------------- constructors

local function resolve(opts)
   local family = opts.family
   if opts.path then
      return {family = S.AF_UNIX, path = opts.path}
   end
   local hints = {socktype = S.SOCK_STREAM}
   if family and family ~= S.AF_UNSPEC then
      hints.family = family
   end
   local host = opts.host or '127.0.0.1'
   local res, err, errnum = S.getaddrinfo(host, tostring(opts.port or 0), hints)
   if res == nil or res[1] == nil then
      return nil, err or 'cannot resolve ' .. tostring(host), errnum
   end
   local sa = res[1]
   return {family = sa.family, addr = sa.addr, port = opts.port or sa.port}
end

local function makefd(sa, opts)
   local fd, err, errnum = S.socket(sa.family, S.SOCK_STREAM, 0)
   if fd == nil then
      return nil, err, errnum
   end
   nonblock(fd)
   if opts.nodelay and sa.family ~= S.AF_UNIX then
      S.setsockopt(fd, S.IPPROTO_TCP, S.TCP_NODELAY, 1)
   end
   if opts.v6only ~= nil and sa.family == S.AF_INET6 then
      S.setsockopt(fd, S.IPPROTO_IPV6, S.IPV6_V6ONLY, opts.v6only and 1 or 0)
   end
   return fd
end

--[[ Upstream hands back a socket that has not connected yet, and
     connects it on the first use or on an explicit connect().  This does
     the same, which is what lua-http's connection_common expects when it
     calls socket:connect(timeout). ]]
function M.connect(opts, port, flags)
   if type(opts) == 'string' then
      opts = {host = opts, port = port, flags = flags}
   end
   local sa, err, errnum = resolve(opts)
   if sa == nil then
      return nil, err, errnum
   end
   local fd
   fd, err, errnum = makefd(sa, opts)
   if fd == nil then
      return nil, err, errnum
   end
   if opts.bind then
      local b = opts.bind
      if type(b) == 'string' then
         local h, p = b:match '^(.*):(%d+)$'
         b = {host = h or b, port = tonumber(p) or 0}
      end
      local bsa = resolve({host = b.host, port = b.port, family = sa.family})
      if bsa then
         S.setsockopt(fd, S.SOL_SOCKET, S.SO_REUSEADDR, 1)
         S.bind(fd, bsa)
      end
   end
   local s = newsocket(fd)
   s.peer = sa
   s.connecting = true
   --[[ Upstream starts the handshake as soon as the socket is made,
        rather than waiting for the first read or write, and callers
        depend on that: lua-http reaches the first I/O with a zero
        timeout and expects the connection to be up by then. ]]
   local started, _, errnum = S.connect(fd, sa)
   if started then
      s.connecting = false
   elseif errnum ~= EINPROGRESS and errnum ~= EINTR
      and errnum ~= ce.EALREADY then
      s.pending_connect_error = errnum
   end
   s.sendname = opts.sendname
   if s.sendname == nil and opts.host and not opts.path then
      s.sendname = opts.host
   end
   return s
end

function M.listen(opts, port)
   if type(opts) == 'string' then
      opts = {host = opts, port = port}
   end
   local sa, err, errnum = resolve(opts)
   if sa == nil then
      return nil, err, errnum
   end
   local fd
   fd, err, errnum = makefd(sa, opts)
   if fd == nil then
      return nil, err, errnum
   end
   if sa.family ~= S.AF_UNIX then
      S.setsockopt(fd, S.SOL_SOCKET, S.SO_REUSEADDR, 1)
   end
   local ok
   ok, err, errnum = S.bind(fd, sa)
   if not ok then
      U.close(fd)
      return nil, err, errnum
   end
   ok, err, errnum = S.listen(fd, opts.backlog or 128)
   if not ok then
      U.close(fd)
      return nil, err, errnum
   end
   local s = newsocket(fd)
   s.listening = true
   return s
end

function M.fdopen(fd)
   nonblock(fd)
   return newsocket(fd)
end

function M.pair(socktype)
   local a, b = S.socketpair(S.AF_UNIX, socktype or S.SOCK_STREAM, 0)
   if a == nil then
      return nil, b
   end
   nonblock(a)
   nonblock(b)
   return newsocket(a), newsocket(b)
end

return M
