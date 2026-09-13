#!/usr/bin/env python3
"""Fail CI when a bundled PE binary still imports APIs known to break Windows 7."""
from __future__ import annotations

import sys
from pathlib import Path

import pefile

BLOCKED_IMPORTS = {
    "processprng",
}


def check(path: Path) -> bool:
    print(f"\n[win7-pe] {path}")
    try:
        pe = pefile.PE(str(path), fast_load=False)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: failed to parse PE file {path}: {exc}")
        return False

    imports: list[tuple[str, str]] = []
    for entry in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []):
        dll = entry.dll.decode("ascii", "replace")
        for item in entry.imports:
            if item.name:
                name = item.name.decode("ascii", "replace")
                imports.append((dll, name))

    bad = [(dll, name) for dll, name in imports if name.lower() in BLOCKED_IMPORTS]
    print(
        "[win7-pe] subsystem version "
        f"{pe.OPTIONAL_HEADER.MajorSubsystemVersion}."
        f"{pe.OPTIONAL_HEADER.MinorSubsystemVersion}"
    )
    print(f"[win7-pe] imported DLL count: {len({dll.lower() for dll, _ in imports})}")

    if bad:
        for dll, name in bad:
            print(f"ERROR: blocked Win7 import: {dll}!{name}")
        return False

    print("[win7-pe] no blocked ProcessPrng import found")
    return True


def collect_targets(arg_path: Path) -> list[Path]:
    if arg_path.is_file():
        return [arg_path]
    if arg_path.is_dir():
        targets: list[Path] = []
        for file in arg_path.rglob("*"):
            if file.is_file() and file.suffix.lower() in (".exe", ".dll"):
                targets.append(file)
        return sorted(targets)
    return []


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check-win7-pe.py <exe-or-dll-or-directory> [...]", file=sys.stderr)
        return 2

    files_to_check: list[Path] = []
    for arg in sys.argv[1:]:
        arg_path = Path(arg)
        if not arg_path.exists():
            print(f"ERROR: path does not exist: {arg_path}", file=sys.stderr)
            return 1
        targets = collect_targets(arg_path)
        if not targets:
            print(f"WARNING: no PE files (.exe/.dll) found in: {arg_path}")
        files_to_check.extend(targets)

    if not files_to_check:
        print("ERROR: no PE binaries were provided for inspection", file=sys.stderr)
        return 1

    print(f"[win7-pe] scanning {len(files_to_check)} binaries...")
    ok = True
    checked_count = 0
    for file_path in files_to_check:
        try:
            passed = check(file_path)
            if not passed:
                ok = False
            checked_count += 1
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR: failed to inspect {file_path}: {exc}", file=sys.stderr)
            ok = False

    print(f"\n[win7-pe] finished inspection: {checked_count} binaries scanned, all passed: {ok}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
