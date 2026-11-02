import { CfnOutput, Duration, Stack, StackProps } from 'aws-cdk-lib';
import {
    Effect,
    ManagedPolicy,
    OpenIdConnectProvider,
    PolicyStatement,
} from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';
import { GITHUB_OIDC_HOST, GitHubEnvironmentRole, GitHubRepoSettings } from './github-actions-roles';

// GitHub environments; see .github/workflows/aws-ci-job.yml and deploy-ci-infra.yml.
export const MAIN_ENVIRONMENT = 'migrations-ci-main';
export const PR_ENVIRONMENT = 'migrations-ci-pr';
export const INFRA_ENVIRONMENT = 'migrations-ci-infra';

export const TEST_JOB_WORKFLOW = 'aws-ci-job.yml';

// CDK bootstrap qualifiers: the default one deploys this stack; tests deploy their CDK apps with their own.
export const INFRA_CDK_QUALIFIER = 'hnb659fds';
export const TEST_CDK_QUALIFIER = 'osmtest';
export const INFRA_DEPLOY_WORKFLOW = 'deploy-ci-infra.yml';

// GitHub-hosted jobs stop at 6h, and every ported test fits inside that.
const TEST_SESSION_DURATION = Duration.hours(6);

export interface CiInfraStackProps extends StackProps {
    readonly github: GitHubRepoSettings;
    /** Managed policies granted to both test roles. Starts view-only; widen it when tests are ported. */
    readonly testRoleManagedPolicyArns: string[];
}

export class CiInfraStack extends Stack {
    constructor(scope: Construct, id: string, props: CiInfraStackProps) {
        super(scope, id, props);

        // Created once outside this stack (see README), like opensearch-ci, so deleting the stack never deletes it.
        const provider = OpenIdConnectProvider.fromOpenIdConnectProviderArn(
            this,
            'GitHubOidcProvider',
            `arn:aws:iam::${this.account}:oidc-provider/${GITHUB_OIDC_HOST}`,
        );

        const testBoundary = new ManagedPolicy(this, 'TestRoleBoundary', {
            managedPolicyName: 'osm-ci-test-boundary',
            description: 'Ceiling for the GitHub Actions test roles: no IAM users, no changes to CI identity, audit or account settings',
            statements: [
                new PolicyStatement({
                    sid: 'Ceiling',
                    effect: Effect.ALLOW,
                    actions: ['*'],
                    resources: ['*'],
                }),
                new PolicyStatement({
                    sid: 'NoLongLivedCredentials',
                    effect: Effect.DENY,
                    actions: [
                        'iam:CreateUser',
                        'iam:CreateAccessKey',
                        'iam:CreateLoginProfile',
                        'iam:UpdateLoginProfile',
                        'iam:CreateServiceSpecificCredential',
                    ],
                    resources: ['*'],
                }),
                new PolicyStatement({
                    sid: 'NoChangesToCiIdentity',
                    effect: Effect.DENY,
                    actions: ['iam:*'],
                    resources: [
                        `arn:aws:iam::${this.account}:role/osm-ci-*`,
                        `arn:aws:iam::${this.account}:policy/osm-ci-*`,
                        `arn:aws:iam::${this.account}:oidc-provider/${GITHUB_OIDC_HOST}`,
                        `arn:aws:iam::${this.account}:saml-provider/*`,
                    ],
                }),
                new PolicyStatement({
                    // The default CDK bootstrap (qualifier hnb659fds) deploys this stack and its execution role has
                    // admin rights with no boundary. Tests use their own bootstrap (qualifier osmtest), whose
                    // execution role carries this boundary: cdk bootstrap --custom-permissions-boundary osm-ci-test-boundary.
                    sid: 'NoCdkBootstrapRoles',
                    effect: Effect.DENY,
                    actions: ['sts:AssumeRole'],
                    resources: [`arn:aws:iam::${this.account}:role/cdk-${INFRA_CDK_QUALIFIER}-*`],
                }),
                new PolicyStatement({
                    sid: 'NoChangesToThisStack',
                    effect: Effect.DENY,
                    actions: ['cloudformation:*'],
                    resources: [`arn:aws:cloudformation:*:${this.account}:stack/${this.stackName}/*`],
                }),
                new PolicyStatement({
                    sid: 'NoAuditOrAccountChanges',
                    effect: Effect.DENY,
                    actions: [
                        'cloudtrail:StopLogging',
                        'cloudtrail:DeleteTrail',
                        'cloudtrail:UpdateTrail',
                        'cloudtrail:PutEventSelectors',
                        'organizations:*',
                        'account:*',
                    ],
                    resources: ['*'],
                }),
            ],
        });

        const testPolicies = props.testRoleManagedPolicyArns.map((arn, i) =>
            ManagedPolicy.fromManagedPolicyArn(this, `TestRolePolicy${i}`, arn));

        const mainRole = new GitHubEnvironmentRole(this, 'MainTestRole', provider, {
            roleName: 'osm-ci-main',
            description: `AWS integration tests from ${props.github.repository} main, scheduled and release-canary runs`,
            github: props.github,
            environment: MAIN_ENVIRONMENT,
            workflowFile: TEST_JOB_WORKFLOW,
            maxSessionDuration: TEST_SESSION_DURATION,
            permissionsBoundary: testBoundary,
        });

        const prRole = new GitHubEnvironmentRole(this, 'PrTestRole', provider, {
            roleName: 'osm-ci-pr',
            description: `AWS integration tests for ${props.github.repository} PRs, after a maintainer label and approval`,
            github: props.github,
            environment: PR_ENVIRONMENT,
            workflowFile: TEST_JOB_WORKFLOW,
            maxSessionDuration: TEST_SESSION_DURATION,
            permissionsBoundary: testBoundary,
        });

        for (const policy of testPolicies) {
            mainRole.addManagedPolicy(policy);
            prRole.addManagedPolicy(policy);
        }

        // Deploys this stack, following opensearch-ci's deploy-stacks.yml: the role only reaches the CDK bootstrap roles.
        const infraDeployRole = new GitHubEnvironmentRole(this, 'InfraDeployRole', provider, {
            roleName: 'osm-ci-infra-deploy',
            description: `Deploys the ${this.stackName} stack from ${props.github.repository}`,
            github: props.github,
            environment: INFRA_ENVIRONMENT,
            workflowFile: INFRA_DEPLOY_WORKFLOW,
            maxSessionDuration: Duration.hours(1),
        });
        infraDeployRole.addToPolicy(new PolicyStatement({
            actions: ['sts:AssumeRole'],
            resources: [`arn:aws:iam::${this.account}:role/cdk-${INFRA_CDK_QUALIFIER}-*-${this.account}-${this.region}`],
        }));

        new CfnOutput(this, 'MainTestRoleArn', { value: mainRole.roleArn, description: 'Secret MIGRATIONS_CI_MAIN_ROLE' });
        new CfnOutput(this, 'PrTestRoleArn', { value: prRole.roleArn, description: 'Secret MIGRATIONS_CI_PR_ROLE' });
        new CfnOutput(this, 'InfraDeployRoleArn', {
            value: infraDeployRole.roleArn,
            description: 'Secret MIGRATIONS_CI_INFRA_DEPLOY_ROLE',
        });
    }
}
