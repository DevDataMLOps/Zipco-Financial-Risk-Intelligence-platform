from __future__ import annotations

import hashlib
import json
import os
import time
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError


REGION = os.environ["AWS_REGION"]
ACCOUNT_ID = os.environ["ACCOUNT_ID"]
DATA_BUCKET = os.environ["DATA_BUCKET"]
DEMO_DATABASE = os.environ["DEMO_DATABASE"]
DEMO_TABLE = os.environ["DEMO_TABLE"]
ATHENA_WORKGROUP = os.environ["ATHENA_WORKGROUP"]
REGISTERED_LOCATION_ARN = os.environ["REGISTERED_LOCATION_ARN"]
DATA_ACCESS_ROLE_ARN = os.environ["DATA_ACCESS_ROLE_ARN"]
SECURITY_KEY_ARN = os.environ["SECURITY_KEY_ARN"]

lakeformation = boto3.client("lakeformation", region_name=REGION)
glue = boto3.client("glue", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)
sts = boto3.client("sts", region_name=REGION)


def pages(client: Any, operation: str, result_key: str, **kwargs: Any) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    request = dict(kwargs)
    api_call = getattr(client, operation)
    while True:
        page = api_call(**request)
        values.extend(page.get(result_key, []))
        next_token = page.get("NextToken")
        if not next_token:
            break
        request["NextToken"] = next_token
    return values


