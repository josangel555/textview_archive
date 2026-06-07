# VM visual-UI test lane (programmatic, Aqua-session)

Makes real-pixel SwiftUI visual validation run **in the VM/CI**, not just on the
host — the foundational unblock for autonomous UI work (TSK-492). Validation is
**programmatic** (a dense-saturated-block pixel eval with a PASS/FAIL exit code),
not a human eyeballing screenshots.

## The problem it solves

SwiftUI's *real composited* pixels are only readable through the WindowServer
(`screencapture -l<windowID>`); `cacheDisplay` / `CALayer.render` return black
for SwiftUI content, so there's no offscreen shortcut. And the WindowServer only
hands real pixels to a process in the **Aqua** GUI session. Over SSH,
`launchctl managername` == `Background`; via `launchctl asuser` the window is
**redacted to blank** on macOS 15. So the capture must run from a **LaunchAgent**
(which lives in `gui/<uid>` = Aqua).

## Pieces

- `aqua-runner.sh` — runs inside Aqua (launched by the agent): launches
  `dist/TextView.app` with `MDV_UI_SCENE`, captures the window, runs the pixel
  eval, writes `<scene>.result` + `<scene>.png` + a `done` sentinel.
- `com.markdownviewer.uitest.plist.template` — the LaunchAgent (`RunAtLoad`
  false; kickstarted on demand). `__HOME__` substituted at install.
- `../vm-uitest.sh` — host orchestrator: `setup` / `run <scene>` / `teardown`.

## One-time owner setup (authorization required)

`setup` installs + bootstraps a LaunchAgent on the shared VM (a persistence
change) and the first `run` needs a **Screen Recording** TCC grant on the VM GUI
— both are owner actions an autonomous agent can't self-authorize:

```
bash scripts/vm-uitest.sh setup
# build dist on the VM (scripts/test-in-vm.sh / build-app), then:
bash scripts/vm-uitest.sh run terminal-paneright
# first run: VM GUI → System Settings → Privacy & Security → Screen Recording →
# enable the agent entry, then re-run.
```

Once granted, `run <scene>` is fully programmatic and CI-able (wire into
`.github/workflows/nightly-vm.yml`). `teardown` removes the agent.
