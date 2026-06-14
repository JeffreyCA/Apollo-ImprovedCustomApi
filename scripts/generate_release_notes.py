#!/usr/bin/env python3
"""Generate GitHub release notes from the changelog."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHANGELOG_PATH = ROOT / "CHANGELOG.md"


def changelog_entry(version: str) -> str | None:
    if not CHANGELOG_PATH.exists():
        return None

    text = CHANGELOG_PATH.read_text(encoding="utf-8")
    heading_re = re.compile(
        rf"^## \[v?{re.escape(version)}\](?:\s+-\s+.+)?\s*$",
        re.MULTILINE,
    )
    match = heading_re.search(text)
    if not match:
        return None

    next_match = re.search(r"^## \[", text[match.end():], re.MULTILINE)
    end = match.end() + next_match.start() if next_match else len(text)
    entry = text[match.end():end].strip()
    return entry or None


def fallback_notes(apollo_version: str, tweak_version: str) -> str:
    return "\n".join(
        [
            f"Apollo version: `v{apollo_version}`",
            f"Apollo-Reborn version: `v{tweak_version}`",
            "",
            "This release includes the standard, No Extensions, GLASS, No Extensions + GLASS, GLASS Icons, and No Extensions + GLASS Icons IPA variants.",
            "",
            "The extension-bearing variants include Apollo-Reborn widgets; No Extensions variants intentionally omit widgets to reduce App ID usage.",
        ]
    )


def main() -> int:
    apollo_version = os.environ.get("APOLLO_VERSION", "").strip()
    tweak_version = os.environ.get("TWEAK_VERSION", "").strip()
    if not apollo_version or not tweak_version:
        print(
            "APOLLO_VERSION and TWEAK_VERSION environment variables are required",
            file=sys.stderr,
        )
        return 2

    print(changelog_entry(tweak_version) or fallback_notes(apollo_version, tweak_version))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
