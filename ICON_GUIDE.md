# App icon — design + regen guide

## What it is

A six-node hex mesh on a deep-blue squircle. The center is the agent
(bright cream dot with glow); six outer nodes are workers/tools/sub-
agents (white circles with cool-blue halos); thin filaments connect
each outer node to the center, with a faint hexagonal perimeter ring
behind. Variant A from the design (`Downloads/TextView*/app-icon.html`).

Geometry, on a 1024 design canvas:

| Element | Value |
|---|---|
| Canvas | 1024 × 1024 |
| Squircle corner | 22.4% of edge (≈ 229 px) |
| Outer node distance from center | 280 px |
| Outer node radius | 38 px (halo 90 px) |
| Center dot radius | 48 px (glow 220 px) |
| Filament stroke | 7 px, opacity 0.22 |
| Perimeter ring | 3 px, opacity 0.10 |
| Background gradient | 135°: `#3a76b8` → `#1f4d8a` → `#0e2440` |
| Highlight | radial at (28%, 22%), r=55%, white α 0.22 → 0 |
| Center | `#fdf6e3` cream with inner white α 0.6 |

## Source vs artifact

- **Source** — `scripts/render-icon.swift`. Pure Core Graphics; no SVG
  toolchain, no external deps. The design lives as Swift code so it
  can't silently drift from what's committed.
- **Artifact** — `Resources/AppIcon.icns`. Committed binary (≈ 1.9 MB).
  Daily builds copy this into the .app bundle; they do NOT re-render.

## Regenerating after a design tweak

```bash
# 1. Edit the design (geometry, colors, etc.)
$EDITOR scripts/render-icon.swift

# 2. Render PNGs + wrap to .icns
bash scripts/build-icon.sh

# 3. Rebuild + reinstall the .app so it embeds the new icon
bash scripts/build-app.sh && bash scripts/install-app.sh

# 4. Bounce Finder + Dock so the icon-services cache picks up the change
killall Finder Dock
```

`scripts/build-icon.sh` is idempotent and side-effect-free apart from
overwriting `Resources/AppIcon.icns` and `scripts/AppIcon.iconset/`
(the latter is gitignored).

## Why Core Graphics, not SVG → PNG

`rsvg-convert`, ImageMagick, Inkscape, etc. are extra installs the
"minimal deps" rule rules out. Swift + Core Graphics is shipped on
every Mac and produces pixel-perfect output at the exact pixel sizes
`iconutil` needs — no intermediate raster step that bakes in scaling
artifacts.

Tradeoff: design changes require touching Swift code rather than a
visual editor. That's fine for an icon this geometric — every value
in the renderer corresponds to a labeled number above.

## Iconset filename rules (the part that's easy to get wrong)

`iconutil -c icns` expects this exact filename set inside the input
folder; missing any and it returns "Failed to generate ICNS":

| Filename | Actual pixel size |
|---|---|
| `icon_16x16.png` | 16 |
| `icon_16x16@2x.png` | 32 |
| `icon_32x32.png` | 32 |
| `icon_32x32@2x.png` | 64 |
| `icon_128x128.png` | 128 |
| `icon_128x128@2x.png` | 256 |
| `icon_256x256.png` | 256 |
| `icon_256x256@2x.png` | 512 |
| `icon_512x512.png` | 512 |
| `icon_512x512@2x.png` | 1024 |

Some sizes appear twice with different filenames (e.g. 32 px is both
`icon_16x16@2x.png` and `icon_32x32.png`). That's intentional — the
@2x slot is what Retina pulls; the non-@2x slot is what non-Retina
displays pull. They happen to be the same pixels at this size pair.

## Wiring into the bundle

`scripts/Info.plist` declares both keys (both are needed for full
macOS coverage — older macOS uses `CFBundleIconFile`, newer uses
`CFBundleIconName` for asset-catalog lookup; declaring both is safe):

```xml
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
```

`scripts/build-app.sh` copies `Resources/AppIcon.icns` into
`Contents/Resources/AppIcon.icns` of the bundle. The `.icns` filename
must match the value of `CFBundleIconFile`.

## Why Finder / Dock sometimes shows the old icon

macOS aggressively caches app icons. After a rebuild, even with a new
icon embedded:

- **Finder** caches per-bundle-path in `~/Library/Caches/com.apple.iconservices.store`
- **Dock** caches per-app in its own state file

`killall Finder Dock` rebuilds both caches from disk. If that still
doesn't work:

```bash
# Nuclear: drop the system-wide icon services cache
sudo rm -rf /Library/Caches/com.apple.iconservices.store
killall Finder Dock
```

The `.app` itself always has the right icon — it's only Finder's
display that lags.

## How to validate the icon visually without a Mac in front of you

```bash
# Render at any size from the committed .icns
qlmanage -t -s 256 Resources/AppIcon.icns -o /tmp
open /tmp/AppIcon.icns.png
```

Or peek at any individual size in the iconset working dir after
running `bash scripts/build-icon.sh`:

```bash
open scripts/AppIcon.iconset/icon_512x512.png
```

## If you want to swap to a different design

1. Edit (or replace) `scripts/render-icon.swift` — keep the entry
   point signature: `swift render-icon.swift <output-dir>` writing the
   ten PNG filenames listed above.
2. Run `bash scripts/build-icon.sh`. If the swift script fails, the
   error is direct; if `iconutil` fails, it usually means a PNG is
   missing or has the wrong pixel dimensions.
3. Commit the new `.icns` along with the new `.swift`. Future builds
   pick it up automatically.
