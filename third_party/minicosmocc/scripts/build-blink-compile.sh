#!/bin/bash
# Builds Binary A: dist/blink-compile.com
# Fat APE wrapper + amd64/arm64 cosmo toolchains + Blink (for the
# wrapper's own internal cross-arch dispatch only; outputs it produces
# do not get Blink embedded).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_assemble.sh"
assemble "blink-compile"
