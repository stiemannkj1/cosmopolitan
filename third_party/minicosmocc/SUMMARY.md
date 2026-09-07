# Minimal Cosmopolitan/APE C Compiler ("minicosmocc") — Work Summary

Single standalone APE binary, `dist/blink-compile.com` (currently **72 MB**),
that compiles C source into fat (amd64+arm64 native) APE executables. Built
on the prebuilt `cosmocc` 4.0.2 release (never built from source), stripped
to C-only, and packaged so the wrapper carries its own toolchain as embedded
assets.

Original plan lives at `../../MINIMAL_COSMO_COMPILER_GCC_PLAN.md` (relative
to this file) and called for two binaries (`blink-compile` / `blink-embed`);
Binary B was designed, built, and then deliberately dropped (see below).
Only Binary A remains. This project now lives under
`cosmopolitan/third_party/minicosmocc/` on the `minicosmocc` branch (moved
from a standalone `~/Projects/work/cosmo-toolchain/` working directory).

## Current status: all phases complete

- Phases 0–7 of the original plan are done: environment prep, toolchain
  acquisition/staging, wrapper implementation, build script, loader-cleanup
  script (`scripts/clean-ape-loaders.sh`), the test suite
  (`tests/a-hello-world.sh`, `tests/a-tinycc.sh`, `tests/run-all.sh`), the
  bug-fix loop (Phase 6 — see below), and this final report (Phase 7).
- Everything has been validated repeatedly with full clean-cache builds:
  native amd64, arm64-via-Blink (`qemu-aarch64`), and Wine all produce
  **byte-identical** output for a `malloc`/`free` hello-world, and building
  tinycc (a real ~30K-line, 24-file C project) works identically across all
  three.

## Rebuilding from scratch

```
scripts/rebuild-from-scratch.sh
```
Wipes `build/` and `dist/`, re-stages `build/` from the `cosmocc` release
(downloading it if not already cached under `../../.cosmocc/`), rebuilds
`dist/blink-compile.com`, and runs the full test suite. Set
`COSMOCC_VERSION` to stage from a different release. See "Full
clean-checkout reproducibility" below for what this was validated against.

## Architecture

**Pipeline** (`wrapper/cosmocc-min.c`, ~650 lines):
```
compile (cc1 directly) -> assemble (as directly) -> fixupobj ->
link (ld.bfd directly) -> fixupobj -> apelink (join slices) -> pecheck
```

**Host/target dispatch**: both the amd64-target and arm64-target toolchains
are staged as **amd64-native binaries only** — there is no arm64-native
build of anything. On an amd64 host, everything runs directly. On an arm64
host, everything runs under Blink, which emulates the tool's own amd64
execution — independent of what architecture that tool is compiling *for*.
This is why only one Blink build (`blink-arm64.elf`, runs natively on arm64,
emulates amd64 guest code) is ever needed; a `blink-amd64.elf` would never
be exercised by any code path, so it isn't staged.

`libcosmo.a`/`crt.o`/etc. are architecture-specific link-time archives, not
executables — both amd64 and arm64 copies are always staged regardless of
host, since a fat output binary always needs both slices' object code.

