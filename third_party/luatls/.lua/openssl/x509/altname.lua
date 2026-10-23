-- openssl.x509.altname, shaped for lua-http over mbedtls
local methods = {}
local mt = {
   __index = methods,
   __name = 'openssl.x509.altname',
   __pairs = function(self)
      local i = 0
      return function()
         i = i + 1
         local e = self.entries[i]
         if e then
            return e[1], e[2]
         end
      end
   end,
}

local M = {}

function M.new()
   return setmetatable({entries = {}}, mt)
end

function methods:add(kind, value)
   self.entries[#self.entries + 1] = {kind, value}
   return true
end

return M
