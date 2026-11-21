#!/usr/bin/env bash
# Delete a stack and what it kept on purpose:  ./scripts/destroy.sh <stack-name>
set -euo pipefail
STACK="${1:?usage: ./scripts/destroy.sh <stack-name>}"
export AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"

# The DynamoDB table has DeletionPolicy: Retain, so delete-stack leaves it behind.
TABLE="$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='TableName'].OutputValue" --output text)"

echo "== deleting stack $STACK (the ECR images go with it: EmptyOnDelete)"
aws cloudformation delete-stack --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --stack-name "$STACK"

echo "== deleting the retained table $TABLE"
aws dynamodb delete-table --table-name "$TABLE" >/dev/null
echo "Done."
