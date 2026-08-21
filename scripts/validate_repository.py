from __future__ import annotations

import json
import hashlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAX_GIT_FILE_BYTES = 10 * 1024 * 1024
SECRET_PATTERNS = {
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "AWS secret assignment": re.compile(
        r"(?i)aws_secret_access_key\s*[:=]\s*['\"]?[A-Za-z0-9/+=]{30,}"
    ),
    "GitHub token": re.compile(r"\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b"),
}
TEXT_SUFFIXES = {
    ".md",
    ".json",
    ".yaml",
    ".yml",
    ".py",
    ".sql",
    ".sh",
    ".csv",
    ".txt",
}


def repository_files() -> list[Path]:
    return [
        path
        for path in ROOT.rglob("*")
        if path.is_file() and ".git" not in path.parts and "__pycache__" not in path.parts
    ]


def validate_json(files: list[Path], errors: list[str]) -> None:
    for path in files:
        if path.suffix.lower() == ".json":
            try:
                json.loads(path.read_text(encoding="utf-8-sig"))
            except Exception as exc:  # noqa: BLE001 - report every invalid artifact
                errors.append(f"Invalid JSON: {path.relative_to(ROOT)} ({exc})")


def validate_markdown_links(files: list[Path], errors: list[str]) -> None:
    link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
    for path in files:
        if path.suffix.lower() != ".md":
            continue
        body = path.read_text(encoding="utf-8-sig")
        for raw_target in link_pattern.findall(body):
            target = raw_target.strip().strip("<>").split("#", 1)[0]
            if not target or re.match(r"^(?:https?://|mailto:|s3://)", target):
                continue
            if not (path.parent / target).resolve().exists():
                errors.append(f"Broken link: {path.relative_to(ROOT)} -> {raw_target}")


