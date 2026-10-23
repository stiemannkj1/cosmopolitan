--[[ openssl.x509.verify_param, shaped for lua-http over mbedtls.

     lua-http uses this to say which hostname or address a certificate
     has to match.  mbedtls expresses the same thing through
     mbedtls_ssl_set_hostname, so the parameters are recorded here and
     applied by the engine. ]]
local methods = {}
local mt = {__index = methods, __name = 'openssl.x509.verify_param'}

local M = {}

function M.new()
   return setmetatable({}, mt)
end

function methods:setHost(host)
   self.host = host
   return true
end

function methods:addHost(host)
   self.host = self.host or host
   return true
end

function methods:setIP(ip)
   self.ip = ip
   return true
end

function methods:setTime(t)
   self.time = t
   return true
end

function methods:setDepth(d)
   self.depth = d
   return true
end

function methods:setFlags(f)
   self.flags = f
   return true
end

--[[ luaossl's inherit copies settings from another parameter set
     without overwriting what is already there, which is how lua-http
     lets a user-supplied parameter win over its own default. ]]
function methods:inherit(other)
   if type(other) == 'table' then
      for _, k in ipairs{'host', 'ip', 'time', 'depth', 'flags'} do
         if self[k] == nil then
            self[k] = other[k]
         end
      end
   end
   return true
end

return M
