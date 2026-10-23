--[[ cqueues.errno, reimplemented over luaposix.

     Upstream is a C module that exposes every errno constant plus
     strerror.  posix.errno already has both, so this is a thin
     re-export rather than a reimplementation. ]]
local perrno = require 'posix.errno'

local M = {}

for k, v in pairs(perrno) do
   if type(k) == 'string' and k:match '^E%u*%d*$' and type(v) == 'number' then
      M[k] = v
   end
end

-- a few lua-http checks for names that not every platform defines
M.EWOULDBLOCK = M.EWOULDBLOCK or M.EAGAIN
M.EAGAIN = M.EAGAIN or M.EWOULDBLOCK

--[[ Tolerates a non-numeric code, because the TLS engine reports its
     own failures as strings rather than errnos and they travel through
     the same error path. ]]
function M.strerror(code)
   if code == nil then
      return 'no error'
   end
   if type(code) ~= 'number' then
      return tostring(code)
   end
   local msg = perrno.errno(code)
   return msg or ('errno ' .. tostring(code))
end

-- upstream also exposes these two, which some callers use
function M.errno()
   return perrno.errno()
end

M[0] = 'no error'

return M
