# Shell free process spawning for redbean

Status. Built and tested on this checkout, uncommitted. The tests pass on
Linux x86_64 (72 of 72), on aarch64 under `qemu-aarch64` (72 of 72) and on
Windows under `wine` (68 of 68, where four cases that need a real `touch`
are skipped). See "What was verified" and "Reverting" at the bottom.

## Goal

Give redbean a process API that works the same on every platform
cosmopolitan supports and that is hard to misuse. Lua's `os.execute` and
`io.popen` hand a single string to a shell, so any untrusted text that
reaches the string can run arbitrary commands. `posix_spawn` takes the
program and its arguments as separate values and never involves a shell,
which removes that whole class of bug. Cosmopolitan already implements it
on Windows, where `fork` is slow and `exec` has no equivalent, so one Lua
API covers all of them.

## Two layers

The work is split on purpose. The C layer is the smallest thing that
exposes the libc calls and trusts its caller completely. A Lua layer on top
adds the safety, the pipes and the lifetime management. Everything that
could be done in Lua is done in Lua.

The C layer is two functions in `third_party/lua/lunix.c`, so they sit in
the `unix` module next to `fork` and `execve`.

```
unix.posix_spawn(prog[, args, env, opts])   --> pid | nil, Errno
unix.posix_spawnp(prog[, args, env, opts])  --> pid | nil, Errno
```

`args` and `env` are string lists and default the same way `unix.execve`
does, `{prog}` and the current environment. `opts.actions` is an ordered
list run in the child before the program starts, with entries
`{"dup2", fd, newfd}`, `{"close", fd}`, `{"open", fd, path, flags[, mode]}`
and `{"chdir", path}`. Order matters, so it is a list and not a table.
`opts` also takes `pgroup`, `setsid`, `sigmask` and `sigdefault`. The raw
call does no validation of `args` or `env`. A non string entry is
undefined behavior, and the caller owns every descriptor it opened and the
child it started. The help text says so in a warning.

The Lua layer is `tool/net/.lua/cosmo-spawn.lua`, shipped in redbean's zip
store the way `cosmo-lfs.lua` is and loaded with `require 'cosmo-spawn'`.
Only redbean gets it. `lua.com` links the same `lunix.c` so it carries the
two C functions, but nothing there depends on them.

## Why the C part cannot be Lua

A spawned child can only be set up through the file actions and attributes
that `posix_spawn` accepts. Lua has no hook between fork and exec, so
redirecting a pipe onto descriptor 1 has to be described to C as a `dup2`
action. That is the only reason the options table has an action list.
Pipes, `poll`, `read`, `write`, `wait` and `kill` already exist in `unix`,
so every convenience feature is plain composition.

## The wrapper

```lua
local spawn = require 'cosmo-spawn'
local p = assert(spawn.spawn({'sort', '-r'}, {search = true}))
p:writeStdin('a\nb\nc\n')
p:closeStdin()
print(p:readStdout())   --> c\nb\na\n
print(p:wait())         --> 0
```

`spawn.spawn(argv[, opts])` returns a process object, or `nil` and a
`unix.Errno` when the program cannot start. Invalid arguments raise an
error instead, since they are caller bugs that do not depend on the
environment. The object has `pid`, `writeStdin`, `closeStdin`,
`readStdout`, `readStderr`, `wait` and `kill`. `closeStdin` was not asked
for but is needed, because programs like `sort` and `cat` never finish
without end of file on their input.

Reads go to end of file by default and take an optional byte count for a
single bounded read. `wait` returns the exit code, plus the signal number
when the child was killed, in which case the code is 128 plus the signal
as a shell would report it. `wait(true)` returns `false` while the child
still runs. Options are `search`, `path`, `env`, `cwd`, `stdin`, `stdout`
and `stderr`. The three streams are pipes by default and can instead be
`'null'` or `'inherit'`, and `stderr` can be `'stdout'`.

### What the wrapper refuses

