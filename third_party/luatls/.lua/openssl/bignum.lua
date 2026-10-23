--[[ openssl.bignum, a thin arbitrary-precision stand-in.

     lua-http uses this for one thing, turning sixteen random bytes into
     a certificate serial number, so the binary form is all that
     matters. ]]
local methods = {}
local mt = {
   __index = methods,
   __name = 'openssl.bignum',
   __tostring = function(self)
      return (self.bin:gsub('.', function(c)
         return string.format('%02X', c:byte())
      end))
   end,
}

local M = {}

function M.new(n)
   if type(n) == 'number' then
      return setmetatable({bin = string.pack('>I8', n)}, mt)
   end
   return setmetatable({bin = n or ''}, mt)
end

function M.fromBinary(s)
   return setmetatable({bin = s}, mt)
end

function M.interpose()
   return nil
end

function methods:toBinary()
   return self.bin
end

function methods:toHex()
   return tostring(self)
end

return M
