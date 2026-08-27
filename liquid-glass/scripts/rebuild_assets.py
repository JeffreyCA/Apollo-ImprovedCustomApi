#!/usr/bin/env python3
"""
Rebuild Assets.car from an existing Assets.car.

Strategy:
  1. assetutil -I  → full metadata: maps Name + Appearance → RenditionName
  2. cartool       → extract vector PDFs (preserves original vector format)
  3. act extract   → SVG symbol weight/size variants + PNG fallbacks
  4. Group files by asset Name, preferring PDFs from cartool over act's rasters
  5. For symbol assets: use the correctly-sized SVG variant from act
  6. Compile with actool, including every .icon package registered in icons.json
"""

import copy
import json
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict

# Layout (resolved relative to this script so the rebuild can run from anywhere):
#
#   liquid-glass/
#   ├── icons.json                          (registry: which icons to include)
#   ├── Assets.car                          (user-supplied original — input)
#   ├── icons/<id>/<id>.icon/               (Icon Composer packages)
#   ├── prebuilt/Assets.car                 (rebuilt output destination)
#   └── scripts/
#       ├── rebuild_assets.py               (this file)
#       ├── cartool-extracted/              (intermediate, gitignored)
#       ├── act-extracted/                  (intermediate, gitignored)
#       └── rebuilt/{Assets.xcassets,compiled}/  (intermediate, gitignored)

SCRIPTS_DIR     = os.path.dirname(os.path.abspath(__file__))
LG_DIR          = os.path.abspath(os.path.join(SCRIPTS_DIR, ".."))
REGISTRY_PATH   = os.path.join(LG_DIR, "icons.json")
ICONS_ROOT      = os.path.join(LG_DIR, "icons")
ORIGINAL_CAR    = os.path.join(LG_DIR, "Assets.car")
PREBUILT_CAR    = os.path.join(LG_DIR, "prebuilt", "Assets.car")

CARTOOL_DIR     = os.path.join(SCRIPTS_DIR, "cartool-extracted")
EXTRACTED_DIR   = os.path.join(SCRIPTS_DIR, "act-extracted")
REBUILT_ROOT    = os.path.join(SCRIPTS_DIR, "rebuilt")
XCASSETS_DIR    = os.path.join(REBUILT_ROOT, "Assets.xcassets")
OUTPUT_DIR      = os.path.join(REBUILT_ROOT, "compiled")

ACT             = "/Applications/Asset Catalog Tinkerer.app/Contents/MacOS/act"
CARTOOL         = shutil.which("cartool") or "/usr/local/bin/cartool"

# Appearance string → Contents.json appearances array entry
APPEARANCE_MAP = {
    "UIAppearanceDark":  [{"appearance": "luminosity", "value": "dark"}],
    "UIAppearanceLight": [{"appearance": "luminosity", "value": "light"}],
}

# act names symbol SVGs as: {name}_{weight}_{size}_automatic.svg  (weight may be camelCase)
SYMBOL_SVG_RE = re.compile(
    r'^(.+)_(ultralight|thin|light|regular|medium|semibold|bold|heavy|black)'
    r'_(small|medium|large)_automatic\.svg$',
    re.IGNORECASE,
)

# act names raster PNGs as: {rendition-stem}_Normal[@2x|@3x][_N].png
# We only care about the base scale files (no numbered suffix = appearance 0 / universal-any)
RASTER_PNG_RE = re.compile(r'^(.+)_Normal(@2x|@3x)?\.png$')

RENDERING_INTENTS  = {}      # asset name -> original/template/automatic
TEMPLATE_ASSETS    = set()   # asset names that need template-rendering-intent
SYMBOL_ASSETS      = set()   # asset names that have SVG glyph variants
VECTOR_PRESERVED   = set()   # asset names whose original rasters carry Preserved Vector Representation

PREVIEW_VARIANTS  = ["default", "dark", "clear-light", "clear-dark"]
STATIC_ICON_DIR   = os.path.join(REBUILT_ROOT, "static-icon-variants")
STATIC_ICON_MODES = {
    "__apollo_light": "light",
    "__apollo_dark": "dark",
}


