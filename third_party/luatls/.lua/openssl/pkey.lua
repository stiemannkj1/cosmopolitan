--[[ openssl.pkey, shaped for lua-http over mbedtls.

     lua-http makes a key object for two reasons: to name an ephemeral
     curve, which the engine turns into mbedtls curve configuration, and
     to generate a key for the self-signed certificate its server can
     make on the fly.  The second is not implemented, so generation
     answers with an error rather than a key that does not work. ]]
local methods = {}
local mt = {__index = methods, __name = 'openssl.pkey'}

local M = {}

function M.new(opts)
   opts = opts or {}
   if type(opts) == 'string' then
      return nil, 'parsing keys is not implemented by the mbedtls shim'
   end
   if opts.type and opts.type ~= 'EC' then
      -- a request to actually generate an RSA or DSA key
      return nil, 'key generation is not implemented by the mbedtls shim'
   end
   return setmetatable({
      type = opts.type or 'EC',
      curve = opts.curve or 'prime256v1',
      bits = opts.bits,
   }, mt)
end

function M.interpose()
   return nil
end

function methods:type()
   return self.type
end

function methods:toPEM()
   return nil, 'not implemented by the mbedtls shim'
end

function methods:getParameters()
   return {curve = self.curve}
end

return M
