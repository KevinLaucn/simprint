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
    pe = pefile.PE(str(path), fast_load=False)
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


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check-win7-pe.py <exe-or-dll> [...]", file=sys.stderr)
        return 2

    ok = True
    for arg in sys.argv[1:]:
        path = Path(arg)
        if not path.is_file():
            print(f"ERROR: file not found: {path}", file=sys.stderr)
            ok = False
            continue
        try:
            ok = check(path) and ok
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR: failed to inspect {path}: {exc}", file=sys.stderr)
            ok = False
        return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
