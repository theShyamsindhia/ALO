#!/usr/bin/env bash
set -euo pipefail

# No installed app, recording permissions, or production room data required.
# Run from any directory: bash /path/to/alo/Scripts/test_room_scenarios.sh [repeat-count]
iterations="${1:-1}"
if [[ ! "$iterations" =~ ^[1-9][0-9]?$|^100$ ]] || (( $# > 1 )); then
    echo "Usage: bash Scripts/test_room_scenarios.sh [repeat-count: 1..100]" >&2
    exit 2
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
test_log_dir="$(mktemp -d "${TMPDIR:-/tmp}/alo-room-scenarios.XXXXXX")"
echo "Scenario logs: $test_log_dir"
filter='RoomNetworkSimulationTests|RoomStatePendingDependencyTests|mixedTrafficSurvivesListenerRestarts|lateListenerNetworkDelayCannotMasqueradeAsHardwareLatency|lateHardwareCalibrationDoesNotCauseRepeatedCutovers'
for (( iteration=1; iteration<=iterations; iteration++ )); do
    echo "Scenario pass $iteration/$iterations"
    # These scenarios enforce real processing deadlines. Match the optimized
    # CI suite; Debug overhead can exhaust the budget before a storage boundary
    # is reached. Keep every fixture and timing limit intact.
    if ! swift test -c release --no-parallel \
        -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=CapturePropagation \
        -Xswiftc -Xllvm -Xswiftc -sil-disable-pass-only-function=main \
        --filter "$filter" 2>&1 | tee "$test_log_dir/run-$iteration.log"; then
        echo "Scenario failed. Logs retained at: $test_log_dir" >&2
        exit 1
    fi
    if ! grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites)? passed' "$test_log_dir/run-$iteration.log"; then
        echo "Scenario runner did not report executed tests. Logs retained at: $test_log_dir" >&2
        exit 1
    fi
done
echo "All $iterations scenario passes succeeded. Logs: $test_log_dir"
