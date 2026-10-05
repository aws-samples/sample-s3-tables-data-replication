#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="zero-etl-workshop-shared"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null)}"
if [ -z "$REGION" ]; then
  echo "ERROR: No AWS region set. Run 'aws configure set region <region>' or export AWS_REGION." >&2
  echo "       Pick a region where both S3 Tables and Glue zero-ETL-to-S3-Tables are available (e.g. us-east-1, us-east-2, us-west-2)." >&2
  exit 1
fi
TEMPLATE="$(dirname "$0")/template.yaml"

echo "=== Deploying shared infrastructure ==="
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

echo "=== Stack outputs ==="
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs' \
  --output table

echo "=== Shared infrastructure deployed ==="
