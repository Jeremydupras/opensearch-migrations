#!/usr/bin/env bash
# Shared helpers for the AWS integration tests run from GitHub Actions (.github/workflows/aws-ci-job.yml).
# Ported from the Jenkins shared library in vars/ (withMigrationsTestAccount, parseCfnExports, expandVersionString,
# finalCleanup). Source it; don't run it.

CI_AWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CI_REPO_ROOT points at the product checkout when these scripts come from a different ref (release canaries).
REPO_ROOT="${CI_REPO_ROOT:-$(cd "$CI_AWS_DIR/../.." && pwd)}"
export REPO_ROOT
REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

# State shared between the test step and the always-run cleanup step of the same job.
CI_STATE_FILE="${CI_STATE_FILE:-$REPO_ROOT/tmp/ci-aws-state.env}"

log() { printf '%s | %s\n' "$(date -u '+%H:%M:%S')" "$*"; }

die() { log "ERROR: $*" >&2; exit 1; }

state_set() {
    mkdir -p "$(dirname "$CI_STATE_FILE")"
    printf 'export %s=%q\n' "$1" "$2" >> "$CI_STATE_FILE"
    export "$1=$2"
}

state_load() {
    # shellcheck disable=SC1090
    [[ -f "$CI_STATE_FILE" ]] && source "$CI_STATE_FILE"
    return 0
}

# Stage name: <base>-<pool letter><last 5 digits of run id><attempt>, like Jenkins' <STAGE>-<p|m|r><build#>. The pool
# letter keeps PR and main stacks apart; the run attempt keeps a re-run from colliding with leftovers of the first
# attempt. The cluster CDK app (amazon-opensearch-service-sample-cdk) allows at most 15 characters.
MAX_STAGE_NAME_LENGTH=15
stage_name() {
    local base="$1" pool_letter
    case "${CI_POOL:-pr}" in
        main) pool_letter=m ;;
        release) pool_letter=r ;;
        *) pool_letter=p ;;
    esac
    local run_id="${GITHUB_RUN_ID:-00000}"
    local stage
    stage=$(printf '%s-%s%s%s' "$base" "$pool_letter" "${run_id: -5}" "${GITHUB_RUN_ATTEMPT:-1}")
    [[ ${#stage} -le $MAX_STAGE_NAME_LENGTH ]] || die "Stage name '$stage' is longer than $MAX_STAGE_NAME_LENGTH characters"
    printf '%s' "$stage"
}

# ARN of the IAM role behind the current credentials (the session ARN can't be an EKS access entry).
caller_role_arn() {
    local arn account role
    arn=$(aws sts get-caller-identity --query Arn --output text)
    account=$(aws sts get-caller-identity --query Account --output text)
    if [[ "$arn" =~ :assumed-role/([^/]+)/ ]]; then
        role="${BASH_REMATCH[1]}"
        printf 'arn:aws:iam::%s:role/%s' "$account" "$role"
    else
        printf '%s' "$arn"
    fi
}

account_id() { aws sts get-caller-identity --query Account --output text; }

# ES_7.10 -> elasticsearch-7-10 (configmap names), as vars/expandVersionString.groovy.
expand_version() {
    local v="$1"
    [[ "$v" =~ ^(ES|OS|SOLR)_([0-9]+)\.([0-9]+)$ ]] || die "Invalid version string '$v'; expected e.g. ES_7.10"
    local name
    case "${BASH_REMATCH[1]}" in
        ES) name=elasticsearch ;;
        OS) name=opensearch ;;
        SOLR) name=solr ;;
    esac
    printf '%s-%s-%s' "$name" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# Prints KEY=VALUE lines from the stack's MigrationsExportString output, as vars/parseCfnExports.groovy.
cfn_exports() {
    local stack="$1" raw
    raw=$(aws cloudformation describe-stacks --stack-name "$stack" \
        --query "Stacks[0].Outputs[?OutputKey=='MigrationsExportString'].OutputValue" --output text)
    [[ -n "$raw" && "$raw" != "None" ]] || die "No MigrationsExportString output on stack '$stack'"
    tr ';' '\n' <<< "$raw" | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//' | grep '='
}

stack_status() {
    aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>/dev/null \
        || echo GONE
}

cfn_destroy() {
    local stack="$1"
    if [[ "$(stack_status "$stack")" == GONE ]]; then
        log "cfn-destroy: $stack already gone"
        return 0
    fi
    log "cfn-destroy: deleting $stack"
    aws cloudformation delete-stack --stack-name "$stack"
    if ! aws cloudformation wait stack-delete-complete --stack-name "$stack"; then
        aws cloudformation describe-stack-events --stack-name "$stack" --max-items 25 \
            --query "StackEvents[?ResourceStatus=='DELETE_FAILED']" || true
        return 1
    fi
}

# Prefix each output line with a timestamp and a label, so parallel steps stay readable.
prefix_lines() {
    local label="$1"
    while IFS= read -r line; do printf '%s | %-8s | %s\n' "$(date -u '+%H:%M:%S')" "$label" "$line"; done
}

# Points every CDK command on this runner at the test bootstrap (qualifier osmtest, stack CDKToolkitTests), whose
# execution role carries the osm-ci-test-boundary. For CDK apps that take no qualifier setting of their own.
use_test_cdk_bootstrap() {
    jq -n '{toolkitStackName: "CDKToolkitTests", context: {"@aws-cdk/core:bootstrapQualifier": "osmtest"}}' > "$HOME/.cdk.json"
}

# unbuffer (expect) and the Session Manager plugin, for `aws ecs execute-command` into the migration console.
install_ecs_exec_tools() {
    command -v unbuffer >/dev/null || sudo apt-get install -y -qq expect >/dev/null
    if ! command -v session-manager-plugin >/dev/null; then
        curl -fsSL -o /tmp/session-manager-plugin.deb \
            https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb
        sudo dpkg -i /tmp/session-manager-plugin.deb >/dev/null
    fi
}
