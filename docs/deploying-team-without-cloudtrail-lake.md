# Deploying TEAM When AWS CloudTrail Lake Is Closed to New Customers

TEAM (Temporary Elevated Access Management) is an open source solution for AWS IAM Identity Center. It gives users a self service portal to request time bound elevated access to accounts across an organization. An approver grants the request, access is assigned for a set window, and it is automatically revoked when the window closes. That is the Zero Standing Privilege model, and it works well.

There is one snag you hit the moment you try to deploy it in 2026, and the stock documentation does not cover it. This post walks through what the snag is, why it happens, and the exact change that gets you deployed and auditing properly.

## Source and attribution

This write-up builds on TEAM (Temporary Elevated Access Management), the open source solution published by AWS at [aws-samples/iam-identity-center-team](https://github.com/aws-samples/iam-identity-center-team), licensed under MIT-0. The TEAM application code is the work of its original AWS authors and is maintained in that repository. This repo does not redistribute it.

What I am sharing here is my own work on top of it:

- A modified [`deployment/template.yml`](../deployment/template.yml), based on upstream v1.5.2, that deploys TEAM without AWS CloudTrail Lake and supports Identity Center encrypted with a customer managed AWS KMS key from a delegated admin account.
- A [`post-deploy-permissions.sh`](../deployment/post-deploy-permissions.sh) script that reattaches the required policies to the Lambda roles AWS Amplify creates.
- The auditing approach in this post, which replaces the in app Audit view with an AWS CloudTrail organization trail, Amazon S3 and Amazon Athena.

## Get the TEAM code

Always pull the application code from the official repository so you get its security fixes and releases.

1. Fork [aws-samples/iam-identity-center-team](https://github.com/aws-samples/iam-identity-center-team) to your own GitHub account. AWS Amplify needs to create a webhook on the repository it builds from, and that requires admin access, so you cannot point Amplify at the aws-samples repository directly.
2. Create a classic GitHub personal access token with the `repo` and `admin:repo_hook` scopes. Fine grained tokens do not work for the Amplify webhook.
3. In the TEAM account, in the same Region you deploy to, store the token and your fork URL in AWS Secrets Manager. The keys `AccessToken` and `url` are case sensitive, and the URL has no `.git` suffix:

```powershell
Set-Content -Path secret.json -Value '{"AccessToken":"YOUR_TOKEN","url":"https://github.com/YOUR_USERNAME/iam-identity-center-team"}'
aws secretsmanager create-secret --name TeamAppToken --secret-string file://secret.json
Remove-Item secret.json
```

4. Download the modified [`deployment/template.yml`](../deployment/template.yml) and [`post-deploy-permissions.sh`](../deployment/post-deploy-permissions.sh) from this repo. Use the template in place of the upstream one when you deploy.

When upstream publishes a new release, sync your fork from GitHub and compare the new upstream `deployment/template.yml` with the modified one before you redeploy.

## The snag

TEAM's deployment template has a parameter called `CloudTrailAuditLogs`. It is how the solution wires up its built in session auditing. The portal has an "Audit" area that is meant to show you, per elevated session, every API call the user made while they held that access. Behind the scenes, that feature is built on AWS CloudTrail Lake.

AWS CloudTrail Lake closed to new customers on May 31, 2026. If your account was not already using it, you cannot create a new event data store. So when you deploy TEAM the normal way, you are leaning on a service you can no longer turn on.

If you leave the parameter at its default or pass an empty value, the deploy fails validation:

```
Parameter 'CloudTrailAuditLogs' must match pattern (read_write|read|write|none|arn.*)
```

An empty string does not satisfy the allowed pattern, so AWS CloudFormation rejects it outright.

## The fix in one line

Set the parameter to `none`:

```
CloudTrailAuditLogs=none
```

That value is explicitly allowed by the pattern, and it tells TEAM to skip the AWS CloudTrail Lake integration entirely. The core workflow (request, approve, grant, auto revoke) deploys and runs with no dependency on Lake.

One detail worth knowing if you are reading the template closely. There is a condition inside it that rewrites an empty string to `read_write`. That is why passing nothing does not quietly fall back to "off", it falls forward to "on". You have to pass the literal `none` to get the behavior you want. Empty is not the same as none here.

Here is the relevant part of the deploy command:

```powershell
aws cloudformation deploy `
    --region $REGION `
    --template-file template.yml `
    --stack-name TEAM-IDC-APP `
    --parameter-overrides `
        Login=$IDC_LOGIN_URL `
        CloudTrailAuditLogs=none `
        teamAdminGroup="$TEAM_ADMIN_GROUP" `
        teamAuditGroup="$TEAM_AUDITOR_GROUP" `
        teamAccount="$TEAM_ACCOUNT" `
        IdCKmsKeyArn=$KMS_KEY_ARN `
        cacheTTL=$CACHE_TTL `
        customRepository="Yes" `
        customRepositorySecretName="TeamAppToken" `
    --no-fail-on-empty-changeset `
    --capabilities CAPABILITY_NAMED_IAM
```

Leave `IdCKmsKeyArn` blank if Identity Center uses an AWS managed key. If it uses a customer managed key, also add the TEAM account to that key's policy in the management account. After each Amplify build, run `post-deploy-permissions.sh`, because a rebuild can drop the policies from the Lambda roles.

## What you give up, and what you do instead

Setting `none` has one tradeoff. The portal's built in Audit view will not populate, because that specific view queries an AWS CloudTrail Lake event data store that no longer exists in your account. Everything else works.

That sounds worse than it is. The access decisions themselves (who requested what, who approved it, when it was granted, when it was revoked) are all still captured, because TEAM makes those changes through AWS IAM Identity Center and every one of those calls lands in AWS CloudTrail. You just read them from a standard trail instead of from the in app view.

So the move is to stand up a normal AWS CloudTrail organization trail that writes to Amazon S3, and query it with Amazon Athena. You get the same audit coverage, it is centralized across every account in the org, it is tamper resistant, and it is cheap.

### Set up the organization trail

In the management account, create an organization trail:

1. Open AWS CloudTrail, go to Trails, choose Create trail.
2. Give it a name.
3. Point it at an Amazon S3 bucket for log storage (new or an existing central logging bucket).
4. Turn on "Enable for all accounts in my organization".
5. Keep management events set to Read and Write.
6. Create the trail.

### Create an Amazon Athena table

AWS CloudTrail will generate the table definition for you:

1. In AWS CloudTrail, open Event history, choose Create Athena table.
2. Pick the Amazon S3 bucket the trail writes to.
3. Accept the generated DDL and create the table.

One thing to watch here. If your trail is an organization trail, the logs are written under an org prefix, not the single account path. The Amazon S3 layout looks like this:

```
s3://YOUR_LOG_BUCKET/AWSLogs/o-xxxxxxxxxx/ACCOUNT_ID/CloudTrail/REGION/YYYY/MM/DD/
```

If the auto generated table points at the plain `AWSLogs/ACCOUNT_ID/` path, it will find nothing, because the real objects sit one level deeper under `o-xxxxxxxxxx`. Set the table `LOCATION` to the org path and your queries start returning rows:

```
s3://YOUR_LOG_BUCKET/AWSLogs/o-xxxxxxxxxx/
```

### Query the access decisions

The two events that represent a TEAM grant and a TEAM revoke are `CreateAccountAssignment` and `DeleteAccountAssignment` on `sso.amazonaws.com`. This query pulls every grant and revoke in a window:

```sql
SELECT eventtime, useridentity.arn, eventname, requestparameters
FROM cloudtrail_logs
WHERE eventsource = 'sso.amazonaws.com'
  AND eventname IN ('CreateAccountAssignment', 'DeleteAccountAssignment')
  AND eventtime >= '2026-09-01T00:00:00Z'
  AND eventtime <  '2026-10-01T00:00:00Z'
ORDER BY eventtime DESC;
```

To reconstruct what a specific user actually did inside an account during their elevated window, scope the query to that one person and the time range of the session:

```sql
SELECT element_at(split(useridentity.arn, '/'), cardinality(split(useridentity.arn, '/'))) AS username,
       useridentity.sessionContext.sessionIssuer.arn AS permission_set_role,
       eventtime, eventsource, eventname, awsregion, sourceipaddress, errorcode, requestparameters
FROM cloudtrail_logs
WHERE useridentity.arn LIKE '%/user@example.com'
  AND eventtime BETWEEN '2026-09-01T14:00:00Z' AND '2026-09-01T18:00:00Z'
ORDER BY eventtime;
```

Filtering on the account and time window alone is not enough. That returns every API call made during that window by every principal, and the user you care about is buried in the noise. The filter that scopes it to one person is the match on `useridentity.arn`.

A couple of things make this work, and both are easy to get wrong:

- The elevated session is an assumed role, and the ARN looks like `arn:aws:sts::ACCOUNT_ID:assumed-role/AWSReservedSSO_PermissionSet_abc123/user@example.com`. The final path segment is the session name, which is the user's email. `useridentity.arn LIKE '%/user@example.com'` anchors to that trailing segment, so it scopes cleanly to one person.
- The session name is the user's **email**, not their Identity Center username. In some directories those differ (the username might be `jdoe` while the email is `john.doe@example.com`). CloudTrail records the email as the session identifier, so filter on the email. It also carries no `idc_` prefix, even if your Cognito usernames do.

The `username` column is the same session name pulled out of the ARN for readability, so every row is clearly attributed to the person. The `element_at`/`cardinality` pair grabs the last `/`-segment of the ARN. It is more portable than a negative `split_part` index, which some Athena engine versions reject.

The `permission_set_role` column surfaces the role the session assumed, taken from `useridentity.sessionContext.sessionIssuer.arn`. For an Identity Center elevation this is the reserved SSO role, named `AWSReservedSSO_<PermissionSetName>_<suffix>`, so you can see at a glance which permission set the user was acting under. Returning the full role ARN keeps it unambiguous, which is what you want in an audit trail.

Adding `errorcode` to the SELECT shows not just what the user did but what they attempted and were denied, which is often the part that matters most in an audit.

Partition the table by date and keep your time filters tight. Amazon Athena bills on data scanned, so a bounded window keeps each query well under a dollar.

## What this costs

For a small to medium organization this runs a few dollars a month. Amazon S3 storage for the logs is a couple of gigabytes in most cases, and Amazon Athena is five dollars per terabyte scanned, which you rarely approach if you filter by date.

| Item | Rough cost |
|------|-----------|
| Amazon S3 storage for CloudTrail logs | A few cents per GB per month |
| Amazon Athena queries | $5 per TB scanned, far less in practice with date filters |
| Typical monthly total | Under $5 for a small to medium org |

## The takeaway

The AWS CloudTrail Lake closure is not a blocker for TEAM, it is a one word parameter change plus a standard trail. You deploy with `CloudTrailAuditLogs=none`, you route auditing through an AWS CloudTrail organization trail to Amazon S3, and you query it with Amazon Athena. The portal's in app Audit view stays dark, but you end up with a cleaner audit posture than the built in view would have given you: centralized across the whole org, durable, and inexpensive.

If you are standing up TEAM today, this is the path.
