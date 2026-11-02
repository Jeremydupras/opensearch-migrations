#!/usr/bin/env bash
# EKS Solutions CloudFormation test, ported from vars/eksSolutionsCFNTest.groovy (create-VPC mode): deploys
# Migration Assistant through the production create-VPC template with aws-bootstrap.sh, then checks that the migration
# console comes up. Run ci/aws/eks-cleanup.sh afterwards, whatever the outcome.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

stage=$(stage_name ekscvpc)
state_set STAGE "$stage"
state_set MA_STACK_NAME "Migration-Assistant-Infra-Create-VPC-eks-$stage-$REGION"
state_set KUBE_CONTEXT "migration-eks-cluster-$stage-$REGION"

cat <<INFO
================================================================
EKS Solutions CFN Test (create VPC)
Stage:   $stage
Region:  $REGION
================================================================
INFO
aws sts get-caller-identity --query Arn --output text

"$CI_AWS_DIR/bootstrap-ma.sh" --stack-name "$MA_STACK_NAME" --stage "$stage" --kube-context "$KUBE_CONTEXT" \
    --use-general-node-pool
state_load

log "Validating the EKS deployment"
kubectl --context="$KUBE_CONTEXT" wait --namespace ma --for=condition=ready pod/migration-console-0 --timeout=600s
kubectl --context="$KUBE_CONTEXT" exec -n ma migration-console-0 -- /bin/bash -lc 'console --version'
log "EKS deployment validation completed successfully"
