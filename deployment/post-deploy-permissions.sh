#!/bin/bash
# =============================================================================
# POST-DEPLOY PERMISSIONS SCRIPT
# Run this in the TEAM account (for example from AWS CloudShell) AFTER every
# Amplify build completes. Override REGION or STACK_NAME as environment variables.
# Attaches the KMS Decrypt and SSO/Org Access managed policies to all
# Amplify-created Lambda roles that are NOT managed by the CloudFormation stack.
# =============================================================================

set -e

REGION="${REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-TEAM-IDC-APP}"

echo "=== Fetching policy ARNs from CloudFormation outputs ==="

SSO_POLICY_ARN=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query "Stacks[0].Outputs[?OutputKey=='TEAMSsoOrgAccessPolicyArn'].OutputValue" \
    --output text)

KMS_POLICY_ARN=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query "Stacks[0].Outputs[?OutputKey=='TEAMKmsDecryptPolicyArn'].OutputValue" \
    --output text 2>/dev/null || echo "")

echo "SSO/Org Policy: $SSO_POLICY_ARN"
echo "KMS Policy: $KMS_POLICY_ARN"

echo ""
echo "=== Finding all TEAM Lambda roles ==="

# Read the roles straight from the TEAM Lambda functions. Amplify uses several
# role name patterns, so filtering IAM roles by name misses some of them.
ROLES=$(aws lambda list-functions \
    --region $REGION \
    --query "Functions[?contains(FunctionName,'team') || contains(FunctionName,'Team')].Role" \
    --output text | tr '\t' '\n' | sed 's|.*/||' | sort -u)

echo "Found roles:"
echo "$ROLES"

echo ""
echo "=== Attaching SSO/Org Access policy to all roles ==="

for role in $ROLES; do
    aws iam attach-role-policy --role-name "$role" --policy-arn "$SSO_POLICY_ARN" 2>/dev/null && \
        echo "  SSO policy attached to $role" || \
        echo "  SSO policy already attached to $role (or error)"
done

if [ -n "$KMS_POLICY_ARN" ] && [ "$KMS_POLICY_ARN" != "None" ]; then
    echo ""
    echo "=== Attaching KMS Decrypt policy to all roles ==="
    for role in $ROLES; do
        aws iam attach-role-policy --role-name "$role" --policy-arn "$KMS_POLICY_ARN" 2>/dev/null && \
            echo "  KMS policy attached to $role" || \
            echo "  KMS policy already attached to $role (or error)"
    done
else
    echo ""
    echo "=== No KMS policy (IdCKmsKeyArn was not provided) ==="
fi

echo ""
echo "=== Done! All TEAM roles now have SSO/Org and KMS permissions ==="
echo ""
echo "Next steps:"
echo "1. Configure the SAML app in Identity Center"
echo "2. Run the Cognito configuration (cognito.sh or PowerShell equivalent)"
echo "3. Assign users/groups to the TEAM app in Identity Center"
