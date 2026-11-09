# waitid based cosmo-spawn and ccw plan

This replaces `LIVENESS_WRAPPER_PLAN.md`. The wrapper, liveness fds, ppoll, pselect, SIGCHLD and kqueue ideas are all dropped. The whole design rests on one new primitive, `waitid` with `WNOWAIT`, which lets us see that a child has exited without reaping it.

## 1. Decisions taken

1. Add `waitid` to cosmo libc for every OS, plus `unix.waitid` in lunix.
2. No wrapper process. No liveness descriptor. No `DIEWITHPARENT` or job object code.
3. `Process:wait(timeout, sleepMs)` and `Process:exitValue()` never reap and never kill.
4. Reaping and killing happen in exactly one place, the GC finalizer, plus the signal and exit paths that call the same cleanup.
5. ccw polls only on claude's stdout, sends stderr to a temp file, and uses claude's partial messages.

## 2. Part A, waitid in libc

### API

```c
int waitid(idtype_t idtype, id_t id, siginfo_t *info, int options);
```

`idtype` is `P_ALL`, `P_PID` or `P_PGID`. Options are `WEXITED`, `WSTOPPED`, `WCONTINUED`, `WNOHANG` and `WNOWAIT`. On success with `WNOHANG` and no child ready, return 0 with `info->si_pid == 0`. It is a cancelation point and async signal safe, like `wait4`.

The constants `WEXITED`, `WSTOPPED` and `WNOWAIT` already exist in `libc/sysv/consts.sh` for every OS. We need to add `P_ALL`, `P_PID`, `P_PGID` (check they exist, otherwise add to `consts.sh`) and `WCONTINUED` if absent.

### Per OS strategy

| OS | Approach |
|---|---|
| Linux x86_64 and aarch64 | `sys_waitid` already exists in `syscalls.sh` (0xf7 and 0x5f). Call it directly. |
| macOS | `sys_waitid` also has an XNU ordinal (0x20000ad, 0xad). Call it, then convert siginfo with the existing `siginfo2cosmo`. |
| FreeBSD | No waitid syscall. Enable the commented out `wait6` entry in `syscalls.sh` (ordinal 0x214) and build waitid on it. It returns a status int and a `siginfo_t`. |
| NetBSD | Same, `wait6` at 0x1e1, with `WNOWAIT` 0x10000 and `WEXITED` 32. |
| OpenBSD | No `waitid`, no `wait6`, no `WNOWAIT`. `waitid` returns `ENOSYS`. |
| Windows | Copy the `libc/proc/wait4-nt.c` pattern, see below. |

New files, following the repo's style. `libc/calls/waitid.c` (dispatcher and docs), `libc/calls/waitid.h` or an addition to `siginfo.h`, `libc/proc/waitid-nt.c`, and `libc/calls/waitid-sysv.c` for the BSD wait6 translation.

### Windows (`waitid-nt.c`)

`__proc_wait` already finds the `struct Proc` for a pid, bumps `pr->waiters` so the proc daemon stops zombifying it, and sleeps on `WaitForMultipleObjects({pr->handle, event})` so signals and cancelation wake it. The new version shares that skeleton and differs in two places. When a zombie is found and `WNOWAIT` is set, fill in `siginfo` from `pr->wstatus` and return without calling `__proc_reap`, so the entry stays in `__proc.zombies`. When the process is still alive and `WNOHANG` is set, return 0. Care points are the `waiters` count (it must be decremented on every exit path, including the non-reaping one, otherwise the daemon never reaps the entry), and the `haszombies` event, which must not be reset by a non-reaping peek. Without `WNOWAIT` it reaps exactly as `wait4` does. Factor the shared pieces out of `wait4-nt.c` rather than duplicating them.

### OpenBSD

`waitid` returns `ENOSYS`. cosmo-spawn on OpenBSD therefore cannot wait, and `spawn` itself should fail early with a clear error (decided, no cache fallback). The tests skip the OpenBSD cases and the docs say so.

### siginfo translation

`si_pid`, `si_status`, `si_code` (`CLD_EXITED`, `CLD_KILLED`, `CLD_DUMPED`) and `si_signo` (`SIGCHLD`) are the only fields we guarantee. For BSD and macOS use `siginfo2cosmo`. For the Windows and OpenBSD paths build the struct from a wait status. A shared helper `__wstatus2siginfo(int ws, int pid, siginfo_t *)` serves wait6 and Windows.

