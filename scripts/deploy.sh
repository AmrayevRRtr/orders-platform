#!/usr/bin/env bash
# One command deploy:  ./scripts/deploy.sh <stack-name> [dev|staging|prod]
# Works in AWS CloudShell (aws cli, docker and git are there). Safe to run again.
set -euo pipefail

STACK="${1:?usage: ./scripts/deploy.sh <stack-name> [dev|staging|prod]}"
ENVIRONMENT="${2:-dev}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"
export AWS_DEFAULT_REGION="$REGION"
cd "$(dirname "$0")/.."

TAG="$(git rev-parse --short HEAD)"   # immutable tag = commit hash, never "latest"
if [ -n "$(git status --porcelain app)" ]; then
  echo "ERROR: app/ has uncommitted changes. Commit first, the image tag is the commit hash." >&2
  exit 1
fi

if command -v cfn-lint >/dev/null 2>&1; then
  echo "== cfn-lint"; cfn-lint template.yaml
else
  echo "== cfn-lint not installed, skipping (pip install --user cfn-lint)"
fi

deploy() {  # $1 = image tag ("" on the very first run)
  aws cloudformation deploy \
    --template-file template.yaml \
    --stack-name "$STACK" \
    --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides "Env=$ENVIRONMENT" "ImageTag=$1"
}
output() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

# Tag already used by this stack (empty on the first run). Keeping it in step 1 means a
# re-run never removes a running service.
PREVIOUS="$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Parameters[?ParameterKey=='ImageTag'].ParameterValue" --output text 2>/dev/null || true)"
[ "$PREVIOUS" = "None" ] && PREVIOUS=""

echo "== 1/3 stack $STACK: network, messaging, ECR, load balancer (env=$ENVIRONMENT)"
deploy "$PREVIOUS"

echo "== 2/3 image $TAG -> ECR"
REPO_URI="$(output RepositoryUri)"
REPO_NAME="$(output RepositoryName)"
if aws ecr describe-images --repository-name "$REPO_NAME" --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
  echo "image $TAG is already in ECR, skipping the push"
else
  aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO_URI%%/*}"
  docker build --platform linux/amd64 -t "$REPO_URI:$TAG" app
  docker push "$REPO_URI:$TAG"
fi

echo "== 3/3 stack $STACK: task definition and service with image $TAG"
deploy "$TAG"

echo
echo "Service URL: $(output ServiceUrl)"
echo "Next: ./scripts/test.sh $STACK"
