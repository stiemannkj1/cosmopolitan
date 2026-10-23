--[[ openssl.digest, over mbedtls' message digests.

     lua-http needs exactly one digest, the SHA-1 of the websocket
     handshake key. ]]
local tls = require '_cosmo_tls'

local methods = {}
local mt = {__index = methods, __name = 'openssl.digest'}

local M = {}

function M.new(kind)
   return setmetatable({kind = kind or 'sha1', parts = {}}, mt)
end

function M.interpose()
   return nil
end

function methods:update(...)
   for i = 1, select('#', ...) do
      self.parts[#self.parts + 1] = (select(i, ...))
   end
   return self
end

function methods:final(...)
   self:update(...)
   return tls.digest(self.kind, table.concat(self.parts))
end

return M
