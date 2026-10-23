--[[ openssl.ssl, shaped for lua-http over mbedtls.

     An "ssl" here is the live connection object a socket hands back from
     checktls().  The engine itself lives in C; this is the luaossl
     shaped face of it. ]]
local M = {}

M.TLS = 'TLS'
M.SSL3_VERSION = 0x0300
M.TLS1_VERSION = 0x0301
M.TLS1_1_VERSION = 0x0302
M.TLS1_2_VERSION = 0x0303
M.TLS1_3_VERSION = 0x0304

--[[ A connection object inherits everything the context was configured
     with, and may then be adjusted for this one connection, which is
     what lua-http does when it sets the hostname and the ALPN list. ]]
function M.new(ctx, server)
   local ctxlib = require 'openssl.ssl.context'
   local ssl = ctxlib.clone(ctx)
   if server ~= nil then
      ssl.server = not not server
   end
   return ssl
end

function M.interpose()
   return nil
end

return M
