from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import mimetypes
import re
import sys
from pathlib import Path

import botocore.session
from botocore.exceptions import ClientError, NoCredentialsError


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "outputs"
SOURCE_CSV = Path(r"C:\Users\USER\Downloads\zipco_bank_data.csv")
SOURCE_DICTIONARY = Path(r"C:\Users\USER\Downloads\DATA DICTIONARY.pdf")
CONTRACT = OUTPUT_DIR / "zipco_data_contract_v1.yaml"
PROFILE_REPORT = OUTPUT_DIR / "zipco_phase2_profile_and_data_contract.md"


def parse_args():
    parser = argparse.ArgumentParser(description="Deploy and verify the ZIPCO S3 data lake baseline.")
    parser.add_argument("--region", required=True, help="AWS region, for example us-east-1")
    parser.add_argument("--profile", help="Optional AWS shared-config profile")
    parser.add_argument("--bucket-name", help="Optional globally unique bucket name")
    parser.add_argument("--project", default="zipco-financial-risk-platform")
    parser.add_argument("--owner", default="ehibhahiemen-ughele")
    parser.add_argument("--environment", default="dev")
    parser.add_argument("--encryption", choices=["AES256", "aws:kms"], default="AES256")
    parser.add_argument("--kms-key-id", help="KMS key ID/ARN/alias; only used with aws:kms")
    parser.add_argument("--skip-upload", action="store_true", help="Configure only; do not upload artifacts")
    return parser.parse_args()


def sha256(path: Path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_b64(path: Path):
    return base64.b64encode(bytes.fromhex(sha256(path))).decode("ascii")


def normalize_bucket_component(value: str):
    value = value.lower().replace("_", "-")
    value = re.sub(r"[^a-z0-9.-]+", "-", value)
    value = re.sub(r"-+", "-", value).strip("-.")
    return value


def call(client, operation: str, **kwargs):
    return getattr(client, operation)(**kwargs)


def ensure_bucket(s3, bucket: str, region: str, account_id: str):
    try:
        s3.head_bucket(Bucket=bucket)
        return "reused"
    except ClientError as error:
        code = str(error.response.get("Error", {}).get("Code", ""))
        status = error.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if code not in {"404", "NoSuchBucket", "NotFound"} and status != 404:
            raise RuntimeError(
                f"Bucket {bucket!r} exists but is not accessible to AWS account {account_id}. "
                "Choose another --bucket-name."
            ) from error

    parameters = {"Bucket": bucket, "ObjectOwnership": "BucketOwnerEnforced"}
    if region != "us-east-1":
        parameters["CreateBucketConfiguration"] = {"LocationConstraint": region}
    s3.create_bucket(**parameters)
    waiter = s3.get_waiter("bucket_exists")
    waiter.wait(Bucket=bucket)
    return "created"


def put_controls(s3, bucket: str, args):
    s3.put_public_access_block(
        Bucket=bucket,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
    s3.put_bucket_ownership_controls(
        Bucket=bucket,
        OwnershipControls={"Rules": [{"ObjectOwnership": "BucketOwnerEnforced"}]},
    )
    s3.put_bucket_versioning(Bucket=bucket, VersioningConfiguration={"Status": "Enabled"})

    encryption = {"SSEAlgorithm": args.encryption}
    if args.encryption == "aws:kms":
        encryption["KMSMasterKeyID"] = args.kms_key_id or "alias/aws/s3"
        encryption["BucketKeyEnabled"] = True
    s3.put_bucket_encryption(
        Bucket=bucket,
        ServerSideEncryptionConfiguration={"Rules": [{"ApplyServerSideEncryptionByDefault": encryption}]},
    )

    tls_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "DenyInsecureTransport",
                "Effect": "Deny",
                "Principal": "*",
                "Action": "s3:*",
                "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
                "Condition": {"Bool": {"aws:SecureTransport": "false"}},
            }
        ],
    }
    s3.put_bucket_policy(Bucket=bucket, Policy=json.dumps(tls_policy, separators=(",", ":")))

    s3.put_bucket_tagging(
        Bucket=bucket,
        Tagging={
            "TagSet": [
                {"Key": "Project", "Value": args.project},
                {"Key": "Environment", "Value": args.environment},
                {"Key": "Owner", "Value": args.owner},
                {"Key": "ManagedBy", "Value": "Codex"},
                {"Key": "DataClassification", "Value": "Confidential-Financial"},
            ]
        },
    )

    lifecycle = {
        "Rules": [
            {
                "ID": "abort-incomplete-multipart-uploads",
                "Status": "Enabled",
                "Filter": {"Prefix": ""},
                "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7},
            },
            {
                "ID": "raw-data-archive",
                "Status": "Enabled",
                "Filter": {"Prefix": "raw/"},
                "Transitions": [
                    {"Days": 30, "StorageClass": "STANDARD_IA"},
                    {"Days": 90, "StorageClass": "GLACIER_IR"},
                ],
                "NoncurrentVersionTransitions": [
                    {"NoncurrentDays": 30, "StorageClass": "STANDARD_IA"},
                    {"NoncurrentDays": 90, "StorageClass": "GLACIER_IR"},
                ],
                "NoncurrentVersionExpiration": {"NoncurrentDays": 365},
            },
            {
                "ID": "quarantine-retention",
                "Status": "Enabled",
                "Filter": {"Prefix": "quarantine/"},
                "Expiration": {"Days": 365},
                "NoncurrentVersionExpiration": {"NoncurrentDays": 90},
            },
            {
                "ID": "athena-results-retention",
                "Status": "Enabled",
                "Filter": {"Prefix": "athena-results/"},
                "Expiration": {"Days": 30},
                "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
            },
            {
                "ID": "processed-noncurrent-retention",
                "Status": "Enabled",
                "Filter": {"Tag": {"Key": "retention", "Value": "processed"}},
                "NoncurrentVersionExpiration": {"NoncurrentDays": 90},
            },
        ]
    }
    s3.put_bucket_lifecycle_configuration(Bucket=bucket, LifecycleConfiguration=lifecycle)


