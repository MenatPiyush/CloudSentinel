"""
Cost Intelligence Lambda – Phase 5
Pulls daily cost data per service from AWS Cost Explorer,
stores it in DynamoDB, and publishes an SNS alert when the
daily total exceeds the configured threshold.

Environment variables:
  COST_TABLE_NAME      – DynamoDB table name for cost records
  SNS_TOPIC_ARN        – SNS topic for cost-anomaly alerts
  COST_ALERT_THRESHOLD – Daily spend threshold in USD (default: 50)
  LINKED_ACCOUNT_IDS   – Comma-separated account IDs to aggregate
                         (optional; omit to report current account only)
"""

import os
import json
import boto3
from datetime import date, timedelta

COST_TABLE_NAME      = os.environ.get("COST_TABLE_NAME", "")
SNS_TOPIC_ARN        = os.environ.get("SNS_TOPIC_ARN", "")
COST_ALERT_THRESHOLD = float(os.environ.get("COST_ALERT_THRESHOLD", "50"))
LINKED_ACCOUNT_IDS   = [a.strip() for a in os.environ.get("LINKED_ACCOUNT_IDS", "").split(",") if a.strip()]

ce  = boto3.client("ce")
ddb = boto3.resource("dynamodb").Table(COST_TABLE_NAME) if COST_TABLE_NAME else None
sns = boto3.client("sns")


def _date_range():
    """Return yesterday as (start, end) strings for Cost Explorer."""
    yesterday = date.today() - timedelta(days=1)
    return str(yesterday), str(date.today())


def _get_costs() -> dict:
    """
    Query Cost Explorer for yesterday's spend grouped by SERVICE.
    Returns { service_name: {"amount": float, "unit": str} }
    """
    start, end = _date_range()

    kwargs = dict(
        TimePeriod={"Start": start, "End": end},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )
    if LINKED_ACCOUNT_IDS:
        kwargs["Filter"] = {
            "Dimensions": {
                "Key": "LINKED_ACCOUNT",
                "Values": LINKED_ACCOUNT_IDS,
            }
        }

    response = ce.get_cost_and_usage(**kwargs)
    results = {}
    for group in response["ResultsByTime"][0]["Groups"]:
        service = group["Keys"][0]
        metric  = group["Metrics"]["UnblendedCost"]
        results[service] = {
            "amount": float(metric["Amount"]),
            "unit":   metric["Unit"],
        }
    return results


def _store(report_date: str, costs: dict, total: float):
    if not ddb:
        return
    ddb.put_item(Item={
        "pk":         f"COST#{report_date}",
        "ts":         report_date,
        "total_usd":  str(round(total, 4)),
        "by_service": json.dumps({k: str(round(v["amount"], 4)) for k, v in costs.items()}),
    })


def _notify(report_date: str, total: float, costs: dict):
    if not SNS_TOPIC_ARN:
        return
    top5 = sorted(costs.items(), key=lambda x: x[1]["amount"], reverse=True)[:5]
    lines = [f"  {svc}: ${amt['amount']:.2f}" for svc, amt in top5]
    message = (
        f"CloudSentinel Cost Alert\n"
        f"Date: {report_date}\n"
        f"Total: ${total:.2f} USD  (threshold: ${COST_ALERT_THRESHOLD:.2f})\n\n"
        f"Top 5 services:\n" + "\n".join(lines)
    )
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[CloudSentinel] Daily spend ${total:.2f} exceeds threshold",
        Message=message,
    )


def lambda_handler(event, context):
    report_date, _ = _date_range()

    costs = _get_costs()
    total = sum(v["amount"] for v in costs.values())

    _store(report_date, costs, total)

    if total > COST_ALERT_THRESHOLD:
        _notify(report_date, total, costs)

    return {
        "statusCode": 200,
        "date":       report_date,
        "total_usd":  round(total, 4),
        "alert_sent": total > COST_ALERT_THRESHOLD,
    }
