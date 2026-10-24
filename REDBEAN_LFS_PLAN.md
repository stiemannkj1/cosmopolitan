# LuaFileSystem on top of redbean's `unix` module

Status, built and tested. The module ships in redbean's zip store at
`/zip/.lua/cosmo-lfs.lua` and is loaded with `require 'cosmo-lfs'`. The
source lives at `tool/net/.lua/cosmo-lfs.lua`. Sections 1 and 2 are the
original comparison and still describe the problem accurately. Sections 3
onward record what was done.

Reference points are LuaFileSystem 1.8.0 as vendored in `third_party/lfs/lfs.c`
and redbean's `unix` module as implemented in `third_party/lua/lunix.c`.
Everything below was verified against a locally built
`o/x86_64/tool/net/redbean` rather than read off documentation.

## 1. API surface comparison

LFS exports fourteen functions. Eleven map cleanly onto redbean primitives,
two need a workaround, one is a no-op.

| LFS function | redbean primitive | Status |
| --- | --- | --- |
| `lfs.currentdir()` | `unix.getcwd()` | direct |
| `lfs.chdir(p)` | `unix.chdir(p)` | direct |
| `lfs.mkdir(p)` | `unix.mkdir(p[, mode])` | direct |
| `lfs.rmdir(p)` | `unix.rmdir(p)` | direct |
| `lfs.dir(p)` | `unix.opendir(p)` | wrapper, semantics differ |
| `lfs.attributes(p[, a])` | `unix.stat(p)` | wrapper, field translation |
| `lfs.symlinkattributes(p[, a])` | `unix.stat(p, unix.AT_SYMLINK_NOFOLLOW)` | wrapper, plus `unix.readlink` for `target` |
| `lfs.link(old, new[, sym])` | `unix.link` / `unix.symlink` | direct, argument order already matches |
| `lfs.touch(p[, at[, mt]])` | `unix.utimensat` | wrapper, seconds to timespec |
| `lfs.lock_dir(p[, stale])` | `unix.symlink` / `unix.unlink` | direct, LFS itself is symlink based |
| `lfs.setmode(f, m)` | none required | stub returning `true, "binary"` |
| `lfs.lock(fh, mode[, s[, l]])` | `unix.fcntl(fd, F_SETLK, ...)` | blocked, see section 3 |
| `lfs.unlock(fh[, s[, l]])` | `unix.fcntl(fd, F_SETLK, F_UNLCK, ...)` | blocked, see section 3 |
| `lfs._VERSION` and friends | none | plain string constants |

Redbean's file coverage is a strict superset of what LFS needs. The work is
almost entirely translation of shapes and conventions, not of capability.

## 2. The four real differences

### Error convention

`unix` returns `nil, Errno` where `Errno` is userdata. LFS returns
`nil, message, errno` where the message is `strerror` text, sometimes prefixed
with the path. The `Errno` object carries `:doc()` giving exactly the
`strerror` string and `:errno()` giving the number, so one small helper
converts between the two with no information loss.

### `stat` result shape

`unix.stat` returns an object with accessor methods. LFS returns a table of
named fields, and the names do not match. The table below is the full mapping.
Note that `mode` in LFS is a type string, not a number, and that the three
timestamps are integer seconds while redbean's accessors return a
`seconds, nanoseconds` pair.

| LFS field | redbean source |
| --- | --- |
| `mode` | `S_IS*` ladder over `st:mode()` producing `file`, `directory`, `link`, `socket`, `named pipe`, `char device`, `block device`, `other` |
| `permissions` | nine character `rwx` string built from the low bits of `st:mode()` |
| `dev` `ino` `nlink` `uid` `gid` `rdev` `size` `blocks` `blksize` | same named accessor on the Stat object |
| `access` | first return of `st:atim()` |
| `modification` | first return of `st:mtim()` |
| `change` | first return of `st:ctim()` |

