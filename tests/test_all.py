"""Tests that need no AWS account: python3 tests/test_all.py
1. The template says what the rubric needs (slide 22 + SIS 3 list) and has no secrets.
2. The idempotent consumer, taken from the template itself, run against a fake DynamoDB (moto).
"""
import json
import os
import sys
import types

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Loader(yaml.SafeLoader):
    pass


def _tag(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return {suffix: loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return {suffix: loader.construct_sequence(node, deep=True)}
    return {suffix: loader.construct_mapping(node, deep=True)}


Loader.add_multi_constructor("!", _tag)
raw = open(os.path.join(ROOT, "template.yaml")).read()
tpl = yaml.load(raw, Loader=Loader)
R = {k: v.get("Properties", {}) for k, v in tpl["Resources"].items()}
TYPE = {k: v["Type"] for k, v in tpl["Resources"].items()}


def test_template():
    q, dlq = R["OrdersQueue"], R["OrdersDLQ"]
    need = 6 * R["ConsumerFunction"]["Timeout"] + R["ConsumerTrigger"]["MaximumBatchingWindowInSeconds"]
    assert q["VisibilityTimeout"] >= need, "visibility timeout >= 6 x timeout + window"
    assert q["RedrivePolicy"]["maxReceiveCount"] >= 5
    assert dlq["MessageRetentionPeriod"] > q["MessageRetentionPeriod"], "DLQ keeps messages longer"
    m = R["ConsumerTrigger"]
    assert "ReportBatchItemFailures" in m["FunctionResponseTypes"]
    assert m["BatchSize"] == 10 and m["MaximumBatchingWindowInSeconds"] == 5
    assert m["ScalingConfig"]["MaximumConcurrency"] == 2
    assert R["OrdersSubscription"]["RawMessageDelivery"] is True
    assert R["Repository"]["ImageTagMutability"] == "IMMUTABLE"
    assert R["Repository"]["LifecyclePolicy"]["LifecyclePolicyText"]
    assert R["ExecutionRole"] != R["TaskRole"], "two separate roles"
    assert R["ServiceLogGroup"]["RetentionInDays"] and R["ConsumerLogGroup"]["RetentionInDays"]
    assert "Retain" == tpl["Resources"]["OrdersTable"]["DeletionPolicy"]
    # reproducibility: nothing is named by hand (a literal string), so a second stack cannot collide
    named = ("TableName", "QueueName", "TopicName", "RoleName", "RepositoryName", "ClusterName",
             "ServiceName", "LoadBalancerName", "Family")
    for name, props in R.items():
        for key in named:
            assert key not in props, "%s hard-codes %s" % (name, key)
        if TYPE[name] == "AWS::Lambda::Function":
            assert "FunctionName" not in props, "%s hard-codes FunctionName" % name
    # no secrets in the template
    low = raw.lower()
    for bad in ("akia", "aws_secret_access_key", "password"):
        assert bad not in low, "possible secret: " + bad
    assert ":latest" not in low, "no :latest image"
    print("template checks ok")


def test_consumer():
    os.environ.update(AWS_ACCESS_KEY_ID="x", AWS_SECRET_ACCESS_KEY="x",
                      AWS_DEFAULT_REGION="eu-central-1", TABLE_NAME="t")
    from moto import mock_aws
    import boto3
    code = tpl["Resources"]["ConsumerFunction"]["Properties"]["Code"]["ZipFile"]
    with mock_aws():
        ddb = boto3.client("dynamodb")
        ddb.create_table(TableName="t", BillingMode="PAY_PER_REQUEST",
                         AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                         KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}])
        mod = types.ModuleType("consumer")
        exec(compile(code, "consumer", "exec"), mod.__dict__)

        def totals():
            it = ddb.get_item(TableName="t", Key={"pk": {"S": "TOTALS"}}).get("Item", {})
            return it.get("orders", {}).get("N"), it.get("revenue", {}).get("N")

        good = json.dumps({"orderId": "o-1", "customer": "ruslan", "total": 25.5})
        r = mod.lambda_handler({"Records": [{"messageId": "m1", "body": good}]}, None)
        assert r == {"batchItemFailures": []} and totals() == ("1", "25.5"), totals()
        r = mod.lambda_handler({"Records": [{"messageId": "m2", "body": good}]}, None)  # duplicate
        assert r == {"batchItemFailures": []} and totals() == ("1", "25.5"), "duplicate changed totals"
        r = mod.lambda_handler({"Records": [{"messageId": "m3", "body": "poison"},
                                            {"messageId": "m4", "body": good}]}, None)
        assert r == {"batchItemFailures": [{"itemIdentifier": "m3"}]}, r
        assert totals() == ("1", "25.5")
    print("consumer checks ok (first delivery, duplicate, poison)")


if __name__ == "__main__":
    test_template()
    test_consumer()
    print("ALL PASSED")
