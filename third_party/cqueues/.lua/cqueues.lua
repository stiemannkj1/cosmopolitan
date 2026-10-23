--[[ cqueues, reimplemented in pure Lua over luaposix.

     Upstream is a C library whose event core, src/lib/kpoll.c, has
     backends for epoll, kqueue and Solaris ports and for nothing else.
     Cosmopolitan exposes none of those, deliberately, because none of
     them is portable to every platform an APE runs on.  What it does
     expose is poll(2), which is all a scheduler of this shape needs.

     This implements the part of the cqueues API that lua-http uses: the
     controller, the poll primitive, the pollable protocol, conditions,
     errno and the buffered socket.  It is not a complete cqueues.  It
     has no threads, no built-in DNS resolver, no file notification and
     no signal handling, because lua-http requires none of them.

     The pollable protocol is upstream's: an object may answer pollfd(),
     events() and timeout(), and whichever of those it answers are used.
     This adds one extension, __cqready(), for objects that can be ready
     without a descriptor, which is how conditions work here. ]]

local P = require 'posix.poll'
local T = require 'posix.time'

local POLL = setmetatable({}, {__name = 'cqueues.poll'})

local M = {}

local running_cq = nil
local plan

function M.monotime()
   local ts = T.clock_gettime(T.CLOCK_MONOTONIC)
   return ts.tv_sec + ts.tv_nsec * 1e-9
end

local monotime = M.monotime

--[[ Suspends the running coroutine until one of the objects is ready,
     and answers the ones that are.  A bare number among the arguments is
     a timeout, and when it expires poll answers that number, which is
     how callers tell a timeout from readiness.  With no arguments at all
     it simply yields to the scheduler. ]]

--[[ Works out what a thread's poll arguments mean: which descriptors to
     wait on, which objects are already ready without one, and when the
     wait should give up. ]]