Two details worth preserving. LFS's `perm2string` ignores setuid, setgid and
sticky, so the string is exactly nine characters of `rwx` and dashes and
nothing more. And redbean does not export the `S_IRUSR` family of bit
constants, only the `S_IS*` predicate functions, so the permission bits have to
be written as literal octal in the Lua source. Those values are fixed by POSIX
and cosmopolitan normalises `st_mode` across platforms, so this is safe.

### Directory iteration

Redbean's `unix.Dir` object already has a `__call` metamethod, which is most of
what is needed, but four things differ from LFS.

LFS raises a Lua error when the directory cannot be opened, with the message
`cannot open <path>: <strerror>`. Redbean returns `nil, Errno`. The wrapper
must call `error()`.

LFS yields exactly one value per iteration, the entry name. Redbean yields
four, being name, dirent type, inode and offset. Code written as
`for name in lfs.dir(p)` works under either, but anything binding a second
variable breaks, so the wrapper should yield one value.

LFS hands back a directory object with `:next()` and `:close()` methods that
tracks a closed flag and raises `closed directory` if used after closing.
Redbean's handle has `read`, `close`, `fd`, `tell` and `rewind` instead.

Under Lua 5.4 LFS returns four values from `lfs.dir` so that the generic for
closes the handle automatically. Matching that needs a `__close` metamethod on
the wrapper object.

Both include `.` and `..`, so no filtering is needed.

### `lock` and `unlock` cannot see a file descriptor

This is the one genuine blocker. LFS's `lock`, `unlock` and `setmode` take a
Lua `io` file handle and call `fileno()` on the underlying `FILE *`. Redbean
exposes no bridge from a Lua file handle to a descriptor. There is no
`unix.fileno`, no `fileno` method on the handle, and nothing in `redbean.c`
that touches `LUA_FILEHANDLE`. Pure Lua cannot reach inside the `luaL_Stream`
userdata, so this cannot be solved in the Lua layer alone.

The locking primitive itself is fully present. `unix.fcntl` special cases
`F_SETLK`, `F_SETLKW` and `F_GETLK`, taking type, start, length and whence as
optional arguments, and `F_RDLCK`, `F_WRLCK` and `F_UNLCK` are all exported.
Only the descriptor is missing.

## 3. The locking gap, and how it was closed

LFS's `lock`, `unlock` and `setmode` take a Lua `io` file handle and call
`fileno()` on the underlying `FILE *`. Redbean exposed no bridge from a Lua
file handle to a descriptor, and pure Lua cannot reach inside the
`luaL_Stream` userdata, so this could not be solved in the Lua layer.

`unix.fileno(file)` was added to `third_party/lua/lunix.c`, documented in
`tool/net/help.txt`, and is what `lfs.lock` and `lfs.unlock` use. It
validates its argument with `luaL_checkudata` against `LUA_FILEHANDLE` and
refuses a file that has already been closed.

The module still loads and mostly works without it. `tofd` accepts a plain
integer descriptor, so code that opened the file with `unix.open` can lock
it on a stock redbean, and only stdio handles are refused, with a message
saying why. `setmode` never needs a descriptor at all.

## 4. A second bug, found by the tests

`unix.readlink(path)` was broken for its whole life on any build whose
compiler evaluates arguments right to left, which includes the cosmocc gcc
used here. The call was written as

```c
readlinkat(luaL_optinteger(L, 2, AT_FDCWD), luaL_checkstring(L, 1),
           luaL_buffinitsize(L, &lb, BUFSIZ), BUFSIZ)
```

and `luaL_buffinitsize` pushes a box onto the Lua stack. When it runs
first, that box sits at stack index 2, so the `luaL_optinteger(L, 2, ...)`
that is meant to find no argument at all finds the box instead and fails
with `bad argument #2 to 'readlink' (number expected, got _UBOX*)`. In
other words, `unix.readlink` only worked when an explicit dirfd was passed.

The fix hoists both argument reads above the buffer initialization.
`cosmo-lfs` also passes `unix.AT_FDCWD` explicitly, so it works on stock
redbean binaries that still carry the bug.

