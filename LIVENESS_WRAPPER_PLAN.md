# cosmo-spawn, ccw and the liveness wrapper, summary and plan

This file records the work done so far on ccw, the cosmo-spawn Lua module and the related libc changes. It also records the design discussion about how to wait for a child and its descriptors without races, and the plan that came out of it. Nothing in the plan section has been implemented yet.

## 1. What exists today

### ccw

ccw is a stateful Claude Code wrapper written in redbean Lua. It lives in `~/Projects/work/ccw`. It reads a session id from `.ccw-session-id`, spawns `claude` with `stdin='null', stdout='pipe', stderr='pipe'`, and loops on `p:wait(50)` while it prints progress. It accepts the same options as claude for permission mode, with `-a` as the short form for auto mode. It handles SIGTERM and SIGHUP by way of cosmo-spawn. Session ids are validated and passed as `--resume=<id>` so a hostile session file cannot inject arguments.

Open ccw item. The session file is read with an unbounded `f:read('l')` that follows symlinks and FIFOs, which hangs on a FIFO. The fix is to open with `O_NOFOLLOW|O_NONBLOCK`, require a regular file, and read at most 256 bytes.

### cosmo-spawn (`tool/net/.lua/cosmo-spawn.lua`)

By default stdout and stderr go to an anonymous temp file. The module creates it with `io.tmpfile`, takes the descriptor with `unix.fileno`, duplicates it with close-on-exec, and closes the Lua file. The child gets the descriptor through `dup2`. The parent reads with `unix.read(fd, n, offset)` so it never disturbs the offset the child shares. In `pipe` mode the parent drains the pipes into memory with `pump()`.

Waiting is done with a liveness descriptor. With the default tmpfile mode the module makes an extra pipe and passes the write end to the child as fd 3. A hangup on the read end means the child exited. A positive `opts.sleep` selects a busy wait instead, and a negative one selects a pipe-based liveness. The module also has a weak `children` registry, `killall`, exit hooks that wrap `os.exit` and `unix.exit`, an orphan sweep, and `Process.__gc`. The test suite has about 164 checks.

### libc and lunix changes

- `libc/calls/poll-nt.c` was fixed in commit ce9760642. Windows pipe handles are always signaled, so `WaitForMultipleObjects` on them returned at once and reported false readability. The fix leaves pipes out of the wait set, waits on the other handles and the signal event for at most 10ms, and re-checks pipes with `PeekNamedPipe`. A dead `if (avail)` branch remains in the `wi < nw` path and should be removed.
- Uncommitted work implements `POSIX_SPAWN_DIEWITHPARENT_NP` (flag value 1024). Linux uses `prctl(PR_SET_PDEATHSIG)` plus a `getppid` race check. Windows uses a job object with `KILL_ON_JOB_CLOSE` through new kernel32 stubs (`AssignProcessToJobObject.S`, `CreateJobObjectW.S`, `SetInformationJobObject.S`), three struct headers, an enum header, `master.sh` entries, `process.h` declarations, and a `diewithparent` option in `third_party/lunix.c`. The plan below removes all of it.
- The Windows itimer worker thread spins a core under wine, so SIGALRM-based timeouts were abandoned.

### Tests and tooling

- Tests live in `test/tool/net/` (`cosmo_spawn_test.lua`, `cosmo_spawn_helper.lua`, `unixpoll_test.lua`, `cosmo_lfs_test.lua`) with an entry in `test/tool/net/BUILD.mk`.
- `scripts/run_lua_tests.py` runs everything on native, fat, aarch64 under qemu-user, the fat binary under qemu through the APE loader, and wine. It runs one test at a time because a binary open for writing gives "Text file busy". It should switch to `redbean.com -i` and stop depending on `o/lua.com`.
- `~/Tools/notify-mcp.lua` no longer sets `stdout = "pipe"`, so it uses the tmpfile default.
- `~/Tools/redbean.com` is an old build. ccw would busy-spin with it. Replacing it needs the user's approval.
- Nothing is committed beyond ce9760642 and 8a1d54e0d. The libc and NT job changes, the cosmo-spawn rewrite, the tests and the runner are uncommitted.

## 2. Review findings and their status

Item 1 is a fork-owner bug, where a forked child's GC could act on the parent's processes. Item 2 is the ccw hostile session file. Item 3 is an absurd `sleep` value. Items 4 to 8 and 10 were about parent-death handling, hooks and waiting, and the wrapper design resolves them. Item 9 is a child writing to the liveness descriptor, which the wrapper makes impossible. Item 11 is the poll-nt dead branch and hand-written stubs, and the stubs disappear with the job code. Item 12 is the runner coupling, cleanup race and memory use. Item 13 is a ccw session-file race, which is left alone. Item 14 is test flakiness and 4 second orphan sleepers. There is also duplicate code, namely four copies of the reap sequence, blocking wait loops, two nap backoffs, docs repeated between the header and `help.txt`, clock helpers, and several ccw write_session sites.

