import os
import boto3

rds = boto3.client("rds")

SNAPSHOT_ID = os.environ["SNAPSHOT_ID"]
TARGET_DB   = os.environ["TARGET_DB_INSTANCE_ID"]
DB_CLASS    = os.environ.get("DB_INSTANCE_CLASS", "db.t4g.medium")

print("Restoring", TARGET_DB, "from", SNAPSHOT_ID)

resp = rds.restore_db_instance_from_db_snapshot(
    DBInstanceIdentifier=TARGET_DB,
    DBSnapshotIdentifier=SNAPSHOT_ID,
    DBInstanceClass=DB_CLASS,
    MultiAZ=True,
    PubliclyAccessible=False
)
print(resp["DBInstance"]["DBInstanceIdentifier"])