### lunix

`unix.waitid(pid [, options])` returns `pid, code, status` on a ready child, `0` (or `nil`, matching how `unix.wait` reports it, to be checked against `LuaUnixWait` at `third_party/lua/lunix.c:919`) when `WNOHANG` finds nothing, and the usual `nil, errno` on error. Expose `unix.P_ALL`, `P_PID`, `P_PGID`, `WEXITED`, `WSTOPPED`, `WCONTINUED`, `WNOWAIT`, `CLD_EXITED`, `CLD_KILLED`, `CLD_DUMPED`. Update the `help.txt` entries for lunix.

### Tests for Part A

C tests in `test/libc/calls/waitid_test.c` and, where Windows behaves differently, `test/libc/proc/`. Cases are the following.
1. Child exits with 7. `waitid(P_PID, pid, WEXITED|WNOWAIT)` returns 0 with `si_code == CLD_EXITED`, `si_status == 7`, `si_pid == pid`. Calling it again gives the same answer. Only then `waitpid` reaps with status 7, and a third `waitid` fails with `ECHILD`.
2. Child killed by SIGKILL gives `CLD_KILLED` and `si_status == SIGKILL`. A Windows child ended with `TerminateProcess` has no signal, so assert only that it reports an exit, and document the mapping.
3. `WNOHANG` on a live child returns 0 with `si_pid == 0`. After it exits, it returns the pid.
4. Without `WNOWAIT`, a single `waitid` reaps, and a second gives `ECHILD`.
5. `waitid` on a pid that is not our child returns `ECHILD`, including after `fork` in the child process.
6. Blocking `waitid` is interrupted by a signal handler with `EINTR`, and is woken by `pthread_cancel`.
7. Bad `idtype`, null info, and options without `WEXITED` return `EINVAL`.
8. Two threads blocked in `WNOWAIT` waitid on the same pid both wake on exit (the Windows `waiters` bookkeeping), and a later `waitpid` still reaps once.
9. Lua level, `test/tool/net/unixwaitid_test.lua` covering the same through `unix.waitid`.

## 3. Part B, cosmo-spawn changes

### Removed

`diewithparent` option use, the DIEWITHPARENT and job object changes in `libc/proc`, `libc/nt` and `lunix.c` (a straight revert of the staged and unstaged work listed in `git status`), the liveness pipe and fd 3 plumbing, `opts.sleep`, the `liveness` field, the `hangup` machinery, the `orphans` table and `sweep`, and the "wait drains pipes while sleeping" logic. The existing tmpfile and pipe stdout and stderr handling stays as it is.

### New wait API

```lua
p:wait(timeout, sleepMs)  -- ms
p:exitValue()             -- p:wait(0, 0)
```

Both return `code, signal`. A normal exit gives `code, nil`. Death by a signal gives `128 + signal, signal`, so scripts that only look at the first value get the shell convention, and scripts that care check the second value to tell a real exit of 143 from SIGTERM. A process that is still running gives `-1, nil`. On Windows a child ended by `TerminateProcess(handle, sig)` already reports as signaled with `sig` in cosmo, so the same shape applies.

| timeout | behavior |
|---|---|
| negative | block in `waitid(P_PID, pid, WEXITED|WNOWAIT)` until the process stops, then return `code, signal` |
| 0 | one `waitid` with `WNOHANG|WNOWAIT`, return `code, signal` or `-1` if still running |
| positive | loop on `WNOHANG|WNOWAIT`, `nanosleep` for `sleepMs` between looks, stop at the deadline, return `code, signal` or `-1` on timeout |

