--[[ cqueues.condition, reimplemented in pure Lua.

     Upstream backs a condition variable with a pipe, so that it can be
     waited on by the same kernel call that waits on sockets.  This
     scheduler runs every coroutine in one thread, so a signal can never
     arrive from outside the loop, and a plain counter is enough.  The
     scheduler knows how to wait on an object that answers __cqready
     instead of pollfd, which is what makes that work. ]]
local cqueues = require 'cqueues'

local methods = {}
local mt = {
   __index = methods,
   __name = 'cqueues.condition',
}

local M = {}

function M.new(nonblocking)
   return setmetatable({
      pending = 0,      -- how many waiters signal() has promised to wake
      waiters = 0,      -- how many coroutines are parked on this object
      nonblocking = not not nonblocking,
   }, mt)
end

function M.type(o)
   if getmetatable(o) == mt then
      return 'condition'
   end
   return nil
end

-- the scheduler's non-descriptor readiness hook
function methods:__cqready()
   return self.pending > 0
end

-- consumed by the scheduler when it wakes a coroutine on this object
function methods:__cqtake()
   if self.pending > 0 then
      self.pending = self.pending - 1
      return true
   end
   return false
end

function methods:pollfd()
   return nil
end

function methods:events()
   return 'r'
end

function methods:timeout()
   return nil
end

--[[ Wakes up to n waiters, or every waiter when n is absent, which is
     upstream's default. ]]
function methods:signal(n)
   if n == nil then
      self.pending = math.max(self.waiters, 1)
   else
      self.pending = self.pending + n
   end
   return true
end

function methods:wait(timeout)
   if self.nonblocking then
      return self:__cqtake()
   end
   self.waiters = self.waiters + 1
   local ok, which = pcall(cqueues.poll, self, timeout)
   self.waiters = self.waiters - 1
   if not ok then
      error(which, 2)
   end
   return which == self
end

return M
