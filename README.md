# orders-platform (SIS 3)

One CloudFormation template that builds the whole system from weeks 9 and 10:

```
SNS topic --> SQS queue (+ DLQ) --> Lambda (idempotent consumer) --> DynamoDB      (week 9)
ECR (immutable tags) --> ECS Fargate service --> Application Load Balancer         (week 10)
```

Everything is in `template.yaml`. No resource has a hand-written name, so the same
template can be deployed a second time under a new stack name.

## Deploy (one command)

Run in AWS CloudShell (it has `aws`, `docker` and `git`) in the region `eu-central-1`:

```bash
git clone <repository-url> && cd orders-platform
./scripts/deploy.sh <stack-name>          # example: ./scripts/deploy.sh orders-dev
```

The script lints the template, deploys the stack, builds the image, pushes it to ECR with the
git commit hash as the tag, and deploys again so ECS starts the service. At the end it prints
the service URL. It takes about 10 minutes and is safe to run again.

Other commands:

```bash
./scripts/test.sh <stack-name> [--poison]   # idempotency, web service, optional DLQ test
./scripts/destroy.sh <stack-name>           # delete the stack and the retained DynamoDB table
python3 tests/test_all.py                   # tests without an AWS account (pip install -r requirements-dev.txt)
```

## Manual steps before the first deploy (done once, not in the template)

1. An AWS account with permission to create IAM roles, VPC, ECS, ALB, SQS, SNS, Lambda, DynamoDB, ECR.
2. AWS CLI configured for it (in CloudShell this is already done).
3. This repository cloned, with at least one commit (the commit hash becomes the image tag).

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `Env` | `dev` | `dev`, `staging` or `prod`. Picks the task size and count from the `Sizing` mapping. |
| `ImageTag` | empty | Image tag in ECR. Empty on the first deploy; `deploy.sh` sets it to the commit hash. |
| `LogRetentionDays` | `7` | Retention of the Lambda and ECS log groups. |

There are no secrets in the template or in the repository.

## What is where (SIS 3 list)

| Requirement | Resource in `template.yaml` |
|---|---|
| SQS queue with a DLQ and maxReceiveCount | `OrdersQueue` (RedrivePolicy, maxReceiveCount 5), `OrdersDLQ` |
| Domain event through SNS | `OrderEventsTopic`, `OrdersSubscription` (raw delivery), `OrdersQueuePolicy` |
| Idempotent consumer, deduplication key | `ConsumerFunction`: key = business key `orderId`, marker item `ORDER#<orderId>` |
| Image in ECR, immutable tags, lifecycle policy | `Repository` |
| ECS Fargate behind an ALB, two separate roles | `Service`, `LoadBalancer`, `ExecutionRole`, `TaskRole` |
| Logs in CloudWatch with a retention period | `ServiceLogGroup`, `ConsumerLogGroup` (`LogRetentionDays`) |
| Parameters for the environment, no secrets | `Env`, `ImageTag`, `Sizing` mapping |

Lambda and SQS settings (slide 22): visibility timeout 60 s (needs at least 6 x 5 s timeout + 5 s window = 35 s),
maxReceiveCount 5, DLQ retention 14 days against 4 days, ReportBatchItemFailures on, batch size 10,
batch window 5 s, maximum concurrency 2.

## Design decisions

- **Deduplication key is `orderId`, not the SQS `messageId`.** SNS may deliver twice and a producer may
  publish twice; only the business key is the same every time. One DynamoDB transaction writes the marker
  `ORDER#<orderId>` (only if it does not exist) and updates the `TOTALS` item, so a duplicate changes nothing.
- **Two-step deploy.** The image cannot exist before the ECR repository does. `ImageTag` empty means the
  task definition and service are not created yet (condition `HasImage`); the script pushes the image and
  deploys again with the tag.
- **The DynamoDB table has `DeletionPolicy: Retain`** and point-in-time recovery, because it is data.
  `destroy.sh` deletes it on purpose after the stack.
- **No NAT gateway.** Tasks run in public subnets with a public IP; the task security group accepts port 8080
  only from the load balancer security group.
- **Lambda code is inline** (under 4096 characters), so no S3 bucket is needed to deploy.

## Honest limits

- A template creates empty tables and queues: data, backups and migrations are a separate problem.
- The AWS account, credentials and the first `git commit` are manual steps.
- If a stack ends in `ROLLBACK_COMPLETE` after the first create, delete it and deploy again.