def validate_inventory(files: list[Path], errors: list[str]) -> None:
    expected = {
        "Glue implementation": (ROOT / "phases/02-glue-etl/implementation/zipco_relational_v2_etl.py"),
        "Athena implementation": (ROOT / "platform/athena/deploy_and_run_zipco_athena.sh"),
        "Optimization implementation": (
            ROOT / "phases/03-optimization/implementation/deploy_and_run_zipco_observability.sh"
        ),
        "Risk implementation": (
            ROOT / "phases/04-business-intelligence/implementation/deploy_and_run_zipco_risk_engine.sh"
        ),
        "Security governance implementation": (
            ROOT
            / "phases/05-security-governance/implementation/deploy_and_verify_zipco_security_governance.sh"
        ),
        "Security governance infrastructure": (
            ROOT
            / "phases/05-security-governance/implementation/zipco_security_governance_infrastructure.json"
        ),
        "Security Config rule pack": (
            ROOT
            / "phases/05-security-governance/implementation/zipco_security_config_rules.json"
        ),
        "Data classification catalog": (
            ROOT
            / "phases/05-security-governance/contracts/data_classification_catalog.json"
        ),
        "Lake Formation demo deployment": (
            ROOT
            / "phases/05-security-governance/lake-formation-demo/implementation/deploy_and_verify_zipco_lake_formation_demo.sh"
        ),
        "Lake Formation demo infrastructure": (
            ROOT
            / "phases/05-security-governance/lake-formation-demo/implementation/zipco_lake_formation_demo.json"
        ),
        "Lake Formation bootstrap infrastructure": (
            ROOT
            / "phases/05-security-governance/lake-formation-demo/implementation/zipco_lake_formation_bootstrap.json"
        ),
        "Lake Formation demo contract": (
            ROOT
            / "phases/05-security-governance/lake-formation-demo/implementation/lake_formation_demo_contract.json"
        ),
        "Streaming resilience deployment": (
            ROOT
            / "phases/06-streaming-resilience/implementation/deploy_and_verify_zipco_streaming_resilience.sh"
        ),
        "Streaming resilience infrastructure": (
            ROOT
            / "phases/06-streaming-resilience/implementation/zipco_streaming_resilience_infrastructure.json"
        ),
        "Streaming resilience transformer": (
            ROOT / "phases/06-streaming-resilience/implementation/firehose_transform.py"
        ),
        "Streaming resilience verifier": (
            ROOT / "phases/06-streaming-resilience/implementation/verify_streaming_resilience.py"
        ),
        "Streaming resilience replay utility": (
            ROOT / "phases/06-streaming-resilience/implementation/replay_stream_records.py"
        ),
        "Streaming resilience contract": (
            ROOT / "phases/06-streaming-resilience/contracts/streaming_resilience_contract.json"
        ),
        "Free-plan event-resilience deployment": (
            ROOT
            / "phases/06-streaming-resilience/free-plan-implementation/deploy_and_verify_zipco_free_plan_event_resilience.sh"
        ),
        "Free-plan event-resilience infrastructure": (
            ROOT
            / "phases/06-streaming-resilience/free-plan-implementation/zipco_free_plan_event_resilience_infrastructure.json"
        ),
        "Free-plan event-resilience processor": (
            ROOT
            / "phases/06-streaming-resilience/free-plan-implementation/lambda_event_processor.py"
        ),
        "Free-plan event-resilience verifier": (
            ROOT
            / "phases/06-streaming-resilience/free-plan-implementation/verify_free_plan_event_resilience.py"
        ),
        "Free-plan event-resilience contract": (
            ROOT
            / "phases/06-streaming-resilience/free-plan-implementation/free_plan_event_resilience_contract.json"
        ),
        "Operational event-resilience demo": (
            ROOT / "phases/06-streaming-resilience/operational-demo.md"
        ),
        "Operational event-resilience transcript": (
            ROOT
            / "phases/06-streaming-resilience/evidence/aws_free_plan_event_resilience_verification_transcript.json"
        ),
        "Operational event-resilience screenshot": (
            ROOT
            / "phases/06-streaming-resilience/screenshots/01-free-plan-event-resilience-verified.png"
        ),
        "Operational event-resilience dashboard": (
            ROOT / "phases/06-streaming-resilience/dashboard/README.md"
        ),
        "Operational event-resilience visual": (
            ROOT / "phases/06-streaming-resilience/dashboard/index.html"
        ),
        "Operational event-resilience dashboard preview": (
            ROOT
            / "phases/06-streaming-resilience/dashboard/operational-dashboard.png"
        ),
        "Professional documentation index": (ROOT / "docs/README.md"),
        "Consolidated architecture": (ROOT / "docs/ARCHITECTURE.md"),
        "Professional project handoff": (ROOT / "docs/PROJECT_HANDOFF.md"),
        "Portfolio demonstration": (ROOT / "docs/PORTFOLIO_DEMO.md"),
        "Contribution guidance": (ROOT / "CONTRIBUTING.md"),
        "Change history": (ROOT / "CHANGELOG.md"),
        "Pull request template": (ROOT / ".github/PULL_REQUEST_TEMPLATE.md"),
    }
    for label, path in expected.items():
        if not path.exists():
            errors.append(f"Missing {label}: {path.relative_to(ROOT)}")

    counts = {
        "Athena validations": len(list((ROOT / "platform/athena/validation").glob("*.sql"))),
        "Risk views": len(list((ROOT / "phases/04-business-intelligence/implementation/views").glob("*.sql"))),
        "Risk validations": len(
            list((ROOT / "phases/04-business-intelligence/implementation/validation").glob("*.sql"))
        ),
    }
    expected_counts = {"Athena validations": 8, "Risk views": 6, "Risk validations": 10}
    for label, actual in counts.items():
        if actual != expected_counts[label]:
            errors.append(f"{label}: expected {expected_counts[label]}, found {actual}")

    delivery_claims = {
        ROOT / "docs/PROJECT_HANDOFF.md": {
            "Evidence boundary",
            "Cost and cleanup",
            "Native streaming is not claimed",
        },
        ROOT / "docs/PORTFOLIO_DEMO.md": {
            "Seven-minute walkthrough",
            "88.21%",
            "95.55%",
            "20/20",
        },
        ROOT / "docs/ARCHITECTURE.md": {
            "Trust boundaries",
            "Free-plan Lambda event processing",
            "Authoritative evidence",
        },
    }
    for path, claims in delivery_claims.items():
        if not path.exists():
            continue
        body = path.read_text(encoding="utf-8-sig")
        for claim in claims:
            if claim not in body:
                errors.append(
                    f"Professional delivery document {path.relative_to(ROOT)} "
                    f"is missing: {claim!r}"
                )

    security_template_path = (
        ROOT
        / "phases/05-security-governance/implementation/zipco_security_governance_infrastructure.json"
    )
    config_template_path = (
        ROOT / "phases/05-security-governance/implementation/zipco_security_config_rules.json"
    )
    contract_path = (
        ROOT / "phases/05-security-governance/implementation/security_governance_contract.json"
    )
    lake_formation_template_path = (
        ROOT
        / "phases/05-security-governance/lake-formation-demo/implementation/zipco_lake_formation_demo.json"
    )
    lake_formation_contract_path = (
        ROOT
        / "phases/05-security-governance/lake-formation-demo/implementation/lake_formation_demo_contract.json"
    )
    lake_formation_bootstrap_path = (
        ROOT
        / "phases/05-security-governance/lake-formation-demo/implementation/zipco_lake_formation_bootstrap.json"
    )
    streaming_template_path = (
        ROOT
        / "phases/06-streaming-resilience/implementation/zipco_streaming_resilience_infrastructure.json"
    )
    streaming_contract_path = (
        ROOT / "phases/06-streaming-resilience/contracts/streaming_resilience_contract.json"
    )
    free_plan_template_path = (
        ROOT
        / "phases/06-streaming-resilience/free-plan-implementation/zipco_free_plan_event_resilience_infrastructure.json"
    )
    free_plan_contract_path = (
        ROOT
        / "phases/06-streaming-resilience/free-plan-implementation/free_plan_event_resilience_contract.json"
    )
    free_plan_transcript_path = (
        ROOT
        / "phases/06-streaming-resilience/evidence/aws_free_plan_event_resilience_verification_transcript.json"
    )
    free_plan_dashboard_path = (
        ROOT / "phases/06-streaming-resilience/dashboard/README.md"
    )
    free_plan_dashboard_visual_path = (
        ROOT / "phases/06-streaming-resilience/dashboard/index.html"
    )
    if security_template_path.exists():
        resources = json.loads(security_template_path.read_text(encoding="utf-8-sig"))["Resources"]
        persona_roles = [
            resource
            for resource in resources.values()
            if resource.get("Type") == "AWS::IAM::Role"
            and any(
                tag.get("Key") == "Persona"
                for tag in resource.get("Properties", {}).get("Tags", [])
            )
        ]
        if len(persona_roles) != 4:
            errors.append(f"Security personas: expected 4, found {len(persona_roles)}")
    if config_template_path.exists():
        resources = json.loads(config_template_path.read_text(encoding="utf-8-sig"))["Resources"]
        config_rules = [
            resource
            for resource in resources.values()
            if resource.get("Type") == "AWS::Config::ConfigRule"
        ]
        if len(config_rules) != 15:
            errors.append(f"Security Config rules: expected 15, found {len(config_rules)}")
    if contract_path.exists():
        contract = json.loads(contract_path.read_text(encoding="utf-8-sig"))
        controls = [
            control
            for family in contract.get("control_families", {}).values()
            for control in family
        ]
        if len(controls) != 24:
            errors.append(f"Security governance controls: expected 24, found {len(controls)}")
        control_ids = [control.get("id") for control in controls]
        if len(set(control_ids)) != len(control_ids):
            errors.append("Security governance control IDs must be unique")
    if lake_formation_template_path.exists():
        resources = json.loads(
            lake_formation_template_path.read_text(encoding="utf-8-sig")
        )["Resources"]
        resource_counts = {
            resource_type: sum(
                resource.get("Type") == resource_type for resource in resources.values()
            )
            for resource_type in (
                "AWS::LakeFormation::Resource",
                "AWS::LakeFormation::Tag",
                "AWS::LakeFormation::TagAssociation",
                "AWS::LakeFormation::PrincipalPermissions",
            )
        }
        expected_lf_counts = {
            "AWS::LakeFormation::Resource": 1,
            "AWS::LakeFormation::Tag": 2,
            "AWS::LakeFormation::TagAssociation": 2,
            "AWS::LakeFormation::PrincipalPermissions": 15,
        }
        for resource_type, expected_count in expected_lf_counts.items():
            if resource_counts[resource_type] != expected_count:
                errors.append(
                    f"Lake Formation {resource_type}: expected {expected_count}, "
                    f"found {resource_counts[resource_type]}"
                )
        registered_locations = [
            resource
            for resource in resources.values()
            if resource.get("Type") == "AWS::LakeFormation::Resource"
        ]
        if not all(
            resource.get("Properties", {}).get("HybridAccessEnabled") is True
            for resource in registered_locations
        ):
            errors.append("Lake Formation demo location must use hybrid access mode")
        lambda_count = sum(
            resource.get("Type") == "AWS::Lambda::Function"
            for resource in resources.values()
        )
        if lambda_count != 1:
            errors.append(f"Lake Formation validation functions: expected 1, found {lambda_count}")
    if lake_formation_bootstrap_path.exists():
        bootstrap = json.loads(
            lake_formation_bootstrap_path.read_text(encoding="utf-8-sig")
        )
        bootstrap_resources = bootstrap["Resources"]
        settings = bootstrap_resources.get("ZipcoLakeFormationSettings", {}).get(
            "Properties", {}
        )
        if settings.get("MutationType") != "APPEND":
            errors.append("Lake Formation bootstrap must append, not replace, data lake settings")
        if len(settings.get("Admins", [])) != 2:
            errors.append("Lake Formation bootstrap must define two scoped administrator roles")
    if lake_formation_contract_path.exists():
        lf_contract = json.loads(
            lake_formation_contract_path.read_text(encoding="utf-8-sig")
        )
        lf_controls = lf_contract.get("mandatory_controls", [])
        if len(lf_controls) != 18:
            errors.append(
                f"Lake Formation demo controls: expected 18, found {len(lf_controls)}"
            )
        lf_control_ids = [control.get("id") for control in lf_controls]
        if len(set(lf_control_ids)) != len(lf_control_ids):
            errors.append("Lake Formation demo control IDs must be unique")
    if streaming_template_path.exists():
        streaming_resources = json.loads(
            streaming_template_path.read_text(encoding="utf-8-sig")
        )["Resources"]
        expected_streaming_counts = {
            "AWS::Kinesis::Stream": 0,
            "AWS::KinesisFirehose::DeliveryStream": 1,
            "AWS::Lambda::Function": 1,
            "AWS::CloudWatch::Alarm": 4,
            "AWS::CloudWatch::CompositeAlarm": 1,
            "AWS::CloudWatch::Dashboard": 1,
            "AWS::SNS::Topic": 1,
            "AWS::KMS::Key": 1,
        }
        for resource_type, expected_count in expected_streaming_counts.items():
            actual_count = sum(
                resource.get("Type") == resource_type
                for resource in streaming_resources.values()
            )
            if actual_count != expected_count:
                errors.append(
                    f"Streaming {resource_type}: expected {expected_count}, found {actual_count}"
                )
        delivery = streaming_resources.get("ZipcoTransactionDeliveryStream", {}).get(
            "Properties", {}
        )
        destination = delivery.get("ExtendedS3DestinationConfiguration", {})
        if delivery.get("DeliveryStreamType") != "DirectPut":
            errors.append("Streaming Firehose must use DirectPut")
        if "KinesisStreamSourceConfiguration" in delivery:
            errors.append("Streaming Firehose DirectPut must not declare a Kinesis source")
        if delivery.get("DeliveryStreamEncryptionConfigurationInput") != {
            "KeyType": "AWS_OWNED_CMK"
        }:
            errors.append("Streaming Firehose transport must use its AWS-owned CMK")
        if destination.get("S3BackupMode") != "Enabled":
            errors.append("Streaming Firehose must retain an all-record S3 backup")
        if destination.get("DynamicPartitioningConfiguration", {}).get("Enabled") is not True:
            errors.append("Streaming Firehose dynamic partitioning must be enabled")
        if "!{firehose:error-output-type}" not in destination.get("ErrorOutputPrefix", ""):
            errors.append("Streaming Firehose error prefix must include the failure type")
    if streaming_contract_path.exists():
        streaming_contract = json.loads(
            streaming_contract_path.read_text(encoding="utf-8-sig")
        )
        streaming_controls = streaming_contract.get("mandatory_controls", [])
        if len(streaming_controls) != 20:
            errors.append(
                f"Streaming resilience controls: expected 20, found {len(streaming_controls)}"
            )
        streaming_ids = [control.get("id") for control in streaming_controls]
        if len(set(streaming_ids)) != len(streaming_ids):
            errors.append("Streaming resilience control IDs must be unique")
        if streaming_contract.get("delivery_semantics", {}).get("guarantee") != "at-least-once":
            errors.append("Streaming delivery semantics must explicitly state at-least-once")
    if free_plan_template_path.exists():
        free_plan_resources = json.loads(
            free_plan_template_path.read_text(encoding="utf-8-sig")
        )["Resources"]
        expected_free_plan_counts = {
            "AWS::Kinesis::Stream": 0,
            "AWS::KinesisFirehose::DeliveryStream": 0,
            "AWS::Lambda::Function": 1,
            "AWS::CloudWatch::Alarm": 4,
            "AWS::CloudWatch::CompositeAlarm": 1,
            "AWS::CloudWatch::Dashboard": 1,
            "AWS::SNS::Topic": 1,
            "AWS::KMS::Key": 1,
        }
        for resource_type, expected_count in expected_free_plan_counts.items():
            actual_count = sum(
                resource.get("Type") == resource_type
                for resource in free_plan_resources.values()
            )
            if actual_count != expected_count:
                errors.append(
                    f"Free-plan {resource_type}: expected {expected_count}, found {actual_count}"
                )
        processor = free_plan_resources.get("ZipcoFreePlanEventProcessor", {}).get(
            "Properties", {}
        )
        variables = processor.get("Environment", {}).get("Variables", {})
        if processor.get("Runtime") != "python3.12":
            errors.append("Free-plan processor must use Python 3.12")
        if variables.get("EXPECTED_SCHEMA_VERSION") != "2.1.0":
            errors.append("Free-plan processor must enforce schema 2.1.0")
        if variables.get("PREFIX_ROOT") != "streaming-free-plan":
            errors.append("Free-plan processor must use its isolated S3 prefix")
    if free_plan_contract_path.exists():
        free_plan_contract = json.loads(
            free_plan_contract_path.read_text(encoding="utf-8-sig")
        )
        free_plan_controls = free_plan_contract.get("mandatory_controls", [])
        if len(free_plan_controls) != 20:
            errors.append(
                f"Free-plan event-resilience controls: expected 20, found {len(free_plan_controls)}"
            )
        free_plan_ids = [control.get("id") for control in free_plan_controls]
        if len(set(free_plan_ids)) != len(free_plan_ids):
            errors.append("Free-plan event-resilience control IDs must be unique")
        if free_plan_contract.get("native_streaming_service") is not False:
            errors.append("Free-plan fallback must explicitly deny a native-streaming claim")
        if free_plan_contract.get("status") != "DEPLOYED_RUN_AND_VERIFIED":
            errors.append("Free-plan contract must record the verified AWS deployment status")
    if free_plan_transcript_path.exists():
        free_plan_transcript = json.loads(
            free_plan_transcript_path.read_text(encoding="utf-8-sig")
        )
        if free_plan_transcript.get("evidence_status") != "TRANSCRIBED_FROM_USER_SUPPLIED_AWS_CONSOLE_OUTPUT":
            errors.append("Free-plan AWS transcript must preserve its screenshot-transcription provenance")
        if free_plan_transcript.get("status") != "DEPLOYED_RUN_AND_VERIFIED":
            errors.append("Free-plan AWS transcript must record the verified status")
        controls = free_plan_transcript.get("controls", {})
        if controls.get("status") != "PASS" or controls.get("passed") != 20 or controls.get("total") != 20:
            errors.append("Free-plan AWS transcript must record PASS (20/20)")
        if free_plan_transcript.get("native_streaming_service") != "NOT_CLAIMED":
            errors.append("Free-plan AWS transcript must deny a native-streaming claim")
        screenshot_path = (free_plan_transcript_path.parent / free_plan_transcript.get("source_screenshot", "")).resolve()
        if screenshot_path.exists():
            actual_hash = hashlib.sha256(screenshot_path.read_bytes()).hexdigest()
            if actual_hash != free_plan_transcript.get("source_screenshot_sha256"):
                errors.append("Free-plan AWS transcript screenshot hash does not match")
        dashboard_claims = {
            "20/20 PASS",
            "25/25",
            "3/3",
            "4 metric + 1 composite",
            free_plan_transcript.get("run_id", ""),
            "Native streaming `NOT CLAIMED`",
        }
        if free_plan_dashboard_path.exists():
            dashboard_text = free_plan_dashboard_path.read_text(encoding="utf-8-sig")
            for claim in dashboard_claims:
                if not claim or claim not in dashboard_text:
                    errors.append(
                        f"Free-plan dashboard is missing verified claim: {claim!r}"
                    )
        if free_plan_dashboard_visual_path.exists():
            visual_text = free_plan_dashboard_visual_path.read_text(encoding="utf-8-sig")
            visual_claims = {
                "20/20",
                "25/25",
                "3/3",
                "4 + 1",
                "NOT CLAIMED",
                free_plan_transcript.get("run_id", ""),
                free_plan_transcript.get("recovery", {}).get("replay_batch_id", ""),
            }
            for claim in visual_claims:
                if not claim or claim not in visual_text:
                    errors.append(
                        f"Free-plan dashboard visual is missing verified claim: {claim!r}"
                    )


