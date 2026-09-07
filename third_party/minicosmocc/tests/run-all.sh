#!/bin/bash
# Phase 5 orchestrator: runs every test scenario, cleaning APE loaders
# before each one, and reports an overall pass/fail summary.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCENARIOS=(
  "a-hello-world.sh"
  "a-tinycc.sh"
)

overall_rc=0
declare -A SCENARIO_RESULTS

for scenario in "${SCENARIOS[@]}"; do
  echo ""
  echo "############################################################"
  echo "# Running tests/$scenario"
  echo "############################################################"
  "$ROOT/scripts/clean-ape-loaders.sh" >/dev/null 2>&1 || true
  if "$SCRIPT_DIR/$scenario"; then
    SCENARIO_RESULTS["$scenario"]="PASS"
  else
    SCENARIO_RESULTS["$scenario"]="FAIL"
    overall_rc=1
  fi
done

echo ""
echo "############################################################"
echo "# run-all.sh FINAL SUMMARY"
echo "############################################################"
for scenario in "${SCENARIOS[@]}"; do
  echo "  ${SCENARIO_RESULTS[$scenario]}: $scenario"
done

exit "$overall_rc"
