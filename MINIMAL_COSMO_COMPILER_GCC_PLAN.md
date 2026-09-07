# Plan: Minimal Cosmopolitan/APE GCC Toolchain (2 Standalone Binaries)

Pause between each step to gather feedback on whether to continue or to improve or change things first.

## Goal Recap
Produce two standalone APE binaries built on Cosmopolitan libc:

- **Binary A ("blink-compile")**: runs on arm64 via Blink emulation for compilation; requires an amd64 GCC and an arm64 GCC internally; outputs APE binaries (no embedded Blink).
- **Binary B ("blink-embed")**: same compilation path as A, but embeds Blink into the binaries it produces so those output binaries also run natively on amd64 and via Blink emulation on arm64.

Both must compile C only, strip C++/sanitizers(GCC)/OpenMP/LTO cruft (keep cosmo sanitizers), include gold linker + cosmo headers/crt/libc objects, and expose a single wrapper CLI that does compile+link+header-extraction+APE-generation, auto-recommending `-ffunction-sections -fdata-sections --gc-sections --icf=all` when absent.

---

## Phase 0 — Environment Prep

1. Verify `~/Projects/work/cosmopolitan` exists; if not, `git clone https://github.com/jart/cosmopolitan.git ~/Projects/work/cosmopolitan`.
2. Clean the repo of prior build artifacts:
   ```
   cd ~/Projects/work/cosmopolitan
   git clean -xffd
   git submodule foreach --recursive git clean -xffd
   make clean 2>/dev/null || true
   ```
