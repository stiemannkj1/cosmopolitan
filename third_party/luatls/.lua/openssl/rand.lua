--[[ openssl.rand, over the kernel's random source.

     Needed even when no TLS is involved, because lua-http's websocket
     client masks every frame it sends with four random bytes. ]]
local tls = require '_cosmo_tls'

local M = {}

function M.bytes(n)
   return tls.rand(n)
end

function M.ready()
   return true
end

function M.stir()
   return true
end

function M.add()
   return true
end

function M.uniform(n)
   if n == nil or n == 0 then
      n = 0x100000000
   end
   local b = tls.rand(8)
   local v = 0
   for i = 1, 8 do
      v = (v * 256 + b:byte(i)) % 0x7fffffffffff
   end
   return v % n
end

return M
