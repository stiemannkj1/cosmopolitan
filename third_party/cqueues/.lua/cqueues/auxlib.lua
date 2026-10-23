--[[ cqueues.auxlib, reimplemented in pure Lua.

     lua-http uses exactly one function from upstream's auxlib, which is
     fileresult, so that is what this provides, alongside the two other
     helpers that are cheap to supply and that callers of cqueues
     sometimes reach for. ]]
local ce = require 'cqueues.errno'

local M = {}

--[[ Normalises the (value) or (nil, message, errno) convention.  Upstream
     exists to turn a bare errno into the io-library's (nil, msg, errno)
     triple, so a caller can treat a cqueues result like a file result. ]]
function M.fileresult(ok, why, code)
   if ok == nil or ok == false then
      if type(why) == 'number' then
         return nil, ce.strerror(why), why
      end
      return nil, why, code
   end
   return ok, why, code
end

function M.assert(ok, why, code, ...)
   if ok == nil or ok == false then
      if type(why) == 'number' then
         error(ce.strerror(why), 2)
      end
      error(why or 'assertion failed', 2)
   end
   return ok, why, code, ...
end

function M.resume(co, ...)
   return coroutine.resume(co, ...)
end

function M.wrap(f)
   return coroutine.wrap(f)
end

return M
