#!/usr/bin/env python3
"""Generate AltStore-compatible source JSON files and a release manifest."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


RELEASE_TAG_RE = re.compile(r"^v(?P<apollo>[^_]+)_(?P<tweak>.+)$")
LEGACY_ASSET_RE = re.compile(
    r"^(?:(?P<prefix>NO-EXTENSIONS_GLASS|NO-EXTENSIONS|GLASS)_)?"
    r"Apollo-(?P<apollo>[^_]+)_Apollo-Reborn-(?P<tweak>.+)\.ipa$"
)
# Longest alternatives first so e.g. "GLASSICONS-NOEXTENSIONS" matches as a
# whole instead of "GLASSICONS" with "-NOEXTENSIONS" left dangling.
REBORN_ASSET_RE = re.compile(
    r"^Apollo-Reborn-(?P<tweak>.+?)"
    r"(?:-(?P<suffix>GLASSICONS-NOEXTENSIONS|GLASS-NOEXTENSIONS|GLASSICONS|NOEXTENSIONS|GLASS))?"
    r"\.ipa$"
)
REBORN_SUFFIX_TO_PREFIX = {
    None: "",
    "GLASS": "GLASS",
    "NOEXTENSIONS": "NO-EXTENSIONS",
    "GLASS-NOEXTENSIONS": "NO-EXTENSIONS_GLASS",
    "GLASSICONS": "GLASS-ICONS",
    "GLASSICONS-NOEXTENSIONS": "NO-EXTENSIONS_GLASS-ICONS",
}


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def fetch_releases(repo: str) -> list[dict[str, Any]]:
    api_url = f"https://api.github.com/repos/{repo}/releases"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "Apollo-Reborn-Source-Generator",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = Request(api_url, headers=headers)
    with urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def build_variant_key(prefix: str | None) -> str:
    mapping = {
        None: "standard",
        "GLASS": "glass",
        "NO-EXTENSIONS": "noExtensions",
        "NO-EXTENSIONS_GLASS": "noExtensionsGlass",
        "GLASS-ICONS": "glassIcons",
        "NO-EXTENSIONS_GLASS-ICONS": "noExtensionsGlassIcons",
    }
    return mapping[prefix]


def load_existing_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"apps": [{}], "news": []}
    return json.loads(path.read_text(encoding="utf-8"))


def markdown_to_plain_text(markdown: str) -> str:
    text = markdown.strip()
    if not text:
        return ""

    # AltStore/Feather version history renders descriptions as plain text, so
    # remove the most visible Markdown syntax while keeping the curated wording.
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"__([^_]+)__", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", text)
    text = re.sub(r"^#{2,6}\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^\s{2,}[-*]\s+", "  - ", text, flags=re.MULTILINE)
    text = re.sub(r"^\s*[-*]\s+", "- ", text, flags=re.MULTILINE)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def format_release_notes(body: str, variant_name: str | None = None) -> str:
    text = markdown_to_plain_text(body)
    if variant_name:
        return f"{variant_name}\n\n{text}" if text else variant_name
    return text


def parse_release_tag(tag: str) -> tuple[str, str] | None:
    match = RELEASE_TAG_RE.match(tag)
    if not match:
        return None
    return match.group("apollo"), match.group("tweak")


def find_matching_asset(release: dict[str, Any], prefix: str | None) -> dict[str, Any] | None:
    wanted = prefix or ""
    for asset in release.get("assets", []):
        name = asset.get("name", "")
        reborn_match = REBORN_ASSET_RE.match(name)
        if reborn_match and REBORN_SUFFIX_TO_PREFIX[reborn_match.group("suffix")] == wanted:
            return asset

        legacy_match = LEGACY_ASSET_RE.match(name)
        if legacy_match and (legacy_match.group("prefix") or "") == wanted:
            return asset
    return None


def build_version_entry(
    release: dict[str, Any],
    prefix: str | None,
    variant_name: str | None,
    build_version: str | None,
) -> dict[str, Any] | None:
    parsed = parse_release_tag(release.get("tag_name", ""))
    if not parsed:
        return None

    asset = find_matching_asset(release, prefix)
    if not asset:
        return None

    apollo_version, tweak_version = parsed
    return {
        # AltStore's VerifyAppOperation rejects an install when `version` does
        # not equal the IPA's CFBundleShortVersionString, and (when present)
        # when `buildVersion` does not equal its CFBundleVersion. The release
        # pipeline rewrites those fields to the tweak version and the source
        # config's monotonic build number, so the source must mirror that exact
        # pair.
        "version": tweak_version,
        "buildVersion": build_version,
        "marketingVersion": tweak_version,
        "date": release.get("published_at"),
        "localizedDescription": format_release_notes(release.get("body", ""), variant_name),
        "downloadURL": asset.get("browser_download_url"),
        "size": asset.get("size"),
    }


def build_variant_manifest_entry(
    release: dict[str, Any],
    variant: dict[str, Any],
    config: dict[str, Any],
) -> dict[str, Any] | None:
    asset = find_matching_asset(release, variant["prefix"])
    if not asset:
        return None

    output_name = variant["output"]
    source_url = f"{config['distribution']['sourceBaseURL'].rstrip('/')}/{output_name}"
    return {
        "label": variant["app"]["subtitle"],
        "sourceURL": source_url,
        "directDownloadURL": asset.get("browser_download_url"),
        "assetName": asset.get("name"),
        "size": asset.get("size"),
    }


def find_latest_release_with_variants(
    releases: list[dict[str, Any]],
    variants: list[dict[str, Any]],
) -> dict[str, Any] | None:
    sorted_releases = sorted(releases, key=lambda item: item.get("published_at") or "", reverse=True)
    for release in sorted_releases:
        if all(find_matching_asset(release, variant["prefix"]) for variant in variants):
            return release
    return None


def find_deb_asset(release: dict[str, Any], suffix: str) -> dict[str, Any] | None:
    for asset in release.get("assets", []):
        if asset.get("name", "").endswith(suffix):
            return asset
    return None


def write_release_manifest(
    output_path: Path,
    releases: list[dict[str, Any]],
    config: dict[str, Any],
) -> None:
    latest_release = find_latest_release_with_variants(releases, config["variants"])
    if latest_release is None:
        manifest = {
            "updatedAt": None,
            "release": None,
            "variants": {},
            "packages": {},
        }
        output_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return

    parsed = parse_release_tag(latest_release.get("tag_name", ""))
    apollo_version, tweak_version = parsed if parsed else ("Unknown", "Unknown")

    variants: dict[str, Any] = {}
    for variant in config["variants"]:
        key = build_variant_key(variant["prefix"])
        entry = build_variant_manifest_entry(latest_release, variant, config)
        if entry:
            variants[key] = entry

    rootful_deb = find_deb_asset(latest_release, "_iphoneos-arm.deb")
    rootless_deb = find_deb_asset(latest_release, "_iphoneos-arm64_rootless.deb")

    manifest = {
        "updatedAt": latest_release.get("published_at"),
        "release": {
            "tag": latest_release.get("tag_name"),
            "name": latest_release.get("name"),
            "url": latest_release.get("html_url"),
            "apolloVersion": apollo_version,
            "tweakVersion": tweak_version,
        },
        "variants": variants,
        "packages": {
            "rootful": {
                "downloadURL": rootful_deb.get("browser_download_url") if rootful_deb else None,
                "assetName": rootful_deb.get("name") if rootful_deb else None,
                "size": rootful_deb.get("size") if rootful_deb else None,
            },
            "rootless": {
                "downloadURL": rootless_deb.get("browser_download_url") if rootless_deb else None,
                "assetName": rootless_deb.get("name") if rootless_deb else None,
                "size": rootless_deb.get("size") if rootless_deb else None,
            },
        },
    }
    output_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def validate_generated_sources(root: Path, config: dict[str, Any]) -> None:
    manifest_path = root / config["distribution"]["manifestOutput"]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    release = manifest.get("release")
    if not release:
        raise ValueError("release-manifest.json has no published release")

    tweak_version = release["tweakVersion"]
    build_version = str(config["app"]["buildVersion"])
    variants = manifest.get("variants") or {}
    expected_variant_keys = {build_variant_key(variant["prefix"]) for variant in config["variants"]}
    missing_variant_keys = sorted(expected_variant_keys - set(variants))
    if missing_variant_keys:
        raise ValueError(f"release-manifest.json is missing variants: {', '.join(missing_variant_keys)}")

    for key, entry in variants.items():
        if not entry.get("sourceURL"):
            raise ValueError(f"manifest variant {key} is missing sourceURL")
        if not entry.get("directDownloadURL"):
            raise ValueError(f"manifest variant {key} is missing directDownloadURL")
        if not entry.get("assetName"):
            raise ValueError(f"manifest variant {key} is missing assetName")

    for variant in config["variants"]:
        output_path = root / variant["output"]
        data = json.loads(output_path.read_text(encoding="utf-8"))
        apps = data.get("apps") or []
        if len(apps) != 1:
            raise ValueError(f"{variant['output']} must contain exactly one app")

        app = apps[0]
        if app.get("version") != tweak_version:
            raise ValueError(f"{variant['output']} version {app.get('version')} != {tweak_version}")
        if str(app.get("buildVersion")) != build_version:
            raise ValueError(f"{variant['output']} buildVersion {app.get('buildVersion')} != {build_version}")
        if app.get("marketingVersion") != tweak_version:
            raise ValueError(f"{variant['output']} marketingVersion {app.get('marketingVersion')} != {tweak_version}")
        if not app.get("downloadURL"):
            raise ValueError(f"{variant['output']} is missing downloadURL")
        if data.get("featuredApps") != [config["app"]["bundleIdentifier"]]:
            raise ValueError(f"{variant['output']} has an invalid featuredApps value")

    print(f"Validated generated sources for Apollo-Reborn {tweak_version} build {build_version}")


def build_news_entry(
    release: dict[str, Any],
    config: dict[str, Any],
    variant_name: str | None,
) -> dict[str, Any]:
    parsed = parse_release_tag(release.get("tag_name", ""))
    apollo_version, tweak_version = parsed if parsed else ("Unknown", "Unknown")
    title = f"Apollo v{apollo_version} / Apollo-Reborn v{tweak_version}"
    if variant_name:
        title = f"{title} ({variant_name})"
    return {
        "title": title,
        "identifier": release.get("tag_name"),
        "caption": config["news"]["caption"],
        "date": release.get("published_at"),
        "tintColor": config["source"]["tintColor"],
        "imageURL": config["news"]["imageURL"],
        "url": release.get("html_url"),
    }


def version_entry_key(entry: dict[str, Any]) -> tuple[Any, ...]:
    download_url = entry.get("downloadURL")
    if download_url:
        return ("downloadURL", download_url)
    return (
        "version",
        entry.get("version"),
        entry.get("buildVersion"),
        entry.get("date"),
    )


def merge_version_entries(
    new_entries: list[dict[str, Any]],
    existing_entries: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    merged: dict[tuple[Any, ...], dict[str, Any]] = {}
    for entry in existing_entries:
        merged[version_entry_key(entry)] = entry
    for entry in new_entries:
        merged[version_entry_key(entry)] = entry
    return sorted(
        merged.values(),
        key=lambda item: item.get("date") or "",
        reverse=True,
    )


def update_source_json(
    output_path: Path,
    releases: list[dict[str, Any]],
    config: dict[str, Any],
    variant: dict[str, Any],
) -> None:
    data = load_existing_json(output_path)
    data.update(config["source"])
    data.update(variant["source"])
    # Feature the app on the source's About page. bundleIdentifier is required in
    # config, so we always override any stale featuredApps carried over from a
    # previously generated source file.
    data["featuredApps"] = [config["app"]["bundleIdentifier"]]
    if "apps" not in data or not data["apps"]:
        data["apps"] = [{}]

    app = data["apps"][0]
    app.update(config["app"])
    app.update(variant["app"])

    build_version = config["app"].get("buildVersion")
    versions: list[dict[str, Any]] = []
    news: list[dict[str, Any]] = []
    existing_versions = app.get("versions") or []
    if not isinstance(existing_versions, list):
        existing_versions = []

    sorted_releases = sorted(
        releases,
        key=lambda item: item.get("published_at") or "",
    )

    for release in reversed(sorted_releases):
        entry = build_version_entry(
            release, variant["prefix"], variant.get("notesLabel"), build_version
        )
        if not entry:
            continue
        # The source config only knows the current IPA build number. Generate the
        # newest release entry, then preserve older entries already in the source
        # so their historical buildVersion values remain installable.
        if not versions:
            versions.append(entry)
        news.append(build_news_entry(release, config, variant.get("newsLabel")))

    merged_versions = merge_version_entries(versions, existing_versions)
    app["versions"] = merged_versions
    if merged_versions:
        latest = merged_versions[0]
        app["version"] = latest["version"]
        app["buildVersion"] = latest["buildVersion"]
        app["marketingVersion"] = latest["marketingVersion"]
        app["versionDate"] = latest["date"]
        app["versionDescription"] = latest["localizedDescription"]
        app["downloadURL"] = latest["downloadURL"]
        app["size"] = latest["size"]

    data["news"] = sorted(news, key=lambda item: item.get("date") or "")

    output_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def validate_config(config: dict[str, Any]) -> None:
    required_top_level = {"repo", "distribution", "source", "app", "news", "variants"}
    missing = sorted(required_top_level - set(config))
    if missing:
        raise KeyError(f"missing config keys: {', '.join(missing)}")


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    config_path = root / "distribution" / "config.json"
    config = load_config(config_path)
    validate_config(config)

    try:
        releases = fetch_releases(config["repo"])
    except (HTTPError, URLError) as exc:
        print(f"Error fetching releases: {exc}", file=sys.stderr)
        return 1

    # Only advertise published, stable releases. Draft assets aren't publicly
    # downloadable, and prereleases shouldn't land in the stable sources.
    releases = [
        r for r in releases if not r.get("draft") and not r.get("prerelease")
    ]

    for variant in config["variants"]:
        output_path = root / variant["output"]
        update_source_json(output_path, releases, config, variant)
        print(f"Updated {output_path}")

    manifest_path = root / config["distribution"]["manifestOutput"]
    write_release_manifest(manifest_path, releases, config)
    print(f"Updated {manifest_path}")

    validate_generated_sources(root, config)

    return 0


if __name__ == "__main__":
    sys.exit(main())
