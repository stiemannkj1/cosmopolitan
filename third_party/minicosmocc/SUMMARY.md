# Minimal Cosmopolitan/APE C Compiler ("minicosmocc") — Work Summary

Single standalone APE binary, `dist/blink-compile.com` (currently **72 MB**),
that compiles C source into fat (amd64+arm64 native) APE executables. Built
on the prebuilt `cosmocc` 4.0.2 release (never built from source), stripped
to C-only, and packaged so the wrapper carries its own toolchain as embedded
assets.

Original plan lived at `../cosmopolitan/MINIMAL_COSMO_COMPILER_GCC_PLAN.md`
and called for two binaries (`blink-compile` / `blink-embed`); Binary B was
designed, built, and then deliberately dropped (see below). Only Binary A
remains.

## Current status

- Phases 0–4 of the original plan are done: environment prep, toolchain
  acquisition/staging, wrapper implementation, build script, loader-cleanup
  script (`scripts/clean-ape-loaders.sh`).
- Phase 5 (the actual hello-world/tinycc test suite across amd64/arm64/wine)
  was **not written** — `tests/` is still empty. Most of this effort went
  into architecture decisions and a size-optimization pass that turned out
  to be substantial, plus a deep bug hunt to make Wine compilation actually
  work. Writing `tests/a-hello-world.sh` etc. is the natural next step.
- Everything below has been validated repeatedly with full clean-cache
  builds: native amd64, arm64-via-Blink (`qemu-aarch64`), and Wine all
  produce **byte-identical** output for a `malloc`/`free` hello-world.

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
would otherwise leave behind — see `scripts/truncate-fat-remnants.py`.

`scripts/truncate-fat-remnants.py` is idempotent and needs to be re-run any
time the toolchain is re-staged from a fresh `cosmocc` release, since a
fresh `assimilate` run reintroduces the same waste.

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

## Known limitations / next steps

- `tests/` is empty. Phase 5 (write `tests/a-hello-world.sh`,
  `tests/a-tinycc.sh`, `tests/run-all.sh`, the pass/fail matrix across
  {amd64 native, arm64 qemu, windows wine} × {compiler-runs-here,
  output-runs-there}) was never implemented.
- `--target=amd64|arm64` (single-arch output, skipping the fat join) has a
  known bug in `apelink_join()` — noted but not revisited since it's not
  exercised by the plan's actual test matrix (which is about the fat-binary
  path). Low priority.
- This wrapper supports exactly one C-only, single-source-file compile per
  invocation, against exactly one cosmo runtime configuration. It is not,
  and was never meant to be, a general-purpose gcc replacement.
- `wrapper/` has its own small local git repo (separate from the
  `cosmopolitan` monorepo) with 8 commits tracking `cosmocc-min.c`'s
  evolution; `scripts/` was never under version control (edited directly on
  disk). Moving both into `cosmopolitan/third_party/minicosmocc/` (on the
  existing `minicosmocc` branch) with history preserved is a planned but
  not-yet-executed follow-up.
- `build/` (staged toolchain assets) and `dist/` (built output) are
  generated/fetched artifacts, not source — they're reproducible from a
  fresh `cosmocc` release via `scripts/build-blink-compile.sh` and were
  deliberately not committed anywhere.

## Directory structure

```
cosmo-toolchain/
  wrapper/cosmocc-min.c       the whole compiler wrapper (~650 lines)
  scripts/
    build-blink-compile.sh    entry point: builds dist/blink-compile.com
    _assemble.sh              shared build logic (bootstrap, embed, verify)
    embed-assets.py           zip-embeds staged assets into the built wrapper
    truncate-fat-remnants.py  the assimilate-waste fix (idempotent, re-run after re-staging)
    clean-ape-loaders.sh      removes global/user/temp APE loaders before tests
    strip-manifest.txt        full record of what was stripped/kept and why
  build/                      staged toolchain (generated, not committed)
    gcc-amd64/, gcc-arm64/    cc1, as, ld.bfd (+ lib/, no gcc or collect2)
    apelink/                  apelink, fixupobj, pecheck (amd64-native only)
    blink/                    blink-arm64.elf only
    include/                  shared cosmo headers
    gold/NOTE.md              no gold linker exists anywhere; ld.bfd substitutes
  dist/blink-compile.com      the built product (generated, not committed)
  tests/                      empty -- Phase 5 not yet implemented
```