def ensure_iam_allowed_principals(resource: dict[str, Any]) -> None:
    principal = {"DataLakePrincipalIdentifier": "IAM_ALLOWED_PRINCIPALS"}
    existing = pages(
        lakeformation,
        "list_permissions",
        "PrincipalResourcePermissions",
        Principal=principal,
        Resource=resource,
    )
    if any("ALL" in item.get("Permissions", []) for item in existing):
        return
    try:
        lakeformation.grant_permissions(
            Principal=principal,
            Resource=resource,
            Permissions=["ALL"],
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "AlreadyExistsException":
            raise


def ensure_opt_in(principal_arn: str, resource: dict[str, Any]) -> None:
    principal = {"DataLakePrincipalIdentifier": principal_arn}
    existing = pages(
        lakeformation,
        "list_lake_formation_opt_ins",
        "LakeFormationOptInsInfoList",
        Principal=principal,
        Resource=resource,
    )
    if existing:
        return
    try:
        lakeformation.create_lake_formation_opt_in(
            Principal=principal,
            Resource=resource,
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "AlreadyExistsException":
            raise


def permissions_for(
    principal_arn: str, resources: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    permissions: list[dict[str, Any]] = []
    for resource in resources:
        resource_permissions = pages(
            lakeformation,
            "list_permissions",
            "PrincipalResourcePermissions",
            CatalogId=ACCOUNT_ID,
            Resource=resource,
        )
        permissions.extend(
            item
            for item in resource_permissions
            if item.get("Principal", {}).get("DataLakePrincipalIdentifier")
            == principal_arn
        )
    return permissions


def lf_tag_policy_permission(
    permissions: list[dict[str, Any]], resource_type: str, permission: str
) -> bool:
    for item in permissions:
        policy = item.get("Resource", {}).get("LFTagPolicy", {})
        if policy.get("ResourceType") == resource_type and permission in item.get(
            "Permissions", []
        ):
            return True
    return False


def lf_tag_permission(
    permissions: list[dict[str, Any]], tag_key: str, permission: str
) -> bool:
    for item in permissions:
        tag = item.get("Resource", {}).get("LFTag", {})
        if tag.get("TagKey") == tag_key and permission in item.get("Permissions", []):
            return True
    return False


def has_tag(payload: dict[str, Any], tag_key: str, tag_value: str) -> bool:
    def walk(value: Any) -> bool:
        if isinstance(value, dict):
            if value.get("TagKey") == tag_key and tag_value in value.get("TagValues", []):
                return True
            return any(walk(item) for item in value.values())
        if isinstance(value, list):
            return any(walk(item) for item in value)
        return False

    return walk(payload)


def catalog_snapshot() -> dict[str, int]:
    snapshot: dict[str, int] = {}
    for database in (
        "zipco_financial_risk",
        "zipco_financial_analytics",
        "zipco_financial_risk_engine",
    ):
        try:
            glue.get_database(Name=database)
        except glue.exceptions.EntityNotFoundException:
            snapshot[database] = -1
            continue
        snapshot[database] = len(
            pages(glue, "get_tables", "TableList", DatabaseName=database)
        )
    return snapshot


def role_session(role_arn: str, session_name: str) -> boto3.Session:
    credentials = sts.assume_role(
        RoleArn=role_arn,
        RoleSessionName=session_name,
        DurationSeconds=900,
    )["Credentials"]
    return boto3.Session(
        aws_access_key_id=credentials["AccessKeyId"],
        aws_secret_access_key=credentials["SecretAccessKey"],
        aws_session_token=credentials["SessionToken"],
        region_name=REGION,
    )


def run_query(role_arn: str, session_name: str) -> dict[str, Any]:
    athena = role_session(role_arn, session_name).client("athena")
    response = athena.start_query_execution(
        QueryString=f"SELECT count(*) AS row_count FROM {DEMO_DATABASE}.{DEMO_TABLE}",
        QueryExecutionContext={"Database": DEMO_DATABASE, "Catalog": "AwsDataCatalog"},
        WorkGroup=ATHENA_WORKGROUP,
    )
    query_id = response["QueryExecutionId"]
    detail: dict[str, Any] = {}
    for _ in range(90):
        detail = athena.get_query_execution(QueryExecutionId=query_id)["QueryExecution"]
        state = detail["Status"]["State"]
        if state not in {"QUEUED", "RUNNING"}:
            break
        time.sleep(2)
    else:
        raise TimeoutError(f"Athena query {query_id} did not reach a terminal state")

    result: dict[str, Any] = {
        "query_execution_id": query_id,
        "state": detail["Status"]["State"],
        "state_change_reason": detail["Status"].get("StateChangeReason", ""),
    }
    if result["state"] == "SUCCEEDED":
        rows = athena.get_query_results(QueryExecutionId=query_id)["ResultSet"]["Rows"]
        result["row_count"] = int(rows[1]["Data"][0]["VarCharValue"])
    return result


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    database_resource = {
        "Database": {"CatalogId": ACCOUNT_ID, "Name": DEMO_DATABASE}
    }
    table_resource = {
        "Table": {
            "CatalogId": ACCOUNT_ID,
            "DatabaseName": DEMO_DATABASE,
            "Name": DEMO_TABLE,
        }
    }
    database_policy_resource = {
        "LFTagPolicy": {
            "CatalogId": ACCOUNT_ID,
            "ResourceType": "DATABASE",
            "Expression": [
                {"TagKey": "zipco-domain", "TagValues": ["risk-analytics"]}
            ],
        }
    }
    table_policy_resource = {
        "LFTagPolicy": {
            "CatalogId": ACCOUNT_ID,
            "ResourceType": "TABLE",
            "Expression": [
                {"TagKey": "zipco-domain", "TagValues": ["risk-analytics"]},
                {"TagKey": "zipco-sensitivity", "TagValues": ["internal"]},
            ],
        }
    }
    domain_tag_resource = {
        "LFTag": {
            "CatalogId": ACCOUNT_ID,
            "TagKey": "zipco-domain",
            "TagValues": ["risk-analytics"],
        }
    }
    sensitivity_tag_resource = {
        "LFTag": {
            "CatalogId": ACCOUNT_ID,
            "TagKey": "zipco-sensitivity",
            "TagValues": ["internal"],
        }
    }
    permission_resources = [
        database_policy_resource,
        table_policy_resource,
        domain_tag_resource,
        sensitivity_tag_resource,
    ]

    persona_arns: dict[str, str] = event["persona_arns"]
    authorized_probe_role_arn = event["authorized_probe_role_arn"]
    denied_probe_role_arn = event["denied_probe_role_arn"]
    all_principals = [
        *persona_arns.values(),
        authorized_probe_role_arn,
        denied_probe_role_arn,
    ]

    ensure_iam_allowed_principals(database_resource)
    ensure_iam_allowed_principals(table_resource)
    for principal_arn in all_principals:
        ensure_opt_in(principal_arn, database_resource)
        ensure_opt_in(principal_arn, table_resource)

    time.sleep(5)

    registration = lakeformation.describe_resource(ResourceArn=REGISTERED_LOCATION_ARN)[
        "ResourceInfo"
    ]
    database_tags = lakeformation.get_resource_lf_tags(Resource=database_resource)
    table_tags = lakeformation.get_resource_lf_tags(Resource=table_resource)
    domain_tag = lakeformation.get_lf_tag(
        CatalogId=ACCOUNT_ID, TagKey="zipco-domain"
    )
    sensitivity_tag = lakeformation.get_lf_tag(
        CatalogId=ACCOUNT_ID, TagKey="zipco-sensitivity"
    )
    glue_database = glue.get_database(Name=DEMO_DATABASE)["Database"]
    glue_table = glue.get_table(DatabaseName=DEMO_DATABASE, Name=DEMO_TABLE)["Table"]
    fixture_object = s3.head_object(
        Bucket=DATA_BUCKET,
        Key="governance-demo/risk_band_summary/part-00000.csv",
    )

    principal_permissions = {
        label: permissions_for(arn, permission_resources)
        for label, arn in persona_arns.items()
    }

    opt_ins = pages(
        lakeformation,
        "list_lake_formation_opt_ins",
        "LakeFormationOptInsInfoList",
    )
    relevant_opt_ins = [
        item
        for item in opt_ins
        if item.get("Principal", {}).get("DataLakePrincipalIdentifier")
        in all_principals
        and (
            item.get("Resource", {}).get("Database", {}).get("Name")
            == DEMO_DATABASE
            or (
                item.get("Resource", {}).get("Table", {}).get("DatabaseName")
                == DEMO_DATABASE
                and item.get("Resource", {}).get("Table", {}).get("Name")
                == DEMO_TABLE
            )
        )
    ]

    authorized_query: dict[str, Any] = {}
    for attempt in range(1, 4):
        authorized_query = run_query(
            authorized_probe_role_arn, f"zipco-lf-authorized-{attempt}"
        )
        if authorized_query["state"] == "SUCCEEDED":
            break
        time.sleep(5)
    denied_query = run_query(denied_probe_role_arn, "zipco-lf-denied")
    denial_reason = denied_query.get("state_change_reason", "").lower()

    catalog_before = event["catalog_before"]
    catalog_after = catalog_snapshot()
    checks = {
        "LF-01": fixture_object.get("ContentLength", 0) > 0,
        "LF-02": registration.get("RoleArn") == DATA_ACCESS_ROLE_ARN,
        "LF-03": fixture_object.get("ServerSideEncryption") == "aws:kms"
        and fixture_object.get("SSEKMSKeyId") == SECURITY_KEY_ARN,
        "LF-04": registration.get("HybridAccessEnabled") is True,
        "LF-05": glue_database.get("Name") == DEMO_DATABASE,
        "LF-06": glue_table.get("Name") == DEMO_TABLE
        and glue_table.get("StorageDescriptor", {}).get("Location", "").endswith(
            "/governance-demo/risk_band_summary/"
        ),
        "LF-07": "risk-analytics" in domain_tag.get("TagValues", []),
        "LF-08": "internal" in sensitivity_tag.get("TagValues", []),
        "LF-09": has_tag(database_tags, "zipco-domain", "risk-analytics"),
        "LF-10": has_tag(table_tags, "zipco-domain", "risk-analytics")
        and has_tag(table_tags, "zipco-sensitivity", "internal"),
        "LF-11": lf_tag_policy_permission(
            principal_permissions["data_engineer"], "TABLE", "SELECT"
        ),
        "LF-12": lf_tag_policy_permission(
            principal_permissions["risk_analyst"], "TABLE", "SELECT"
        ),
        "LF-13": lf_tag_policy_permission(
            principal_permissions["data_steward"], "TABLE", "ALTER"
        )
        and lf_tag_permission(
            principal_permissions["data_steward"], "zipco-domain", "ASSOCIATE"
        ),
        "LF-14": lf_tag_policy_permission(
            principal_permissions["security_auditor"], "TABLE", "DESCRIBE"
        )
        and not lf_tag_policy_permission(
            principal_permissions["security_auditor"], "TABLE", "SELECT"
        ),
        "LF-15": len(relevant_opt_ins) == 12,
        "LF-16": authorized_query.get("state") == "SUCCEEDED"
        and authorized_query.get("row_count") == 4,
        "LF-17": denied_query.get("state") == "FAILED"
        and any(
            marker in denial_reason
            for marker in ("lake formation", "permission", "access denied")
        ),
        "LF-18": catalog_before == catalog_after,
    }
    failed = [control_id for control_id, passed in checks.items() if not passed]
    if failed:
        raise RuntimeError(f"Lake Formation validation failed: {', '.join(failed)}")

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-lambda")
    evidence_key = (
        "security-governance/lake-formation-demo/evidence/"
        f"run_id={run_id}/zipco_iam_lake_formation_demo_verification.json"
    )
    evidence_uri = f"s3://{DATA_BUCKET}/{evidence_key}"
    evidence = {
        "status": "DEPLOYED_RUN_AND_VERIFIED",
        "run_id": run_id,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "aws": {
            "region": REGION,
            "account_id": ACCOUNT_ID,
            "validation_role_arn": event["validation_role_arn"],
        },
        "scope": {
            "database": DEMO_DATABASE,
            "table": DEMO_TABLE,
            "registered_location_arn": REGISTERED_LOCATION_ARN,
            "access_mode": "HYBRID",
            "data_access_role_arn": DATA_ACCESS_ROLE_ARN,
            "kms_key_arn": SECURITY_KEY_ARN,
            "athena_workgroup": ATHENA_WORKGROUP,
        },
        "classification": {
            "database_lf_tags": database_tags,
            "table_lf_tags": table_tags,
        },
        "personas": {
            "mapped": 4,
            "hybrid_opt_ins": len(relevant_opt_ins),
            "security_auditor_select": False,
        },
        "access_tests": {
            "authorized_probe_role_arn": authorized_probe_role_arn,
            "authorized_query": authorized_query,
            "denied_probe_role_arn": denied_probe_role_arn,
            "denied_query": denied_query,
        },
        "regression_guard": {
            "catalog_before": catalog_before,
            "catalog_after": catalog_after,
            "unchanged": True,
        },
        "controls": {
            "passed": 18,
            "total": 18,
            "status": "PASS",
            "results": checks,
        },
        "integrity": {
            "contract_sha256": event["contract_sha256"],
            "fixture_sha256": event["fixture_sha256"],
            "validator_sha256": event["validator_sha256"],
        },
        "evidence_uri": evidence_uri,
        "lake_formation_console_url": (
            f"https://{REGION}.console.aws.amazon.com/lakeformation/"
            f"home?region={REGION}#permissions"
        ),
        "data_notice": (
            "The queried CSV is a four-row deterministic control fixture, "
            "not customer data or a business result."
        ),
    }
    payload = json.dumps(evidence, indent=2, sort_keys=True).encode("utf-8")
    for key in (
        evidence_key,
        "metadata/contracts/lake-formation-demo/latest_verification.json",
    ):
        s3.put_object(
            Bucket=DATA_BUCKET,
            Key=key,
            Body=payload,
            ServerSideEncryption="aws:kms",
            SSEKMSKeyId=SECURITY_KEY_ARN,
            BucketKeyEnabled=True,
            ContentType="application/json",
            Metadata={"sha256": hashlib.sha256(payload).hexdigest()},
        )
    return evidence
