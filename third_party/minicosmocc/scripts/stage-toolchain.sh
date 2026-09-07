#!/bin/bash
# Stages build/ from scratch: downloads (or reuses a cached) cosmocc
# release, assimilates every dual-arch tool to an amd64-native view with
# the zero+trim technique (see zero-trim.py), copies the filtered lib/
# and include/ trees, and installs the vendored Blink binary.
#
# This is the "Source" step described in scripts/strip-manifest.txt,
# fully automated. Re-run after a cosmocc version bump (set
# COSMOCC_VERSION) to re-derive build/ from the new release; the
# zero+trim math is re-measured from the fresh binaries each time, not
# hardcoded to today's offsets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$ROOT/build"

COSMOCC_VERSION="${COSMOCC_VERSION:-4.0.2}"
COSMOCC_STORE="$(cd "$ROOT/../.." && pwd)/.cosmocc"
COSMOCC="$COSMOCC_STORE/$COSMOCC_VERSION"
ZERO_TRIM="$SCRIPT_DIR/zero-trim.py"

# ---------------------------------------------------------------------
# 1. cosmocc release: reuse the cached extraction, or download it.
# ---------------------------------------------------------------------
if [ ! -x "$COSMOCC/bin/assimilate" ]; then
  echo "==> downloading cosmocc $COSMOCC_VERSION"
  mkdir -p "$COSMOCC_STORE"
  tmp_zip="$(mktemp "${TMPDIR:-/tmp}/cosmocc-$COSMOCC_VERSION.XXXXXX.zip")"
  curl -fL -o "$tmp_zip" \
    "https://github.com/jart/cosmopolitan/releases/download/${COSMOCC_VERSION}/cosmocc-${COSMOCC_VERSION}.zip"
  rm -rf "$COSMOCC.tmp"
  mkdir -p "$COSMOCC.tmp"
  (cd "$COSMOCC.tmp" && unzip -q "$tmp_zip")
  rm -f "$tmp_zip"
  mv "$COSMOCC.tmp" "$COSMOCC"
fi
ln -sfn "$COSMOCC_VERSION" "$COSMOCC_STORE/current"
echo "==> using cosmocc release: $COSMOCC"

command -v python3 >/dev/null 2>&1 || { echo "need python3" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "need readelf (binutils)" >&2; exit 1; }

# ---------------------------------------------------------------------
# 2. Fresh build/ layout.
# ---------------------------------------------------------------------
echo "==> wiping and recreating $BUILD"
rm -rf "$BUILD"
mkdir -p "$BUILD/gcc-amd64/bin" "$BUILD/gcc-amd64/lib" \
         "$BUILD/gcc-amd64/libexec/gcc/x86_64-linux-cosmo/14.1.0" \
         "$BUILD/gcc-arm64/bin" "$BUILD/gcc-arm64/lib" \
         "$BUILD/gcc-arm64/libexec/gcc/aarch64-linux-cosmo/14.1.0" \
         "$BUILD/apelink" "$BUILD/blink" "$BUILD/include" "$BUILD/gold"

# lib/ files to keep per tree: the C-only cosmo runtime pieces the
# wrapper's link_one() needs. Everything else in the release's lib dirs
# (libstdc++.a, libcxx.a, libgomp.a/.spec, and the dbg/optlinux/tiny
# variant subdirs) is C++/OpenMP/alternate-libc-variant support this
# C-only, single-variant toolchain never uses -- see strip-manifest.txt.
AMD64_LIB_KEEP=(ape-no-modify-self.o ape.lds ape.o crt.o libc.a libcosmo.a
                libcrypt.a libdl.a libgcc_s.a libm.a libpthread.a
                libresolv.a librt.a libunwind.a)
ARM64_LIB_KEEP=(aarch64.lds crt.o libc.a libcosmo.a libcrypt.a libdl.a
                libgcc_s.a libm.a libpthread.a libresolv.a librt.a
                libunwind.a)

