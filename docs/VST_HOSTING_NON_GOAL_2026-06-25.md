# VST Hosting — Non-Goal (decision record)

**Decision (owner, 2026-06-20; recorded per TSK-1097):** Hosting VST / VST3 audio
plug-ins is a **non-goal**. **Audio Unit (AU / AUv3)** is the supported plug-in
format for the app's audio surface.

This file exists so the decision is durable and not re-litigated or silently
revived — exactly the class of scope decision that has vanished from chat history
before.

## Why VST is a non-goal

- **Complexity & maintenance surface.** VST hosting means implementing the
  Steinberg VST3 SDK host side (component model, parameter/bus negotiation, editor
  GUI embedding) — a large, ongoing surface that duplicates capability macOS
  already gives us via AU.
- **SDK & licensing.** The VST3 SDK ships under Steinberg's terms (GPLv3 or a
  proprietary commercial license), which constrain how we distribute. AU carries
  no third-party-SDK licensing burden on macOS.
- **Process model / crash isolation.** Robust plug-in hosting wants
  out-of-process, sandboxed instantiation so a misbehaving plug-in can't take down
  the app. macOS provides this for AU out of the box (the AUv3 app-extension
  model); equivalent isolation for VST would be bespoke and fragile.
- **Platform fit.** AU is the first-class macOS plug-in format — OS-level
  discovery, validation (`auval`), and sandboxing. Targeting AU aligns with the
  platform; VST would be swimming upstream for marginal extra coverage.

## Scope

- **Supported:** Audio Unit (AU / AUv3) hosting (epic TSK-956).
- **Not supported (non-goal):** VST / VST3 hosting.

This is a deliberate scope decision, not a backlog item. It should not be
re-opened casually. If the calculus genuinely changes (e.g. a compelling
cross-platform requirement), reopen with a fresh spike rather than assuming it was
an oversight.

_Refs: TSK-1097 (this decision), TSK-956 (AU hosting epic), CLAUDE.md plugin-format policy._
