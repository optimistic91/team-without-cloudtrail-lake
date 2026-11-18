# TEAM Without AWS CloudTrail Lake

Deployment add-ons for [TEAM (Temporary Elevated Access Management)](https://github.com/aws-samples/iam-identity-center-team), the open source AWS IAM Identity Center solution from AWS.

AWS CloudTrail Lake closed to new customers on May 31, 2026. TEAM's in app session auditing depends on it, so new customers need another way to deploy and audit. This repo shares how I solved that.

**This repo does not contain the TEAM application.** Get the code from the official repository so you receive its releases and security fixes.

## What is here

| Path | Purpose |
|------|---------|
| [`docs/deploying-team-without-cloudtrail-lake.md`](docs/deploying-team-without-cloudtrail-lake.md) | Full walkthrough: deploying without AWS CloudTrail Lake and auditing elevated sessions with an AWS CloudTrail organization trail, Amazon S3 and Amazon Athena |
| [`deployment/template.yml`](deployment/template.yml) | Modified TEAM template based on upstream v1.5.2. Defaults `CloudTrailAuditLogs` to `none` and supports an Identity Center customer managed AWS KMS key and a delegated admin account |
| [`deployment/post-deploy-permissions.sh`](deployment/post-deploy-permissions.sh) | Reattaches the required policies to the Lambda roles AWS Amplify creates. Run after every Amplify build |

## Quick start

1. Fork [aws-samples/iam-identity-center-team](https://github.com/aws-samples/iam-identity-center-team) to your GitHub account.
2. Follow the [walkthrough](docs/deploying-team-without-cloudtrail-lake.md) to create the `TeamAppToken` secret, deploy with the modified template and set up auditing.

## Keeping up with upstream

The template tracks upstream v1.5.2. When a new TEAM release ships, sync your fork and compare the upstream `deployment/template.yml` with the one here before you redeploy.

## Attribution and license

TEAM is the work of its original AWS authors and is licensed under MIT-0. The template in this repo is a modified version of the upstream `deployment/template.yml`. The changes, the script and the documentation are my own and are also released under MIT-0. See [LICENSE](LICENSE).

This is a personal project and is not an official AWS publication.
