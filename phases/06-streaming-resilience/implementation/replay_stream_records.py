"""Safely inspect or replay records from the immutable Firehose raw backup."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from collections.abc import Iterable

import boto3


def records_from_bytes(body: bytes) -> Iterable[bytes]:
    try:
        body = gzip.GzipFile(fileobj=io.BytesIO(body)).read()
    except (gzip.BadGzipFile, EOFError):
        pass
    for line in body.splitlines():
        if line.strip():
            yield line.strip() + b"\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--prefix", default="streaming/raw/")
    parser.add_argument("--delivery-stream-name", required=True)
    parser.add_argument("--region", default="us-east-2")
    parser.add_argument("--run-id", help="Only replay records whose run_id matches")
    parser.add_argument("--max-records", type=int, default=100)
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually write to Firehose; without this flag the command is a dry run",
    )
    args = parser.parse_args()
    if args.max_records < 1 or args.max_records > 500:
        parser.error("max-records must be between 1 and 500")

    s3 = boto3.client("s3", region_name=args.region)
    firehose = boto3.client("firehose", region_name=args.region)
    paginator = s3.get_paginator("list_objects_v2")
    selected: list[bytes] = []
    objects_scanned = 0

    for page in paginator.paginate(Bucket=args.bucket, Prefix=args.prefix):
        for item in page.get("Contents", []):
            objects_scanned += 1
            body = s3.get_object(Bucket=args.bucket, Key=item["Key"])["Body"].read()
            for raw in records_from_bytes(body):
                try:
                    payload = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if args.run_id and payload.get("run_id") != args.run_id:
                    continue
                selected.append(raw)
                if len(selected) >= args.max_records:
                    break
            if len(selected) >= args.max_records:
                break
        if len(selected) >= args.max_records:
            break

    replay_id = hashlib.sha256(b"".join(selected)).hexdigest()[:16] if selected else None
    failures = 0
    if args.execute and selected:
        result = firehose.put_record_batch(
            DeliveryStreamName=args.delivery_stream_name,
            Records=[{"Data": raw} for raw in selected],
        )
        failures = int(result.get("FailedPutCount", 0))

    print(
        json.dumps(
            {
                "mode": "EXECUTE" if args.execute else "DRY_RUN",
                "bucket": args.bucket,
                "prefix": args.prefix,
                "delivery_stream_name": args.delivery_stream_name,
                "objects_scanned": objects_scanned,
                "records_selected": len(selected),
                "replay_batch_id": replay_id,
                "put_failures": failures,
            },
            indent=2,
        )
    )
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
