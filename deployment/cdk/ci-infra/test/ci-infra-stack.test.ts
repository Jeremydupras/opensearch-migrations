import { App } from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { describe, expect, test } from '@jest/globals';
import { CiInfraStack } from '../lib/ci-infra-stack';
import { GitHubRepoSettings } from '../lib/github-actions-roles';

const UPSTREAM: GitHubRepoSettings = {
    repository: 'opensearch-project/opensearch-migrations',
    subjectPrefix: 'repo:opensearch-project/opensearch-migrations',
    workflowRef: 'refs/heads/main',
    pinWorkflowClaims: true,
};

function synth(github: GitHubRepoSettings = UPSTREAM, testRoleManagedPolicyArns = ['arn:aws:iam::aws:policy/job-function/ViewOnlyAccess'],
               snapshotCopyPrincipalArn?: string) {
    const app = new App();
    const stack = new CiInfraStack(app, 'osm-ci-infra', {
        env: { account: '111122223333', region: 'us-east-1' },
        github,
        testRoleManagedPolicyArns,
        snapshotCopyPrincipalArn,
    });
    return Template.fromStack(stack);
}

function trustConditions(template: Template, roleName: string) {
    const roles = template.findResources('AWS::IAM::Role', { Properties: { RoleName: roleName } });
    const [role] = Object.values(roles);
    return role.Properties.AssumeRolePolicyDocument.Statement[0];
}

