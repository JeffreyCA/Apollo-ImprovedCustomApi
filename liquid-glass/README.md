# Liquid Glass

Everything related to the iOS 26 Liquid Glass patch lives here:

```
liquid-glass/
├── Assets.car                 # original Apollo 1.15.11 catalog used to rebuild prebuilt/Assets.car
├── icons.json                 # single source of truth — icons, groups, and primary icon ID
├── icons/<id>/
│   ├── <id>.icon/             # Icon Composer package, input to actool
│   ├── default.png            # in-app picker preview — light mode
│   ├── dark.png               #                          dark mode
│   ├── clear-light.png        #                          clear light
│   └── clear-dark.png         #                          clear dark
├── prebuilt/
│   └── Assets.car             # pre-built asset catalog injected by patch.sh (with all .icon packages and preview PNGs)
├── scripts/
│   ├── rebuild_assets.py      # rebuilds prebuilt/Assets.car from a fresh Apollo Assets.car
│   ├── generate_icon_previews.py  # exports 104×104 PNG previews from .icon packages via ictool
│   └── generate_previews_header.py
└── generated/
    └── LiquidGlassIconPreviews.gen.h   # group descriptor table + icon entries
```

The Liquid Glass runtime patches live in `src/ApolloLiquidGlass.xm` and
`src/ApolloLiquidGlassIconPicker.xm`, alongside the other `src/Apollo*.xm`
modules.

## Adding a new group

Groups (icon packs) are defined in `icons.json` under the top-level `"groups"`
key. Each group renders as a tappable "icon pack" card in the injected section;
tapping one pushes an adaptive grid (2 columns on a phone, more on wider
screens/orientations) of every icon in that group. Each entry has:

- `id` — stable identifier, also used to derive generated C symbol names.
- `title` — shown on the pack card and as the pushed screen's nav title.
- `coverIconIDs` *(optional)* — ordered icon IDs to sample for the pack
  card's fan artwork. Falls back to the first few icons in the group if
  omitted, or if none of the listed IDs are registered on a given IPA.
- `description` *(optional)* — a short sentence shown as a header above the
  pack's icon grid.
- `author` *(optional)* — pack-level curator credit, shown on the pack card
  (distinct from each icon's own per-icon `"designer"`).

Every icon must declare a `"group"` field naming one of these group ids —
there is no default/fallback group, so the generator fails if an
icon's `"group"` is missing or doesn't match a defined group.

**When to add a new group vs. reuse an existing one:** a new group earns its
own pack card when there's a meaningful cluster of icons (roughly 4+) sharing
a theme or designer that would get lost or feel out of place in an existing
group's fan art and description. For one-off icons or small sets, add them to
the existing `"concepts"` group instead of creating a new pack.

## Featuring specific icons

A top-level `"featured"` key lists icon IDs (must already exist in
`"icons"`) to surface as one-tap shortcut rows above the pack list:

```json
"featured": ["jryng", "helios"]
```

Omit the key or leave it empty for no Featured section — this is fully
backward compatible with registries that predate it. A featured ID that
doesn't exist in `"icons"` fails the generator (it's a config typo,
not something to silently drop).

After editing `icons.json`:

```bash
make lg-previews   # regenerates generated/LiquidGlassIconPreviews.gen.h with the new group/featured icons
```

Then rebuild the tweak. Unless you add a new icon, running `rebuild_assets.py`
is not needed — the preview PNGs for existing icons are already in Assets.car.

## Adding a new icon

### Prerequisites

- **Python 3**
- **[Icon Composer](https://developer.apple.com/icon-composer/)** — for designing icons, exporting `.icon` packages, and generating preview images (can also be installed by installing [Xcode 26+](https://developer.apple.com/xcode/))
- **ImageMagick** — for compression (8-bit normalization) in `generate_icon_previews.py` (install with `brew install imagemagick`)

### Steps

1. Design it in **[Icon Composer](https://developer.apple.com/icon-composer/)** and export the `.icon` package.
2. Create the per-icon directory and drop in the package:
   ```
   liquid-glass/icons/<id>/<id>.icon/        # paste the .icon package here
   ```
3. Append the icon to **`liquid-glass/icons.json`** — set `id`, `displayName`, `designer`, and `group` (required, must name one of the ids in `"groups"`). This is the only registration step — the generated header, the icon picker, and `patch.sh` all read from this file.
4. Generate the 104×104 @2x PNG previews from the `.icon` package:
   ```bash
   python3 liquid-glass/scripts/generate_icon_previews.py --icons <id>
   ```
   This exports all four variants (`default`, `dark`, `clear-light`, `clear-dark`) via
   `ictool` (included in Icon Composer) and compresses them to 8-bit depth.
5. Rebuild the asset catalog and regenerate the metadata header (also see next section):
   ```bash
   # Rebuild prebuilt/Assets.car — must run after step 4 because it reads
   # the variant PNGs to embed them as named imagesets for the in-app picker.
   python3 liquid-glass/scripts/rebuild_assets.py

   # Regenerate the group/icon descriptor header (reads icons.json only).
   # From the repo root:
   make lg-previews
   ```
6. Commit the new `.icon` package, preview PNGs, regenerated
   `generated/LiquidGlassIconPreviews.gen.h`, and updated
   `prebuilt/Assets.car`.

## Rebuilding `prebuilt/Assets.car`

The pre-built catalog is what `patch.sh --liquid-glass` injects into the
final IPA. It bundles Apollo's original assets plus the Liquid Glass
`.icon` packages registered above, with their preview PNGs.

`liquid-glass/Assets.car` is checked in and used by default for rebuilds.

### Prerequisites

- **Python 3**
- **Xcode 26.0.1** — required for `actool`'s hidden `--enable-icon-stack-fallback-generation=disabled` flag, which skips generating fallback icon renditions. Newer Xcode versions ignore this flag so they can't be used. The script finds Xcode 26.0.1 automatically (canonical path, Spotlight, or `XCODE_DEVELOPER_DIR` env var override). (download from [Apple Developer](https://developer.apple.com/download/all/?q=Xcode%2026.0.1))
- **[cartool](https://github.com/showxu/cartools)** — must be on your `PATH` ([binary release](https://github.com/showxu/cartools/releases/download/1.0.0-alpha/cartool-1.0.0-alpha.bigsur.bottle.tar.gz))
- **[Asset Catalog Tinkerer](https://github.com/insidegui/AssetCatalogTinkerer)** — installed at `/Applications/Asset Catalog Tinkerer.app`

### Run

```bash
# Rebuild — output goes to liquid-glass/prebuilt/Assets.car
python3 liquid-glass/scripts/rebuild_assets.py
```

If you intentionally need to refresh the source catalog from another Apollo build, extract `Payload/Apollo.app/Assets.car` from a decrypted IPA and replace `liquid-glass/Assets.car` before rebuilding.

The script:

1. Reads metadata from `liquid-glass/Assets.car` via `assetutil -I`.
2. Extracts vector PDFs with `cartool` and symbol SVGs with `act`.
3. Synthesises an `.xcassets` bundle preserving every original asset.
4. Adds the 104×104 preview PNGs from each `icons/<id>/` directory as named
   imagesets (`lg-preview-{id}-{variant}`) so the in-app icon picker can load
   them via `[UIImage imageNamed:]` directly from the catalog.
5. Invokes `actool` with each `.icon` package listed in `icons.json` and
   writes the result to `liquid-glass/prebuilt/Assets.car`.
6. Thins the catalog with `assetutil -i phone -p p3` (drops pad idiom, keeps
   P3 tintable) since sideloaded IPAs bypass App Store thinning.