Details to pin down.
- The deadline uses `CLOCK_MONOTONIC`, and the final sleep is clamped to the time remaining. `sleepMs` defaults to 10 when omitted, 0 means spin without sleeping, and values are validated like the existing numeric options (reject NaN and infinities, allow fractions).
- Mapping as above. `-1` is returned only for a live process, since a real exit code is 0 to 255 and the signal form is above 128.
- `EINTR` during the blocking form. Lunix runs Lua signal handlers after an interrupted call, so the loop retries after the handler returns unless the handler raised an error.
- `ECHILD` raises a Lua error ("not a child of this process"), decided. The cosmo-spawn API is only for children, so a forked copy using an inherited Process, or a process already reaped, is a programming error and is never confused with `-1`. Cleanup (below) never raises this error, it treats `ECHILD` as "nothing to signal".
- No user API reaps. That includes `readStdout`, `readStderr` and `closeStdin`, which must not touch the pid. A zombie lives until GC, which is the stated behavior.
- Output handling changes. Tmpfile mode is unaffected, since the child writes to a file. Pipe mode used to be drained inside `wait`, and now it cannot be, because `wait` only waits. A child that fills a pipe blocks until the caller reads. `readStdout(max, timeoutMs)` and `readStderr(max, timeoutMs)` gain the timeout, decided. Without it they behave as today. With it they wait up to that many milliseconds for data (a poll inside the module, so callers never see a descriptor), and return the data, an empty string with a second value of `'timeout'` when nothing arrived, or `nil` at EOF. This is also how ccw learns that stdout closed. Tmpfile mode accepts the argument too, and returns at once since a file is always readable. The docs say callers using pipes must read while waiting. ccw does that, by design, in Part C.
- `p:kill(sig)` is removed, decided. The Lua API stays high level with minimal exposure of system calls. Signals are sent only by GC cleanup and the signal handlers. Tests and ccw that used `kill` switch to GC, or to `unix.kill` on the pid in test code only. The documented `p.pid` field stays so tests can do that.

### GC

Fields set at spawn on the process object, `shutdownTimeoutMs` and `shutdownSleepMs`, from `opts.shutdownTimeout` and `opts.shutdownSleep`. Defaults are 10 and 10 (decided), because the timeout is spent at GC time, where a stall freezes the whole Lua program. Callers that want a graceful shutdown for something slow raise it per spawn.

```
__gc(p):
  pcall(function()
    close stdin, stdout and stderr pipe ends   -- first, so a child blocked
                                               -- writing gets SIGPIPE
    r = waitid(P_PID, pid, WEXITED|WNOHANG|WNOWAIT)
    if r is ECHILD: return                     -- not ours, touch nothing
    if r says still running:
        kill(pid, SIGTERM)
        if wait(p.shutdownTimeoutMs, p.shutdownSleepMs) == -1:
            kill(pid, SIGKILL)
            waitid(P_PID, pid, WEXITED|WNOWAIT)   -- blocking, SIGKILL cannot be ignored
    waitid(P_PID, pid, WEXITED)                -- reap, no WNOWAIT
    remove tmpfiles
  end)
```

