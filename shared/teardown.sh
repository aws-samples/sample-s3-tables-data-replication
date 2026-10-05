#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="zero-etl-workshop-shared"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null)}"
if [ -z "$REGION" ]; then
  echo "ERROR: No AWS region set. Run 'aws configure set region <region>' or export AWS_REGION." >&2
  exit 1
fi

echo "=== Emptying error bucket ==="
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ErrorBucketName`].OutputValue' \
  --output text 2>/dev/null || true)

if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  aws s3 rm "s3://$BUCKET" --recursive --region "$REGION" 2>/dev/null || true
fi

echo "=== Deleting shared infrastructure stack ==="
aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "=== Shared infrastructure deleted ==="
