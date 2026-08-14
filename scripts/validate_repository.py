from __future__ import annotations

import json
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


def main() -> int:
    errors: list[str] = []
    files = repository_files()
    validate_json(files, errors)
    validate_markdown_links(files, errors)
    validate_inventory(files, errors)
    validate_security_and_size(files, errors)

    if errors:
        print("Repository validation FAILED")
        for error in errors:
            print(f"- {error}")
        return 1

    print(f"Repository validation PASS ({len(files)} files checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

