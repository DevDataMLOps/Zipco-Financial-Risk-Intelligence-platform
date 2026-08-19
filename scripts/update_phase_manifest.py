from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description="Regenerate a phase SHA-256 manifest.")
    parser.add_argument("phase", help="Phase directory relative to the repository root")
    args = parser.parse_args()

    phase_root = (ROOT / args.phase).resolve()
    if ROOT not in phase_root.parents or not phase_root.is_dir():
        parser.error("phase must be an existing directory inside the repository")

    manifest_path = phase_root / "MANIFEST.sha256"
    files = sorted(
        path
        for path in phase_root.rglob("*")
        if path.is_file()
        and path != manifest_path
        and "__pycache__" not in path.parts
    )
    lines = [
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  "
        f"{path.relative_to(phase_root).as_posix()}"
        for path in files
    ]
    manifest_path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"Updated {manifest_path.relative_to(ROOT)} ({len(files)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
