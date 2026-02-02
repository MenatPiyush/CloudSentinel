import os
import boto3
from datetime import datetime, timezone

rds = boto3.client("rds")
DB_ID = os.environ["DB_INSTANCE_ID"]

snap_id = f"{DB_ID}-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}"
print("Creating snapshot:", snap_id)

resp = rds.create_db_snapshot(DBInstanceIdentifier=DB_ID, DBSnapshotIdentifier=snap_id)
print(resp["DBSnapshot"]["DBSnapshotIdentifier"])