`argv` must be a non empty plain list of strings with no NUL bytes and a
non empty first entry. `env` entries must look like `K=V`, or be a map
whose keys have no `=`, and the environment is empty unless the caller
passes one, so `unix.environ()` is an explicit act. `$PATH` is only
searched when `search = true`, so the default cannot be steered by a
variable. A string such as `"touch foo && /bin/sh -c 'touch bad'"` is
just a program name that does not exist. A separate `path` option lets the
executable differ from `argv[1]`, so `argv[0]` spoofing is possible but
only on purpose.

### Descriptors and deadlocks

Every pipe is created with `O_CLOEXEC`, so nothing leaks into the child
except the three descriptors that are dup2ed onto 0, 1 and 2. A pipe end
that would land on a descriptor from 0 to 2, because the parent had closed
one of its own, is first moved above 2 so it cannot collide with the dup2
targets. Every blocking call polls all open pipes together and moves
whatever arrives into memory. Reading stdout while the child floods
stderr, or writing a megabyte to `cat` while it echoes it back, therefore
cannot deadlock. The price is that output nobody reads accumulates until
the object is collected. `writeStdin` only writes in pieces of
`PIPE_BUF` after `poll` says the pipe is writable, which guarantees a
write never blocks.

### Cleanup

The object's `__gc` closes its descriptors and sends `SIGKILL` to a child
that has not been reaped, then tries one non blocking `wait`. If the child
is not yet reapable its pid goes on an orphan list that every later spawn
sweeps, so zombies do not pile up. Nothing in collection waits, so neither
GC nor shutdown can block.

Shutdown works because redbean's `atexit` handler calls `lua_close`, which
runs every pending finalizer. Two things skip it. `unix.exit` is `_Exit`,
so a script that ends that way, which includes a forked worker, leaves its
children running. And a `SIGKILL` of redbean itself cannot be handled. Both
are noted in the help text and the module header.

Loading the module sets `SIGPIPE` to ignored if it was still the default.
Redbean's server already does this, but a script run with `-i` does not,
and on Windows a write to a pipe whose reader died killed the whole
process before this was added. After it, `writeStdin` returns an error.

## Files

`third_party/lua/lunix.c` gets about 150 lines, the two functions plus an
action helper and two table entries. `tool/net/.lua/cosmo-spawn.lua` is
new. `tool/net/BUILD.mk` adds the Lua file to the redbean and
redbean-demo zip lists and to the `-C2` zip flag rule, mirroring
`cosmo-lfs.lua`. `tool/net/help.txt` documents both layers.
`test/tool/net/cosmo_spawn_test.lua` and `test/tool/net/cosmo_spawn_helper.lua` are
the tests. `o/redbean.com`, which is tracked, is rebuilt as a fat binary.

## Tests

The suite is `test/tool/net/cosmo_spawn_test.lua`, run as
`redbean -i test/tool/net/cosmo_spawn_test.lua`. Windows has no `touch`, `cat`
or `sort`, and an aarch64 build under qemu should not depend on host
tools either, so the child program is redbean itself running
`test/tool/net/cosmo_spawn_helper.lua`. The helper has small modes named
`argv`, `touch`, `cat`, `sortr`, `env`, `exit`, `stderr`, `flood`, `sleep`
and `pid`. The same file therefore runs unchanged everywhere. It exits
through `os.exit(code, true)` because `unix.exit` would skip the state
close that the cleanup depends on. Everything is created in a fresh
directory named from the pid and the clock, and removed at the end.

The suite covers the raw calls (each action type, bad action, missing
program, exit code), argument validation, behavior (stdin and stdout, stderr
capture and merge, null streams, env as list and map, exit codes, a
megabyte round trip, bounded reads, flooding, kill and signal status,
`wait(true)`, writing to a dead child), collection (a garbage collected
child is killed and reaped, descriptors are not leaked) and shutdown (a
grandchild started by a redbean that then exits is dead afterwards, and
exit did not block).

### Malicious input

These cases run on every platform. They all assert that nothing named
`bad-stuff.txt` appears, either in the test directory or the working
directory.

The argv `touch foo && /bin/sh -c "touch bad-stuff.txt"`, written as the
list `{"foo", "&&", "/bin/sh", "-c", "touch bad-stuff.txt"}`, arrives at
the child as five separate strings, byte for byte. Run through the touch
helper, with `/bin/sh` swapped for a name inside the sandbox since the
helper really opens its arguments, it makes five literal files named
`foo`, `&&`, `x-sh`, `-c` and `touch bad-stuff.txt` and runs nothing.

