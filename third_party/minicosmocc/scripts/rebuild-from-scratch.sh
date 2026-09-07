#!/bin/bash
# Rebuilds the entire toolchain from scratch: wipes build/ and dist/,
# re-stages build/ from a cosmocc release (downloading it if not already
# cached), reassembles dist/blink-compile.com, and runs the full test
# suite. Set COSMOCC_VERSION to stage from a different cosmocc release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "############################################################"
echo "# 1/3: staging build/ from a cosmocc release"
echo "############################################################"
"$SCRIPT_DIR/stage-toolchain.sh"

echo ""
echo "############################################################"
echo "# 2/3: assembling dist/blink-compile.com"
echo "############################################################"
rm -rf "$ROOT/dist"
"$SCRIPT_DIR/build-blink-compile.sh"

echo ""
echo "############################################################"
echo "# 3/3: running the test suite"
echo "############################################################"
"$ROOT/tests/run-all.sh"