## 5. Handing out real userdata from Lua

`lfs.dir` and `lfs.lock_dir` return userdata, and Lua has no way to create
userdata. The first cut returned tables, which `type()` reports
differently. That is now fixed.

`unix.Sigset()` mints a userdata that owns no operating system resource
and carries no finalizer of its own, `debug.setmetatable()` re-tags it with
the LFS metatable, and the object's state lives in its uservalue. The
result is genuinely userdata, and because `luaL_newmetatable` sets
`__name`, setting `__name` here to `directory metatable` and
`lock metatable` makes `tostring` match upstream as well.

The `unix.Dir` handle itself is deliberately not re-tagged. Its own
methods call `luaL_checkudata(L, 1, "unix.Dir")`, which compares the
metatable by identity, so swapping it would stop `read` and `close` from
working. The handle is kept in the state table instead.

A finalizer attached this way does run, which matters because `lock_dir`
has to release its symlink on collection. That was tested directly
alongside the to-be-closed path and a descriptor leak check, and matches
the C module.

If the `debug` library has been removed the objects fall back to tables,
which changes nothing but `type()`. That path is exercised separately,
because the ordinary tests never reach it.

## 6. The one remaining difference, and two things that are not

Calling `next()` on a closed directory through a tail call reports the
argument error without knowing it was a method call, so it says
`bad argument #1 to 'next'` where upstream says
`calling 'next' on bad self`. A tail-called Lua frame has lost its call
site, while a C function in the same position has not. Four of the five
call shapes, including the plain method call and the generic for, produce
byte-identical messages.

Two further things get mistaken for differences and are not. Both were
measured against the C module rather than assumed.

`lfs.setmode` always reports `binary`. Upstream compiles it as a no-op
wherever `_WIN32` is undefined, and cosmopolitan is not `_WIN32`, so the
vendored C `lfs` does the same. Both return `true, binary` even for
`setmode(f, 'text')`. This differs only from LFS built with MSVC.

`lfs.chdir` cannot enter `/zip`. Both implementations end up in `chdir(2)`
and both get `ENOTSUP`, with byte-identical messages. This is a
cosmopolitan zipos limitation, not something this module introduced.

What does work, and was not expected to, is that `unix.stat` and
`unix.opendir` accept `/zip` paths, so `lfs.dir` and `lfs.attributes` walk
the binary's own embedded assets with no special casing.

## 7. Testing, and the results

The existing suite at `scripts/luaext_test.lua` already carried nine lfs
tests, so it was reused rather than duplicated. Three changes make it serve
both binaries. It prefers `cosmo-lfs` over `lfs` when both could be found,
luaposix is now an optional require, and `group()` marks every luaposix
group unsupported when that module is absent. The result is that the same
file runs under redbean, which has no luaposix, and under the cosmopolitan
lua, where putting `tool/net/.lua` on `LUA_PATH` swaps the pure-Lua
implementation in for the C one and runs the whole suite against it.

| Run | Result |
| --- | --- |
| redbean, x86_64 | 9 lfs passed, 0 failed |
| redbean, aarch64 under qemu | 9 lfs passed, 0 failed |
| redbean, windows under wine | 7 lfs passed, 2 unsupported, 0 failed |
| lua APE, C lfs, all three targets | 60/1, 60/1, 55/6, unchanged from before |
| lua APE, cosmo-lfs substituted, all three | 60/1, 60/1, 55/6, identical |

The two Windows skips are the account lacking the create-symlink right,
which is exactly what the C module does there, with the same message down
to the win32 error code.

Beyond the suite, an A/B harness dumps every observable of the API under
both implementations and diffs them. It covers all fourteen functions,
every attribute member and its Lua type, the three `attributes` call forms,
`symlinkattributes` with and without `target`, nine error paths, the four
values `lfs.dir` returns, five directory call shapes, both `touch` forms,
and the full `lock_dir` acquire and release cycle. The only lines that
differ are the two described in section 6.
