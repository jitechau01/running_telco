"""
upload_to_s3.py

Uploads local feed files (produced by generate_telecom_data.py, or dropped
by a real upstream system) into the Running Telco raw landing bucket,
under the same prefixes the Snowflake external stages point at.

Usage:
    python upload_to_s3.py --local-dir ./data_out --bucket running-telco-raw
"""
import argparse
import logging
import os
import sys

import boto3
from botocore.exceptions import ClientError

sys.path.append(os.path.join(os.path.dirname(__file__), "..", "config"))
from config import S3Config  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")
log = logging.getLogger("upload_to_s3")


def upload_directory(local_dir: str, bucket: str, region: str) -> dict:
    """Uploads every file under local_dir/<feed>/ to s3://bucket/<feed>/filename.
    Returns a dict of feed -> list of uploaded keys, used by the orchestrator
    to know exactly which files were landed in this run."""
    s3 = boto3.client("s3", region_name=region)
    uploaded = {}

    for feed in os.listdir(local_dir):
        feed_dir = os.path.join(local_dir, feed)
        if not os.path.isdir(feed_dir):
            continue
        uploaded[feed] = []
        for fname in os.listdir(feed_dir):
            local_path = os.path.join(feed_dir, fname)
            s3_key = f"{feed}/{fname}"
            try:
                s3.upload_file(local_path, bucket, s3_key)
                uploaded[feed].append(s3_key)
                log.info(f"uploaded s3://{bucket}/{s3_key}")
            except ClientError as e:
                log.error(f"FAILED to upload {local_path} -> s3://{bucket}/{s3_key}: {e}")
                raise
    return uploaded


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--local-dir", default="./data_out")
    ap.add_argument("--bucket", default=S3Config.bucket)
    ap.add_argument("--region", default=S3Config.region)
    args = ap.parse_args()

    result = upload_directory(args.local_dir, args.bucket, args.region)
    total = sum(len(v) for v in result.values())
    log.info(f"Upload complete: {total} files across {len(result)} feeds.")


if __name__ == "__main__":
    main()