def put_prefix_markers(s3, bucket: str, encryption: str, kms_key_id: str | None):
    prefixes = [
        "raw/zipco_bank_flat/",
        "validated/zipco_bank_flat/",
        "curated/customers/",
        "curated/accounts/",
        "curated/transactions/",
        "curated/transaction_categories/",
        "curated/categorized_transactions/",
        "curated/market_data/",
        "analytics/customer_risk/",
        "analytics/transaction_risk/",
        "analytics/portfolio_metrics/",
        "quarantine/schema_errors/",
        "quarantine/duplicate_records/",
        "quarantine/business_rule_errors/",
        "metadata/contracts/",
        "metadata/data_dictionary/",
        "athena-results/",
    ]
    encryption_args = {"ServerSideEncryption": encryption}
    if encryption == "aws:kms":
        encryption_args["SSEKMSKeyId"] = kms_key_id or "alias/aws/s3"
        encryption_args["BucketKeyEnabled"] = True
    for prefix in prefixes:
        s3.put_object(
            Bucket=bucket,
            Key=prefix,
            Body=b"",
            ContentType="application/x-directory",
            Metadata={"purpose": "logical-prefix-marker"},
            **encryption_args,
        )
    return prefixes


def upload_file(s3, bucket: str, path: Path, key: str, encryption: str, kms_key_id: str | None, tags: str):
    if not path.exists():
        raise FileNotFoundError(path)
    digest_hex = sha256(path)
    encryption_args = {"ServerSideEncryption": encryption}
    if encryption == "aws:kms":
        encryption_args["SSEKMSKeyId"] = kms_key_id or "alias/aws/s3"
        encryption_args["BucketKeyEnabled"] = True
    content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    with path.open("rb") as stream:
        response = s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=stream,
            ContentLength=path.stat().st_size,
            ContentType=content_type,
            ChecksumAlgorithm="SHA256",
            ChecksumSHA256=sha256_b64(path),
            Metadata={"sha256": digest_hex, "source-name": path.name},
            Tagging=tags,
            **encryption_args,
        )
    return {
        "key": key,
        "source_path": str(path),
        "bytes": path.stat().st_size,
        "sha256": digest_hex,
        "etag": response.get("ETag", "").strip('"'),
        "version_id": response.get("VersionId"),
        "checksum_sha256": response.get("ChecksumSHA256"),
    }


