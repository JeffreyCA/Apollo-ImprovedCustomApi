#!/usr/bin/env python3
"""Generate LiquidGlassIconPreviews.gen.h from icons.json.

Groups are defined in icons.json under the top-level "groups" key:

  "groups": [
    { "id": "original", "title": "Original",
      "coverIconIDs": ["igerman00", "jryng"], "description": "..." },
    { "id": "helios",   "title": "Helios" }
  ]

Every icon must belong either to one Liquid Glass "group" or to a supported
native-style pack through "standardPack". Standard-pack icons are compiled
into Assets.car and emitted separately for their owning picker, so they never
appear in Liquid Glass pack grids or the Daily Spotlight rotation.
The generator emits one per-group entry array and a kLGIconGroups[]
descriptor table that the picker reads at runtime — no source changes are
needed to add, rename, or reorder groups.

Per-group optional fields:

  "coverIconIDs" — ordered icon IDs to sample for that pack's fan artwork
                    on the main screen. Falls back at runtime to the first
                    few icons in the group if omitted or if none of the
                    listed IDs are registered on a given IPA.
  "description"  — short sentence shown as a header above the pack's icon
                    grid.

Pack-level authors are intentionally unsupported. Credits belong on each icon
through its "designer" field, where they remain visible inside the pack. The
picker selects its daily Featured icons from these generated group entries at
runtime, so Featured choices require no separate registry field.

Preview images are NOT embedded here. They are compiled as named imagesets
into the app's Assets.car by rebuild_assets.py and loaded at runtime via
[UIImage imageNamed:@"lg-preview-{iconID}-{variant}"].
"""
from __future__ import annotations

import json
import os
import re
import sys


def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def c_id(s: str) -> str:
    """Convert an arbitrary string to a valid C identifier fragment."""
    return re.sub(r"[^a-zA-Z0-9_]", "_", s)


