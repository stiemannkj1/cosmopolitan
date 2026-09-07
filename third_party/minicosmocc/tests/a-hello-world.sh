#!/bin/bash
# Phase 5.1.1: hello-world (malloc/free) test for blink-compile.com.
#
# Matrix: {compile on amd64-native, arm64-via-qemu+Blink, windows-via-wine}
#       x {run on amd64-native, arm64-via-qemu, windows-via-wine}
# = 9 combinations. Runs to completion even if individual cells fail, so
# the final report always shows the full matrix, not just the first
# failure. clean-ape-loaders.sh is invoked before every scenario per
# Phase 4/5.3, and once more at the end as a check.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/dist/blink-compile.com"
COSMOCC="$(cd "$ROOT/../../.cosmocc/current" && pwd)"
WORK="$ROOT/tests/work/a-hello-world"
EXPECTED="hello from cosmo"

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

cat > hello.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(void) {
  char *buf = malloc(32);
  snprintf(buf, 32, "hello from %s", "cosmo");
  puts(buf);
  free(buf);
  return 0;
}
EOF

declare -A RESULTS
PASS=0
FAIL=0

record() {
  local label="$1" status="$2"
  RESULTS["$label"]="$status"
  if [ "$status" = "PASS" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
  fi
}

check_output() {
  local label="$1" actual="$2"
  if [ "$actual" = "$EXPECTED" ]; then
    record "$label" "PASS"
  else
    echo "    (got: '$actual', want: '$EXPECTED')" >&2
    record "$label" "FAIL"
  fi
}

# Runs the compiled hello binary on all three platforms and records each.
run_output_matrix() {
  local bin="$1" prefix="$2"
  local out rc

  if [ ! -f "$bin" ]; then
    record "$prefix run=amd64-native" "FAIL"
    record "$prefix run=arm64-qemu" "FAIL"
    record "$prefix run=windows-wine" "FAIL"
    return
  fi
  # Wine's Windows-translation layer doesn't preserve the Unix
  # executable bit on file creation (Windows has no equivalent concept);
  # a wine-compiled binary needs this the same way a real cross-platform
  # transfer would, regardless of which host later runs it.
  chmod +x "$bin"

  out=$("$bin" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && check_output "$prefix run=amd64-native" "$out" || record "$prefix run=amd64-native" "FAIL"

  if "$COSMOCC/bin/assimilate" -a -o "$bin.arm64.elf" "$bin" 2>/dev/null; then
    out=$(qemu-aarch64 "$bin.arm64.elf" 2>/dev/null); rc=$?
    [ "$rc" -eq 0 ] && check_output "$prefix run=arm64-qemu" "$out" || record "$prefix run=arm64-qemu" "FAIL"
  else
    record "$prefix run=arm64-qemu" "FAIL"
  fi

  out=$(wine "$bin" 2>/dev/null | tr -d '\r'); rc=$?
  [ "$rc" -eq 0 ] && check_output "$prefix run=windows-wine" "$out" || record "$prefix run=windows-wine" "FAIL"
}

clean_loaders() { "$ROOT/scripts/clean-ape-loaders.sh" >/dev/null 2>&1 || true; }

# Cache state from a wine-hosted run and a plain Linux run can otherwise
# collide at overlapping paths with different ownership/attributes;
# clearing every known cache location before each scenario keeps runs
# reproducible regardless of what earlier manual testing left behind.
clean_wrapper_caches() {
  rm -rf /tmp/cosmocc-min "$HOME/.cache/cosmocc-min" 2>/dev/null
  rm -rf "$HOME"/.wine/drive_c/users/*/AppData/Local/Temp/cosmocc-min* 2>/dev/null
  true
}

echo "=== Scenario 1: compile on amd64 (native) ==="
clean_loaders
clean_wrapper_caches
rm -f hello_native
if "$BIN" -o hello_native hello.c 2>&1; then
  run_output_matrix "$WORK/hello_native" "compile=amd64-native,"
else
  echo "  compile FAILED" >&2
  run_output_matrix "/nonexistent" "compile=amd64-native,"
fi

echo ""
echo "=== Scenario 2: compile on arm64 (qemu-aarch64 + Blink dispatch) ==="
clean_loaders
clean_wrapper_caches
rm -f "$WORK/blink-compile.arm64.elf" hello_from_arm64
if "$COSMOCC/bin/assimilate" -a -o "$WORK/blink-compile.arm64.elf" "$BIN" \
   && qemu-aarch64 -E HOME="$HOME" "$WORK/blink-compile.arm64.elf" -o hello_from_arm64 hello.c 2>&1; then
  run_output_matrix "$WORK/hello_from_arm64" "compile=arm64-qemu,"
else
  echo "  compile FAILED" >&2
  run_output_matrix "/nonexistent" "compile=arm64-qemu,"
fi

echo ""
echo "=== Scenario 3: compile on windows (wine) ==="
clean_loaders
clean_wrapper_caches
cp "$BIN" "$WORK/blink-compile-wine.exe"
rm -f hello_from_wine
wine "$WORK/blink-compile-wine.exe" -o hello_from_wine hello.c 2>&1 | grep -v "fixme\|semi-stub"
if [ -f hello_from_wine ]; then
  run_output_matrix "$WORK/hello_from_wine" "compile=windows-wine,"
else
  echo "  compile FAILED" >&2
  run_output_matrix "/nonexistent" "compile=windows-wine,"
fi

echo ""
echo "=== Determinism check: are all three outputs byte-identical? ==="
if cmp -s hello_native hello_from_arm64 2>/dev/null && cmp -s hello_native hello_from_wine 2>/dev/null; then
  record "cross-compiler-host byte-identical output" "PASS"
else
  record "cross-compiler-host byte-identical output" "FAIL"
fi

echo ""
echo "=== Cross-check: no APE loader silently reinstalled ==="
if "$ROOT/scripts/clean-ape-loaders.sh"; then
  record "no loader silently reinstalled" "PASS"
else
  record "no loader silently reinstalled" "FAIL"
fi

echo ""
echo "=== a-hello-world.sh SUMMARY: $PASS passed, $FAIL failed (of $((PASS + FAIL))) ==="
for label in "${!RESULTS[@]}"; do
  echo "  ${RESULTS[$label]}: $label"
done | sort

[ "$FAIL" -eq 0 ]