def validate_security_and_size(files: list[Path], errors: list[str]) -> None:
    for path in files:
        relative = path.relative_to(ROOT)
        if path.stat().st_size > MAX_GIT_FILE_BYTES:
            errors.append(f"File exceeds 10 MiB policy: {relative}")
        if path.suffix.lower() not in TEXT_SUFFIXES and path.name not in {".gitignore"}:
            continue
        try:
            body = path.read_text(encoding="utf-8-sig")
        except UnicodeDecodeError:
            continue
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(body):
                errors.append(f"Possible {label} in {relative}")


def validate_phase_manifest(errors: list[str]) -> None:
    phases = {
        "Phase 5": ROOT / "phases/05-security-governance",
        "Phase 6": ROOT / "phases/06-streaming-resilience",
    }
    for label, phase_root in phases.items():
        manifest_path = phase_root / "MANIFEST.sha256"
        if not manifest_path.exists():
            errors.append(f"Missing {label} SHA-256 manifest")
            continue
        for line_number, raw_line in enumerate(
            manifest_path.read_text(encoding="utf-8-sig").splitlines(), start=1
        ):
            match = re.fullmatch(r"([0-9a-f]{64})  (.+)", raw_line)
            if not match:
                errors.append(f"Invalid {label} manifest line {line_number}")
                continue
            expected_hash, relative_path = match.groups()
            artifact_path = phase_root / relative_path
            if not artifact_path.is_file():
                errors.append(f"{label} manifest target missing: {relative_path}")
                continue
            actual_hash = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
            if actual_hash != expected_hash:
                errors.append(f"{label} manifest hash mismatch: {relative_path}")


def main() -> int:
    errors: list[str] = []
    files = repository_files()
    validate_json(files, errors)
    validate_markdown_links(files, errors)
    validate_inventory(files, errors)
    validate_security_and_size(files, errors)
    validate_phase_manifest(errors)

    if errors:
        print("Repository validation FAILED")
        for error in errors:
            print(f"- {error}")
        return 1

    print(f"Repository validation PASS ({len(files)} files checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