# ---------------------------------------------------------------------------
# Step 1 – load metadata from original Assets.car
# ---------------------------------------------------------------------------

def load_metadata():
    """
    Returns:
      rendition_to_assets: dict[rendition_stem -> list[(asset_name, appearance_str_or_None)]]
      rendering_intents:   dict of asset names to template-rendering-intent values
      symbol_assets:       set of asset names that have Glyph Size entries (SF Symbol-style)
    """
    global RENDERING_INTENTS, TEMPLATE_ASSETS, SYMBOL_ASSETS, VECTOR_PRESERVED

    print(f"Reading metadata from {ORIGINAL_CAR}...")
    result = subprocess.run(
        ["assetutil", "-I", ORIGINAL_CAR],
        capture_output=True, text=True, check=True,
    )
    entries = json.loads(result.stdout)

    rendition_to_assets = defaultdict(list)

    for e in entries:
        if not isinstance(e, dict) or "Name" not in e or "RenditionName" not in e:
            continue

        name         = e["Name"]
        rendition    = e["RenditionName"]               # e.g. "launch-dark-bg.pdf"
        appearance   = e.get("Appearance")              # "UIAppearanceDark" | "UIAppearanceLight" | None
        stem         = os.path.splitext(rendition)[0]   # strip .pdf / .svg

        rendition_to_assets[stem].append((name, appearance))

        template_mode = e.get("Template Mode")
        if template_mode == "template":
            RENDERING_INTENTS[name] = "template"
            TEMPLATE_ASSETS.add(name)
        elif template_mode == "automatic":
            RENDERING_INTENTS.setdefault(name, "automatic")
        elif name not in RENDERING_INTENTS:
            RENDERING_INTENTS[name] = "original"

        if e.get("Glyph Size"):
            SYMBOL_ASSETS.add(name)

        if e.get("Preserved Vector Representation"):
            VECTOR_PRESERVED.add(name)

    print(f"  {len(rendition_to_assets)} unique rendition stems")
    print(f"  {len(TEMPLATE_ASSETS)} template assets, {len(SYMBOL_ASSETS)} symbol assets, "
          f"{len(VECTOR_PRESERVED)} vector-preserved assets")
    return rendition_to_assets


# ---------------------------------------------------------------------------
# Step 2 – extract files with cartool (PDFs) and act (SVGs + PNG fallbacks)
# ---------------------------------------------------------------------------

def run_cartool_extraction():
    if os.path.exists(CARTOOL_DIR):
        shutil.rmtree(CARTOOL_DIR)
    os.makedirs(CARTOOL_DIR)
    print(f"Extracting vectors with cartool...")
    r = subprocess.run(
        [CARTOOL, ORIGINAL_CAR, CARTOOL_DIR],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"✗ cartool failed:\n{r.stderr}")
        return False
    count = sum(len(files) for _, _, files in os.walk(CARTOOL_DIR))
    print(f"  Extracted {count} files into {len(os.listdir(CARTOOL_DIR))} asset directories")
    return True


def run_act_extraction():
    if os.path.exists(EXTRACTED_DIR):
        shutil.rmtree(EXTRACTED_DIR)
    print(f"Extracting symbol SVGs with act...")
    r = subprocess.run(
        [ACT, "-i", ORIGINAL_CAR, "extract", "-o", EXTRACTED_DIR],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"✗ act failed:\n{r.stderr}")
        return False
    print(f"  Extracted {len(os.listdir(EXTRACTED_DIR))} files")
    return True


# ---------------------------------------------------------------------------
# Step 3 – group files by asset name
#   - PDFs from cartool (vector, preferred for non-symbol assets)
#   - SVGs from act (weight/size variants for SF Symbols)
#   - PNGs from act (fallback for assets with no PDF in the catalog)
# ---------------------------------------------------------------------------

