#!/usr/bin/env python3
"""Generate 104×104 PNG preview images for each icon variant using ictool.

For each icon registered in icons.json, finds <id>/<id>.icon and exports
four variants (default, dark, clear-light, clear-dark) via ictool into
icons/<id>/<variant>.png at 104×104 px (@2x for 52pt logical size).

Usage:
    python3 scripts/generate_icon_previews.py [--icons <id1,id2,...>] [--size N]

    --icons  Comma-separated list of icon IDs to (re)generate.
             Omit to regenerate all icons in icons.json.
    --size   Output size in logical points for both width and height
             (default: 104).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys


def find_ictool() -> str:
    """Locate ictool without depending on one maintainer's Xcode path."""
    candidates = ["/Applications/Icon Composer.app/Contents/Executables/ictool"]

    # Prefer the standalone composer, including side-by-side versioned apps.
    for app in sorted(glob.glob("/Applications/Icon Composer*.app"), reverse=True):
        candidates.append(os.path.join(app, "Contents", "Executables", "ictool"))

    # Respect DEVELOPER_DIR and the active xcode-select toolchain.
    developer_dirs = [os.environ.get("DEVELOPER_DIR", "")]
    result = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True)
    if result.returncode == 0:
        developer_dirs.append(result.stdout.strip())
    for developer_dir in developer_dirs:
        if developer_dir:
            candidates.append(os.path.normpath(os.path.join(
                developer_dir, "..", "Applications", "Icon Composer.app",
                "Contents", "Executables", "ictool",
            )))

    # Cover side-by-side stable and beta Xcodes.
    for app in sorted(glob.glob("/Applications/Xcode*.app")):
        candidates.append(os.path.join(
            app, "Contents", "Applications", "Icon Composer.app",
            "Contents", "Executables", "ictool",
        ))

    # Some toolchains expose the composer through xcrun. Keep this last: Xcode
    # 27 also ships an unrelated Asset Catalog ictool with incompatible flags.
    result = subprocess.run(["xcrun", "--find", "ictool"], capture_output=True, text=True)
    if result.returncode == 0 and result.stdout.strip():
        candidates.append(result.stdout.strip())

    for path in dict.fromkeys(candidates):
        if os.path.isfile(path):
            return path
    return candidates[0]


ICTOOL = find_ictool()

# Maps preview filename stem → ictool rendition name
VARIANTS: dict[str, str] = {
    "default":     "Default",
    "dark":        "Dark",
    "clear-light": "ClearLight",
    "clear-dark":  "ClearDark",
}

# 52pt tile displayed at @2x → 104px; declared as @2x so UIKit sees exactly 52pt logical,
# no scaling on @2x devices and a clean 1.5× on @3x.
PREVIEW_SIZE  = 104
PREVIEW_SCALE = 1


def export_variant(icon_file: str, rendition: str, out_path: str, size: int) -> bool:
    legacy_cmd = [
        ICTOOL, icon_file,
        "--export-image",
        "--output-file", out_path,
        "--platform", "iOS",
        "--rendition", rendition,
        "--width",  str(size),
        "--height", str(size),
        "--scale",  str(PREVIEW_SCALE),
    ]
    result = subprocess.run(legacy_cmd, capture_output=True, text=True)
    if result.returncode != 0:
        # Icon Composer 27 replaced the named --export-image options with a
        # positional --export-preview interface. Try it for any legacy-command
        # failure: different releases report the unsupported option through
        # either stdout or stderr and use different wording.
        modern_cmd = [
            ICTOOL, icon_file, "--export-preview", "iOS", rendition,
            str(size), str(size), str(PREVIEW_SCALE), out_path,
        ]
        result = subprocess.run(modern_cmd, capture_output=True, text=True)
    if result.returncode != 0 or not os.path.isfile(out_path):
        print(f"  ERROR: ictool failed for rendition={rendition}", file=sys.stderr)
        if result.stderr.strip():
            print(f"  stderr: {result.stderr.strip()}", file=sys.stderr)
        return False

    # ictool may export 16-bit (rgba64be) PNGs; normalise to 8-bit so file
    # sizes are consistent with the other icons.
    convert = subprocess.run(
        ["magick", out_path, "-depth", "8", out_path],
        capture_output=True, text=True,
    )
    if convert.returncode != 0:
        print(f"  WARNING: magick depth conversion failed for {out_path}", file=sys.stderr)
        if convert.stderr.strip():
            print(f"  stderr: {convert.stderr.strip()}", file=sys.stderr)

    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--icons", help="Comma-separated icon IDs to regenerate")
    parser.add_argument("--size", type=int, default=PREVIEW_SIZE,
                        help=f"Output pixel size for both width and height (default: {PREVIEW_SIZE}, declared @2x = 52pt logical)")
    args = parser.parse_args()

    size = args.size

    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    lg_dir = os.path.abspath(os.path.join(scripts_dir, ".."))

    if not os.path.isfile(ICTOOL):
        print(f"ictool not found at:\n  {ICTOOL}", file=sys.stderr)
        return 1

    registry_path = os.path.join(lg_dir, "icons.json")
    with open(registry_path) as fp:
        registry = json.load(fp)

    entries_by_id = {entry["id"]: entry for entry in registry["icons"]}
    all_ids = list(entries_by_id)
    if args.icons:
        selected = [s.strip() for s in args.icons.split(",")]
        unknown = [i for i in selected if i not in all_ids]
        if unknown:
            print(f"Unknown icon IDs: {', '.join(unknown)}", file=sys.stderr)
            print(f"Known: {', '.join(all_ids)}", file=sys.stderr)
            return 1
        target_ids = selected
    else:
        target_ids = all_ids

    errors = 0
    for icon_id in target_ids:
        icon_dir  = os.path.join(lg_dir, "icons", icon_id)
        icon_file = os.path.join(icon_dir, f"{icon_id}.icon")

        if not os.path.exists(icon_file):
            print(f"[{icon_id}] SKIP — .icon file not found: {icon_file}", file=sys.stderr)
            errors += 1
            continue

        print(f"[{icon_id}] Exporting from {os.path.basename(icon_file)} ...")
        ok = True
        variants = {"default": VARIANTS["default"]} if entries_by_id[icon_id].get("standardPack") else VARIANTS
        for stem, rendition in variants.items():
            out_path = os.path.join(icon_dir, f"{stem}.png")
            success  = export_variant(icon_file, rendition, out_path, size)
            status   = "OK" if success else "FAIL"
            print(f"  {stem:<12} ({rendition:<12}) → {status}")
            if not success:
                ok = False
                errors += 1

        if ok:
            print(f"  All variants written to {icon_dir}")

    if errors:
        print(f"\n{errors} error(s). Check stderr above.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