3. Verify `~/Projects/work/tinycc` exists (clone from https://github.com/Tiny-C-Compiler/tinycc-mirror-repository if missing).
4. Record host toolchain versions (make, gcc, git) and confirm required tools are installed: `make`, `git`, `curl`, `qemu-aarch64` (or full-system qemu), `wine`, `binutils` (for gold linker source/binary), `python3`.
5. Create working directories:
   ```
   mkdir -p ~/Projects/work/cosmo-toolchain/{build,dist,scripts,tests}
   ```

## Phase 1 — Acquire Cosmopolitan-Provided Binaries

1. From the Cosmopolitan repo/releases, identify and download the prebuilt Cosmopolitan-patched toolchain artifacts (do NOT build GCC from vanilla GNU source):
   - Cosmopolitan-patched `x86_64` GCC binary/toolchain release.
   - Cosmopolitan-patched `aarch64` GCC binary/toolchain release (for the arm64-native compile path used inside Binary A/B when running natively on arm64 hardware, and for Phase 3 host-native builds).
   - Cosmopolitan gold linker binary (`ld.gold` build shipped/patched by Cosmopolitan), or build gold using the Cosmopolitan-provided sources/patches only if no prebuilt exists.
   - Prebuilt Blink binary/source from https://github.com/jart/blink (clone and build Blink natively for arm64 and amd64 hosts if no prebuilt release fits).
2. Extract/stage these into `~/Projects/work/cosmo-toolchain/build/{gcc-amd64,gcc-arm64,gold,blink}`.
3. From the Cosmopolitan repo build output (`o/` directory after `make`), collect:
   - `cosmopolitan.h` (single-header amalgamation) and any needed sub-headers.
   - `crt.o`, `crt1.o`/equivalent crt objects.
   - `libc.a` / `cosmopolitan.a` (the libc objects).
   - `ape.lds` linker script, `ape.S`/`ape-*.o` loader stubs, and the `apelink`/`ape` conversion tool (build via `make -j$(nproc) o/tool/build/apelink.com` or equivalent target).
   - Confirm via the Cosmopolitan build system which targets to `make` to produce these without pulling in C++/OpenMP/LTO/GCC-sanitizer support; only build the C runtime targets.
4. Strip the fetched/staged GCC toolchains down to C-only, no-LTO, no-OpenMP, no-GCC-sanitizer components:
   - Remove `cc1plus`, `liblto_plugin*`, `libgomp*`, `libasan*`/`libtsan*`/`libubsan*` (GCC's own), C++ headers/libstdc++, LTO wrapper binaries.
   - Keep `cc1`, `as`, `collect2`, `gold`, cosmo's own sanitizer support (ASAN/etc. as implemented inside cosmopolitan libc, not GCC's runtime sanitizer libs).
   - Document the exact removed file list in `scripts/strip-manifest.txt` for reproducibility.

## Phase 2 — Wrapper Program

1. Design a single wrapper CLI (e.g. `cosmocc-min`) written in C (compiled with the host's cosmo-aware compiler, or POSIX shell/portable C if simpler for zero-dependency operation) that:
   - Accepts standard GCC-style args (`-o`, `-c`, `-I`, `-L`, `-l`, `-D`, optimization flags, etc.) and passes them through to the staged `cc1`/`as`/`gold` pipeline.
   - Detects target request (implicit host arch/OS, or explicit `--target=...` flag you define) and selects the amd64 or arm64 internal GCC accordingly, invoking Blink for cross-arch execution when the host can't run the needed GCC natively.
   - Performs header extraction on first run (or on demand) by unpacking bundled `cosmopolitan.h` and crt/libc objects to a cache dir if not already present.
   - Performs compilation → object files → link (via gold, cosmo crt/libc objects) → APE conversion (via `apelink`) as one pipeline, cleaning up intermediates unless `-save-temps` is passed.
   - Inspects the final argument list; if `-ffunction-sections`, `-fdata-sections`, `--gc-sections`, or `--icf=all` are missing, print a one-line recommendation (stderr) suggesting they be added for smaller binaries, but proceed without forcing them.
   - For Binary B specifically: after producing the APE, embed the Blink binary/runtime into the output artifact (e.g., append/link Blink as an embedded APE payload or auxiliary section) so the produced binary can self-emulate on arm64 hosts while running natively on amd64.
2. Keep the wrapper source in `~/Projects/work/cosmo-toolchain/wrapper/` under version control (even if just local git init) for the shell scripts to reference.

## Phase 3 — Build Scripts (one per binary)

1. `scripts/build-blink-compile.sh` — builds **Binary A**:
   - Assembles wrapper + amd64 GCC (C-only, stripped) + arm64 GCC (C-only, stripped) + gold + Blink (for emulation only, not embedded in outputs) + cosmo headers/crt/libc objects + apelink into one self-contained tree.
   - Packages everything into a single APE binary (embedding the toolchain data as embedded/zip-appended assets the wrapper reads at runtime, consistent with Cosmopolitan's APE self-contained-zip convention).
   - Outputs to `dist/blink-compile.com` (or extension-less APE convention).
2. `scripts/build-blink-embed.sh` — builds **Binary B**:
   - Same as above, plus bundles the Blink runtime as an embeddable payload so the wrapper's link step can inject it into every binary it produces.
   - Outputs to `dist/blink-embed.com`.
3. Both scripts must be idempotent, take no required arguments, log each step, and fail fast (`set -euo pipefail`) on any missing dependency.
4. After each script builds its binary, print the final APE file size in MB:
   ```
   size_mb=$(du -m dist/<binary>.com | cut -f1)
   echo "Binary size: ${size_mb} MB"
   ```

## Phase 4 — Loader Cleanup Helper

1. Create `scripts/clean-ape-loaders.sh` that, before every test run, removes:
   - Global APE loader (e.g. `/usr/bin/ape`, `/usr/local/bin/ape`, or wherever Cosmopolitan installs the binfmt_misc/loader).
   - User-level loader (e.g. `~/.ape`, `~/.local/bin/ape`, or equivalent per Cosmopolitan docs).
   - Temp loader locations (`/tmp/.ape-*`, `$TMPDIR/ape*`).
   - Confirms removal and re-checks nothing was silently reinstalled.
2. This script is invoked as the first step of every test scenario below.

## Phase 5 — Test Suite

Create `tests/run-all.sh` orchestrating the following, calling `clean-ape-loaders.sh` before each numbered scenario. Each scenario should be its own script in `tests/` for isolation and rerun-ability.

### 5.1 Binary A (blink-compile) Tests
1. `tests/a-hello-world.sh`:
   - Write a minimal `hello.c` using `malloc`/`free`.
   - Compile with `dist/blink-compile.com` to produce an APE.
   - Run the APE natively on amd64; run under `qemu-aarch64` for arm64; run under `wine` for Windows. Assert correct stdout/exit code on all three. On failure, diagnose, patch wrapper/toolchain, rebuild via Phase 3 script, and re-run.
   - Additionally, execute `dist/blink-compile.com` itself natively on amd64, then under qemu-aarch64 for arm64, then under wine for Windows, each time compiling `hello.c` and validating the produced APE runs correctly on amd64/arm64/Windows (9 total run combinations for the compiler-runs-here × target-runs-there matrix, or as many as make sense given amd64/arm64/Windows compiler execution is being tested per the request).
2. `tests/a-tinycc.sh`:
   - Use `dist/blink-compile.com` to build tinycc from `~/Projects/work/tinycc` producing an APE tinycc.
   - Run APE tinycc on amd64 (native), arm64 (qemu), Windows (wine) to each compile tinycc's own sources; byte-compare the three resulting (non-APE) tinycc binaries for exact equality (accounting for embedded build timestamps/paths — normalize or disable those in the build if needed for determinism).
   - Use the resulting non-APE tinycc to compile the `hello.c` test program and confirm it runs correctly.
   - Fix any determinism/build bugs found, rebuild via Phase 3 as needed, and re-run until passing.

### 5.2 Binary B (blink-embed) Tests
1. `tests/b-hello-world.sh`: same structure as 5.1 step 1, but using `dist/blink-embed.com`, and additionally confirming the compiled `hello.c` APE (with embedded Blink) runs correctly with no external Blink install present on the arm64 test host.
2. `tests/b-tinycc.sh`: same structure as 5.1 step 2, but using `dist/blink-embed.com`.

### 5.3 Cross-Check
1. Confirm no global/user/temp APE loader was silently reinstalled by any test (re-run `clean-ape-loaders.sh` as a check, not just a cleanup, after each scenario).
2. Collect pass/fail matrix across: {Binary A, Binary B} × {hello-world, tinycc} × {amd64 native, arm64 qemu, windows wine} × {compiler-runs-here, output-runs-there}.

## Phase 6 — Bug Fix Loop

1. For every failing test in Phase 5, root-cause against wrapper logic, GCC flag pass-through, gold linker invocation, apelink step, or Blink embedding step.
2. Patch the wrapper source and/or build scripts, re-run the relevant Phase 3 build script to regenerate the affected binary, then re-run only the previously failing test(s) before re-running the full suite.
3. Repeat until all Phase 5 scenarios pass cleanly on a freshly loader-cleaned system.

## Phase 7 - allow self-hosting

1. Embed the wrapper program source file directly into the binary
2. When creating the on-disk cache, extrct the wrapper program source as well (it must always be  a single C source file)


## Phase 7 - allow self-hosting

1. Embed the wrapper program source file directly into the binary
2. When creating the on-disk cache, extrct the wrapper program source as well (it must always be  a single C source file)

## Phase 7 - allow self-hosting

1. Embed the wrapper program source file directly into the binary
2. When creating the on-disk cache, extrct the wrapper program source as well (it must always be  a single C source file)

## Phase 7 - allow self-hosting

1. Embed the wrapper program source file directly into the binary
2. When creating the on-disk cache, extrct the wrapper program source as well (it must always be  a single C source file)
3. Test that self hosting on amd64, arm64 (via qemu), and windows (via wine) with both binaries. Add a print statement and validate that we can rebuild the APE compiler on all those systems and that the APE compiler re-built on amd64 runs on arm64 and windows.

## Phase 8 — Final Report

1. Run both Phase 3 build scripts fresh (clean checkout of Phase 0) to confirm reproducibility.
2. Print final size-in-MB output for `dist/blink-compile.com` and `dist/blink-embed.com`.
3. Print the full Phase 5 pass/fail matrix as the final validation report.
