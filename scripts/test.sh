#!/usr/bin/env bash
# Smoke test of a deployed stack:  ./scripts/test.sh <stack-name> [--poison]
set -euo pipefail
STACK="${1:?usage: ./scripts/test.sh <stack-name> [--poison]}"
export AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"

output() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
TOPIC="$(output TopicArn)"; TABLE="$(output TableName)"; URL="$(output ServiceUrl)"
QUEUE="$(output QueueUrl)"; DLQ="$(output DlqUrl)"

totals() {
  aws dynamodb get-item --table-name "$TABLE" --consistent-read \
    --key '{"pk":{"S":"TOTALS"}}' --query 'Item.[orders.N,revenue.N]' --output text 2>/dev/null \
    | sed 's/None/0/g'
}
publish() {
  aws sns publish --topic-arn "$TOPIC" --query MessageId --output text \
    --message "{\"eventType\":\"OrderPlaced\",\"orderId\":\"$1\",\"customer\":\"ruslan\",\"total\":25.5}" >/dev/null
}

ORDER="o-$(date +%Y%m%d%H%M%S)"
echo "== idempotency: TOTALS before:   $(totals)"
publish "$ORDER"; sleep 20
echo "   TOTALS after 1st event:  $(totals)   (orders +1, revenue +25.5)"
publish "$ORDER"; sleep 20
echo "   TOTALS after duplicate:  $(totals)   (must be the same as the line above)"

echo "== web service: $URL/health"
curl -s -o /dev/null -w "   HTTP %{http_code}\n" "$URL/health"
curl -s "$URL/"; echo

if [ "${2:-}" = "--poison" ]; then
  echo "== poison message: it must end in the DLQ after 5 receives (about 6 minutes)"
  aws sqs send-message --queue-url "$QUEUE" --message-body poison >/dev/null
  for i in $(seq 1 24); do
    N="$(aws sqs get-queue-attributes --queue-url "$DLQ" --attribute-names ApproximateNumberOfMessages \
         --query Attributes.ApproximateNumberOfMessages --output text)"
    echo "   $(date +%H:%M:%S) messages in DLQ: $N"
    [ "$N" -ge 1 ] && break
    sleep 30
  done
fi