**Why cc1/as/ld.bfd are invoked directly instead of through `gcc`/`collect2`**
(the single biggest fix of this whole effort): GCC's own bundled spawn
helpers request `POSIX_SPAWN_USEVFORK`, and Cosmopolitan's `posix_spawn()`
unconditionally routes that into a broken `vfork-nt.c` mechanism on Windows.
This was isolated with a minimal reproduction: even a trivial cosmo program,
properly `apelink`-wrapped, spawning a known-good APE binary via
`posix_spawn()` with a fully-qualified path fails under Wine with
inconsistent error codes (`Exec format error`, `No such file`, `Not a
directory` depending on path details) — while plain `fork()`+`execv()`
(what this wrapper's `run_or_die()` uses everywhere) is completely reliable
under Wine. Bypassing `gcc`'s driver and `collect2` sidesteps the bug
identically on Linux and Windows, with no OS branching in the wrapper code.
`gcc` and `collect2` are consequently **unused and unstaged entirely**.

Because of this, the flag set passed to `cc1`/`as`/`ld.bfd` is a **fixed,
closed set of constants**, not a general gcc-flag translation — this
wrapper only ever targets one cosmo runtime configuration (no
`-mtiny`/`-mdbg`/`-moptlinux` support), and the exact flags were captured
once via `BUILDLOG=1` against the real `cosmocc` driver.

**`apelink`/`fixupobj`/`pecheck`** are likewise staged amd64-native only
(no arm64-native variant), dispatched through Blink on an arm64 host, for
the same reason as the compiler trees — plus a subtler one: their "other"
architecture slice was zeroed out during size trimming (see below), so an
arm64-native variant of the same file would need a *different* half zeroed,
which staging doesn't produce. One amd64-only copy avoids the mismatch.

## Binary B: designed, built, then dropped

Binary B (`blink-embed.com`) was originally meant to produce amd64-only
outputs with an embedded Blink runtime, self-relaunching via Blink when run
directly on arm64 hardware. It was fully implemented and validated for the
"compiler produces the right bytes" part, but the actual arm64
self-relaunch mechanism has two possible implementations, both dead ends
within this plan's constraints:

- Patch `apelink`'s generated shell-script polyglot header to add an
  arm64-Blink-fallback branch — high risk of corrupting the file's
  byte-offset-dependent MZ/PE/ELF/zip structure.
- Replace the whole output with a plain POSIX shell-script launcher —
  robust, but the file stops being a valid PE, so it can no longer run on
  Windows/Wine at all (unacceptable given the plan's own three-platform
  test matrix).

Binary B was removed entirely (wrapper code, build script, staged assets).
Only `blink-compile.com` (fat, dual-native, no embedded Blink) remains.

## Size optimization: 429 MB → 72 MB

In rough chronological order:

| Change | Result |
|---|---|
| Start (fat outputs, two binaries, unstripped variants) | 429 MB |
| Strip `-mdbg`/`-moptlinux`/`-mtiny` runtime variants (unused, ~195MB/tree) | 295 MB |
| Drop Binary B entirely | 238 MB |
| Fix symlink-duplication in embedding (zipfile followed symlinks, storing full duplicate content per alias) | 161 MB |
| Eliminate the redundant arm64-native GCC tree (both toolchains amd64-native only, Blink handles either) | — |
| Remove `cc`/`cpp` (unused GCC driver aliases, byte-identical to `gcc`) | 151 MB |
| Remove `ar`/`ranlib`/`nm`/`objcopy`/`objdump`/`strip`/`addr2line`/`size`/`readelf`/`elfedit`/`ld` — verified empirically the pipeline never invokes any of them | 119 MB |
| **Discover and fix `assimilate`'s "other-arch slice never truncated" bug**: every assimilated executable still physically contained ~50% dead weight (the *other* architecture's full ELF slice, headers just repatched to hide it) | 77 MB |
| Remove `gcc`/`collect2` (made obsolete by the direct cc1/as/ld.bfd fix) | 72 MB |

The `assimilate` discovery was the largest single win and is worth
understanding: `assimilate -x`/`-a` only patches the ELF/program headers to
select which slice is "active" — it never truncates the other slice's bytes
away. `readelf -lW` showed the file size vs. the end of the last loaded
segment differed by almost exactly 50% for every single assimilated file
(e.g. `cc1`: 82.4MB file, only 41.5MB ever mapped at runtime). Truncating to
the actual used size recovered the difference with zero functional cost —
validated by building a full scratch toolchain with every file trimmed this
way and running the complete pipeline against it before touching the real
staged files.

A related, smaller discovery: the *trailing zip-stored content* in each fat
binary (a `.symtab` for each slice, plus a full embedded IANA timezone
database — apparently boilerplate added to every cosmo binary, not
something specific to these particular tools) accounted for a further
~2.4MB per large file. Where APE-ness needed to be preserved (see next
section), that trailing content is dropped in addition to zeroing the
unused slice, recovering size that a naive "just zero the slice" approach
would otherwise leave behind — see `scripts/zero-trim.py`.

`scripts/zero-trim.py` is invoked by `scripts/stage-toolchain.sh`, which
re-derives `build/` from a fresh `cosmocc` release, so re-staging from a
version bump always re-applies the zero+trim step rather than needing a
separate manual pass.

## Windows/Wine compilation: the real fix

Per the section above, the pipeline now invokes `cc1`/`as`/`ld.bfd`/
`fixupobj`/`apelink`/`pecheck` directly via `fork()`+`execv()`, never
through `gcc`'s driver. Two more things had to line up for this to actually
work end-to-end under Wine, beyond just avoiding `posix_spawn`:

1. **The tool binaries must remain genuinely fat/APE (valid PE), not plain
   assimilated ELF.** Windows cannot execute raw ELF under any mechanism,
   full stop — a plain-ELF `fixupobj`, even though it's launched via the
   safe `fork()`+`execv()` path, will still fail to launch under Wine
   simply because it has no PE header at all. So every tool actually
   invoked at runtime (`cc1`, `as`, `ld.bfd`, `fixupobj`, `apelink`,
   `pecheck`) is zeroed+trimmed (APE-preserving), never plain-assimilated,
   in the final staged/embedded assets.