def group_by_asset(rendition_to_assets):
    """
    Returns two dicts keyed by asset name:
      symbol_variants: name -> {(weight, size): filepath}   (SVG files from act)
      raster_groups:   name -> [(filepath, scale, appearance_str_or_None)]
                       scale is "1x" for PDFs (vector), "1x"/"2x"/"3x" for PNGs
    """
    symbol_variants = defaultdict(dict)   # name -> {(weight,size): abs_path}
    raster_groups   = defaultdict(list)   # name -> [(path, scale, appearance)]
    pdf_assets      = set()               # asset names covered by a PDF

    # --- A: Collect PDFs from cartool output ---
    # cartool extracts to: {CARTOOL_DIR}/{asset_name}/{rendition-name}.pdf
    # It also writes .pdf.png rasters alongside each PDF — skip those.
    if os.path.isdir(CARTOOL_DIR):
        for dirname in sorted(os.listdir(CARTOOL_DIR)):
            dirpath = os.path.join(CARTOOL_DIR, dirname)
            if not os.path.isdir(dirpath):
                continue
            for fname in sorted(os.listdir(dirpath)):
                if not fname.endswith(".pdf") or fname.endswith(".pdf.png"):
                    continue
                filepath = os.path.join(dirpath, fname)
                stem = fname[:-4]  # strip .pdf
                if stem in rendition_to_assets:
                    for (asset_name, appearance) in rendition_to_assets[stem]:
                        raster_groups[asset_name].append((filepath, "1x", appearance))
                        pdf_assets.add(asset_name)
                else:
                    # Rendition stem == asset name (simple case)
                    raster_groups[dirname].append((filepath, "1x", None))
                    pdf_assets.add(dirname)

    # --- B: Collect SVG symbol variants + PNG fallbacks from act output ---
    for filename in os.listdir(EXTRACTED_DIR):
        filepath = os.path.join(EXTRACTED_DIR, filename)

        # SVG symbol variant (act outputs one file per weight×size combination)
        m = SYMBOL_SVG_RE.match(filename)
        if m:
            rendition_stem = m.group(1)
            weight, size   = m.group(2).lower(), m.group(3).lower()
            if rendition_stem in rendition_to_assets:
                name = rendition_to_assets[rendition_stem][0][0]
            else:
                name = rendition_stem
            symbol_variants[name][(weight, size)] = filepath
            continue

        # Raster PNG — only use if cartool didn't provide a PDF for this asset
        m = RASTER_PNG_RE.match(filename)
        if m:
            rendition_stem = m.group(1)
            scale_suffix   = m.group(2)
            scale = {None: "1x", "@2x": "2x", "@3x": "3x"}[scale_suffix]

            if rendition_stem in rendition_to_assets:
                for (asset_name, appearance) in rendition_to_assets[rendition_stem]:
                    if asset_name not in pdf_assets:
                        raster_groups[asset_name].append((filepath, scale, appearance))
            else:
                if rendition_stem not in pdf_assets:
                    raster_groups[rendition_stem].append((filepath, scale, None))

    return symbol_variants, raster_groups


# ---------------------------------------------------------------------------
# Step 4 – write .xcassets
# ---------------------------------------------------------------------------

def is_template(name):
    return name in TEMPLATE_ASSETS or name in SYMBOL_ASSETS


def rendering_intent(name):
    if is_template(name):
        return "template"
    return RENDERING_INTENTS.get(name, "original")