There is no state flag, no record and no registry. One Process object owns one child, and Lua runs a finalizer at most once per object, including when `lua_close` finalizes everything at exit and including when that happens from inside a signal handler that interrupted another finalizer (the object whose finalizer is running is already off Lua's finalization list, so it is not finalized again). The SIGTERM is sent only after `waitid` has positively said "our child, still running", so a forked copy (which gets `ECHILD`) signals and reaps nothing, with no owner-pid field. Exceptions in `__gc` must never escape, hence the `pcall`. `__close` is not provided, since it would be a second path to the same cleanup, and the user surface has no explicit close.

### Signals and exit

Goal, children are cleaned up when Lua dies by SIGTERM, SIGINT or SIGHUP, and on every normal or `os.exit` exit, using nothing but the finalizers. The trick is that `os.exit(code, true)` calls `lua_close`, and `lua_close` runs the finalizer of every object that has one, reachable or not. So a signal handler only has to exit with the close flag set, and every live Process is cleaned by its own `__gc`.

- On the first `spawn`, install handlers for SIGTERM, SIGHUP and SIGINT with `unix.sigaction`. Each handler calls `os.exit(128 + sig, true)`. Exit status is the shell convention for death by that signal. (An optional refinement, a sentinel object created first whose finalizer runs last and re-raises the signal with the default disposition, gives a true signal exit status. Not planned unless you want it.)
- Check before installing, and raise an error rather than replace anything, decided. cosmo-spawn is for simple scripts. If SIGTERM or SIGHUP already has a handler, `spawn` raises (this is what happens inside the redbean server, which installs C handlers for SIGINT, SIGHUP, SIGTERM and SIGCHLD in `SigInit`). If SIGINT already has a Lua function handler, it raises. If SIGCHLD is set to ignore, it raises (the kernel would reap children itself and `waitid` would report `ECHILD`), so never set SIGCHLD to ignore with this tool, which goes in the docs.
- SIGINT needs care. I ran `redbean.com -i` and found that in script mode SIGINT already holds a handler, `laction`, which is Lua's standard Ctrl-C hook (it turns Ctrl-C into an "interrupted!" error at the next Lua instruction). A "must be default" check on SIGINT would therefore reject every script. So SIGINT is checked only for a Lua function handler, and our handler replaces `laction`, which also matters because `laction` would not wake a thread blocked in `waitid` if the call is restarted.
- Lunix delivers Lua handlers at safe points after a syscall returns `EINTR`. The blocking `waitid` and the `nanosleep` in the busy loop both return `EINTR`, so a handler runs promptly while we wait. A Lua loop doing pure computation with no syscalls would delay it, which is acceptable.
- A terminal Ctrl-C also reaches the child directly, because it shares the foreground process group. The cleanup then finds it already dying, and the SIGTERM is harmless.
- `os.exit` and `unix.exit` do not close the state by default (`os.exit(code)` skips finalizers, `unix.exit` skips even atexit). cosmo-spawn wraps both so that they always close the state first, which runs the finalizers. Falling off the end of the script closes the state anyway. A forked copy that exits does the same, its finalizers find `ECHILD` and touch nothing.
- Limit that must be documented, SIGKILL, OOM kill, a crash, and Windows `TerminateProcess` of Lua cannot run any handler, so the children are orphaned. Accepted.
- On Windows the same handlers apply. `kill(pid, SIGTERM)` from another cosmo process works there, it sets a bit in the target's shared memory signal file (`__sig_map_process` in `libc/proc/kill-nt.c`), so the test can send it from a second redbean process under wine. On a cosmo child the SIGTERM during cleanup is a real catchable signal. On a non-cosmo child it terminates immediately, so the graceful phase is a no-op for those.
- Blocking waits on Windows (`wait(-1)`) rely on `WaitForMultipleObjects` over `{process handle, signal event}` in `libc/proc/wait4-nt.c`, which the new `waitid-nt.c` copies. A process that is already dead has a signaled handle, so the call returns at once (and `__proc_check` finds an already harvested zombie before blocking at all), so waiting after a kill is fine. A separate race exists between a signal arriving and the waiter registering its event (`__sig_generate` in `libc/intrin/sig.c` scans for blocked threads before it sets the pending bit). If the Windows signal test hangs, the fix is a bounded wait slice (about 100ms) in `waitid-nt.c`, or reordering that code, and that decision waits for the test result.

### Cleanups included

Remove the dead `if (avail)` branch in `libc/calls/poll-nt.c`. Keep the 10ms pipe peek, it is still correct for `poll`. Update the header docs of `cosmo-spawn.lua` and `tool/net/help.txt` from one source of truth, since they drifted earlier.

## 4. Part C, ccw

Current behavior, `p:wait(50)` with pipes for stdout and stderr, then everything is read after exit, and the `Clauding...` dots redraw between waits.

### What `claude --help` and a live run showed (claude 2.1.319)

Streaming needs `--output-format stream-json --include-partial-messages` and, in print mode, `--verbose`. The help says partial messages only work with `--print` and `stream-json`. A real run with those flags gave one JSON object per line, in this order. `system` (init, status), then `stream_event` objects (`message_start`, `content_block_start`, several `content_block_delta` with `delta.type == "text_delta"` and `delta.text`, `content_block_stop`, `message_delta`, `message_stop`), a full `assistant` message, a `rate_limit_event`, and last a `result` object with `subtype`, `is_error`, `result` and `session_id`. stderr stayed empty on success. Deltas are small and arrive within a fraction of a second of each other, and the text that streamed equals `result` for a one-message turn.

Consequences for the design.
- Only `text_delta` is printed. `thinking_delta`, `input_json_delta`, hook events and the rest are ignored, and unknown event types are skipped, never fatal.
- A turn that uses tools produces several messages and text blocks. Each `content_block_start` of type text after earlier printed text gets a newline separator, so blocks do not run together. `result` holds only the final message, so printing both the streamed text and `result` would duplicate it. Rule, print `result` only when no text was streamed, otherwise just finish the line.
- Errors can arrive as a `result` with `is_error == true` and a nonzero exit, or the process can die with nothing on stdout. Both go through the failure path below.
- The session id comes from the `result` event, as it does from the JSON object today, and is validated before being saved.
- One thing worth watching in implementation, a very long single line (a big `assistant` event) must not be rejected by a line cap that is too small. Use a generous cap (say 16MB) and fail the run, with a message, if exceeded.

### New behavior

1. Spawn `claude -p <prompt> --output-format stream-json --include-partial-messages --verbose --permission-mode=<mode> [--resume=<id>]`. The prompt keeps its existing "prompt" prefix guard.
2. `stdin = 'null'`, `stdout = 'pipe'`, `stderr` to the cosmo-spawn temp file default, so claude can never block on a full stderr pipe.
3. Loop.
   - `p:readStdout(65536, 100)`, which waits on stdout only for up to 100ms (the redraw cadence) and returns data, `'timeout'` or `nil` at EOF. ccw never touches a descriptor.
   - On wake up, append to a line buffer, and handle every complete line. Do the redraw and partial printing first.
   - Then check termination. Break only when `p:exitValue() ~= -1` and stdout is closed (`readStdout` returned `nil`). Requiring both means the last bytes are never lost to a race between exit and the pipe closing, and a grandchild holding the pipe open does not hang us once we also see the exit... if the process has exited but stdout stays open for more than a short grace period (500ms of empty polls), break anyway, drain, and note it in a debug-level comment. Please say if you would rather wait forever.
4. Display. Dots animate while no text has arrived and while the stream is quiet. The first delta clears the dots line with `\r\27[K` and prints sanitized text. When we have printed a partial and then go quiet (no delta for 400ms, decided, so it does not flicker between close-together deltas), print a newline if the partial did not end with one, then show `Clauding` again. The next delta clears it again. Text goes through `strip_controls` in whole-line or flush-interval chunks, so a split escape sequence never reaches the terminal raw.
5. Not a tty, no animation. Text is written as it arrives to ccw's usual output stream, to be preserved by the tests.
6. Failure path, decided. If claude exits nonzero, or the final result has `is_error`, ccw reads the whole stderr temp file and writes its contents to the Lua process's own stderr (sanitized with `strip_controls`, since it is untrusted child output going to a terminal). The error text from the `result` event follows it, then ccw exits with claude's exit code, `128 + signal` if it died by a signal (using the second return value), or 1 if the code is zero but the result was an error. The file read has a size cap so a runaway stderr cannot exhaust memory, with a "truncated" note. When `soft` is set, ccw still prints the stderr and returns nil as it does now.
7. The id file read gets a size cap (the open FIFO hang item from review), fixed in the same change.
8. ccw's own SIGTERM and SIGINT handling is replaced by the library behavior in Part B. Remove the duplicate code.
9. notify-mcp and the test runner move to the new API where they call `wait`.

## 5. Part D, tests

### Lua unit tests (`test/tool/net/cosmo_spawn_test.lua`)

Rewrite the wait related and liveness related sections and keep the rest. New and changed cases:
- `exitValue()` is `-1` while a `sleep 5` child runs, and the real code afterward. Repeated calls keep returning it, with no change in `/proc/<pid>` state (zombie remains on Linux, which the test asserts by reading `/proc/<pid>/stat` for `Z`).
- `wait(-1)` blocks until a child that sleeps 1 second exits and returns 0. Measure elapsed time, and measure CPU time with `getrusage` to prove it is blocked, not spinning.
- `wait(0)` returns immediately. `wait(200, 20)` on a 5 second sleeper returns `-1` after roughly 200ms and uses a bounded number of wakeups (count with a monkeypatched sleep or assert CPU time).
- `wait(timeout, 0)` spins and still works, with a short timeout.
- Signal death returns `128 + n, n`, and a program that itself exits 143 returns `143, nil`.
- Kill then wait. A child is killed (SIGKILL through `unix.kill(p.pid, 9)` in test code), and then `wait(-1)` returns at once with `137, 9`. Also a child that exited long before `wait(-1)` is called. Runs on Windows too, where the child is ended by `TerminateProcess`.
- `readStdout`/`readStderr` with timeouts, `'timeout'` on a silent child, data as soon as it arrives, `nil` at EOF, and argument validation.
- Calling `wait` or `exitValue` on a reaped or forked-copy Process raises the "not a child" error and never returns `-1`.
- SIGCHLD set to ignore makes spawn raise. So does an existing SIGTERM or SIGHUP handler, and an existing Lua SIGINT handler, and a plain `redbean -i` script (SIGINT at `laction`) does not.
- Cleanup closes pipes first. A child blocked writing to a full pipe, whose SIGTERM is ignored, still dies from SIGPIPE before the timeout.
- Pipe mode, a child writing 1MB with a reader loop that polls and calls `exitValue`, finishes with all bytes. Without a reader, `exitValue` stays `-1` (documented blocking behavior).
- GC. A child `sleep 30` goes out of scope, `collectgarbage()` runs, and the process is gone and reaped (`kill(pid, 0)` fails with `ESRCH`) within the shutdown timeout. A child that traps SIGTERM and exits in 100ms shows the graceful path (its handler writes a marker file, create based as in my memory note). A child that ignores SIGTERM is killed after `shutdownTimeout`, measured. Both timeouts are checked using small values.
- Forked copy. After `unix.fork()`, the forked copy's `exitValue` raises, and its cleanup (explicit, GC, and through `os.exit`) does not signal or reap the real child. The parent still sees the right exit value.
- Reentrancy. A SIGTERM delivered while a `__gc` waits out its shutdown timeout makes the handler exit with the close flag, and each child is cleaned exactly once, including the one whose cleanup was interrupted. This is the test that confirms Lua tolerates `lua_close` from inside a running finalizer. If it does not, the fallback is a one-line flag that the handler sets and the wait loop checks.
- Signals. A subprocess Lua script spawns a long child, writes the child's pid to a file, then blocks in `wait(-1)`. The test sends SIGTERM, then separately SIGINT and SIGHUP, to the script and asserts that the script exited with status `128 + signal`, and the child pid is gone. Repeat with the script busy in the timed loop, and with it in `readStdout`. A SIGKILL case documents the orphan, and is marked as expected.
- A pre-installed SIGTERM handler makes `spawn` raise, and leaves the handler untouched.
- `os.exit`, `os.exit(code, true)`, `unix.exit`, an uncaught error and falling off the end, each with live children, clean them up.
- Spawn failure, a missing program still returns `nil, errno` (unchanged).
- Validation of `wait` arguments (strings, NaN, huge values, negative sleep).
- Descriptor count baseline before and after many spawns and collections, to prove nothing leaks.

### ccw tests

The ccw tests live under `~/Projects/work/` next to ccw, as Lua tests (for example `~/Projects/work/ccw_test.lua`, with fixtures beside it), not in the cosmopolitan repo. They run with the freshly built redbean (`redbean.com -i ccw_test.lua`) and drive ccw as a subprocess through cosmo-spawn.

These tests run only on the current system (x86_64 native here), not under qemu aarch64 or wine, decided.

A fake `claude` script on `PATH` (a shell or Lua script that prints canned stream-json events with delays, and also variants that exit nonzero, print to stderr, emit a partial then stall, emit control characters, and emit a final result with an invalid session id). Assertions run against ccw's captured stdout and stderr.
- Fake events follow the real shapes captured above (saved as fixtures next to the ccw tests), including a tool turn with two text blocks, a `thinking_delta`, an unknown event type, and a result-only run. Partial text is printed in order, `Clauding` is erased before it and resumes after it.
- A final-only response with no partials still prints correctly.
- Escape sequences in model text are stripped.
- On failure, the stderr temp file contents appear on ccw's stderr (including a variant with control characters and one larger than the cap), then the result error text, with claude's exit code propagated, and no hang when the fake claude exits while stdout is still held open by a grandchild (the exit and EOF both-required check is exercised by a variant that closes stdout early and one that exits before the final flush).
- SIGTERM and SIGINT to ccw kill the fake claude.
- Session id file handling, FIFO and oversize input.
- CPU use during a 3 second idle stall is under a small threshold.

### Platforms

Everything runs through `scripts/run_lua_tests.py` (switched to launch `redbean.com -i` as planned, so we test the real binary) and the C tests through the repo's normal `make` targets.

| Platform | How |
|---|---|
| x86_64 native | Direct, full suite |
| aarch64 | qemu-user, the libc, lunix and cosmo-spawn suites, no ccw. `waitid` uses the Linux arm64 syscall, so this exercises the syscall numbering |
| Windows | wine, the `waitid`, posix_spawn and cosmo-spawn tests only, no ccw. Known wine gaps (the existing `KNOWN_SKIPS` for `lunix_test`) stay skipped. The kill-then-wait test and the SIGTERM test (sent by `kill` from a second redbean process to a redbean script process) are in the must-pass list |

Runs are sequential, to avoid the "Text file busy" problem seen earlier. ccw tests run natively only, through `redbean.com -i`.

Not testable here, macOS, FreeBSD, NetBSD, OpenBSD (which only returns `ENOSYS`). The fat build compiles them. You will test macOS yourself later, and the commit message says those paths were built but not run. No BSD VM work is planned.

## 6. Order of work

1. Revert the DIEWITHPARENT and job object work (staged and unstaged). Rebuild, run the existing tests as a baseline.
2. `waitid` in libc for Linux, then macOS, then BSDs, then Windows, with C tests after each. Run x64 and qemu aarch64 as it goes, wine after the Windows piece.
3. `unix.waitid` and its Lua test, help text.
4. cosmo-spawn rewrite, wait API, GC, signal and exit handling, with its tests.
5. ccw rewrite with fake claude tests. Confirm the real stream-json event shape with one live call first.
6. Remove the `poll-nt.c` dead branch, update docs, run the whole matrix, delete stray repo-root test directories.
7. Review pass (concurrency, security, duplicate code), then rebuild everything from scratch and rerun the matrix.

## 7. Risks and open questions

1. Orphans on a hard kill of Lua are accepted, see Part B. Nothing on Linux or macOS could fully prevent it anyway.
2. A possible Windows signal wakeup race while blocked in `waitid`, see Part B. It is decided by the test result.
3. OpenBSD has no `waitid`, so cosmo-spawn does not work there. None of the BSD or macOS code can be run here.
4. Pipe mode semantics change, since `wait` no longer drains. Existing callers (notify-mcp passes `stdout = 'pipe'` removed already) need a check.
5. Zombies stay until GC, so a long running Lua program that spawns many short jobs and keeps the objects alive holds pids. Document, or add an explicit `close` later.
6. `p:kill` is gone and `wait` now returns two values and `exitValue`/`wait` raise on non-children, so external callers (notify-mcp, the test runner, ccw) need updating.
7. `~/Tools/redbean.com` is an old build, and I will not replace it without your approval.
8. Public facing docs and help text need a review by the product or docs owners before any external use, and the cosmo-spawn behavior notes should be verified against the current build.

## 8. As built, differences from the plan above

- `readStdout(n, timeout)` and `readStderr(n, timeout)` return the data, an empty string at end of file, or `false` when the time ran out. (The plan said `nil` at end of file. An empty string was already the end of file answer, so that stays.)
- Lunix runs a Lua signal handler inside the C signal handler, wherever the script happened to be, not at a safe point. Calling `os.exit(code, true)` from there is unsafe (one full test run deadlocked in it, inside the allocator or the collector). The handler therefore only calls `debug.sethook` with a pre-made function, and that hook closes the state at the next instruction of the script. Lua does not run hooks during a finalizer, so a collection that is reaping a child always finishes first. This replaced an earlier `sigprocmask` design.
- On Windows the `WEXITED`, `WSTOPPED` and `WNOWAIT` constants had the value 0, which made `WNOWAIT` impossible to test for. They now have the Linux values on Windows.
- `waitid()` on Windows rejects `P_PGID`, `WSTOPPED` and `WCONTINUED` with `EINVAL`.
- The tests found that a forked child that calls `usleep` crashes on wine, in `QueryUnbiasedInterruptTimePrecise`. Not caused by this work. The tests avoid sleeping in forked children, and use a pipe to hold them instead.
- `kill(pid, 0)` and even `kill(pid, SIGKILL)` cannot tell a live process from a dead one on Windows and wine, so the tests use a heartbeat file written by the children there.
- `scripts/run_lua_tests.py` already ran the tests with `redbean -i`, so it only gained the new test files. Its `o/lua.com` coupling is unchanged.
- `futex_test.lua` failed on wine in one full run and passed on every rerun, with and without the `poll-nt.c` change, so it looks load dependent.
- ccw prints partial text to stdout, the `Clauding` dots go to stderr, and the stderr of claude goes to the temporary file. ccw's tests are `~/Projects/work/ccw_test.lua` and run on this machine only.
- `p:close()` and `__close` were added later, with a `closed` flag. Once an explicit close can run before collection, a second cleanup could signal or reap a reused pid, so the flag is needed after all, and the earlier "no state" argument only held while collection was the single path. Every method but close raises "process is closed" afterwards. `close()` returns the final code and signal, or nothing when there is no status.
