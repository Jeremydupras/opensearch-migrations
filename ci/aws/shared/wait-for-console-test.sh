#!/usr/bin/env bash
# Follows a chained test (see chain_state_uri in lib.sh) that an earlier job started in the migration console pod:
# prints its pytest log as it grows and waits for its exit code, for at most --max-minutes. If the test is still running
# then, it records that and exits 0, so the next job of the chain carries on; with --last it fails instead. When the test
# finishes, it saves the test report for collect-logs.sh and exits with the test's exit code.
#
# Run after chain-state.sh restore. Usage: wait-for-console-test.sh --max-minutes N [--last]
set -uo pipefail
source "$(dirname "$0")/lib.sh"
state_load

max_minutes="" last=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-minutes) max_minutes="$2"; shift 2 ;;
        --last) last=true; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ "$max_minutes" =~ ^[0-9]+$ ]] || die "--max-minutes N is required"
[[ "${TEST_STATUS:-}" == running ]] || die "No running test recorded in $CI_STATE_FILE (status: ${TEST_STATUS:-none})"
: "${KUBE_CONTEXT:?}" "${TEST_UNIQUE_ID:?}" "${TEST_CONSOLE_UID:?}"

kc=(kubectl --context="$KUBE_CONTEXT" --request-timeout=60s -n ma)
console=migration-console-0
log_file="/tmp/${TEST_UNIQUE_ID}_pytest.log"
exit_code_file="/tmp/${TEST_UNIQUE_ID}_exit_code"
report_file="/root/lib/integ_test/results/${TEST_UNIQUE_ID}/test_report.json"
deadline=$((SECONDS + max_minutes * 60))
printed=0 missing_pod=0
chunk=$(mktemp)

log "Following test $TEST_UNIQUE_ID in $console for up to $max_minutes minutes (last job: $last)"
while true; do
    uid=$("${kc[@]}" get pod "$console" -o jsonpath='{.metadata.uid}' 2>/dev/null) || uid=""
    if [[ -z "$uid" ]]; then
        missing_pod=$((missing_pod + 1))
        [[ $missing_pod -lt 3 ]] || { state_set TEST_STATUS finished; die "$console is gone; the test's state is lost"; }
    elif [[ "$uid" != "$TEST_CONSOLE_UID" ]]; then
        state_set TEST_STATUS finished
        die "$console was replaced (uid $TEST_CONSOLE_UID -> $uid); the test's pod-local state is lost"
    else
        missing_pod=0
        # New log output since the last poll; this job's log starts from the beginning of the test's log.
        if "${kc[@]}" exec "$console" -- tail -c "+$((printed + 1))" "$log_file" > "$chunk" 2>/dev/null; then
            cat "$chunk"
            printed=$((printed + $(wc -c < "$chunk")))
        fi
        if exit_code=$("${kc[@]}" exec "$console" -- cat "$exit_code_file" 2>/dev/null) && [[ "$exit_code" =~ ^[0-9]+$ ]]; then
            "${kc[@]}" exec "$console" -- tail -c "+$((printed + 1))" "$log_file" 2>/dev/null
            mkdir -p "$REPO_ROOT/libraries/testAutomation/reports"
            "${kc[@]}" exec "$console" -- cat "$report_file" \
                > "$REPO_ROOT/libraries/testAutomation/reports/test-report-$TEST_UNIQUE_ID.json" 2>/dev/null || true
            state_set TEST_STATUS finished
            log "Test $TEST_UNIQUE_ID finished with exit code $exit_code"
            exit "$exit_code"
        fi
    fi
    if [[ $SECONDS -ge $deadline ]]; then
        if [[ "$last" == true ]]; then
            state_set TEST_STATUS finished
            die "Test $TEST_UNIQUE_ID is still running after the chain's last job"
        fi
        log "Test $TEST_UNIQUE_ID is still running; the next job of the chain carries on"
        exit 0
    fi
    sleep 60
done
