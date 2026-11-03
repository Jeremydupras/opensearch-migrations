#!/usr/bin/env bash
# Always-run teardown for cdk-integ-test.sh: destroys the run's migration and source stacks and its log groups.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
state_load

if [[ -z "${CDK_INTEG_STAGE:-}" ]]; then
    log "Nothing to clean up: no stage recorded in $CI_STATE_FILE"
    exit 0
fi

use_test_cdk_bootstrap
cd "$REPO_ROOT/test" || exit 1
log "Destroying all stacks for stage $CDK_INTEG_STAGE"
./awsE2ESolutionSetup.sh --source-context-file ./sourceJenkinsContext.json \
    --migration-context-file ./migrationJenkinsContext.json --source-context-id "$CDK_INTEG_SOURCE_ID" \
    --migration-context-id "$CDK_INTEG_MIGRATION_ID" --stage "$CDK_INTEG_STAGE" --clean-up-all
rc=$?

leftover=$(aws cloudformation list-stacks \
    --query "StackSummaries[?StackStatus!='DELETE_COMPLETE' && contains(StackName, '$CDK_INTEG_STAGE')].[StackName,StackStatus]" \
    --output text)
for group in $(aws logs describe-log-groups --query "logGroups[?contains(logGroupName, '$CDK_INTEG_STAGE')].logGroupName" --output text 2>/dev/null); do
    aws logs delete-log-group --log-group-name "$group" || true
done
if [[ -n "$leftover" ]]; then
    echo "::error::Stacks still present after cleanup: $leftover"
    exit 1
fi
[[ $rc -eq 0 ]] || { echo "::error::awsE2ESolutionSetup.sh --clean-up-all exited $rc"; exit "$rc"; }
log "Cleanup complete"