## 3. The waiting problem and what we learned

The goal is to wait for a child to exit, for pipe data, and for a timeout, all at once, with no race and no busy wait.

On Linux, `ppoll` with a blocked SIGCHLD closes the race atomically. In cosmo it is wired for Linux, FreeBSD and OpenBSD. NetBSD has `pollts` and macOS has no `ppoll`. `pselect` is wired on all five systems, but it cannot report hangup, error or invalid descriptors separately and has descriptor-set limits. Neither `ppoll`, `pselect` nor `sigtimedwait` is exposed in lunix. `sigsuspend`, `sigprocmask`, `sigaction` and `setitimer` are exposed. A kqueue route exists on the BSDs and macOS but cosmo has only raw stubs and no `EVFILT_PROC` or `NOTE_EXIT` constants, and the `kevent` struct differs between systems.

On Windows, `select` is built on the same poll code as `poll` and caps at 128 descriptors, so `pselect` does not help there. Reading the libc source showed a real lost-wakeup window. `__sig_generate` in `libc/intrin/sig.c` looks for a blocked thread to wake before it records the process-wide pending bit, and the waiter publishes its blocker and then checks pending signals without a full fence. A signal raised in that gap, such as SIGCHLD from the proc worker thread, can be missed. Poll-based waits recover within 10ms because they cap each wait and re-check. Waits built on `park.c` (`sigsuspend`, `pause`, `nanosleep`, blocking `wait4`) use an infinite timeout and could hang. This was found by reading code and has not been reproduced.

The conclusion was to stop relying on signals or on atomic multiplexing of a child and descriptors. Instead the exit of the child becomes a descriptor event, which `poll` handles correctly everywhere.

## 4. Chosen design, the liveness wrapper

### Components

A small C program, `cosmo-liveness-wrapper`, sits between the parent and the real command. It is built as a standalone APE and its code is also reachable through a flag, `--liveness-wrapper`, so it is available in every APE. With `--assimilate --liveness-wrapper` it is extracted as a native executable for the current system. It is not built into redbean or lua. The flag works like `--assimilate` in that a normal run of the binary never sees it.

The parent spawns the wrapper with the real command as arguments. The wrapper spawns the real command with stdin, stdout and stderr inherited, so the output redirection and tmpfile machinery stays exactly as it is.

### Shared descriptor

Fd 3 in the wrapper is a socketpair end. The parent holds the other end, marked close-on-exec so no sibling child inherits it. Two pipes are the fallback if sockets on Windows behave badly. At startup the wrapper checks that fd 3 exists and is a connected socket, for example with `fstat` and a zero-timeout `poll` that must not report `POLLNVAL` or `POLLHUP`. It then marks fd 3 close-on-exec so the real command never gets it.

### Wrapper threads

Thread one calls `waitid` with `WEXITED|WNOWAIT` on the child. The zombie stays in place until the wrapper chooses to reap it. When `waitid` returns, thread one takes a mutex, reaps the child with `waitpid`, sets a done flag and unlocks. It then closes stdin, stdout, stderr and fd 3, in that order, and exits with the child's code. If the child died by a signal, the wrapper resets that signal to default and raises it on itself on POSIX systems, so the parent sees the same signal. On Windows it exits with a code derived from the child's status.

Thread two blocks in `poll` on fd 3 with no timeout. On EOF or hangup it takes the mutex, and if the done flag is clear it sends SIGKILL to the child, then unlocks. Thread one then wakes from `waitid`, reaps, and the wrapper exits. Because the zombie persists until thread one reaps it, and the done flag is checked under the mutex, the kill can never hit a reused pid.

Signals sent to the wrapper itself are forwarded to the child for SIGTERM, SIGHUP and SIGUSR1/2. Terminal-generated SIGINT and SIGQUIT reach the child directly because they go to the whole foreground group, so the wrapper ignores them to avoid delivering them twice.

### Parent side

`wait` polls the shared descriptor together with stdout and stderr, using the caller's timeout. Hangup on fd 3 means the wrapper exited. The parent then reads any remaining output and reaps the wrapper with a blocking `waitpid`. That wait is bounded because the wrapper is already exiting. On Linux the descriptor closes slightly before the zombie becomes waitable, so a non-blocking reap right after the hangup can miss, which is why the reap blocks. After a successful reap `p.pid` is set to nil, which is the only extra state the process object needs.

Spawn failure is reported through the shared descriptor. After `posix_spawn` the wrapper writes a small record containing zero or the errno, and the parent reads it with a short timeout inside `spawn`. This keeps the existing `nil, errno` return from `spawn`. If the wrapper cannot start the command it exits 127.

### GC and shutdown

Process GC does three things in order. It closes the shared descriptor. It calls `waitid` with `WNOHANG|WNOWAIT` on the wrapper pid. If the wrapper is still alive it waits a short bounded time for it to finish, then sends it SIGKILL as a last resort. Finally it reaps it with `waitpid`. Closing the descriptor already makes the wrapper kill the child and exit, so the SIGKILL fallback only matters for a stuck wrapper. Using `waitid` on a pid that is not our child fails with `ECHILD`, which makes a forked copy of the parent harmless and avoids needing an owner-pid field.

