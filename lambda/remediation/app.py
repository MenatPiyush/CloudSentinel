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
    role_arn = f"arn:aws:iam::{account_id}:role/{ASSUME_ROLE_NAME}"
    response = sts_client.assume_role(
        RoleArn=role_arn,
        RoleSessionName=session_name
    )
    credentials = response['Credentials']
    return boto3.Session(
        aws_access_key_id=credentials['AccessKeyId'],
        aws_secret_access_key=credentials['SecretAccessKey'],
        aws_session_token=credentials['SessionToken']
    )

def handle_high_cpu_scale_asg(session, asg_name: str, desired: int):
    asg_client = session.client('autoscaling')
    asg_client.update_auto_scaling_group(
        AutoScalingGroupName=asg_name,
        DesiredCapacity=desired
    )

def log_event(audit_info: dict):
    if not ddb:
        return
    ddb.put_item(Item=audit_info)

def notify(subject: str, message: str):
    if not SNS_TOPIC_ARN:
        return
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject,
        Message=json.dumps(message, indent=2)
    )

def lambda_handler(event, context):
    now = datetime.now(timezone.utc).isoformat()
    account_id = event.get('account_id')
    action = event.get('action')

    if not account_id or not action:
        return {
            'statusCode': 400,
            'body': json.dumps('Missing account_id or action in event')
        }
    try:
        session = assume(account_id)
        if action == "scale_asg":
            handle_high_cpu_scale_asg(session, event["asg_name"], int(event["desired"]))
        else:
            return {
                'statusCode': 400,
                'body': json.dumps(f'Unknown action: {action}')
            }
        audit_info = {
            "pk": f"ACCOUNT#{account_id}",
            "account_id": account_id,
            "ts": now,
            "action": action,
            "payload": json.dumps(event),
            "status": "SUCCESS"
        }
        log_event(audit_info)
        notify("Remediation executed successfully", audit_info)
        return {
            'statusCode': 200,
            'body': json.dumps('Remediation executed successfully')
        }
    except Exception as e:
        audit_info = {
            "pk": f"ACCOUNT#{account_id}",
            "account_id": account_id,
            "ts": now,
            "action": action,
            "payload": json.dumps(event),
            "status": "FAILED",
            "error": str(e)
        }
        log_event(audit_info)
        notify("Remediation failed", audit_info)
        return {
            'statusCode': 500,
            'body': json.dumps(f'Remediation failed: {str(e)}')
        }