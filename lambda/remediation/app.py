import os
import json
import boto3
from datetime import datetime, timezone

ASSUME_ROLE_NAME = os.environ.get("ASSUME_ROLE_NAME", "CloudGovernanceRemediatorRole")
DDB_TABLE_NAME = os.environ.get("DDB_TABLE_NAME", "")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")

sts_client = boto3.client('sts')
sns = boto3.client("sns")
ddb = boto3.resource("dynamodb").Table(DDB_TABLE_NAME) if DDB_TABLE_NAME else None


def assume(account_id: str, session_name: str = "remediation"):
    """Return a boto3 Session scoped to the target workload account."""
    role_arn = f"arn:aws:iam::{account_id}:role/{ASSUME_ROLE_NAME}"
    creds = sts_client.assume_role(RoleArn=role_arn, RoleSessionName=session_name)["Credentials"]
    return boto3.Session(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )


# ─── Action handlers ──────────────────────────────────────────────────────────

def handle_scale_asg(session, asg_name: str, desired: int):
    """
    Scenario 1 – Traffic Spike / Scenario 2 – Node Dies
    Scale the EKS node group ASG to `desired` capacity.
    Triggered by the high-cpu-* CloudWatch alarm → EventBridge rule.
    """
    session.client("autoscaling").update_auto_scaling_group(
        AutoScalingGroupName=asg_name,
        DesiredCapacity=desired,
    )


def handle_remove_open_sg(session, group_id: str, ip_permissions: list):
    """
    Scenario 4 – Open Security Group (0.0.0.0/0 or ::/0 rule added)
    Revoke every ingress rule in ip_permissions that allows traffic from
    the public internet.  Skips rules that are already scoped to private CIDRs.

    Triggered by: CloudTrail EC2 AuthorizeSecurityGroupIngress event → EventBridge → Lambda.
    The EventBridge input_transformer passes the group_id and ip_permissions
    straight from the CloudTrail requestParameters.
    """
    ec2 = session.client("ec2")
    open_cidrs = {"0.0.0.0/0", "::/0"}

    # Filter down to only the rules that are open to the internet.
    risky_permissions = []
    for perm in ip_permissions:
        risky_ranges    = [r for r in perm.get("ipRanges", [])   if r.get("cidrIp")   in open_cidrs]
        risky_ipv6      = [r for r in perm.get("ipv6Ranges", []) if r.get("cidrIpv6") in open_cidrs]
        if risky_ranges or risky_ipv6:
            risky_perm = dict(perm)
            risky_perm["ipRanges"]   = risky_ranges
            risky_perm["ipv6Ranges"] = risky_ipv6
            risky_permissions.append(risky_perm)

    if not risky_permissions:
        return  # nothing to do – the rule was not actually open

    ec2.revoke_security_group_ingress(
        GroupId=group_id,
        IpPermissions=risky_permissions,
    )


def handle_increase_rds_storage(session, db_instance_identifier: str, increment_gb: int = 20):
    """
    Scenario 5 – RDS Storage Nearly Full
    Increase the allocated storage of the RDS instance by `increment_gb` GB.
    RDS applies the change immediately (no maintenance window needed for storage).

    Triggered by: CloudWatch FreeStorageSpace alarm → EventBridge → Lambda.
    """
    rds = session.client("rds")

    # Fetch current allocated storage so we can add to it, not replace it.
    instances = rds.describe_db_instances(DBInstanceIdentifier=db_instance_identifier)
    current_gb = instances["DBInstances"][0]["AllocatedStorage"]
    new_gb = current_gb + increment_gb

    rds.modify_db_instance(
        DBInstanceIdentifier=db_instance_identifier,
        AllocatedStorage=new_gb,
        ApplyImmediately=True,
    )
    return {"old_storage_gb": current_gb, "new_storage_gb": new_gb}


# ─── Audit + notify helpers ───────────────────────────────────────────────────

def log_event(audit_info: dict):
    if not ddb:
        return
    ddb.put_item(Item=audit_info)


def notify(subject: str, message: str):
    if not SNS_TOPIC_ARN:
        return
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=json.dumps(message, indent=2))


# ─── Lambda entry point ───────────────────────────────────────────────────────

def lambda_handler(event, context):
    now        = datetime.now(timezone.utc).isoformat()
    account_id = event.get("account_id")
    action     = event.get("action")

    if not account_id or not action:
        return {"statusCode": 400, "body": json.dumps("Missing account_id or action")}

    try:
        session = assume(account_id)
        result  = {}

        if action == "scale_asg":
            handle_scale_asg(session, event["asg_name"], int(event["desired"]))

        elif action == "remove_open_sg":
            # ip_permissions comes from the CloudTrail requestParameters forwarded
            # by the EventBridge input_transformer.
            result = handle_remove_open_sg(
                session,
                group_id=event["group_id"],
                ip_permissions=event.get("ip_permissions", []),
            ) or {}

        elif action == "increase_rds_storage":
            result = handle_increase_rds_storage(
                session,
                db_instance_identifier=event["db_instance_identifier"],
                increment_gb=int(event.get("increment_gb", 20)),
            )

        else:
            return {"statusCode": 400, "body": json.dumps(f"Unknown action: {action}")}

        audit_info = {
            "pk":         f"ACCOUNT#{account_id}",
            "account_id": account_id,
            "ts":         now,
            "action":     action,
            "payload":    json.dumps(event),
            "result":     json.dumps(result),
            "status":     "SUCCESS",
        }
        log_event(audit_info)
        notify("Remediation executed successfully", audit_info)
        return {"statusCode": 200, "body": json.dumps("Remediation executed successfully")}

    except Exception as e:
        audit_info = {
            "pk":         f"ACCOUNT#{account_id}",
            "account_id": account_id,
            "ts":         now,
            "action":     action,
            "payload":    json.dumps(event),
            "status":     "FAILED",
            "error":      str(e),
        }
        log_event(audit_info)
        notify("Remediation failed", audit_info)
        return {"statusCode": 500, "body": json.dumps(f"Remediation failed: {str(e)}")}