def load_registry(lg_dir: str) -> dict:
    path = os.path.join(lg_dir, "icons.json")
    with open(path) as fp:
        registry = json.load(fp)
    if "icons" not in registry or "primaryIconID" not in registry:
        print(f"invalid registry at {path}", file=sys.stderr)
        sys.exit(1)
    return registry


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: generate_previews_header.py <output_header_path>", file=sys.stderr)
        return 2

    out_path = sys.argv[1]
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    lg_dir = os.path.abspath(os.path.join(scripts_dir, ".."))
    registry = load_registry(lg_dir)

    raw_groups = registry.get("groups", [])
    if not raw_groups:
        print('error: icons.json has no "groups"', file=sys.stderr)
        return 1
    for group in raw_groups:
        if "author" in group:
            print(f'error: group "{group.get("id", "(unknown)")}" uses unsupported '
                  'pack-level "author"; credit individual icons with "designer" instead',
                  file=sys.stderr)
            return 1

    # icon_id -> (displayName, designer), used for both Liquid Glass groups
    # and tweak-owned additions to Apollo's native-style packs.
    icon_lookup: dict[str, tuple[str, str]] = {}
    for entry in registry["icons"]:
        icon_lookup[entry["id"]] = (entry.get("displayName", entry["id"]), entry.get("designer", ""))

    # Bucket icons by exactly one placement, preserving registry order.
    buckets: dict[str, list[tuple[str, str, str]]] = {g["id"]: [] for g in raw_groups}
    standard_buckets: dict[str, list[tuple[str, str, str, int]]] = {"ultra": []}
    for entry in registry["icons"]:
        icon_id      = entry["id"]
        display_name, designer = icon_lookup[icon_id]
        group = entry.get("group")
        standard_pack = entry.get("standardPack")
        if (group is None) == (standard_pack is None):
            print(f'error: icon "{icon_id}" must declare exactly one of '
                  '"group" or "standardPack"', file=sys.stderr)
            return 1
        if group is not None:
            if group not in buckets:
                print(f'error: icon "{icon_id}" has invalid "group" {group!r}; '
                      f'must be one of {sorted(buckets)}', file=sys.stderr)
                return 1
            buckets[group].append((icon_id, display_name, designer))
        else:
            if standard_pack not in standard_buckets:
                print(f'error: icon "{icon_id}" has unsupported "standardPack" '
                      f'{standard_pack!r}; must be one of {sorted(standard_buckets)}', file=sys.stderr)
                return 1
            native_anchor_row = entry.get("insertAfterNativeRow", -1)
            if (isinstance(native_anchor_row, bool) or
                    not isinstance(native_anchor_row, int) or native_anchor_row < -1):
                print(f'error: icon "{icon_id}" has invalid "insertAfterNativeRow" '
                      f'{native_anchor_row!r}; must be -1 or a nonnegative integer',
                      file=sys.stderr)
                return 1
            standard_buckets[standard_pack].append(
                (icon_id, display_name, designer, native_anchor_row)
            )

    with open(out_path, "w") as fp:
        fp.write("// Auto-generated by liquid-glass/scripts/generate_previews_header.py.\n")
        fp.write("// Do not edit by hand. Regenerate with `make lg-previews`.\n")
        fp.write("#pragma once\n\n")

        # ── Types ──────────────────────────────────────────────────────────
        fp.write("typedef struct {\n")
        fp.write("    const char *iconID;\n")
        fp.write("    const char *displayName;\n")
        fp.write("    const char *designer;\n")
        fp.write("    int nativeAnchorRow;\n")
        fp.write("} LGIconRowEntry;\n\n")

        fp.write("typedef struct {\n")
        fp.write("    const char          *groupID;\n")
        fp.write("    const char          *title;\n")
        fp.write("    const char          *description;\n")
        fp.write("    const LGIconRowEntry *entries;\n")
        fp.write("    size_t               entryCount;\n")
        fp.write("    const char *const   *coverIconIDs;\n")
        fp.write("    size_t               coverIconIDCount;\n")
        fp.write("} LGIconGroupDef;\n\n")

        # ── Per-group entry arrays ─────────────────────────────────────────
        for g in raw_groups:
            gid     = g["id"]
            entries = buckets[gid]
            fp.write(f"static const LGIconRowEntry kLGGroupEntries_{c_id(gid)}[] = {{\n")
            for icon_id, display_name, designer in entries:
                fp.write(f'    {{ "{escape(icon_id)}", "{escape(display_name)}", '
                         f'"{escape(designer)}", -1 }},\n')
            fp.write("};\n\n")

        # ── Per-group cover-icon-ID arrays (only when non-empty) ───────────
        for g in raw_groups:
            gid       = g["id"]
            cover_ids = g.get("coverIconIDs", [])
            if not cover_ids:
                continue
            fp.write(f"static const char *const kLGGroupCover_{c_id(gid)}[] = {{\n")
            for icon_id in cover_ids:
                fp.write(f'    "{escape(icon_id)}",\n')
            fp.write("};\n\n")

        # ── Group descriptor table ─────────────────────────────────────────
        fp.write("static const LGIconGroupDef kLGIconGroups[] = {\n")
        for g in raw_groups:
            gid         = g["id"]
            title       = g.get("title", gid)
            description = g.get("description", "")
            arr         = f"kLGGroupEntries_{c_id(gid)}"
            n           = len(buckets[gid])
            cover_ids   = g.get("coverIconIDs", [])
            if cover_ids:
                cover_arr  = f"kLGGroupCover_{c_id(gid)}"
                cover_n    = len(cover_ids)
            else:
                cover_arr  = "NULL"
                cover_n    = 0
            fp.write(f'    {{ "{escape(gid)}", "{escape(title)}", "{escape(description)}", '
                     f'{arr}, {n}, {cover_arr}, {cover_n} }},\n')
        fp.write("};\n\n")

        # ── Tweak-owned additions to native-style Standard packs ──────────
        for pack_id, entries in standard_buckets.items():
            array_name = f"kLGStandardPackEntries_{c_id(pack_id)}"
            fp.write(f"static const LGIconRowEntry {array_name}[] = {{\n")
            for icon_id, display_name, designer, native_anchor_row in entries:
                fp.write(f'    {{ "{escape(icon_id)}", "{escape(display_name)}", '
                         f'"{escape(designer)}", {native_anchor_row} }},\n')
            fp.write("};\n")
            fp.write(f"static const size_t {array_name}Count = {len(entries)};\n\n")

        fp.write(f"static const size_t kLGIconGroupCount = {len(raw_groups)};\n\n")

        primary = registry["primaryIconID"]
        fp.write(f'static const char *const kLGPrimaryIconIDCString = "{escape(primary)}";\n')

    total = sum(len(v) for v in buckets.values()) + sum(len(v) for v in standard_buckets.values())
    summary_parts = [f"{len(buckets[g['id']])} {g['id']}" for g in raw_groups]
    summary_parts.extend(f"{len(entries)} standard/{pack_id}"
                         for pack_id, entries in standard_buckets.items() if entries)
    summary = ", ".join(summary_parts)
    print(f"Wrote {len(raw_groups)} groups ({summary}), {total} total → {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
