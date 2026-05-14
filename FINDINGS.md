# Investigation: source-view invisible content

Status: **bug isolated, root cause unclear, fix in progress.**

## Symptom

When `TextDisplayView` (NSScrollView + NSTextView + LineNumberRulerView) is
rendered as part of the SwiftUI tree, **only the LineNumberRulerView draws**.
Everything else in the window — TabBar, ModeBar, NSTextView text glyphs,
file-name label, sidebar — is invisible. The window shows white background.

The user has reported this consistently. Confirmed via in-app self-snapshot
(`CGWindowListCreateImage`, no Screen Recording permission needed).

## What renders vs what doesn't

| Element | Status when TextDisplayView present | Notes |
| --- | --- | --- |
| Title bar | ✓ Visible | WindowServer-drawn |
| LineNumberRulerView | ✓ Visible | Traditional NSView `drawHashMarksAndLabels` |
| NSTextView background fill | ✓ Visible (white) | `drawsBackground=true` |
| NSTextView text glyphs | ✗ Invisible | Despite glyphs generated, layoutManager populated |
| TabBar (SwiftUI) | ✗ Invisible | SwiftUI hosting layer empty |
| ModeBar (SwiftUI) | ✗ Invisible | SwiftUI hosting layer empty |
| Sidebar (if visible) | ✗ Invisible | SwiftUI hosting layer empty |

| Scenario | Result |
| --- | --- |
| Launch with no file (empty state) | ✓ Everything renders |
| Launch with `.md`, default rendered mode (WKWebView) | ✓ Everything renders |
| Launch with `.md`, toggled to source | ✗ Only ruler visible |
| Launch with `.xml` (always source) | ✗ Only ruler visible |

## Diagnostic dump confirms

- Window: occlusionState_visible=True, isKey=True, isMain=True
- NSHostingView<ContentView>: 1500x1068, alpha=1, hidden=false
- TabBar's PlatformContainer: 1468x28, but **layer.hasContents=False**
- ModeBar's segmented control host: layer.hasContents=False
- AppKitPlatformViewHost<TextDisplayView>: 1500x1002, layer.hasContents=False
- NSScrollView: 1500x1002, layer.hasContents=False
- NSClipView: 1500x985, layer.hasContents=False
- **NSTextView: 1500x985, layer.hasContents=True ←** but glyphs invisible
- NSTextView.textColor: black sRGB (0,0,0,1), background: white (1,1,1,1), contrast distance 1.73
- NSTextView.numberOfGlyphs: 102 (for 102-char file)
- NSTextView.glyph_boundingRect: (0,0 1475x176) — laid out correctly
- LineNumberRulerView: 40x1002, **layer.hasContents=True** (the only SwiftUI-tree-sibling with contents)

## What's been ruled out

- ❌ Zero-sized views — all sizes match parents
- ❌ Alpha/hidden — all alphaValue=1, isHidden=false
- ❌ Color contrast — text and bg are max-contrast
- ❌ TextKit 2 — switched to explicit TextKit 1 stack, no change
- ❌ `_NSScrollViewContentBackgroundView` (visual effect bg) — set
   `scrollView.drawsBackground=false` to suppress, no change
- ❌ Window occlusion — `tell application activate` confirms occlusion=visible
- ❌ Pre-rasterization race — 5s delays don't help, state is persistent

## Strong leads

1. **The bug propagates upward**: when TextDisplayView appears,
   *every* SwiftUI hosting layer in the window becomes empty
   (TabBar, ModeBar, etc.). Whatever the NSScrollView/NSTextView setup is
   doing, it's breaking the *parent* NSHostingView's compositing.

2. **AppKit drawing paths still work**: LineNumberRulerView (an NSRulerView
   subclass with traditional `drawHashMarksAndLabels`) draws. NSTextView's
   background fill draws. So the window IS receiving display passes. The
   compositor isn't entirely dead.

3. **SwiftUI's bitmap commits go silent**: the SwiftUI-managed layers all
   report `layer.contents == nil`. Something is causing SwiftUI to stop
   committing its rasterized output.

## Next steps to try

- Remove `verticalRulerView` / `rulersVisible=true` → does NSTextView alone draw?
- Try NSTextView without NSScrollView wrapping
- Try a non-text NSView with `wantsLayer=true` and `drawRect` content to see if
  arbitrary subviews are affected, or only NSTextView/NSScrollView
- Compare layer hierarchy of working (.empty) vs broken (.loaded source) state
- Check NSHostingView for any `wantsLayer` or `drawsAsynchronously` config

## Files touched

- `Sources/ViewerUI/DiagnosticDump.swift` — view-tree introspection
- `Sources/MarkdownViewer/main.swift` — `--diagnose` flag + SIGUSR1 handler
- `Sources/ViewerUI/TextDisplayView.swift` — TextKit 1 attempt (no change in symptom)
