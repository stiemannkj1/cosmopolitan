--[[ openssl.ssl.context, shaped for lua-http over mbedtls.

     Nothing here talks to a TLS library.  A context is a plain record of
     what the caller asked for, which third_party/luatls turns into
     mbedtls configuration when a socket actually starts a handshake.
     That keeps the C side small and keeps the awkward parts of the
     OpenSSL API, like cipher list strings, in Lua where they are easy to
     read and to fix. ]]
local tls = require '_cosmo_tls'

local methods = {}
local mt = {__index = methods, __name = 'openssl.ssl.context'}

local M = {}

-- OpenSSL's SSL_OP_* bits.  Only the protocol-version ones carry any
-- meaning here, and they are translated into an mbedtls version floor.
M.OP_NO_SSLv2 = 0x01000000
M.OP_NO_SSLv3 = 0x02000000
M.OP_NO_TLSv1 = 0x04000000
M.OP_NO_TLSv1_1 = 0x10000000
M.OP_NO_TLSv1_2 = 0x08000000
M.OP_NO_TLSv1_3 = 0x20000000
M.OP_NO_COMPRESSION = 0x00020000
M.OP_SINGLE_ECDH_USE = 0x00080000
M.OP_CIPHER_SERVER_PREFERENCE = 0x00400000

M.VERIFY_NONE = 0
M.VERIFY_PEER = 1
M.VERIFY_FAIL_IF_NO_PEER_CERT = 2
M.VERIFY_CLIENT_ONCE = 4

local store_methods = {}
local store_mt = {__index = store_methods, __name = 'openssl.x509.store'}

function store_methods:addDefaults()
   self.defaults = true
   return true
end

function store_methods:add(what)
   self.extra[#self.extra + 1] = what
   return true
end

function M.new(protocol, server)
   return setmetatable({
      protocol = protocol or 'TLS',
      server = not not server,
      options = 0,
      verify = M.VERIFY_NONE,
      ciphers = nil,
      groups = nil,
      alpn = nil,
      alpn_select = nil,
      cert = nil,
      key = nil,
      store = setmetatable({defaults = false, extra = {}}, store_mt),
      param = nil,
   }, mt)
end

--[[ luaossl's openssl.ssl.new(ctx) makes a connection object that
     starts from a context's settings and can then be customised for the
     one connection.  Here both are the same kind of record, so this is a
     copy. ]]
function M.clone(ctx)
   local c = M.new(ctx.protocol, ctx.server)
   for k, v in pairs(ctx) do
      c[k] = v
   end
   return c
end

function methods:setHostName(name)
   self.hostname = name
   return true
end

function methods:getHostName()
   return self.hostname
end

function M.interpose(name, f)
   local old = methods[name]
   methods[name] = f
   return old
end

function methods:setCipherList(list)
   self.ciphers = list
   return true
end

function methods:setCipherSuites(list)
   self.ciphersuites = list
   return true
end

function methods:setOptions(bits)
   self.options = (self.options | bits)
   return true
end

function methods:getOptions()
   return self.options
end

function methods:clearOptions(bits)
   self.options = self.options & ~bits
   return true
end

function methods:setGroups(groups)
   self.groups = groups
   return true
end

--[[ OpenSSL takes a key object describing the ephemeral parameters.
     mbedtls expresses the same intent as a curve list, so record the
     curve and let the engine translate. ]]
function methods:setEphemeralKey(key)
   if type(key) == 'table' and key.curve then
      self.groups = self.groups or key.curve
   end
   return true
end

function methods:setVerify(mode, depth)
   self.verify = mode
   self.depth = depth
   return true
end

function methods:getVerify()
   return self.verify, self.depth
end

function methods:setStore(store)
   self.store = store
   return true
end

function methods:getStore()
   return self.store
end

function methods:setParam(param)
   self.param = param
   return true
end

function methods:getParam()
   if self.param == nil then
      self.param = require('openssl.x509.verify_param').new()
   end
   return self.param
end

function methods:setCertificate(crt)
   self.cert = crt
   return true
end

function methods:setPrivateKey(key)
   self.key = key
   return true
end

function methods:setAlpnProtos(protos)
   self.alpn = protos
   return true
end

--[[ mbedtls picks from the configured list itself rather than calling
     back into the application, so this records the preference order the
     callback would have expressed and lets the engine apply it. ]]
function methods:setAlpnSelect(fn, ...)
   self.alpn_select = fn
   self.alpn_select_arg = ...
   return true
end

function methods:setCurvesList(list)
   self.groups = list
   return true
end

function methods:setDHParam()
   return true
end

function methods:setTicketKeys()
   return true
end

function methods:setEphemeralDH()
   return true
end

return M
