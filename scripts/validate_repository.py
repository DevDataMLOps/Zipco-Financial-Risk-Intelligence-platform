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
    phase_root = ROOT / "phases/05-security-governance"
    manifest_path = phase_root / "MANIFEST.sha256"
    if not manifest_path.exists():
        errors.append("Missing Phase 5 SHA-256 manifest")
        return
    for line_number, raw_line in enumerate(
        manifest_path.read_text(encoding="utf-8-sig").splitlines(), start=1
    ):
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", raw_line)
        if not match:
            errors.append(f"Invalid Phase 5 manifest line {line_number}")
            continue
        expected_hash, relative_path = match.groups()
        artifact_path = phase_root / relative_path
        if not artifact_path.is_file():
            errors.append(f"Phase 5 manifest target missing: {relative_path}")
            continue
        actual_hash = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
        if actual_hash != expected_hash:
            errors.append(f"Phase 5 manifest hash mismatch: {relative_path}")


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
