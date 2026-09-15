"""Delete every object version in the evidence bucket with a governance
retention bypass, so `terraform destroy` can remove the Object-Locked bucket.

Demo retention is 1 day; production would never ship a bypass script like this,
the whole point of GOVERNANCE mode is that deletes require a deliberate,
privileged action. That is the story: teardown is possible but not casual.

Usage: python3 scripts/purge_evidence.py <bucket-name>
       (falls back to the conventional vpl-demo-evidence-<account> name)
"""

import sys

import boto3

bucket = sys.argv[1] if len(sys.argv) > 1 else None
if not bucket:
    account = boto3.client("sts").get_caller_identity()["Account"]
    bucket = f"vpl-demo-evidence-{account}"

s3 = boto3.client("s3")
paginator = s3.get_paginator("list_object_versions")
deleted = 0
try:
    for page in paginator.paginate(Bucket=bucket):
        for group in ("Versions", "DeleteMarkers"):
            for v in page.get(group, []):
                s3.delete_object(
                    Bucket=bucket,
                    Key=v["Key"],
                    VersionId=v["VersionId"],
                    BypassGovernanceRetention=True,
                )
                deleted += 1
except s3.exceptions.NoSuchBucket:
    pass
print(f"purged {deleted} object versions from {bucket}")
