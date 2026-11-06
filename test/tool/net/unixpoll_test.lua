-- poll() on pipes. On the New Technology it once reported an idle pipe as
-- readable at once, so a blocking read right after it hung forever. This
-- file is separate from lunix_test.lua because that one cannot run under
-- wine, and this is the platform it exists to guard.

local function ms()
   local sec, nsec = unix.clock_gettime(unix.CLOCK_MONOTONIC)
   return sec * 1000 + nsec / 1e6
end

-- the monotonic clock really advances
local t0 = ms()
unix.nanosleep(0, 30 * 1000 * 1000)
assert(ms() - t0 >= 25)

local reader, writer = assert(unix.pipe())

-- nothing written, so not readable, and the timeout is honored
local ready = assert(unix.poll({[reader] = unix.POLLIN}, 0))
assert(not ready[reader] or ready[reader] == 0)
t0 = ms()
ready = assert(unix.poll({[reader] = unix.POLLIN}, 150))
local took = ms() - t0
assert(not ready[reader] or ready[reader] == 0, 'idle pipe reported readable')
assert(took >= 120 and took < 5000, took)

-- readable soon after a write, with exactly the bytes written
assert(unix.write(writer, 'x'))
t0 = ms()
ready = assert(unix.poll({[reader] = unix.POLLIN}, 5000))
assert((ready[reader] & unix.POLLIN) ~= 0)
assert(ms() - t0 < 2000)
assert(unix.read(reader, 10) == 'x')

-- once the writer is gone it is reported at once, and reads end of file
unix.close(writer)
ready = assert(unix.poll({[reader] = unix.POLLIN}, 5000))
assert(ready[reader] and ready[reader] ~= 0)
assert(unix.read(reader, 10) == '')
unix.close(reader)
print('unixpoll_test ok')