The single string `touch foo2 && /bin/sh -c 'touch bad-stuff.txt'` cannot
be launched as a program, with or without `search`, and cannot be given as
`path`. As an argument it is one argument, and touching it creates nothing
because it contains slashes.

Substitution and redirection syntax is inert in arguments and in the
environment. The cases are `$(...)`, backticks, `;`, `|`, `>`, quotes,
`%PATH%` and `*`.

On systems that have a real `touch`, and when not running as root, the
same attack is also run against it. GNU touch permutes its arguments and
would treat the trailing `-c` as an option, so those cases set
`POSIXLY_CORRECT` to keep the arguments literal. The real touch then makes
`foo`, `&&`, `-c` and `touch bad-stuff.txt` and still no `bad-stuff.txt`.
Root skips these because the argument `/bin/sh` is a real path.

## What was verified

Linux x86_64 native, 72 passed and 0 failed. aarch64 under `qemu-aarch64`
against `o/aarch64/tool/net/redbean`, 72 and 0. Windows under `wine`
against the fat `o/redbean.com`, 68 and 0, where the four real `touch`
cases are skipped as designed. All three include the shutdown test.

Not verified. Apple Silicon macOS and the BSDs, which no emulator here can
stand in for, and aarch64 on real hardware.

## Problems found while testing

Writing the suite found five real defects, none of which would have shown
up on one platform.

A bad action entry made the C code skip a `lua_getfield` through a
short circuited `&&` while still popping the stack afterwards, which
unbalanced it and surfaced much later as an unrelated nil index error. The
fields are now pushed unconditionally.

`unix.exit` being `_Exit` meant the shutdown test and the helper at first
never cleaned up. That is now documented as a limitation instead of being
hidden, and the helper uses `os.exit`.

A test helper that read stdin in 4096 byte blocks held back a short write
until end of file, which made the test hang while real `cat` would not
have. The helper forwards whatever has arrived.

On Windows the missing program error is a different errno than on Linux,
so the test now only asserts failure. And on Windows a write to a dead
child pipe terminated redbean outright, which led to the `SIGPIPE` rule
above.

## Sandboxing

This is meant for scripting and is not supported together with redbean's
`-S` flags, `unix.pledge` or `unix.unveil`. Their promise lists redbean
uses do not include `proc` or `exec`, so spawning is refused. Redbean sets
the return EPERM penalty under `-S`, so the call fails with an error. A
script that pledges on its own gets the default penalty of killing the
process unless it passes `unix.PLEDGE_PENALTY_RETURN_EPERM` as the third
argument, which was observed as a core dump on the first spawn attempt.
Unveil without `x` on the program fails with EACCES. Pledge and unveil
do nothing on Windows or macOS.

Two test cases pin this down by running a child that applies
`unix.pledge("stdio rpath")` or an unveil of only the working directory and
then asks the wrapper to spawn. On Linux the wrapper returns `nil` with an
error and the child exits normally, so the module fails closed. Under
`qemu-user` and `wine` nothing is enforced, so the spawn succeeds, and the
test prints a note instead of failing.

## Known gaps

The raw API does not validate, by design. Resource limits, scheduling
attributes and `POSIX_SPAWN_RESETIDS` are not exposed, though the libc
supports them and each is a few lines if wanted. There is no timeout on
`wait`, the only way to bound it is `wait(true)` in a loop with
`unix.nanosleep`. Buffered output is unbounded. A process object does
not survive `fork`, since the child's copy would kill the process on
collection, so a forked worker should not hold one. The module is
incompatible with `-S` and with `unix.pledge` and `unix.unveil`, see the
sandboxing section.

## Reverting

Nothing is committed. To get back to a clean tree,

```
git checkout third_party/lua/lunix.c tool/net/BUILD.mk tool/net/help.txt o/redbean.com
rm test/tool/net/cosmo_spawn_test.lua test/tool/net/cosmo_spawn_helper.lua tool/net/.lua/cosmo-spawn.lua REDBEAN_SPAWN_PLAN.md
```
