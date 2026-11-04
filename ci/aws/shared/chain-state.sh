#!/usr/bin/env bash
# Saves, restores or deletes the state a chained test hands to its next job (see chain_state_uri in lib.sh): the CI
# state file, and test/tmp (the cluster CDK context and details, which cleanup needs). Restore also recreates the kube
# context, since each job runs on a new runner.
#
# Usage: chain-state.sh save|restore|delete NAME
set -euo pipefail
source "$(dirname "$0")/lib.sh"

action="${1:?Usage: chain-state.sh save|restore|delete NAME}"
name="${2:?Usage: chain-state.sh save|restore|delete NAME}"
uri=$(chain_state_uri "$name")
state_rel="${CI_STATE_FILE#"$REPO_ROOT"/}"

case "$action" in
    save)
        paths=("$state_rel")
        [[ -d "$REPO_ROOT/test/tmp" ]] && paths+=(test/tmp)
        tar -czf - -C "$REPO_ROOT" "${paths[@]}" | aws s3 cp - "$uri" --only-show-errors
        log "Saved the chain state for $name"
        ;;
    restore)
        aws s3 cp "$uri" - --only-show-errors | tar -xzf - -C "$REPO_ROOT"
        state_load
        log "Restored the chain state for $name (stage ${STAGE:-unknown})"
        if [[ -n "${EKS_CLUSTER_NAME:-}" && -n "${KUBE_CONTEXT:-}" ]]; then
            aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --alias "$KUBE_CONTEXT" --region "$REGION" >/dev/null
            log "Kube context $KUBE_CONTEXT points at $EKS_CLUSTER_NAME"
        fi
        ;;
    delete)
        aws s3 rm "$uri" --only-show-errors || true
        ;;
    *)
        die "Usage: chain-state.sh save|restore|delete NAME"
        ;;
esac