def verify(s3, bucket: str, expected_uploads: list[dict], expected_prefixes: list[str], args):
    encryption = s3.get_bucket_encryption(Bucket=bucket)["ServerSideEncryptionConfiguration"]
    public_access = s3.get_public_access_block(Bucket=bucket)["PublicAccessBlockConfiguration"]
    ownership = s3.get_bucket_ownership_controls(Bucket=bucket)["OwnershipControls"]
    versioning = s3.get_bucket_versioning(Bucket=bucket)
    lifecycle = s3.get_bucket_lifecycle_configuration(Bucket=bucket)
    policy_status = s3.get_bucket_policy_status(Bucket=bucket)["PolicyStatus"]
    tags = s3.get_bucket_tagging(Bucket=bucket)["TagSet"]
    location = s3.get_bucket_location(Bucket=bucket).get("LocationConstraint") or "us-east-1"

    object_checks = []
    for item in expected_uploads:
        head = s3.head_object(Bucket=bucket, Key=item["key"], ChecksumMode="ENABLED")
        remote_digest = head.get("Metadata", {}).get("sha256")
        object_checks.append(
            {
                "key": item["key"],
                "bytes_expected": item["bytes"],
                "bytes_remote": head["ContentLength"],
                "sha256_expected": item["sha256"],
                "sha256_metadata_remote": remote_digest,
                "size_match": item["bytes"] == head["ContentLength"],
                "sha256_match": item["sha256"] == remote_digest,
                "server_side_encryption": head.get("ServerSideEncryption"),
                "version_id": head.get("VersionId"),
            }
        )

    listed = []
    continuation = None
    while True:
        params = {"Bucket": bucket, "MaxKeys": 1000}
        if continuation:
            params["ContinuationToken"] = continuation
        page = s3.list_objects_v2(**params)
        listed.extend(obj["Key"] for obj in page.get("Contents", []))
        if not page.get("IsTruncated"):
            break
        continuation = page["NextContinuationToken"]

    encryption_rule = encryption["Rules"][0]["ApplyServerSideEncryptionByDefault"]
    result = {
        "verified_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "bucket": bucket,
        "region": location,
        "controls": {
            "private_public_access_block": all(public_access.values()),
            "public_access_block": public_access,
            "bucket_policy_is_public": policy_status.get("IsPublic"),
            "ownership": ownership,
            "versioning": versioning.get("Status"),
            "default_encryption": encryption_rule,
            "lifecycle_rule_ids": sorted(rule["ID"] for rule in lifecycle["Rules"]),
            "tags": sorted(tags, key=lambda item: item["Key"]),
        },
        "prefix_markers_expected": expected_prefixes,
        "prefix_markers_present": sorted(key for key in listed if key.endswith("/")),
        "objects": object_checks,
    }
    result["verification_passed"] = all(
        [
            result["controls"]["private_public_access_block"],
            result["controls"]["bucket_policy_is_public"] is False,
            result["controls"]["versioning"] == "Enabled",
            encryption_rule.get("SSEAlgorithm") == args.encryption,
            set(expected_prefixes).issubset(set(result["prefix_markers_present"])),
            all(item["size_match"] and item["sha256_match"] for item in object_checks),
        ]
    )
    return result


