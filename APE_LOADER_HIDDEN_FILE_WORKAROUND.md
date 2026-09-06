# APE loader: work around EDR blocking of hidden-file execution

## Problem

APE (Actually Portable Executable) binaries that don't self-modify
(`APE_NO_MODIFY_SELF` / any binary linked with an embedded loader instead of
using `--assimilate`) work by extracting a small loader binary to a cache
location on first run, then re-executing themselves through it:

```
${TMPDIR:-${HOME:-.}}/.ape-$VERSION
```

Some EDR/AV products (reportedly including CrowdStrike) flag the execution of
hidden top-level dotfiles like `~/.ape-1.10`, even though the file is
harmless (it's just the loader, not user-controlled payload). This can
block APE binaries from running at all in monitored environments.

## Fix

Nest the extracted loader one level deeper, under a hidden *directory*
whose contents have normal (non-dotfile) names:

```
${TMPDIR:-${HOME:-.}}/.ape/ape-$VERSION
```

The heuristic products flag appears to be specifically about hidden
top-level files executing, not normally-named files living inside a hidden
directory. The directory itself (`.ape/`) still needs `mkdir -p`, but that
codepath already existed (`mkdir -p "${t%/*}"`) and required no changes.

## Where the path is constructed or recognized

This path is not defined in one place; it's duplicated across the shell
script generator, the sandboxing code, and two runtime heuristics. All four
had to change together:

- **`ape/ape.S`** — the embedded shell-script self-extraction header baked
  into every APE binary linked with `APE_NO_MODIFY_SELF` and `APE_LOADER`.
  This is the primary code path exercised on every run: the kernel treats
  the APE header as a `#!/bin/sh` shebang, so `/bin/sh` runs this script,
  which checks `[ -x "$t" ]` and either re-execs the cached loader or
  extracts it first (`mkdir -p`, `dd`, `chmod`, `mv`).
- **`tool/build/apelink.c`** — the `apelink` tool generates the *same* shell
  script text at link time when combining multiple architecture-specific
  ELFs into one fat binary. Two independent generators had to move in
  lockstep or a binary built with an old `apelink` would look for the loader
  in the old location while a binary linked with a new one would look in the
  new one — with no way to detect the mismatch.
- **`tool/build/pledge.c`** — when a program run under `pledge()`/`unveil()`
  needs filesystem access to load itself via the ape strategy, it grants
  `rx` on the expected loader path. Left unpatched, this would have made the
  new loader location invisible to a pledged process, breaking self-loading
  rather than fixing anything about hidden files.
- **`libc/calls/getprogramexecutablename.greg.c`** — `OldApeLoader()`
  recognizes "the currently running process is actually the ape loader
  binary" (used as a fallback when the kernel's `KERN_PROC_PATHNAME` et al.
  report the loader's own path instead of the wrapped program's). Extended
  to recognize the new nested pattern (`/.ape/ape-<version>`) in addition to
  the old flat one, so this call doesn't misidentify the process on systems
  that reach this code path.
- **`libc/proc/execve-sysv.c`** — a C-level `execve()` fallback (used when
  the kernel's own `execve()` returns `ENOEXEC` for the APE format) that
  tries to directly re-exec an already-extracted loader from
  `$TMPDIR`/`$HOME`/`.` without going through a shell at all. Updated to
  look in the new location.
- **`ape/apeuninstall.sh`** — cleans up old ad-hoc installs. Also fixes a
  latent bug this change would otherwise have introduced: the script's
  existing loop did `rm -f ~/.ape` (among other names) under `set -e`; once
  `.ape` becomes a directory instead of a file, plain `rm -f` on it fails
  and would have aborted the rest of the uninstall script. Split into a
  `rm -f` loop for the old versioned flat files and a separate `rm -rf` for
  the new-style directory (which also safely handles a stray old-style bare
  `.ape` file, if one ever existed).
- **`ape/loader.c`**, **`tool/cosmocc/README.md`** — doc comments/examples
  updated to describe the real path so they don't mislead future readers.

## What was deliberately left alone

Two other, unrelated `.ape*`-named files were found by the same search and
confirmed to be different features, not touched:

- `~/.ape.key` (`tool/build/apesign.c`) — APE code-signing key.
- `~/.ape.trust` (`tool/build/apetrust.c`) — APE trust store.

Also left alone: generic prose in `tool/net/help.txt` /
`tool/net/definitions.lua` that mentions extracting "a 4kb loader program to
`${TMPDIR:-${HOME:-.}}/.ape`" without giving a concrete versioned path —
already imprecise before this change, and not worth touching for this fix.

## Validation

1. Confirmed no system-wide loader was installed (`command -v ape` →
   not found, `/usr/bin/ape` and `/usr/local/bin/ape` absent), and removed
   a leftover old-style `~/.ape-1.10` from earlier testing, so the retest
   would genuinely exercise the ad-hoc self-extraction path rather than
   silently short-circuiting through a system install.
2. Rebuilt `tool/build/apelink` from this repo's source (the fat-binary
   build scripts normally use a prebuilt `apelink` bundled with the
   `.cosmocc` toolchain distribution, which does *not* contain this fix).
3. Linked a fresh fat `chibicc.com` with the rebuilt `apelink` and confirmed
   by disassembling its header that the embedded shell script now reads
   `t="${TMPDIR:-${HOME:-.}}/.ape/ape-1.10"`.
4. Ran it directly (`./chibicc.com --version`) and confirmed:
   - it extracted the loader to `~/.ape/ape-1.10` (new style), not
     `~/.ape-1.10` (old style);
   - a second run reused the cached extraction (`mtime` unchanged, no
     re-extraction);
   - it still worked correctly under `qemu-aarch64` (arm64 loader
     dispatch).
5. Re-ran the full `third_party/chibicc/test/run_multiarch.sh` matrix
   (amd64 native / arm64 via qemu / Windows amd64 via Wine, including
   self-hosting on both architectures) with the rebuilt `apelink`:
   **12 passed, 0 failed, 0 skipped.**
6. `run_multiarch.sh` itself was updated to accept an `APELINK` override
   (mirroring the pattern `third_party/chibicc/build.sh` already used) so
   this retest — and any future one — doesn't require bypassing the script.