function plan(want)
   local fds, byfd, ready = nil, nil, nil
   local deadline, on_timeout = nil, nil
   for i = 1, want.n do
      local o = want[i]
      if type(o) == 'number' then
         if deadline == nil or o < deadline then
            deadline, on_timeout = o, o
         end
      elseif o ~= nil then
         if o.__cqready and o:__cqready() then
            ready = ready or {}
            ready[#ready + 1] = o
         end
         --[[ a nested controller has no descriptor of its own, it has
              the descriptors its threads are waiting on ]]
         if o.__cqfds then
            local nested = o:__cqfds()
            for nfd, nspec in pairs(nested) do
               fds = fds or {}
               byfd = byfd or {}
               if fds[nfd] then
                  fds[nfd].events.IN = fds[nfd].events.IN or nspec.events.IN
                  fds[nfd].events.OUT = fds[nfd].events.OUT or nspec.events.OUT
               else
                  fds[nfd] = nspec
                  byfd[nfd] = o
               end
            end
         end
         local fd = o.pollfd and o:pollfd() or nil
         if fd and fd >= 0 then
            local ev = (o.events and o:events()) or 'r'
            fds = fds or {}
            byfd = byfd or {}
            local spec = fds[fd]
            if spec then
               spec.events.IN = spec.events.IN or ev:find('r') ~= nil
               spec.events.OUT = spec.events.OUT or ev:find('w') ~= nil
            else
               fds[fd] = {events = {IN = ev:find('r') ~= nil,
                                    OUT = ev:find('w') ~= nil}}
               byfd[fd] = o
            end
         end
         local t = o.timeout and o:timeout() or nil
         if t and (deadline == nil or t < deadline) then
            deadline, on_timeout = t, o
         end
      end
   end
   return fds, byfd, ready, deadline, on_timeout
end

--[[ Outside a controller there is nobody to yield to, so wait here
     instead.  Upstream does the same, and lua-http relies on it: a plain
     script that calls request:go() ends up polling from the main thread
     with no scheduler anywhere in sight. ]]
local function poll_blocking(want)
   if want.n == 0 then
      -- a bare poll() is a turn of the scheduler, and with no scheduler
      -- there is nothing to give a turn to
      return nil
   end
   local fds, byfd, ready, timeout, on_timeout = plan(want)
   if ready then
      for _, o in ipairs(ready) do
         if o.__cqtake then
            o:__cqtake()
         end
      end
      return ready[1]
   end
   local ms = timeout and math.max(0, math.floor(timeout * 1000 + 0.5)) or -1
   if fds == nil then
      if ms < 0 then
         error('deadlock: nothing to wait for', 3)
      end
      T.nanosleep({tv_sec = math.floor(ms / 1000),
                   tv_nsec = (ms % 1000) * 1000000})
      return on_timeout
   end
   local n = P.poll(fds, ms)
   if n and n > 0 then
      for fd, spec in pairs(fds) do
         local re = spec.revents
         if re and (re.IN or re.OUT or re.HUP or re.ERR or re.NVAL) then
            return byfd[fd]
         end
      end
   end
   return on_timeout
end

function M.poll(...)
   if running_cq and coroutine.isyieldable() then
      return coroutine.yield(POLL, ...)
   end
   return poll_blocking(table.pack(...))
end

local poll = M.poll

----------------------------------------------------------------- controller

local cq_methods = {}
local cq_mt = {
   __index = cq_methods,
   __name = 'cqueues.controller',
}

function M.new()
   return setmetatable({threads = {}, n = 0}, cq_mt)
end

function M.type(o)
   local mt = getmetatable(o)
   if mt == cq_mt then
      return 'controller'
   end
   local ok, cc = pcall(require, 'cqueues.condition')
   if ok and cc.type(o) then
      return 'condition'
   end
   return nil
end

function M.running()
   if running_cq then
      return running_cq, true
   end
   return nil
end

--[[ Upstream uses this to break another thread out of a poll on a
     descriptor it is about to close.  Here every poll set is rebuilt
     from scratch on each pass of the loop, so a closed descriptor simply
     stops being waited on, and this has nothing to do. ]]
function M.cancel(_fd)
   return true
end

function cq_methods:attach(co)
   if self.threads[co] == nil then
      self.threads[co] = {state = 'ready'}
      self.n = self.n + 1
   end
   return self
end

function cq_methods:wrap(f, ...)
   local co = coroutine.create(f)
   self.threads[co] = {state = 'ready', args = table.pack(...)}
   self.n = self.n + 1
   return self
end

function cq_methods:empty()
   return self.n == 0
end

function cq_methods:count()
   return self.n
end

function cq_methods:cancel(_fd)
   return true
end

--[[ A controller has no descriptor of its own here, unlike upstream
     where it is an epoll or kqueue handle.  It is still pollable, by way
     of __cqfds below, which lets an outer loop wait on the descriptors
     an inner controller's threads are waiting on. ]]
function cq_methods:pollfd()
   return nil
end

function cq_methods:events()
   return 'r'
end

function cq_methods:timeout()
   local soonest = nil
   for _, st in pairs(self.threads) do
      if st.state == 'ready' then
         return 0
      end
      if st.deadline then
         local left = st.deadline - monotime()
         if soonest == nil or left < soonest then
            soonest = left
         end
      end
   end
   return soonest and math.max(soonest, 0) or nil
end

function cq_methods:__cqready()
   for _, st in pairs(self.threads) do
      if st.state == 'ready' then
         return true
      end
   end
   return false
end

function cq_methods:__cqfds()
   local all, byfd = {}, {}
   for _, st in pairs(self.threads) do
      if st.state == 'waiting' and st.want then
         local fds, map = plan(st.want)
         if fds then
            for fd, spec in pairs(fds) do
               all[fd], byfd[fd] = spec, map[fd]
            end
         end
      end
   end
   return all, byfd
end

local function finish(self, co, err)
   self.threads[co] = nil
   self.n = self.n - 1
   return err
end

local function resume(self, co, st)
   local prev = running_cq
   running_cq = self
   local args = st.args or st.wake
   st.args, st.wake = nil, nil
   local res
   if args then
      res = table.pack(coroutine.resume(co, table.unpack(args, 1, args.n)))
   else
      res = table.pack(coroutine.resume(co))
   end
   running_cq = prev
   if not res[1] then
      return false, finish(self, co, res[2])
   end
   if coroutine.status(co) == 'dead' then
      finish(self, co, nil)
      return true
   end
   if res[2] ~= POLL then
      return false, finish(self, co,
         'coroutine yielded without going through cqueues.poll')
   end
   st.want = table.pack(table.unpack(res, 3, res.n))
   st.deadline = nil
   if st.want.n == 0 then
      -- a bare cqueues.poll(), which just gives the loop a turn
      st.state = 'ready'
   else
      st.state = 'waiting'
      local _, _, _, timeout = plan(st.want)
      if timeout then
         st.deadline = monotime() + timeout
      end
   end
   return true
end

--[[ Nobody is runnable, so work out what every waiting thread is waiting
     for, wait for the first of it, and mark whoever woke. ]]
local function wait(self, timeout)
   local fds, byfd, owner = {}, {}, {}
   local deadline = timeout and (monotime() + timeout) or nil
   local any = false

   for co, st in pairs(self.threads) do
      if st.state == 'waiting' then
         local f, map, ready = plan(st.want)
         if ready then
            -- ready without a descriptor, a signalled condition
            for _, o in ipairs(ready) do
               if o.__cqtake then
                  o:__cqtake()
               end
            end
            st.state, st.wake = 'ready', table.pack(ready[1])
            any = true
         elseif f then
            for fd, spec in pairs(f) do
               if fds[fd] then
                  fds[fd].events.IN = fds[fd].events.IN or spec.events.IN
                  fds[fd].events.OUT = fds[fd].events.OUT or spec.events.OUT
               else
                  fds[fd], byfd[fd], owner[fd] = spec, map[fd], co
               end
            end
         end
         if st.deadline and (deadline == nil or st.deadline < deadline) then
            deadline = st.deadline
         end
      end
   end
   if any then
      return true
   end

   local ms = -1
   if deadline then
      ms = math.max(0, math.floor((deadline - monotime()) * 1000 + 0.5))
   end
   if next(fds) == nil then
      if ms < 0 then
         return false, 'deadlock: every thread is waiting for nothing'
      end
      T.nanosleep({tv_sec = math.floor(ms / 1000),
                   tv_nsec = (ms % 1000) * 1000000})
   else
      local ok, err, errnum = P.poll(fds, ms)
      if ok == nil and errnum ~= require('cqueues.errno').EINTR then
         return false, err
      end
      for fd, spec in pairs(fds) do
         local re = spec.revents
         if re and (re.IN or re.OUT or re.HUP or re.ERR or re.NVAL) then
            local co = owner[fd]
            local st = self.threads[co]
            if st and st.state == 'waiting' then
               st.state, st.wake = 'ready', table.pack(byfd[fd])
            end
         end
      end
   end

   local now = monotime()
   for _, st in pairs(self.threads) do
      if st.state == 'waiting' and st.deadline and now >= st.deadline then
         local _, _, _, _, on_timeout = plan(st.want)
         st.state, st.wake = 'ready', table.pack(on_timeout)
      end
   end
   return true
end

function cq_methods:step(timeout)
   local ready = {}
   for co, st in pairs(self.threads) do
      if st.state == 'ready' then
         ready[#ready + 1] = co
      end
   end
   if #ready == 0 then
      if self.n == 0 then
         return true
      end
      local ok, err = wait(self, timeout)
      if not ok then
         return false, err
      end
      for co, st in pairs(self.threads) do
         if st.state == 'ready' then
            ready[#ready + 1] = co
         end
      end
   end
   for _, co in ipairs(ready) do
      local st = self.threads[co]
      if st and st.state == 'ready' then
         st.state = 'running'
         local ok, err = resume(self, co, st)
         if not ok then
            return false, err
         end
      end
   end
   return true
end

--[[ Running a controller from inside another controller's coroutine is
     a normal thing to do, and lua-http's server does exactly that.  The
     inner loop must not block, or the outer one never gets a turn, so it
     steps without waiting and then parks on itself, which lets the outer
     loop wait on the descriptors the inner threads want. ]]
function cq_methods:loop(timeout)
   local deadline = timeout and (monotime() + timeout) or nil
   while self.n > 0 do
      local left = nil
      if deadline then
         left = deadline - monotime()
         if left <= 0 then
            return true
         end
      end
      local outer = running_cq
      if outer and outer ~= self then
         local ok, err = self:step(0)
         if not ok then
            return false, err
         end
         if self.n > 0 and not self:__cqready() then
            poll(self, left)
         end
      else
         local ok, err = self:step(left)
         if not ok then
            return false, err
         end
      end
   end
   return true
end

function cq_methods:errors(timeout)
   -- upstream returns an iterator of loop errors; one at a time is
   -- enough for every caller here
   return function()
      local ok, err = self:loop(timeout)
      if not ok then
         return err
      end
      return nil
   end
end

return M
