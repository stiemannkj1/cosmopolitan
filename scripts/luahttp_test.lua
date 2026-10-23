--[[ Functional test for lua-http and its cosmo support layer.

       o/x86_64/third_party/lua/lua scripts/luahttp_test.lua

     Network-dependent cases are skipped when there is no route out, so
     the suite is still meaningful offline.  Exit status is 0 only when
     nothing failed. ]]
io.stdout:setvbuf('no')

local npass, nfail, nskip = 0, 0, 0
local failed = {}

local function skip(why)
   error({skip = why or 'unsupported'}, 0)
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
      io.write(string.format('  skip      %s  (%s)\n', name, err.skip))
   else
      nfail = nfail + 1
      failed[#failed + 1] = name
      io.write(string.format('  FAIL      %s  (%s)\n', name, tostring(err)))
   end
end

local function group(name)
   io.write(string.format('\n%s\n', name))
end

local have_network
local function needs_network()
   if have_network == nil then
      local S = require 'posix.sys.socket'
      have_network = S.getaddrinfo('example.com', '80',
                                   {socktype = S.SOCK_STREAM}) ~= nil
   end
   if not have_network then
      skip 'no network'
   end
end

--------------------------------------------------------------------- modules

group('modules load')

local MODULES = {
   'lpeg', 're', 'zlib', '_cosmo_tls', 'basexx', 'fifo', 'binaryheap',
   'cqueues', 'cqueues.errno', 'cqueues.auxlib', 'cqueues.condition',
   'cqueues.socket', 'cqueues.socket.tls',
   'lpeg_patterns.http', 'lpeg_patterns.uri', 'lpeg_patterns.IPv4',
   'lpeg_patterns.IPv6',
   'openssl.ssl', 'openssl.ssl.context', 'openssl.rand', 'openssl.digest',
   'openssl.x509', 'openssl.x509.verify_param', 'openssl.bignum',
   'http.bit', 'http.client', 'http.connection_common', 'http.cookie',
   'http.h1_connection', 'http.h1_stream', 'http.h2_connection',
   'http.h2_error', 'http.h2_stream', 'http.headers', 'http.hpack',
   'http.hsts', 'http.proxies', 'http.request', 'http.server',
   'http.socks', 'http.stream_common', 'http.tls', 'http.util',
   'http.version', 'http.websocket', 'http.zlib',
}

test(#MODULES .. ' modules required', function()
   for _, m in ipairs(MODULES) do
      local ok, err = pcall(require, m)
      want(ok, '%s: %s', m, tostring(err))
   end
end)

----------------------------------------------------------------- the pieces

group('the support layer')

test('lpeg matches a pattern', function()
   local lpeg = require 'lpeg'
   local digits = lpeg.R '09' ^ 1
   want(digits:match '123abc' == 4, 'lpeg did not match')
end)

test('lpeg_patterns parses a URI', function()
   local uri = require 'lpeg_patterns.uri'
   local lpeg = require 'lpeg'
   local m = (uri.uri * lpeg.P(-1)):match 'http://user@host:8080/p?q=1#f'
   want(m, 'no match')
   want(m.scheme == 'http', 'scheme was %s', tostring(m.scheme))
   want(m.host == 'host' and m.port == 8080, 'bad authority')
   want(m.path == '/p', 'path was %s', tostring(m.path))
end)

test('zlib deflate and inflate round trip', function()
   local zlib = require 'zlib'
   want(zlib._VERSION:match '^lua%-zlib', 'wrong _VERSION for http.zlib')
   local text = string.rep('the quick brown fox. ', 200)
   local deflate = zlib.deflate()
   local packed = deflate(text, 'finish')
   want(#packed < #text / 2, 'compression achieved nothing')
   local inflate = zlib.inflate()
   local back, eof = inflate(packed)
   want(back == text, 'round trip changed the data')
   want(eof, 'end of stream not reported')
end)

test('http.zlib presents the lua-zlib interface', function()
   local hzlib = require 'http.zlib'
   want(hzlib.engine == 'lua-zlib', 'engine is %s', tostring(hzlib.engine))
   local deflate, inflate = hzlib.deflate(), hzlib.inflate()
   local packed = deflate('hello gzip', true)
   want(inflate(packed, true) == 'hello gzip', 'round trip failed')
end)

test('openssl.rand and openssl.digest', function()
   local rand = require 'openssl.rand'
   local digest = require 'openssl.digest'
   want(#rand.bytes(16) == 16, 'wrong length')
   want(rand.bytes(16) ~= rand.bytes(16), 'randomness is not random')
   -- the well known sha1 of "abc"
   local sha1 = digest.new 'sha1'
   local out = sha1:final 'abc'
   want(#out == 20, 'sha1 length')
   want((out:gsub('.', function(c) return string.format('%02x', c:byte()) end))
        == 'a9993e364706816aba3e25717850c26c9cd0d89d', 'sha1 mismatch')
end)

test('cqueues schedules two coroutines', function()
   local cqueues = require 'cqueues'
   local cq = cqueues.new()
   local order = {}
   cq:wrap(function()
      order[#order + 1] = 'a1'
      cqueues.poll(0.01)
      order[#order + 1] = 'a2'
   end)
   cq:wrap(function()
      order[#order + 1] = 'b1'
      cqueues.poll(0.02)
      order[#order + 1] = 'b2'
   end)
   want(cq:loop(5), 'loop failed')
   want(table.concat(order, ',') == 'a1,b1,a2,b2',
        'ran as %s', table.concat(order, ','))
end)

test('a condition wakes a waiter', function()
   local cqueues = require 'cqueues'
   local cc = require 'cqueues.condition'
   local cq, cond, woke = cqueues.new(), nil, false
   cond = cc.new()
   cq:wrap(function()
      cqueues.poll(cond)
      woke = true
   end)
   cq:wrap(function()
      cqueues.poll(0.01)
      cond:signal()
   end)
   want(cq:loop(5), 'loop failed')
   want(woke, 'the waiter never woke')
end)

------------------------------------------------------------------- loopback

group('client and server over loopback')

local function serve(onstream, fn)
   local cqueues = require 'cqueues'
   local server = require 'http.server'
   local s = assert(require('http.server').listen{
      host = '127.0.0.1', port = 0, tls = false, onstream = onstream})
   assert(s:listen())
   local _, _, port = s:localname()
   local cq = cqueues.new()
   cq:wrap(function() assert(s:loop()) end)
   local err
   cq:wrap(function()
      local ok, e = pcall(fn, port)
      s:close()
      if not ok then err = e end
   end)
   assert(cq:loop(20))
   if err then error(err, 0) end
end

local function echo_handler(_, stream)
   local headers = require 'http.headers'
   local h = assert(stream:get_headers())
   local body = stream:get_body_as_string() or ''
   local reply = string.format('%s %s %s', h:get ':method', h:get ':path', body)
   local res = headers.new()
   res:append(':status', '200')
   res:append('content-type', 'text/plain')
   res:append('content-length', tostring(#reply))
   assert(stream:write_headers(res, false))
   assert(stream:write_chunk(reply, true))
   stream:shutdown()
end

test('GET returns a body', function()
   serve(echo_handler, function(port)
      local request = require 'http.request'
      local req = request.new_from_uri('http://127.0.0.1:' .. port .. '/hello')
      local h, stream = assert(req:go(10))
      want(h:get ':status' == '200', 'status %s', h:get ':status')
      want(stream:get_body_as_string() == 'GET /hello ', 'wrong body')
      stream:shutdown()
   end)
end)

test('POST sends a request body', function()
   serve(echo_handler, function(port)
      local request = require 'http.request'
      local req = request.new_from_uri('http://127.0.0.1:' .. port .. '/post')
      req.headers:upsert(':method', 'POST')
      req:set_body 'payload'
      local h, stream = assert(req:go(10))
      want(h:get ':status' == '200', 'status %s', h:get ':status')
      want(stream:get_body_as_string() == 'POST /post payload', 'wrong body')
      stream:shutdown()
   end)
end)

test('a large body survives the round trip', function()
   local big = string.rep('0123456789', 50000) -- 500 KB
   serve(function(_, stream)
      local headers = require 'http.headers'
      assert(stream:get_headers())
      local res = headers.new()
      res:append(':status', '200')
      res:append('content-length', tostring(#big))
      assert(stream:write_headers(res, false))
      assert(stream:write_chunk(big, true))
      stream:shutdown()
   end, function(port)
      local request = require 'http.request'
      local h, stream = assert(request.new_from_uri(
         'http://127.0.0.1:' .. port .. '/big'):go(20))
      want(h:get ':status' == '200', 'status')
      local body = stream:get_body_as_string()
      want(#body == #big, 'got %d bytes, wanted %d', #body, #big)
      want(body == big, 'the bytes changed in flight')
      stream:shutdown()
   end)
end)

test('chunked transfer encoding', function()
   serve(function(_, stream)
      local headers = require 'http.headers'
      assert(stream:get_headers())
      local res = headers.new()
      res:append(':status', '200')
      -- no content-length, so lua-http has to chunk it
      assert(stream:write_headers(res, false))
      for i = 1, 5 do
         assert(stream:write_chunk('chunk' .. i .. ';', false))
      end
      assert(stream:write_chunk('', true))
      stream:shutdown()
   end, function(port)
      local request = require 'http.request'
      local h, stream = assert(request.new_from_uri(
         'http://127.0.0.1:' .. port .. '/chunked'):go(10))
      local te = h:get 'transfer-encoding'
      want(te and te:match 'chunked', 'transfer-encoding was %s', tostring(te))
      want(stream:get_body_as_string() ==
           'chunk1;chunk2;chunk3;chunk4;chunk5;', 'wrong body')
      stream:shutdown()
   end)
end)

--[[ With the zlib binding present lua-http advertises the gzip
     transfer-encoding, so a chunked response comes back compressed and
     the client inflates it without the caller noticing.  That exercises
     third_party/luazlib over a real connection. ]]
test('the body is gzipped when the client offers it', function()
   serve(function(_, stream)
      local headers = require 'http.headers'
      assert(stream:get_headers())
      local res = headers.new()
      res:append(':status', '200')
      assert(stream:write_headers(res, false))
      assert(stream:write_chunk(string.rep('compress me. ', 500), true))
      stream:shutdown()
   end, function(port)
      local request = require 'http.request'
      local h, stream = assert(request.new_from_uri(
         'http://127.0.0.1:' .. port .. '/gz'):go(10))
      local te = h:get 'transfer-encoding'
      want(te and te:match 'gzip', 'transfer-encoding was %s', tostring(te))
      want(stream:get_body_as_string() == string.rep('compress me. ', 500),
           'the inflated body does not match')
      stream:shutdown()
   end)
end)

test('request headers reach the server', function()
   serve(function(_, stream)
      local headers = require 'http.headers'
      local h = assert(stream:get_headers())
      local res = headers.new()
      res:append(':status', '200')
      res:append('x-saw-agent', h:get 'user-agent' or 'none')
      res:append('content-length', '0')
      assert(stream:write_headers(res, false))
      assert(stream:write_chunk('', true))
      stream:shutdown()
   end, function(port)
      local request = require 'http.request'
      local req = request.new_from_uri('http://127.0.0.1:' .. port .. '/h')
      req.headers:upsert('user-agent', 'cosmo-lua-http-test')
      local h, stream = assert(req:go(10))
      want(h:get 'x-saw-agent' == 'cosmo-lua-http-test',
           'server saw %s', tostring(h:get 'x-saw-agent'))
      stream:shutdown()
   end)
end)

test('two requests on one connection', function()
   serve(echo_handler, function(port)
      local request = require 'http.request'
      for i = 1, 2 do
         local req = request.new_from_uri(
            'http://127.0.0.1:' .. port .. '/n' .. i)
         local h, stream = assert(req:go(10))
         want(h:get ':status' == '200', 'request %d failed', i)
         want(stream:get_body_as_string() == 'GET /n' .. i .. ' ', 'body %d', i)
         stream:shutdown()
      end
   end)
end)

test('websocket echo over loopback', function()
   local cqueues = require 'cqueues'
   local server = require 'http.server'
   local websocket = require 'http.websocket'
   local s = assert(server.listen{host = '127.0.0.1', port = 0, tls = false,
      onstream = function(sv, stream)
         local ws = websocket.new_from_stream(stream, assert(stream:get_headers()))
         assert(ws:accept{timeout = 5})
         local msg = assert(ws:receive(5))
         assert(ws:send(msg:upper(), nil, 5))
         ws:close()
         sv:close()
      end})
   assert(s:listen())
   local _, _, port = s:localname()
   local cq = cqueues.new()
   cq:wrap(function() assert(s:loop()) end)
   local got
   cq:wrap(function()
      local ws = assert(websocket.new_from_uri('ws://127.0.0.1:' .. port))
      assert(ws:connect(10))
      assert(ws:send('hello websocket', nil, 5))
      got = ws:receive(5)
      ws:close()
   end)
   assert(cq:loop(20))
   want(got == 'HELLO WEBSOCKET', 'echo was %s', tostring(got))
end)

---------------------------------------------------------------------- live

group('live network')

test('http to a real server', function()
   needs_network()
   local request = require 'http.request'
   local h, stream = assert(request.new_from_uri('http://example.com/'):go(20))
   want(h:get ':status' == '200', 'status %s', h:get ':status')
   want(#assert(stream:get_body_as_string()) > 100, 'body too short')
   stream:shutdown()
end)

test('https with certificate verification', function()
   needs_network()
   local request = require 'http.request'
   local h, stream = assert(request.new_from_uri('https://example.com/'):go(30))
   want(h:get ':status' == '200', 'status %s', h:get ':status')
   local ssl = stream.connection:checktls()
   want(ssl, 'the connection is not encrypted')
   want(ssl:getVerifyResult() == 0, 'certificate did not verify')
   want(ssl:getVersion():match 'TLS', 'version is %s', ssl:getVersion())
   stream:shutdown()
end)

test('an expired certificate is rejected', function()
   needs_network()
   local request = require 'http.request'
   local h, err = request.new_from_uri('https://expired.badssl.com/'):go(30)
   want(h == nil, 'an expired certificate was accepted')
   want(tostring(err):match 'starttls' or tostring(err):match 'certificate',
        'rejected for the wrong reason: %s', tostring(err))
end)

test('a self-signed certificate is rejected', function()
   needs_network()
   local request = require 'http.request'
   local h, err = request.new_from_uri('https://self-signed.badssl.com/'):go(30)
   want(h == nil, 'a self-signed certificate was accepted')
   want(tostring(err):match 'starttls' or tostring(err):match 'certificate',
        'rejected for the wrong reason: %s', tostring(err))
end)

test('a wrong-host certificate is rejected', function()
   needs_network()
   local request = require 'http.request'
   local h, err = request.new_from_uri('https://wrong.host.badssl.com/'):go(30)
   want(h == nil, 'a certificate for the wrong host was accepted')
end)

---------------------------------------------------------------------- done

io.write(string.format('\n%d passed, %d skipped, %d failed\n',
                       npass, nskip, nfail))
if nfail > 0 then
   io.write('failed: ' .. table.concat(failed, ', ') .. '\n')
   os.exit(1)
end
os.exit(0)