def write_symbol_imageset(name, variants, xcassets_path):
    imageset_path = os.path.join(xcassets_path, f"{name}.imageset")
    os.makedirs(imageset_path, exist_ok=True)

    # Context menus use medium glyph size; prefer regular weight
    preferred = [
        ("regular", "medium"), ("regular", "large"), ("regular", "small"),
        ("semibold", "medium"), ("semibold", "large"), ("semibold", "small"),
    ]
    key = next((k for k in preferred if k in variants), next(iter(variants)))
    src = variants[key]
    dst_name = os.path.basename(src)
    shutil.copy2(src, os.path.join(imageset_path, dst_name))

    contents = {
        "images": [{"filename": dst_name, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {
            "preserves-vector-representation": True,
            "template-rendering-intent": "template",
        },
    }
    with open(os.path.join(imageset_path, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)


def write_raster_imageset(name, entries, xcassets_path):
    """
    entries: [(filepath, scale, appearance_str_or_None)]
    """
    imageset_path = os.path.join(xcassets_path, f"{name}.imageset")
    os.makedirs(imageset_path, exist_ok=True)

    images = []
    # Use a set to avoid copying the same file twice (same rendition, multiple appearances)
    copied = set()

    for (filepath, scale, appearance) in entries:
        dst_name = os.path.basename(filepath)
        if dst_name not in copied:
            shutil.copy2(filepath, os.path.join(imageset_path, dst_name))
            copied.add(dst_name)

        entry = {"filename": dst_name, "idiom": "universal", "scale": scale}
        if appearance and appearance in APPEARANCE_MAP:
            entry["appearances"] = APPEARANCE_MAP[appearance]
        images.append(entry)

    has_pdf = any(fp.endswith(".pdf") for (fp, _, _) in entries)
    properties = {"template-rendering-intent": rendering_intent(name)}
    # Only preserve vector representation for assets that had it in the original catalog.
    # Applying it broadly (e.g. to launch-icon/launch-bg) causes the launch screen renderer
    # to skip the pre-rasterized bitmaps and attempt PDF rendering, which fails silently.
    if has_pdf and name in VECTOR_PRESERVED:
        properties["preserves-vector-representation"] = True

    contents = {"images": images, "info": {"author": "xcode", "version": 1}, "properties": properties}

    with open(os.path.join(imageset_path, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)


def write_preview_imagesets(xcassets_path):
    """Write one imageset per icon×variant for the in-app icon picker preview.

    Each asset is named `lg-preview-{iconID}-{variant}` so the tweak can load
    it via [UIImage imageNamed:] from the main bundle's Assets.car rather than
    decoding base64 blobs compiled into the tweak binary.

    Preview PNGs live at: liquid-glass/icons/<id>/<variant>.png
    """
    with open(REGISTRY_PATH, "r") as fp:
        registry = json.load(fp)

    count = 0
    missing = []
    for entry in registry.get("icons", []):
        icon_id = entry["id"]
        variants = ["default"] if entry.get("standardPack") else PREVIEW_VARIANTS
        for variant in variants:
            src = os.path.join(ICONS_ROOT, icon_id, f"{variant}.png")
            if not os.path.isfile(src):
                missing.append(src)
                continue
            asset_name = f"lg-preview-{icon_id}-{variant}"
            imageset_path = os.path.join(xcassets_path, f"{asset_name}.imageset")
            os.makedirs(imageset_path, exist_ok=True)
            dst_name = f"{variant}.png"
            shutil.copy2(src, os.path.join(imageset_path, dst_name))
            contents = {
                "images": [{"filename": dst_name, "idiom": "universal", "scale": "2x"}],
                "info": {"author": "xcode", "version": 1},
            }
            with open(os.path.join(imageset_path, "Contents.json"), "w") as f:
                json.dump(contents, f, indent=2)
            count += 1

    if missing:
        print(f"  ⚠ {len(missing)} preview PNGs not found: {missing}")
    print(f"  Added {count} lg-preview imagesets (loadable via [UIImage imageNamed:])")
    return count


def build_xcassets(symbol_variants, raster_groups):
    print(f"Building {XCASSETS_DIR}...")
    if os.path.exists(REBUILT_ROOT):
        shutil.rmtree(REBUILT_ROOT)
    os.makedirs(XCASSETS_DIR, exist_ok=True)
    with open(os.path.join(XCASSETS_DIR, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)

    count = 0
    for name, variants in symbol_variants.items():
        write_symbol_imageset(name, variants, XCASSETS_DIR)
        count += 1

    for name, entries in raster_groups.items():
        if name not in symbol_variants:
            write_raster_imageset(name, entries, XCASSETS_DIR)
            count += 1

    sym = len(symbol_variants)
    pdf_count = sum(
        1 for name, entries in raster_groups.items()
        if name not in symbol_variants and any(fp.endswith(".pdf") for (fp, _, _) in entries)
    )
    png_count = count - sym - pdf_count
    print(f"  Created {count} imagesets ({sym} symbol SVG, {pdf_count} vector PDF, {png_count} raster PNG)")

    write_preview_imagesets(XCASSETS_DIR)
    return count


# ---------------------------------------------------------------------------
# Step 5 – compile
# ---------------------------------------------------------------------------

def _pin_specializations(entries, mode, root_fill=False):
    """Write the selected appearance into both Default and Dark slots.

    A value placed only in the appearance-neutral slot can still be
    auto-adjusted by Icon Composer when actool renders the Dark rendition.
    Conversely, a Dark-only value falls back to the original Default value in
    a Light environment. Emitting the selected value in both slots prevents
    either fallback while retaining the source icon's Tinted specialization.
    """
    defaults = [entry for entry in entries
                if isinstance(entry, dict) and "appearance" not in entry]
    darks = [entry for entry in entries
             if isinstance(entry, dict) and entry.get("appearance") == "dark"]
    tinted = [copy.deepcopy(entry) for entry in entries
              if isinstance(entry, dict) and entry.get("appearance") == "tinted"]
    other = [copy.deepcopy(entry) for entry in entries if (
        not isinstance(entry, dict)
        or entry.get("appearance") not in (None, "dark", "tinted")
    )]
    selected = defaults if mode == "light" else (darks or defaults)

    pinned = []
    for entry in selected:
        neutral = copy.deepcopy(entry)
        neutral.pop("appearance", None)
        # Root-level ``automatic`` is the normal automatic Dark background,
        # which resolves to Icon Composer's system-dark gradient. Naming that
        # result directly also makes it stable in a Light environment.
        if root_fill and mode == "dark" and neutral.get("value") == "automatic":
            neutral["value"] = "system-dark"
        dark = copy.deepcopy(neutral)
        dark["appearance"] = "dark"
        pinned.extend([neutral, dark])
    pinned.extend(tinted)
    pinned.extend(other)
    return pinned


def _pin_icon_appearance(value, mode, path=()):
    if isinstance(value, dict):
        for key in list(value):
            child = value[key]
            if key.endswith("-specializations") and isinstance(child, list):
                pinned = _pin_specializations(
                    child,
                    mode,
                    root_fill=(not path and key == "fill-specializations"),
                )
                if pinned:
                    value[key] = pinned
                else:
                    del value[key]
            else:
                _pin_icon_appearance(child, mode, path + (key,))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _pin_icon_appearance(child, mode, path + (str(index),))
    return value


def _is_monochrome_svg(package_path, image_name):
    """Return whether an SVG has one authored paint color.

    Icon Composer lets monochrome artwork in a combined-lighting group inherit
    the icon's root fill. When a static Dark clone replaces that root fill with
    system-dark, materialize the authored fill on those layers first so their
    artwork color remains unchanged. Multicolor SVGs must keep their own fills.
    """
    if not image_name or not image_name.lower().endswith(".svg"):
        return False
    asset_path = os.path.join(package_path, "Assets", image_name)
    try:
        with open(asset_path, encoding="utf-8") as fp:
            source = fp.read()
    except OSError:
        return False

    paints = set()
    patterns = [
        r'(?:fill|stroke|stop-color)\s*:\s*([^;\}\s]+)',
        r'(?:fill|stroke|stop-color)\s*=\s*["\']([^"\']+)["\']',
    ]
    for pattern in patterns:
        for paint in re.findall(pattern, source, flags=re.IGNORECASE):
            paint = paint.strip().lower()
            if paint not in {"none", "transparent"} and not paint.startswith("url("):
                paints.add(paint)
    return len(paints) == 1


def _pin_root_fill(icon, mode, package_path):
    """Specialize Icon Composer's direct root fill without losing inheritance."""
    if "fill" not in icon:
        return
    source_fill = icon.pop("fill")
    if mode == "dark":
        for group in icon.get("groups", []):
            for layer in group.get("layers", []):
                if (group.get("lighting") == "combined"
                        and "fill" not in layer
                        and "fill-specializations" not in layer
                        and _is_monochrome_svg(package_path, layer.get("image-name"))):
                    layer["fill-specializations"] = [
                        {"value": copy.deepcopy(source_fill)},
                        {"appearance": "dark", "value": copy.deepcopy(source_fill)},
                    ]

    selected = copy.deepcopy(source_fill) if mode == "light" else "system-dark"
    icon["fill-specializations"] = [
        {"value": copy.deepcopy(selected)},
        {"appearance": "dark", "value": copy.deepcopy(selected)},
    ]


def _build_static_icon_packages(source_packages):
    """Create build-only Light/Dark clones without editing source .icon files."""
    shutil.rmtree(STATIC_ICON_DIR, ignore_errors=True)
    os.makedirs(STATIC_ICON_DIR, exist_ok=True)
    variants = []
    for source in source_packages:
        icon_id = os.path.splitext(os.path.basename(source))[0]
        for suffix, mode in STATIC_ICON_MODES.items():
            variant_id = icon_id + suffix
            destination = os.path.join(STATIC_ICON_DIR, variant_id + ".icon")
            shutil.copytree(source, destination)
            descriptor = os.path.join(destination, "icon.json")
            with open(descriptor, "r") as fp:
                icon = json.load(fp)
            _pin_root_fill(icon, mode, destination)
            _pin_icon_appearance(icon, mode)
            with open(descriptor, "w") as fp:
                json.dump(icon, fp, indent=2)
                fp.write("\n")
            variants.append(destination)
    return variants


def load_icon_packages():
    """Resolve every `.icon` package listed in icons.json.

    Each entry maps to liquid-glass/icons/<id>/<id>.icon. Missing
    packages are a hard error since the registry is the source of truth.
    """
    with open(REGISTRY_PATH, "r") as fp:
        registry = json.load(fp)

    packages = []
    appearance_packages = []
    for entry in registry.get("icons", []):
        icon_id = entry["id"]
        pkg = os.path.join(ICONS_ROOT, icon_id, f"{icon_id}.icon")
        if not os.path.isdir(pkg):
            print(f"✗ missing .icon package: {pkg}", file=sys.stderr)
            return None
        packages.append(pkg)
        # Standard-pack additions follow the system appearance just like
        # Apollo's built-in Standard icons. Only Liquid Glass group icons get
        # the build-only static Light and Dark choices.
        if entry.get("group") is not None:
            appearance_packages.append(pkg)
    return packages + _build_static_icon_packages(appearance_packages)


def _find_xcode_26_0_1():
    """
    Return (developer_dir, True) if Xcode 26.0.1 can be found, else (None, False).

    Xcode 26.0.1 is required for --enable-icon-stack-fallback-generation=disabled,
    a hidden actool flag that strips ~100 MB of icon-stack fallback data from the
    compiled catalog.  The flag exists only in 26.0.1; later Xcode versions silently
    ignore it and produce a bloated Assets.car.

    Search order:
      1. XCODE_DEVELOPER_DIR env var (explicit override)
      2. /Applications/Xcode_26.0.1.app (canonical install path)
      3. mdfind Spotlight search (handles renamed/non-standard locations)
    """
    override = os.environ.get("XCODE_DEVELOPER_DIR")
    if override:
        if os.path.isdir(override):
            print(f"  Using XCODE_DEVELOPER_DIR override: {override}")
            return override, True
        print(f"  ⚠ XCODE_DEVELOPER_DIR={override!r} does not exist — ignoring")

    candidate = "/Applications/Xcode_26.0.1.app/Contents/Developer"
    if os.path.isdir(candidate):
        return candidate, True

    try:
        r = subprocess.run(
            [
                "mdfind",
                "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"
                " && kMDItemVersion == '26.0.1'",
            ],
            capture_output=True, text=True, timeout=5,
        )
        for line in r.stdout.strip().splitlines():
            dev = os.path.join(line.strip(), "Contents/Developer")
            if os.path.isdir(dev):
                return dev, True
    except Exception:
        pass

    return None, False


def compile_assets():
    print("\nCompiling Assets.car...")
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    icon_packages = load_icon_packages()
    if icon_packages is None:
        return False
    if icon_packages:
        names = [os.path.splitext(os.path.basename(p))[0] for p in icon_packages]
        print(f"  Including {len(icon_packages)} icon packages: {', '.join(names)}")

    xcode_dev_dir, has_26_0_1 = _find_xcode_26_0_1()
    if has_26_0_1:
        print(f"  Xcode 26.0.1 found at: {xcode_dev_dir}")
    else:
        print("  ✗ Xcode 26.0.1 not found.")
        print("    --enable-icon-stack-fallback-generation=disabled requires Xcode 26.0.1's")
        print("    actool specifically; later versions silently ignore the flag and produce a")
        print("    significantly larger catalog with the icon-stack fallback renditions included.")
        print("    Install Xcode 26.0.1 or set XCODE_DEVELOPER_DIR to its Contents/Developer.")
        return False

    env = os.environ.copy()
    env["DEVELOPER_DIR"] = xcode_dev_dir

    cmd = ["xcrun", "actool", XCASSETS_DIR]

    # Add each .icon package as an additional input
    cmd.extend(icon_packages)

    cmd.extend([
        "--compile", OUTPUT_DIR,
        "--platform", "iphoneos",
        "--minimum-deployment-target", "13.0",
        "--output-format", "human-readable-text",
    ])

    # Register every icon as an alternate app icon.
    # --enable-icon-stack-fallback-generation=disabled is a hidden Xcode 26.0.1-only
    # flag; without it actool generates 100+ MB of icon-stack fallback renditions.
    cmd.extend([
        "--include-all-app-icons",
        "--enable-icon-stack-fallback-generation=disabled",
    ])

    # --output-partial-info-plist is required when alternate icons are present
    if icon_packages:
        cmd.extend(["--output-partial-info-plist", os.path.join(OUTPUT_DIR, "partial-info.plist")])

    try:
        print(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, env=env)
        print(result.stdout)
        compiled_car = os.path.join(OUTPUT_DIR, "Assets.car")
        if not os.path.exists(compiled_car):
            print("⚠ Assets.car not found in output")
            return False
        print(f"✓ Assets.car ({os.path.getsize(compiled_car):,} bytes) → {compiled_car}")

        # Copy into prebuilt/ for the patcher to pick up.
        os.makedirs(os.path.dirname(PREBUILT_CAR), exist_ok=True)
        shutil.copy2(compiled_car, PREBUILT_CAR)
        print(f"✓ Copied to {PREBUILT_CAR}")
        return True
    except subprocess.CalledProcessError as e:
        print(f"✗ actool:\n{e.stderr}")
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("=" * 60)
    print("Assets.car Rebuild")
    print("=" * 60)

    if not os.path.exists(ORIGINAL_CAR):
        print(f"✗ {ORIGINAL_CAR} not found")
        print(f"  Copy a decrypted Apollo Assets.car to {ORIGINAL_CAR} and rerun.")
        return 1

    rendition_to_assets = load_metadata()

    if not run_cartool_extraction():
        return 1

    if not run_act_extraction():
        return 1

    symbol_variants, raster_groups = group_by_asset(rendition_to_assets)
    print(f"  Grouped into {len(symbol_variants)} symbol, {len(raster_groups)} raster assets")

    if build_xcassets(symbol_variants, raster_groups) == 0:
        print("✗ No assets found")
        return 1

    # Verify coverage against original
    original_names = set(rendition_to_assets[s][0][0]
                         for s in rendition_to_assets
                         for _ in rendition_to_assets[s])
    rebuilt_names  = set(
        d.replace(".imageset", "")
        for d in os.listdir(XCASSETS_DIR)
        if d.endswith(".imageset")
    )
    # ZZZZPackedAsset entries are internal actool packing atlases, not real named assets
    missing = {n for n in original_names - rebuilt_names if not n.startswith("ZZZZPackedAsset")}
    if missing:
        print(f"  ⚠ {len(missing)} assets still missing: {sorted(missing)}")

    if compile_assets():
        print("\n" + "=" * 60)
        print("✓ Rebuild complete!")
        print(f"  .xcassets : {XCASSETS_DIR}")
        print(f"  Assets.car: {OUTPUT_DIR}/Assets.car")
        print(f"  Installed : {PREBUILT_CAR}")
        print("=" * 60)
        return 0
    return 1


if __name__ == "__main__":
    exit(main())
