// Smoke test for the CI Jenkins itself, run after the Jenkins infrastructure is redeployed
// (OpenSearchMigrationsCIInternal pipeline). It checks that an agent built from the current init script has
// everything the migrations pipelines rely on: the toolchain, Docker with cgroup v2, the ECR pull-through cache,
// and kind + kubectl + helm against a real cluster, using the same scripts and kind config as k8sLocalDeployment.
//
// No cron and no webhook trigger: the deploy automation runs it with NODE pinned to the freshly launched agent and a
// unique DEPLOY_ID so it can find its build; it can also be run by hand.
def call(Map config = [:]) {
    def defaultAgent = config.workerAgent ?: 'Jenkins-Default-Agent-X64-C5xlarge-Single-Host'

    pipeline {
        agent { label params.NODE ?: defaultAgent }

        environment {
            // Keep in sync with k8sLocalDeployment.groovy
            KIND_VERSION = 'v0.31.0'
            KIND_NODE_IMAGE = 'kindest/node:v1.35.1@sha256:05d7bcdefbda08b4e038f644c4df690cdac3fba8b06f8289f30e10026720a1ab'
            KIND_CLUSTER_NAME = "ci-smoke-${env.BUILD_NUMBER}"
        }

        parameters {
            string(name: 'GIT_REPO_URL', defaultValue: 'https://github.com/opensearch-project/opensearch-migrations.git', description: 'Git repository url')
            string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Git branch to use for repository')
            string(name: 'NODE', defaultValue: defaultAgent, description: 'Agent label or node name to run on (the deploy automation passes the freshly launched agent)')
            string(name: 'DEPLOY_ID', defaultValue: '', description: 'Set by the deploy automation to identify its build; leave empty for manual runs')
        }

        options {
            timeout(time: 45, unit: 'MINUTES')
            buildDiscarder(logRotator(numToKeepStr: '30'))
            skipDefaultCheckout(true)
            disableConcurrentBuilds()
        }

        stages {
            stage('Checkout') {
                steps {
                    checkoutStep(branch: params.GIT_BRANCH, repo: params.GIT_REPO_URL)
                }
            }

            stage('Toolchain') {
                steps {
                    // Login shell, like the migrations jobs, so /etc/profile.d (ECR_PULL_THROUGH_ENDPOINT) is loaded.
                    sh '''#!/bin/bash -l
                        set -euxo pipefail
                        java -version 2>&1 | tee /dev/stderr | grep -q 'version "17'
                        git --version
                        node --version
                        npm --version
                        cdk --version
                        python3.11 --version
                        pipenv --version
                        aws --version
                        session-manager-plugin --version
                        command -v expect
                        kubectl version --client
                        helm version
                    '''
                }
            }

            stage('Docker and cgroup v2') {
                steps {
                    sh 'docker info'
                    sh 'docker buildx version'
                    // Same host checks and sysctl tuning the kind-based integ tests run.
                    sh './jenkins/configureKindHost.sh'
                }
            }

            stage('ECR pull-through cache') {
                steps {
                    sh '''#!/bin/bash -l
                        set -euxo pipefail
                        test -n "${ECR_PULL_THROUGH_ENDPOINT:-}"
                        command -v docker-credential-ecr-login
                        test -f /etc/buildkitd.toml
                        image="${ECR_PULL_THROUGH_ENDPOINT}/docker-hub/library/busybox:latest"
                        docker pull "${image}"
                        docker run --rm "${image}" true
                    '''
                }
            }

            stage('kind + kubectl + helm') {
                steps {
                    sh 'KIND_INSTALL_DIR="${WORKSPACE}/.ci-bin" ./jenkins/installKind.sh'
                    timeout(time: 15, unit: 'MINUTES') {
                        sh '''#!/bin/bash -l
                            set -euxo pipefail
                            kind="${WORKSPACE}/.ci-bin/kind"
                            context="kind-${KIND_CLUSTER_NAME}"
                            "${kind}" delete cluster --name "${KIND_CLUSTER_NAME}" || true
                            "${kind}" create cluster --name "${KIND_CLUSTER_NAME}" \
                                --config ./deployment/k8s/kindClusterConfigSingleNode.yaml \
                                --image "${KIND_NODE_IMAGE}" --wait 5m
                            kubectl --context "${context}" get nodes -o wide
                            kubectl --context "${context}" wait node --all --for=condition=Ready --timeout=180s
                            kubectl --context "${context}" -n kube-system get pods

                            rm -rf "${WORKSPACE}/.ci-smoke-chart"
                            helm create "${WORKSPACE}/.ci-smoke-chart"
                            helm lint "${WORKSPACE}/.ci-smoke-chart"
                            helm install ci-smoke "${WORKSPACE}/.ci-smoke-chart" --kube-context "${context}" \
                                --namespace ci-smoke --create-namespace --dry-run=server
                        '''
                    }
                }
            }
        }

        post {
            always {
                sh '"${WORKSPACE}/.ci-bin/kind" delete cluster --name "${KIND_CLUSTER_NAME}" || true'
                sh 'rm -rf "${WORKSPACE}/.ci-smoke-chart"'
            }
        }
    }
}