def write_reports(deployment: dict):
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    json_path = OUTPUT_DIR / "zipco_s3_deployment_verification.json"
    json_path.write_text(json.dumps(deployment, indent=2), encoding="utf-8")

    controls = deployment["verification"]["controls"]
    lines = [
        "# ZIPCO S3 Implementation Record",
        "",
        f"**Deployment status:** `{deployment['status']}`  ",
        f"**Verified:** `{deployment['verification']['verification_passed']}`  ",
        f"**AWS account:** `{deployment['account_id']}`  ",
        f"**Region:** `{deployment['region']}`  ",
        f"**Bucket:** `{deployment['bucket']}`  ",
        f"**Completed (UTC):** `{deployment['completed_at_utc']}`",
        "",
        "## Applied controls",
        "",
        f"- Block Public Access: `{controls['private_public_access_block']}`",
        f"- Bucket policy public: `{controls['bucket_policy_is_public']}`",
        f"- Object ownership: `{controls['ownership']['Rules'][0]['ObjectOwnership']}`",
        f"- Versioning: `{controls['versioning']}`",
        f"- Default encryption: `{controls['default_encryption']['SSEAlgorithm']}`",
        "- TLS-only access enforced by bucket policy.",
        f"- Lifecycle rules: `{', '.join(controls['lifecycle_rule_ids'])}`",
        "",
        "## Uploaded objects",
        "",
        "| S3 key | Bytes | SHA-256 verified | Encryption |",
        "|---|---:|---|---|",
    ]
    for item in deployment["verification"]["objects"]:
        lines.append(
            f"| `{item['key']}` | {item['bytes_remote']:,} | "
            f"{item['sha256_match']} | `{item['server_side_encryption']}` |"
        )
    lines.extend(
        [
            "",
            "## Publication posture",
            "",
            "The source CSV is retained in the immutable raw zone. The Phase 2 contract blocks normalized curated publication because the declared entity IDs are relationally inconsistent and the dictionary fields `CategoryName`, `StockSymbol`, and `Timestamp` are missing.",
        ]
    )
    md_path = OUTPUT_DIR / "zipco_s3_implementation_record.md"
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return json_path, md_path


def main():
    args = parse_args()
    session = botocore.session.get_session()
    if args.profile:
        session.set_config_variable("profile", args.profile)
    session.set_config_variable("region", args.region)
    credentials = session.get_credentials()
    if credentials is None:
        raise NoCredentialsError()

    sts = session.create_client("sts", region_name=args.region)
    identity = sts.get_caller_identity()
    account_id = identity["Account"]
    default_name = f"zipco-financial-platform-{account_id}-{args.region}"
    bucket = normalize_bucket_component(args.bucket_name or default_name)
    s3 = session.create_client("s3", region_name=args.region)

    bucket_action = ensure_bucket(s3, bucket, args.region, account_id)
    put_controls(s3, bucket, args)
    prefixes = put_prefix_markers(s3, bucket, args.encryption, args.kms_key_id)

    uploads = []
    if not args.skip_upload:
        ingestion_date = dt.date.today().isoformat()
        uploads.append(
            upload_file(
                s3,
                bucket,
                SOURCE_CSV,
                f"raw/zipco_bank_flat/ingestion_date={ingestion_date}/zipco_bank_data.csv",
                args.encryption,
                args.kms_key_id,
                "data-zone=raw&classification=confidential-financial&retention=source",
            )
        )
        for path, key in [
            (SOURCE_DICTIONARY, "metadata/data_dictionary/DATA_DICTIONARY.pdf"),
            (CONTRACT, "metadata/contracts/zipco_data_contract_v1.yaml"),
            (PROFILE_REPORT, "metadata/contracts/zipco_phase2_profile_and_data_contract.md"),
        ]:
            uploads.append(
                upload_file(
                    s3,
                    bucket,
                    path,
                    key,
                    args.encryption,
                    args.kms_key_id,
                    "data-zone=metadata&classification=internal&retention=processed",
                )
            )

    verification = verify(s3, bucket, uploads, prefixes, args)
    deployment = {
        "status": "DEPLOYED_AND_VERIFIED" if verification["verification_passed"] else "DEPLOYED_VERIFICATION_FAILED",
        "completed_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "account_id": account_id,
        "caller_arn": identity["Arn"],
        "region": args.region,
        "bucket": bucket,
        "bucket_action": bucket_action,
        "verification": verification,
    }
    paths = write_reports(deployment)
    print(json.dumps({"status": deployment["status"], "bucket": bucket, "reports": [str(p) for p in paths]}, indent=2))
    if not verification["verification_passed"]:
        raise SystemExit(2)


if __name__ == "__main__":
    try:
        main()
    except NoCredentialsError:
        print(
            "No AWS credentials were found. Authenticate using an AWS profile or temporary environment credentials, "
            "then rerun this deployment.",
            file=sys.stderr,
        )
        raise SystemExit(3)

