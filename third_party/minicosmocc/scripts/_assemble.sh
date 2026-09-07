#!/bin/bash
# Shared assembly logic for build-blink-compile.sh.
# Not meant to be run directly; sourced with $1 = final binary name
# (without extension), e.g. "blink-compile".
set -euo pipefail

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
WRAPPER_SRC="$ROOT/wrapper/cosmocc-min.c"
COSMOCC="$(cd "$ROOT/../../.cosmocc/current" && pwd)"

assemble() {
  local name="$1"
  local out="$DIST/$name.com"
  mkdir -p "$DIST"

  for dep in "$WRAPPER_SRC" "$BUILD/gcc-amd64" "$BUILD/gcc-arm64" \
             "$BUILD/apelink" "$BUILD/blink" "$BUILD/include"; do
    [ -e "$dep" ] || { echo "==> [$name] missing dependency: $dep" >&2; exit 1; }
  done
  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || {
    echo "==> [$name] need a host C compiler (cc or gcc) to bootstrap" >&2; exit 1;
  }
  command -v python3 >/dev/null 2>&1 || { echo "==> [$name] need python3" >&2; exit 1; }

  echo "==> [$name] building bootstrap wrapper with the host compiler"
  local bootstrap="$BUILD/.bootstrap-cosmocc-min"
  local host_cc
  host_cc=$(command -v cc || command -v gcc)
  "$host_cc" -std=c11 -D_GNU_SOURCE -O2 -o "$bootstrap" "$WRAPPER_SRC"

  # The bootstrap above is a plain host-glibc binary, not cosmo-linked,
  # so its execv() can't launch cc1/as/ld.bfd in their real fat/APE form
  # (that only works from a cosmo-linked caller's fork()+execv(), which
  # the *shipped* wrapper is). Stage single-arch-assimilated (plain ELF)
  # copies just for this one self-hosting step -- a build-time-only
  # concern that never affects the embedded runtime assets below.
  echo "==> [$name] staging plain-ELF toolchain copies for bootstrap use only"
  local bootstrap_assets="$BUILD/.bootstrap-assets"
  rm -rf "$bootstrap_assets"
  mkdir -p "$bootstrap_assets"
  for tree in gcc-amd64 gcc-arm64 blink include; do
    ln -s "$BUILD/$tree" "$bootstrap_assets/$tree"
  done
  for pair in "gcc-amd64:x86_64-linux-cosmo:-x" "gcc-arm64:aarch64-linux-cosmo:-x"; do
    IFS=: read -r tree triple flag <<<"$pair"
    rm -rf "$bootstrap_assets/$tree"
    mkdir -p "$bootstrap_assets/$tree/bin" "$bootstrap_assets/$tree/libexec/gcc/$triple/14.1.0" "$bootstrap_assets/$tree/lib"
    ln -s "$BUILD/$tree/lib"/* "$bootstrap_assets/$tree/lib/" 2>/dev/null || true
    "$COSMOCC/bin/assimilate" "$flag" -o "$bootstrap_assets/$tree/libexec/gcc/$triple/14.1.0/cc1" \
      "$BUILD/$tree/libexec/gcc/$triple/14.1.0/cc1"
    "$COSMOCC/bin/assimilate" "$flag" -o "$bootstrap_assets/$tree/bin/$triple-as" \
      "$BUILD/$tree/bin/$triple-as"
    "$COSMOCC/bin/assimilate" "$flag" -o "$bootstrap_assets/$tree/bin/$triple-ld.bfd" \
      "$BUILD/$tree/bin/$triple-ld.bfd"
    ln -sf "$triple-as" "$bootstrap_assets/$tree/bin/as"
    ln -sf "$triple-ld.bfd" "$bootstrap_assets/$tree/bin/ld.bfd"
  done
  # apelink/fixupobj/pecheck: same story, assimilate to plain ELF for
  # bootstrap use (the bootstrap always runs on this amd64 build host).
  #
  # This apelink is used ONLY to link the wrapper binary itself into its
  # final APE form (below) -- it always comes from the prebuilt cosmocc
  # release, not $BUILD's locally-built copy. Using the locally-built
  # one here was tried and reverted: joining the wrapper's OWN slices
  # with it produced a wrapper whose self-extraction shell script embeds
  # a corrupt gzip payload (deterministic "gzip: stdin: unexpected end
  # of file" on every fresh ~/.ape state) -- a distinct bug from the
  # Wine absolute-path one, specific to a locally-built apelink joining
  # a binary that embeds itself as its own loader payload. The prebuilt
  # apelink doesn't have this problem, so the wrapper binary itself
  # keeps self-extracting to the old ~/.ape-$VERSION path; only the
  # programs it goes on to compile (linked with the locally-built
  # apelink embedded as a runtime asset in step 4 of stage-toolchain.sh)
  # get the new ~/.ape/ape-$VERSION path.
  mkdir -p "$bootstrap_assets/apelink"
  cp "$BUILD/apelink/ape-x86_64.elf" "$BUILD/apelink/ape-aarch64.elf" "$BUILD/apelink/ape-m1.c" "$bootstrap_assets/apelink/"
  for tool in apelink fixupobj pecheck; do
    "$COSMOCC/bin/assimilate" -x -o "$bootstrap_assets/apelink/${tool}-amd64" "$COSMOCC/bin/$tool"
  done

  # The wrapper checks its own runtime cache (keyed only by
  # WRAPPER_VERSION, not by content) before even looking at
  # COSMOCC_MIN_ASSETS -- a cache left "ready" by an unrelated earlier
  # run (e.g. of the built product, using the real fat/APE assets) would
  # otherwise get reused here instead of these plain-ELF bootstrap
  # assets, breaking the non-cosmo bootstrap's execv() the same way a
  # fat cc1 always does. Clear it so this step is deterministic
  # regardless of ambient /tmp state.
  rm -rf "${TMPDIR:-/tmp}/cosmocc-min" "$HOME/.cache/cosmocc-min"

  echo "==> [$name] self-hosting: compiling the wrapper into a fat APE via the staged cosmo toolchain"
  rm -f "$out"
  COSMOCC_MIN_ASSETS="$bootstrap_assets" "$bootstrap" -o "$out" "$WRAPPER_SRC"
  rm -rf "$bootstrap_assets"

  local subdirs="gcc-amd64,gcc-arm64,apelink,blink,include"
  echo "==> [$name] embedding toolchain assets ($subdirs)"
  python3 "$ROOT/scripts/embed-assets.py" "$out" "$BUILD" "$subdirs"

  echo "==> [$name] verifying the assembled binary executes"
  # bare invocation with no source file: expected to print usage and
  # exit 1; anything else (crash, exec failure) means assembly is broken.
  set +e
  "$out" >/tmp/cosmocc-min-selfcheck.log 2>&1
  local rc=$?
  set -e
  if [ "$rc" != 1 ]; then
    echo "==> [$name] self-check failed (exit $rc):" >&2
    cat /tmp/cosmocc-min-selfcheck.log >&2
    exit 1
  fi
  rm -f /tmp/cosmocc-min-selfcheck.log

  local size_mb
  size_mb=$(du -m "$out" | cut -f1)
  echo "==> [$name] Binary size: ${size_mb} MB"
}