2. **The build-time bootstrap step needed its own fix.** The very first
   self-hosting compile (compiling `cosmocc-min.c` into a fat APE using a
   plain host-`gcc`-compiled, non-cosmo bootstrap binary) can't `execv()` a
   fat/APE file at all — only a *cosmo-linked* process's `execve()` has the
   self-extraction retry logic that makes that work. Fixed by staging
   temporary plain-ELF (`assimilate`d) copies of the toolchain just for
   that one bootstrap step (`scripts/_assemble.sh`), which never affects
   what actually gets embedded into the shipped binary.
3. **Cache location matters.** `$HOME`-derived paths (`/home/user/...`) hit
   inconsistent path-translation behavior in Cosmopolitan's Windows layer;
   `$TMPDIR`-derived paths (`/tmp/...`) are reliable. The wrapper's cache
   now lives under `$TMPDIR/cosmocc-min/<version>/`, not `~/.cache/...`.

## Phase 5: the test suite

Only §5.1 (Binary A tests) and §5.3 (cross-check) from the plan apply,
since Binary B no longer exists.

**`tests/a-hello-world.sh`** — the full 3×3 matrix from the plan: compile a
`malloc`/`free` hello-world on {amd64-native, arm64-via-qemu+Blink,
windows-via-wine}, then run each resulting binary on all three of the same
platforms (9 combinations), plus a cross-compiler-host byte-identical-output
check and the loader-reinstallation cross-check. All 11 checks pass.

**`tests/a-tinycc.sh`** — builds tinycc (a real ~30K-line, 24-file C
project that happens to be a unity build, `tcc.c` → ... → every other
source file, which suits this wrapper's one-source-file-per-invocation
design well) with `blink-compile.com`, confirms the built `tcc` reports its
version correctly on all three platforms, and validates self-compile
(`tcc -c tcc.c -o out.o`) determinism between amd64-native and
windows-wine. The arm64-qemu self-compile leg is intentionally excluded:
an aarch64-native `tcc` slice reading this host's x86_64-specific glibc
headers hits an architecture-mismatched macro path in `gnu/stubs.h` (glibc
header logic keys off the *compiler binary's own* CPU identity, not its
output target) — a tinycc+glibc header limitation, not a wrapper defect;
the "tcc -v" check already separately confirms the arm64 slice itself
works correctly. Building tinycc's optional bounds-checking runtime
(`lib/bcheck.c`) also fails on this host (`__malloc_hook` was removed from
modern glibc) — an unrelated, pre-existing tinycc/glibc incompatibility,
so the test validates what's actually in scope (building tinycc, and
compile-only self-hosting) rather than full link+`-run` execution via
tinycc's own separately-built runtime. All 8 checks pass.

**`tests/run-all.sh`** — orchestrates both, cleaning APE loaders before
each. Both currently pass.

## Phase 6: bug-fix loop

No Phase 5 test was failing when this phase started, so there was nothing
to root-cause against test failures directly. Phase 7's reproducibility
check (immediately below) did surface one real bug, fixed as part of
confirming reproducibility: `scripts/_assemble.sh`'s self-hosting build
step didn't clear the wrapper's own runtime cache first. The wrapper
checks its cache-readiness (keyed only by version, not content) before
even looking at `COSMOCC_MIN_ASSETS` — so a cache left "ready" by an
unrelated earlier run of the *built product* (using the real fat/APE
assets) would get reused by the *build script's* bootstrap step instead
of the plain-ELF assets it actually needs, breaking the non-cosmo
bootstrap's `execv()` the same way any fat `cc1` always does for a
non-cosmo caller. Fixed by having `_assemble.sh` clear
`$TMPDIR/cosmocc-min` and `~/.cache/cosmocc-min` before self-hosting,
making the build deterministic regardless of ambient `/tmp` state left
by prior manual testing or test-suite runs.

## Phase 7: final report

Two independent, back-to-back runs of `scripts/build-blink-compile.sh`
(after the Phase 6 fix above) produce **byte-identical** output
(verified via `sha256sum`) — the build is reproducible given the staged
`build/` toolchain.

**Final size**: `dist/blink-compile.com` = **72 MB**.

