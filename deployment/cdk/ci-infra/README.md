# CI infra: GitHub Actions access to the AWS test account

This CDK app creates the IAM roles that GitHub Actions jobs assume, through the GitHub OIDC provider, to run the AWS
integration tests. It follows the pattern of
[opensearch-ci](https://github.com/opensearch-project/opensearch-ci) (`deploy-stacks.yml`, `lib/secrets/iam-roles.ts`,
`lib/secrets/gha-federate-access.ts`).

| Role | GitHub environment | Assumed from | Used for |
|---|---|---|---|
| `osm-ci-main` | `migrations-ci-main` (main only) | `.github/workflows/aws-ci-job.yml` | push, schedule and dispatch runs on main |
| `osm-ci-pr` | `migrations-ci-pr` (required reviewers) | `.github/workflows/aws-ci-job.yml` | PR runs, after a maintainer label and approval |
| `osm-ci-infra-deploy` | `migrations-ci-infra` (required reviewers, main only) | `.github/workflows/deploy-ci-infra.yml` | deploying this stack |

Each role trusts only `sub` = `repo:<owner>/<repo>:environment:<name>` and, by default, `job_workflow_ref` = the workflow
file on `refs/heads/main`. Roles are bound to environments rather than branches: a `pull_request_target` token has
`sub` = `ref:refs/heads/main`, the same as a push to main.

The test roles start with `ViewOnlyAccess` (context `testRoleManagedPolicyArns`) under the `osm-ci-test-boundary`
permissions boundary. Widen their policies as tests are ported. The boundary denies IAM users and access keys, changes to
the `osm-ci-*` roles and policies and the GitHub provider, the CDK bootstrap roles, this stack, CloudTrail, and
account/organization settings.

## How PRs reach AWS

1. A user with write, maintain or admin permission adds the test's `run-*` label (for the smoke test,
   `run-aws-smoke-test`). `.github/workflows/aws-ci-pr-gate.yml` checks who applied it, because users with only Triage
   can add labels too.
2. The job waits in the `migrations-ci-pr` environment until a maintainer approves the run. A new push to the PR waits
   again.
3. Only then does the job get an OIDC token whose `sub` matches `osm-ci-pr`.

## Setup

One-time steps, in order. Steps 1–3 need Isengard Admin on the test account.

1. **Create the GitHub OIDC provider** outside any stack, so deleting the stack never deletes it:

   ```bash
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com
   ```

   `token.actions.githubusercontent.com` is on the allowlist of the Cloud Security `IAMOpenIdProvider` detection
   (`UDDDetectionTemplateRegistry`). Check that the provider still exists two hours later.
2. **Bootstrap CDK**: `npx cdk bootstrap aws://<account-id>/us-east-1`.
3. **First deploy from a laptop**, because the deploy role doesn't exist yet:

   ```bash
   npm ci
   npx cdk deploy osm-ci-infra
   ```

   The stack outputs are the three role ARNs.
4. **GitHub (repo admin)**:
   - Environments: `migrations-ci-main` (deployment branches: `main`), `migrations-ci-pr` (required reviewers: the
     maintainers), `migrations-ci-infra` (required reviewers: the maintainers; deployment branches: `main`).
   - Repo secrets from the stack outputs: `MIGRATIONS_CI_MAIN_ROLE`, `MIGRATIONS_CI_PR_ROLE`,
     `MIGRATIONS_CI_INFRA_DEPLOY_ROLE`.
   - Labels: `run-aws-smoke-test`, `run-aws-e2e-tests`.
5. **Run the smoke test** (`.github/workflows/aws-ci-smoke-test.yml`): dispatch it on main, and label a PR with
   `run-aws-smoke-test`. Each run prints the OIDC claims and `aws sts get-caller-identity` (account IDs masked).
   Without the role secrets it prints the claims only.

Later changes to this stack go through **Deploy CI infra** (`workflow_dispatch` on main): environment approval →
masked `cdk diff` → approval issue for maintainers → `cdk deploy`.

## Testing on a fork

Forks created after 2026-07-15 use the immutable `sub` format. Read the prefix with
`gh api repos/<owner>/<repo>/actions/oidc/customization/sub`, then deploy with context overrides, for example:

```bash
npx cdk deploy osm-ci-infra \
  -c githubRepository=Jeremydupras/opensearch-migrations \
  -c githubSubjectPrefix='repo:Jeremydupras@103400788/opensearch-migrations@1345285990' \
  -c githubWorkflowRef=refs/heads/gha-aws-oidc
```

If IAM ignores the `job_workflow_ref` condition (the smoke test fails to assume the role while the `sub` matches),
deploy with `-c pinWorkflowClaims=false` to trust `sub` and `aud` only.

## Development

```bash
npm ci
npm test        # eslint + jest
npx cdk synth   # needs CDK_DEFAULT_ACCOUNT or AWS credentials
```