describe('CiInfraStack', () => {
    test('does not create the OIDC provider (it is created once outside the stack)', () => {
        const template = synth();
        template.resourceCountIs('AWS::IAM::OIDCProvider', 0);
        template.resourceCountIs('Custom::AWSCDKOpenIdConnectProvider', 0);
    });

    test.each([
        ['osm-ci-main', 'migrations-ci-main', 'aws-ci-job.yml'],
        ['osm-ci-pr', 'migrations-ci-pr', 'aws-ci-job.yml'],
        ['osm-ci-infra-deploy', 'migrations-ci-infra', 'deploy-ci-infra.yml'],
    ])('%s trusts only the %s environment and %s on main', (roleName, environment, workflowFile) => {
        const statement = trustConditions(synth(), roleName);
        expect(statement.Action).toBe('sts:AssumeRoleWithWebIdentity');
        expect(statement.Principal.Federated).toBe(
            'arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com');
        expect(statement.Condition).toEqual({
            StringEquals: {
                'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com',
                'token.actions.githubusercontent.com:sub':
                    `repo:opensearch-project/opensearch-migrations:environment:${environment}`,
                'token.actions.githubusercontent.com:job_workflow_ref':
                    `opensearch-project/opensearch-migrations/.github/workflows/${workflowFile}@refs/heads/main`,
            },
        });
    });

    test('no role trusts a branch or tag subject, which pull_request_target tokens share with main', () => {
        const roles = Object.values(synth().findResources('AWS::IAM::Role'));
        expect(roles).toHaveLength(3);
        for (const role of roles) {
            const sub = role.Properties.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals[
                'token.actions.githubusercontent.com:sub'];
            expect(sub).toMatch(/:environment:/);
        }
    });

    test('supports a fork on the immutable subject format, and dropping the workflow pin', () => {
        const statement = trustConditions(synth({
            repository: 'Jeremydupras/opensearch-migrations',
            subjectPrefix: 'repo:Jeremydupras@103400788/opensearch-migrations@1345285990',
            workflowRef: 'refs/heads/gha-aws-oidc',
            pinWorkflowClaims: false,
        }), 'osm-ci-pr');
        expect(statement.Condition).toEqual({
            StringEquals: {
                'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com',
                'token.actions.githubusercontent.com:sub':
                    'repo:Jeremydupras@103400788/opensearch-migrations@1345285990:environment:migrations-ci-pr',
            },
        });
    });

    test('test roles run up to 6h under the boundary with the configured policies', () => {
        const template = synth();
        for (const roleName of ['osm-ci-main', 'osm-ci-pr']) {
            template.hasResourceProperties('AWS::IAM::Role', {
                RoleName: roleName,
                MaxSessionDuration: 21600,
                PermissionsBoundary: { Ref: Match.stringLikeRegexp('TestRoleBoundary') },
                ManagedPolicyArns: ['arn:aws:iam::aws:policy/job-function/ViewOnlyAccess'],
            });
        }
    });

    test('boundary denies the escalation paths', () => {
        const template = synth();
        const [boundary] = Object.values(template.findResources('AWS::IAM::ManagedPolicy', {
            Properties: { ManagedPolicyName: 'osm-ci-test-boundary' },
        }));
        const denies = boundary.Properties.PolicyDocument.Statement
            .filter((s: { Effect: string }) => s.Effect === 'Deny')
            .map((s: { Sid: string }) => s.Sid);
        expect(denies).toEqual([
            'NoLongLivedCredentials',
            'NoChangesToCiIdentity',
            'NoCdkBootstrapRoles',
            'NoChangesToThisStack',
            'NoAuditOrAccountChanges',
        ]);
    });

    test('boundary blocks only the infra CDK bootstrap roles, leaving the osmtest bootstrap to tests', () => {
        const [boundary] = Object.values(synth().findResources('AWS::IAM::ManagedPolicy', {
            Properties: { ManagedPolicyName: 'osm-ci-test-boundary' },
        }));
        const statement = boundary.Properties.PolicyDocument.Statement
            .find((s: { Sid: string }) => s.Sid === 'NoCdkBootstrapRoles');
        expect(statement.Resource).toBe('arn:aws:iam::111122223333:role/cdk-hnb659fds-*');
    });

    test('infra deploy role can only assume the CDK bootstrap roles', () => {
        const template = synth();
        template.hasResourceProperties('AWS::IAM::Role', {
            RoleName: 'osm-ci-infra-deploy',
            MaxSessionDuration: 3600,
            PermissionsBoundary: Match.absent(),
        });
        template.hasResourceProperties('AWS::IAM::Policy', {
            PolicyDocument: {
                Statement: [{
                    Action: 'sts:AssumeRole',
                    Effect: 'Allow',
                    Resource: 'arn:aws:iam::111122223333:role/cdk-hnb659fds-*-111122223333-us-east-1',
                }],
            },
        });
    });

    test('snapshot library is retained, private, readable by MA pods and writable only by admins', () => {
        const template = synth();
        template.hasResource('AWS::S3::Bucket', {
            DeletionPolicy: 'Retain',
            Properties: {
                BucketName: 'migrations-snapshots-library-111122223333-us-east-1',
                PublicAccessBlockConfiguration: {
                    BlockPublicAcls: true, BlockPublicPolicy: true, IgnorePublicAcls: true, RestrictPublicBuckets: true,
                },
                OwnershipControls: { Rules: [{ ObjectOwnership: 'BucketOwnerEnforced' }] },
            },
        });
        const [policy] = Object.values(template.findResources('AWS::S3::BucketPolicy'));
        const deny = policy.Properties.PolicyDocument.Statement.find((s: { Sid?: string }) => s.Sid === 'OnlyAdminsWrite');
        expect(deny.Effect).toBe('Deny');
        expect(deny.Condition).toEqual({ ArnNotLike: { 'aws:PrincipalArn': [
            'arn:aws:iam::111122223333:role/Admin',
            'arn:aws:iam::111122223333:role/cdk-hnb659fds-cfn-exec-role-111122223333-us-east-1',
        ] } });
        expect(policy.Properties.PolicyDocument.Statement.some((s: { Sid?: string }) => s.Sid === 'AllowSnapshotCopyIn')).toBe(false);
    });

    test('the copy role gets write access only while it is configured', () => {
        const copier = 'arn:aws:iam::329599636015:role/Admin';
        const template = synth(UPSTREAM, ['arn:aws:iam::aws:policy/job-function/ViewOnlyAccess'], copier);
        const [policy] = Object.values(template.findResources('AWS::S3::BucketPolicy'));
        const statements = policy.Properties.PolicyDocument.Statement;
        const allow = statements.find((s: { Sid?: string }) => s.Sid === 'AllowSnapshotCopyIn');
        expect(allow.Principal).toEqual({ AWS: copier });
        expect(allow.Action).toContain('s3:PutObject');
        expect(allow.Action).not.toContain('s3:DeleteObject');
        const deny = statements.find((s: { Sid?: string }) => s.Sid === 'OnlyAdminsWrite');
        expect(deny.Condition.ArnNotLike['aws:PrincipalArn']).toContain(copier);
    });
});