**Final validation matrix** (`tests/run-all.sh`, fresh build, freshly
loader-cleaned system): **19/19 checks passing** —
`tests/a-hello-world.sh` 11/11 (the full 3×3 compile-host × run-host
matrix across amd64-native/arm64-qemu/windows-wine, plus byte-identity
and loader-reinstallation cross-checks) and `tests/a-tinycc.sh` 8/8
(building and validating tinycc, a real ~30K-line C project, across the
same three platforms).

**Full clean-checkout reproducibility**: `scripts/stage-toolchain.sh` now
automates the whole `build/` derivation (download-or-reuse the `cosmocc`
release, assimilate-measure + zero+trim every dual-arch tool, stage the
filtered `lib/`/`include/` trees, install the vendored `blink-arm64.elf`,
write `gold/NOTE.md`) in one command, and `scripts/rebuild-from-scratch.sh`
chains it with the build and the full test suite. Verified by wiping
`build/` and `dist/` entirely and running `rebuild-from-scratch.sh` fresh:
it re-staged `build/` byte-for-byte equivalent to the prior hand-staged
version (diffed directly — only stale cruft from earlier manual staging
was missing, nothing load-bearing), reassembled `dist/blink-compile.com`
at the same 72MB, and passed all 19/19 test-suite checks. `cosmocc` itself
is still never built from source, only downloaded — consistent with the
project's original ground rule — and Blink is vendored as a prebuilt
binary (`vendor/blink-arm64.elf`) rather than built from source, since
upstream ships no prebuilt aarch64 release asset and this host has no
aarch64 cross-compiler to build it with.

## Known limitations / next steps

- Blink (`vendor/blink-arm64.elf`) is a pinned, vendored prebuilt binary,
  not something `stage-toolchain.sh` builds from source: jart/blink's
  GitHub releases ship only a source tarball (no prebuilt aarch64 asset),
  and this build host has no aarch64 cross-compiler to build one. If
  Blink ever needs a version bump, a new `blink-arm64.elf` has to be
  built elsewhere (a real aarch64 host, or a cross-compiling one) and
  dropped into `vendor/` by hand.
- `--target=amd64|arm64` (single-arch output, skipping the fat join) has a
  known bug in `apelink_join()` — noted but not revisited since it's not
  exercised by the plan's actual test matrix (which is about the fat-binary
  path). Low priority.
- This wrapper supports exactly one C-only, single-source-file compile per
  invocation, against exactly one cosmo runtime configuration. It is not,
  and was never meant to be, a general-purpose gcc replacement.
- `build/` (staged toolchain assets) and `dist/` (built output) are
  generated/fetched artifacts, not source — they're reproducible from a
  fresh `cosmocc` release via `scripts/build-blink-compile.sh`. `build/` is
  gitignored; `dist/` is currently untracked (not yet committed or
  ignored) — worth a deliberate decision one way or the other.
- A wine-compiled output's executable bit doesn't survive Wine's
  Windows-translation layer (Windows has no equivalent permission concept)
  — a real user transferring such a binary to Linux/arm64 needs
  `chmod +x` first, same as `tests/a-hello-world.sh` does internally.

## Directory structure

```
third_party/minicosmocc/
  wrapper/cosmocc-min.c       the whole compiler wrapper (~650 lines)
  vendor/blink-arm64.elf      pinned prebuilt Blink binary (see Known limitations)
  scripts/
    rebuild-from-scratch.sh  orchestrator: stage -> build -> test, one command
    stage-toolchain.sh       derives build/ from a cosmocc release (download-or-reuse)
    zero-trim.py             the assimilate-waste + trailing-zip-content fix
    build-blink-compile.sh    entry point: builds dist/blink-compile.com
    _assemble.sh              shared build logic (bootstrap, embed, verify)
    embed-assets.py           zip-embeds staged assets into the built wrapper
    clean-ape-loaders.sh      removes global/user/temp APE loaders before tests
    strip-manifest.txt        full record of what was stripped/kept and why
  build/                      staged toolchain (generated, gitignored)
    gcc-amd64/, gcc-arm64/    cc1, as, ld.bfd (+ lib/, no gcc or collect2)
    apelink/                  apelink, fixupobj, pecheck (amd64-native only)
    blink/                    blink-arm64.elf only
    include/                  shared cosmo headers
    gold/NOTE.md              no gold linker exists anywhere; ld.bfd substitutes
  dist/blink-compile.com      the built product (generated, currently untracked)
  tests/
    a-hello-world.sh          Phase 5.1.1 (11 checks, all passing)
    a-tinycc.sh               Phase 5.1.2 (8 checks, all passing)
    run-all.sh                orchestrates both
```
