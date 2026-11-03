#!/usr/bin/env bash
# Collects diagnostics from a test's deployment into a directory that aws-ci-job.yml uploads as a public workflow
# artifact. Runs after the test and before cleanup, so the EKS cluster and stacks still exist. Reads what was deployed
# from the CI state file the test script wrote. Best effort: it never fails the job.
#
# What it collects: Kubernetes pods, events, container logs, Argo workflows and migration resources from the 'ma'
# namespace; the pytest logs from the migration console; failed CloudFormation stack events; the testAutomation
# logs/reports. Never Secrets or ConfigMaps. Account IDs, AWS access key IDs and password fields are masked, because
# the artifact is public.
#
# Usage: collect-logs.sh OUTPUT_DIR
set -uo pipefail
source "$(dirname "$0")/lib.sh"
state_load

out="${1:?Usage: collect-logs.sh OUTPUT_DIR}"
mkdir -p "$out"
NAMESPACE=ma
# Per container, so one chatty pod can't fill the artifact.
LOG_LIMIT_BYTES=20000000

capture() {
    local file="$1"; shift
    mkdir -p "$(dirname "$out/$file")"
    "$@" > "$out/$file" 2>&1 || true
}

collect_kubernetes() {
    local ctx="$KUBE_CONTEXT" kc pod
    if ! kubectl config get-contexts "$ctx" >/dev/null 2>&1; then
        log "collect-logs: no kube context '$ctx'; skipping Kubernetes"
        return 0
    fi
    kc=(kubectl --context="$ctx" --request-timeout=60s)
    log "collect-logs: Kubernetes ($ctx)"
    capture k8s/pods.txt "${kc[@]}" get pods -A -o wide
    capture k8s/nodes.txt "${kc[@]}" get nodes -o wide
    capture k8s/events.txt "${kc[@]}" get events -A --sort-by=.lastTimestamp
    capture k8s/workflows.yaml "${kc[@]}" -n "$NAMESPACE" get workflows -o yaml
    capture k8s/migration-resources.yaml "${kc[@]}" -n "$NAMESPACE" get \
        kafkaclusters,capturedtraffics,captureproxies,datasnapshots,snapshotmigrations,trafficreplays,approvalgates,migrationruns \
        -o yaml
    for pod in $("${kc[@]}" -n "$NAMESPACE" get pods --no-headers 2>/dev/null |
                 awk '$3 != "Running" && $3 != "Completed" {print $1}'); do
        "${kc[@]}" -n "$NAMESPACE" describe pod "$pod" >> "$out/k8s/describe-unhealthy-pods.txt" 2>&1 || true
    done

    for pod in $("${kc[@]}" -n "$NAMESPACE" get pods -o name 2>/dev/null); do
        pod="${pod#pod/}"
        capture "k8s/logs/$pod.log" "${kc[@]}" -n "$NAMESPACE" logs "$pod" --all-containers --prefix \
            --limit-bytes="$LOG_LIMIT_BYTES"
        capture "k8s/logs/$pod.previous.log" "${kc[@]}" -n "$NAMESPACE" logs "$pod" --all-containers --prefix \
            --previous --limit-bytes="$LOG_LIMIT_BYTES"
        # Most pods have no previous container; drop the empty or error-only files.
        grep -q -v -E '^Error from server|previous terminated container .* not found' \
            "$out/k8s/logs/$pod.previous.log" 2>/dev/null || rm -f "$out/k8s/logs/$pod.previous.log"
    done

    # testAutomation runs pytest in the background in the console pod and writes its log under /tmp.
    if "${kc[@]}" -n "$NAMESPACE" get pod migration-console-0 >/dev/null 2>&1; then
        # shellcheck disable=SC2016  # expands in the pod
        capture k8s/migration-console-pytest.log "${kc[@]}" -n "$NAMESPACE" exec migration-console-0 -- \
            sh -c 'for f in /tmp/*pytest*.log; do [ -f "$f" ] && echo "===== $f" && cat "$f"; done'
    fi
}

collect_stack_events() {
    local stack
    for stack in "${MA_STACK_NAME:-}" "${CLUSTER_STACK_NAME:-}"; do
        [[ -n "$stack" ]] || continue
        log "collect-logs: failed events for stack $stack"
        # shellcheck disable=SC2016  # backticks are JMESPath literals
        capture "cloudformation/$stack.failed-events.txt" aws cloudformation describe-stack-events --stack-name "$stack" \
            --query 'StackEvents[?contains(ResourceStatus, `FAILED`)].[Timestamp,LogicalResourceId,ResourceType,ResourceStatus,ResourceStatusReason]' \
            --output text
    done
}

# Masks the obvious secret shapes. The artifact is public, like the job log.
mask_files() {
    find "$out" -type f -print0 | xargs -0 -r sed -i.bak -E \
        -e 's/[0-9]{12}/[MASKED]/g' \
        -e 's/(AKIA|ASIA)[A-Z0-9]{16}/[MASKED-KEY-ID]/g' \
        -e 's#://[^/:@[:space:]]+:[^@[:space:]]+@#://[MASKED]@#g' \
        -e 's/("?[Pp]assword"?[[:space:]]*[:=][[:space:]]*)("[^"]*"|[^[:space:],}]+)/\1[MASKED]/g' \
        -e 's/([Aa]uthorization"?[[:space:]]*:[[:space:]]*"?(Basic|Bearer|basic|bearer)[[:space:]]+)[^[:space:]"]+/\1[MASKED]/g'
    find "$out" -type f -name '*.bak' -delete
}

[[ -n "${KUBE_CONTEXT:-}" ]] && collect_kubernetes
collect_stack_events

for dir in logs reports; do
    if [[ -d "$REPO_ROOT/libraries/testAutomation/$dir" ]]; then
        mkdir -p "$out/testAutomation"
        cp -R "$REPO_ROOT/libraries/testAutomation/$dir" "$out/testAutomation/" 2>/dev/null || true
    fi
done
[[ -f "$CI_STATE_FILE" ]] && cp "$CI_STATE_FILE" "$out/ci-aws-state.env"

find "$out" -type f -empty -delete
mask_files
log "collect-logs: $(find "$out" -type f | wc -l | tr -d ' ') files, $(du -sh "$out" | cut -f1)"
exit 0