# ---------------------------------------------------------------------
# 3. Per-target tree: cc1 / as / ld.bfd, assimilated amd64-native +
#    zero+trimmed, plus the filtered lib/ set.
# ---------------------------------------------------------------------
stage_tree() {
  local tree="$1" triple="$2"
  local dst_root="$BUILD/$tree"
  local cc1_src="$COSMOCC/libexec/gcc/$triple/14.1.0/cc1"

  echo "==> [$tree] assimilating cc1/as/ld.bfd to amd64-native + zero-trim"
  python3 "$ZERO_TRIM" fat "$cc1_src" \
    "$dst_root/libexec/gcc/$triple/14.1.0/cc1" "$COSMOCC"

  for tool in as ld.bfd; do
    "$COSMOCC/bin/assimilate" -x -o "$dst_root/bin/$triple-$tool" \
      "$COSMOCC/bin/$triple-$tool"
    python3 "$ZERO_TRIM" fat "$COSMOCC/bin/$triple-$tool" \
      "$dst_root/bin/$triple-$tool" "$COSMOCC"
  done
  ln -sf "$triple-as" "$dst_root/bin/as"
  ln -sf "$triple-ld.bfd" "$dst_root/bin/ld.bfd"
}

stage_tree gcc-amd64 x86_64-linux-cosmo
stage_tree gcc-arm64 aarch64-linux-cosmo

echo "==> [gcc-amd64] staging lib/"
for f in "${AMD64_LIB_KEEP[@]}"; do
  cp "$COSMOCC/x86_64-linux-cosmo/lib/$f" "$BUILD/gcc-amd64/lib/$f"
done
echo "==> [gcc-arm64] staging lib/"
for f in "${ARM64_LIB_KEEP[@]}"; do
  cp "$COSMOCC/aarch64-linux-cosmo/lib/$f" "$BUILD/gcc-arm64/lib/$f"
done

# ---------------------------------------------------------------------
# 4. apelink / fixupobj / pecheck: amd64-native only (both host arches
#    are served by Blink dispatch on arm64 -- see cosmocc-min.c), plus
#    the ape-*.elf/.macho loader-stub data files, copied verbatim.
# ---------------------------------------------------------------------
echo "==> [apelink] assimilating apelink/fixupobj/pecheck to amd64-native + zero-trim"
for tool in apelink fixupobj pecheck; do
  "$COSMOCC/bin/assimilate" -x -o "$BUILD/apelink/${tool}-amd64" "$COSMOCC/bin/$tool"
  python3 "$ZERO_TRIM" fat "$COSMOCC/bin/$tool" "$BUILD/apelink/${tool}-amd64" "$COSMOCC"
done
for f in ape-x86_64.elf ape-aarch64.elf ape-m1.c ape-x86_64.macho; do
  cp "$COSMOCC/bin/$f" "$BUILD/apelink/$f"
done

# ---------------------------------------------------------------------
# 5. Blink: vendored prebuilt binary (see vendor/README.md -- there is
#    no upstream prebuilt release and no aarch64 cross-compiler on this
#    host to build it from source), zero-trimmed to drop its unstripped
#    debug sections.
# ---------------------------------------------------------------------
echo "==> [blink] installing vendored blink-arm64.elf + trim"
cp "$ROOT/vendor/blink-arm64.elf" "$BUILD/blink/blink-arm64.elf"
chmod +x "$BUILD/blink/blink-arm64.elf"
python3 "$ZERO_TRIM" single "$BUILD/blink/blink-arm64.elf"

# ---------------------------------------------------------------------
# 6. Shared include/, staged once.
# ---------------------------------------------------------------------
echo "==> [include] staging shared headers"
cp -a "$COSMOCC/include/." "$BUILD/include/"

# ---------------------------------------------------------------------
# 7. gold/: documents that no gold linker exists in this ecosystem.
# ---------------------------------------------------------------------
cat > "$BUILD/gold/NOTE.md" <<'EOF'
# No gold linker in this toolchain

Cosmopolitan does not ship or build a patched `ld.gold`. Verified by
grepping the `cosmopolitan` monorepo (no gold sources/targets anywhere)
and inspecting the `cosmocc` release `bin/` directory (only `ld` and
`ld.bfd` are present, per architecture). Cosmopolitan builds itself with
`ld.bfd`.

Decision: `ld.bfd` substitutes for gold everywhere this plan calls for a
gold linker. The actual binaries are staged (amd64-native, zero+trimmed,
APE/PE structure preserved) at:

  build/gcc-amd64/bin/x86_64-linux-cosmo-ld.bfd
  build/gcc-arm64/bin/aarch64-linux-cosmo-ld.bfd
EOF

du_before=$(du -sh "$COSMOCC" 2>/dev/null | cut -f1)
du_after=$(du -sh "$BUILD" 2>/dev/null | cut -f1)
echo ""
echo "==> stage-toolchain.sh done. $BUILD staged ($du_after; cosmocc release was $du_before)"
