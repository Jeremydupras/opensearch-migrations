#!/usr/bin/env bash
# AOSS collection tests: bootstraps Migration Assistant on EKS, then runs either or both of:
#   0021  deploys SEARCH, TIMESERIES and VECTORSEARCH (Classic) collections in the MA VPC and migrates a snapshot from
#         the snapshot library into each one.
#   0024  deploys NextGen collections from test/aossNextGen/collections.yaml and migrates the same snapshot through the
#         per-account endpoint, which routes each index to its collection.
# Both run by default. Run ci/aws/shared/eks-cleanup.sh afterwards.
#
# Snapshots come from this account's copy of the snapshot library (see snapshot_library in lib.sh).
#
# Usage: eks-aoss-test.sh [--stage-base aosss|aosst|aossv] [--test-ids 0021,0024] [--s3-repo-uri URI]
#                         [--snapshot-name NAME] [--source-version OS_1.3] [--monitor-retry-limit 33]
set -euo pipefail
source "$(dirname "$0")/../shared/lib.sh"

supported_test_ids=(0021 0024)
stage_base=aosss source_version=OS_1.3 monitor_retry_limit=33 test_ids_arg=0021,0024
s3_repo_uri="$(snapshot_library)/aoss-osb-data/os1x-aoss-osb-data/"
snapshot_name=os1x-aoss-osb-data
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-base) stage_base="$2"; shift 2 ;;
        --test-ids) test_ids_arg="$2"; shift 2 ;;
        --s3-repo-uri) s3_repo_uri="$2"; shift 2 ;;
        --snapshot-name) snapshot_name="$2"; shift 2 ;;
        --source-version) source_version="$2"; shift 2 ;;
        --monitor-retry-limit) monitor_retry_limit="$2"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ "$s3_repo_uri" == */ ]] || s3_repo_uri="$s3_repo_uri/"

# Commas, semicolons or spaces separate the IDs.
read -r -a test_ids <<< "$(tr ',;' '  ' <<< "$test_ids_arg")"
[[ ${#test_ids[@]} -gt 0 ]] || die "--test-ids must list tests from ${supported_test_ids[*]}"
run_classic=false run_routing=false
for id in "${test_ids[@]}"; do
    case "$id" in
        0021) run_classic=true ;;
        0024) run_routing=true ;;
        *) die "--test-ids must list tests from ${supported_test_ids[*]}, got '$test_ids_arg'" ;;
    esac
done

# Release canaries test a tag's code with these scripts from main. Tags before 0024 have no NextGen template (and no
# 0024 test in their migration console), so they run 0021 alone.
nextgen_template="$REPO_ROOT/test/aossNextGen/collections.yaml"
if [[ "$run_routing" == true && ! -f "$nextgen_template" ]]; then
    log "Skipping test 0024: this checkout has no test/aossNextGen/collections.yaml"
    run_routing=false
    [[ "$run_classic" == true ]] || die "Nothing to run: test 0024 needs test/aossNextGen/collections.yaml"
fi
selected_ids=()
[[ "$run_classic" == true ]] && selected_ids+=(0021)
[[ "$run_routing" == true ]] && selected_ids+=(0024)
selected_ids_csv=$(IFS=,; printf '%s' "${selected_ids[*]}")

stage=$(stage_name "$stage_base")
state_set STAGE "$stage"
state_set KUBE_CONTEXT "migration-eks-$stage"
state_set MA_STACK_NAME "MA-Serverless-$stage-$REGION"
state_set CLUSTER_STACK_NAME "OpenSearch-$stage-$REGION"
state_set CLUSTER_INSIDE_MA_VPC true
# Classic collections already use <stage>-search, and collection names are unique per account.
nextgen_prefix="$stage-ng"
nextgen_stack="AOSS-NextGen-$stage-$REGION"
if [[ "$run_routing" == true ]]; then
    # The NextGen collections are outside the MA VPC, so cleanup deletes their stack after the MA stack.
    state_set STACKS_AFTER_MA "$nextgen_stack"
fi

cat <<INFO
================================================================
AOSS Collection Integration Test
Stage:            $stage
Region:           $REGION
Test IDs:         $selected_ids_csv
Classic:          $([[ "$run_classic" == true ]] && echo "SEARCH, TIMESERIES, VECTORSEARCH" || echo skipped)
NextGen routing:  $([[ "$run_routing" == true ]] && echo "$nextgen_prefix-search, $nextgen_prefix-vectors" || echo skipped)
Snapshot:         $snapshot_name at $s3_repo_uri ($source_version)
================================================================
INFO
aws sts get-caller-identity --query Arn --output text