No signal hooks are needed for cleanup. If the parent dies by SIGTERM, SIGINT, SIGKILL, a crash or an out-of-memory kill, the kernel closes the parent's end of the socket and the wrapper kills the child. This holds on Linux, macOS, the BSDs and Windows, including `TerminateProcess`. This is the reason the old exit hooks, `killall`, the registry, the orphan sweep, DIEWITHPARENT and the NT job object can all be deleted.

`Process:kill(SIGKILL)` becomes "close the shared descriptor". Other signals go to the wrapper pid and are forwarded. On Windows the non-kill signals are best effort.

### What goes away

The `opts.sleep` option, the liveness constants, the extra liveness pipe, the busy-wait fallback, `hangup()`, `install_hooks`, `killall`, `children`, `orphans` and `sweep`, `diewithparent` in `lunix.c`, `POSIX_SPAWN_DIEWITHPARENT_NP`, and all the NT job object code.

## 5. Implementation plan

1. Revert the uncommitted DIEWITHPARENT and job object changes in `posix_spawn.c/.h`, `posix_spawnattr_setflags.c`, `master.sh`, `process.h`, the three kernel32 stubs, the struct and enum headers, and `lunix.c`.
2. Add `waitid` to libc with tests. Linux uses the `waitid` syscall. macOS has a `waitid` syscall. FreeBSD and NetBSD have `wait6`, and OpenBSD has neither, so the wrapper needs a documented fallback there. Windows copies the `wait4-nt.c` approach, waiting on the process handle and leaving it in the process table when `WNOWAIT` is given. Expose `unix.waitid` in lunix.
3. Write the wrapper in C, with a standalone build target, the `--liveness-wrapper` entry point in the APE startup path, and the `--assimilate --liveness-wrapper` extraction. Verify first which startup paths run the flag check, because native ELF, PE and Mach-O launches skip the shell stub that handles `--assimilate`.
4. Rewrite cosmo-spawn around the wrapper. Use one wait loop, one reap routine and one nap-free polling path. Locate the wrapper by explicit path (next to the running executable, or the running executable itself with the flag), never by `PATH`. Update the header docs and `help.txt` together, from one source.
5. Remove the dead pipe branch in `poll-nt.c`.
6. Switch `scripts/run_lua_tests.py` to `redbean.com -i` for every target.
7. Harden the ccw session file read, and fold duplicate session writes into one function.
8. Rebuild everything and run the suite on native, aarch64 under qemu, and wine.

### Tests to add

The parent being killed with SIGKILL must kill the child. Exit codes and signal deaths must propagate. A missing command must return the right errno from `spawn`. Starting the wrapper with a bad fd 3 must fail. A backgrounded grandchild holding stdout must not delay `wait`. A sibling spawned later must not inherit the parent's socket end. An idle wait must use almost no CPU. A forked copy of the parent must not kill or reap the original child. The `waitid` unit tests must cover `WNOWAIT`, `WNOHANG` and `ECHILD`.

## 6. Drawbacks and open questions

- The loader has no libc or threads, so it cannot run the wrapper itself. Embedding an APE inside the loader would require extracting it to disk on every system except Linux. Windows binaries do not use the loader at all. The plan therefore puts the flag in the APE startup path and keeps the standalone build as the extractable form. This needs confirming against `ape/ape.S` and the libc startup code.
- Every spawn adds one process start, about 4ms natively and 30 to 40ms under qemu or wine for a redbean-sized binary. A standalone wrapper is much smaller. Spawn also waits for the handshake.
- `p.pid` is the wrapper pid. Anything that signals or inspects it sees the wrapper, and `ps` shows an extra process.
- The wrapper kills the child with SIGKILL when the parent goes away, so the child gets no chance to shut down cleanly. A SIGTERM followed by a grace period is possible but was not chosen.
- If something kills the wrapper itself with SIGKILL, the child is orphaned. A new process group per child on Linux, or a job object on Windows, would narrow that and is left out for now.
- Descendants of the child, other than the child, are not killed.
- A missing `waitid` on OpenBSD means the wrapper falls back to a blocking `waitpid` with a tiny pid-reuse window.
- After the wrapper exits, the parent should read what output remains without waiting for EOF, since a grandchild may keep the pipe open.
- Windows `poll` still has a 10ms ceiling for pipes. Waiting on the socket removes the signal race, but the 10ms peek interval remains.
- The libc lost-wakeup window in `__sig_generate` is still a real bug for `sigsuspend`, `pause` and `nanosleep` on Windows. The fix is to record the pending bit first and then scan and wake, with a full fence on the waiter side. It is independent of this work.
- Decisions still open are whether cosmo-spawn should fail hard or fall back when the wrapper is missing (the plan assumes it fails hard), whether to replace `~/Tools/redbean.com`, and when to commit.