"$CI_SHARED_DIR/bootstrap-ma.sh" --stack-name "$MA_STACK_NAME" --stage "$stage" --kube-context "$KUBE_CONTEXT" \
    --use-general-node-pool
state_load
[[ -n "${MA_VPC_ID:-}" && -n "${EKS_CLUSTER_NAME:-}" ]] || die "Missing VPC_ID / EKS cluster name exports on $MA_STACK_NAME"

# The data access policies name the EKS pod role, which exists only after bootstrap.
job_role=$(caller_role_arn)
pod_role="arn:aws:iam::$(account_id):role/$EKS_CLUSTER_NAME-migrations-role"
endpoint_vars=()

if [[ "$run_classic" == true ]]; then
    log "Deploying the Classic AOSS collections in $MA_VPC_ID"
    context_file="tmp/cluster-context-aoss-$stage.json"
    mkdir -p "$REPO_ROOT/test/tmp"
    jq -n --arg stage "$stage" --arg vpc "$MA_VPC_ID" --arg job_role "$job_role" --arg pod_role "$pod_role" '
        {stage: $stage, vpcId: $vpc, "@aws-cdk/core:bootstrapQualifier": "osmtest",
         clusters: ([["search", "SEARCH"], ["timeseries", "TIMESERIES"], ["vector", "VECTORSEARCH"]] | map(
           {clusterId: .[0], clusterName: "\($stage)-\(.[0])", clusterType: "OPENSEARCH_SERVERLESS", collectionType: .[1],
            standbyReplicas: "DISABLED", domainRemovalPolicy: "DESTROY", dataAccessPrincipals: [$job_role, $pod_role]}))}' \
        > "$REPO_ROOT/test/$context_file"
    cat "$REPO_ROOT/test/$context_file"
    (cd "$REPO_ROOT/test" && ./awsDeployCluster.sh --stage "$stage" --context-file "$context_file")
    details="$REPO_ROOT/test/tmp/cluster-details-$stage.json"
    endpoint_vars+=(
        "AOSS_SEARCH_ENDPOINT=$(jq -r .search.endpoint "$details")"
        "AOSS_TIMESERIES_ENDPOINT=$(jq -r .timeseries.endpoint "$details")"
        "AOSS_VECTOR_ENDPOINT=$(jq -r .vector.endpoint "$details")"
    )
fi

if [[ "$run_routing" == true ]]; then
    log "Deploying the NextGen collections ($nextgen_stack)"
    aws cloudformation deploy --stack-name "$nextgen_stack" --template-file "$nextgen_template" \
        --parameter-overrides "CollectionPrefix=$nextgen_prefix" "DataAccessPrincipals=$job_role,$pod_role"
    nextgen_output() {
        aws cloudformation describe-stacks --stack-name "$nextgen_stack" \
            --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
    }
    search_endpoint=$(nextgen_output SearchCollectionEndpoint)
    vector_endpoint=$(nextgen_output VectorCollectionEndpoint)
    [[ -n "$search_endpoint" && "$search_endpoint" != None && -n "$vector_endpoint" && "$vector_endpoint" != None ]] \
        || die "Missing collection endpoint outputs on $nextgen_stack"
    # No API returns the per-account endpoint; it is built from the account and Region.
    account_endpoint="https://$(account_id).aoss.$REGION.on.aws"
    log "NextGen search: $search_endpoint; vectors: $vector_endpoint"
    endpoint_vars+=(
        "AOSS_ACCOUNT_ENDPOINT=$account_endpoint"
        "AOSS_COLLECTION_PREFIX=$nextgen_prefix"
        "AOSS_NEXTGEN_SEARCH_ENDPOINT=$search_endpoint"
        "AOSS_NEXTGEN_VECTOR_ENDPOINT=$vector_endpoint"
    )
fi

log "Pointing the migration console at the collections and the snapshot"
kubectl --context="$KUBE_CONTEXT" set env statefulset/migration-console -n ma "${endpoint_vars[@]}" \
    "AOSS_SNAPSHOT_NAME=$snapshot_name" "AOSS_S3_REPO_URI=$s3_repo_uri" "AOSS_S3_REGION=$REGION" \
    "AOSS_MONITOR_RETRY_LIMIT=$monitor_retry_limit"
kubectl --context="$KUBE_CONTEXT" rollout status statefulset/migration-console -n ma --timeout=120s

log "Running tests $selected_ids_csv"
cd "$REPO_ROOT/libraries/testAutomation"
pipenv install --deploy
# JSON test reports; collect-logs.sh prints them.
mkdir -p reports
pipenv run app --test-reports-dir=./reports --source-version="$source_version" --target-type=AOSS \
    --test-ids="$selected_ids_csv" --reuse-clusters --skip-delete --skip-install --kube-context="$KUBE_CONTEXT"
