# Running the test suite inside a UTM VM

The whole suite runs cleanly inside a macOS guest VM. You don't have
to grant any host-side permissions, and the spawned app windows show
up inside the VM so they never steal focus on your real Mac.

## VM image specs

| | Recommended | Minimum |
|---|---|---|
| macOS | 15 (Sequoia) | 14 (Sonoma) |
| CPU | 4 vCPU | 2 vCPU |
| RAM | 8 GB | 4 GB |
| Disk | 60 GB | 40 GB |
| Architecture | Apple Silicon (UTM's "Apple Virtualization" backend) | x86_64 via QEMU also works, slower |

Auto-login the test user so the Aqua session is up the moment the VM
boots — L4/L5 tests spawn the app and need a real WindowServer.

## One-time setup inside the VM

1. Install Xcode Command Line Tools:
   ```
   xcode-select --install
   ```
   That brings in `swift`, `xctest`, `xcodebuild`. ~3 GB. No full
   Xcode needed.

2. Clone or sync the project. Two options:
   - **VirtIO shared folder** (UTM → VM settings → Sharing → Directory
     Share → add the project dir read-write). Mounts at
     `/Volumes/My Shared Files/` inside the VM. Cleanest.
   - `git clone` over the VM's network into `~/dev/markdown_viewer/`.
     Heavier on disk; doesn't reflect host-side edits.

3. **Permissions to grant once** (System Settings → Privacy & Security):
   - **Files and Folders → `MarkdownViewer.app`**: enable `/tmp`. The
     test suite writes fixtures into `/tmp`. Won't need Documents/
     Desktop/Downloads — `DocumentModel.restorePreviousFolderIfAvailable`
     intentionally skips those.
   - **(Optional) Screen Recording → `Terminal.app`** (or whatever
     shell host you use to run the script): only needed if you want
     the L4/L5 PNG snapshots written to `$TMPDIR/mdv-step-NN.png` to
     be non-blank for visual review. Tests pass without it — they
     assert on the JSON dump, not the PNG.
   - **(Optional) Accessibility → `Terminal.app`**: not used by the
     test suite (the script runner drives the model directly), but
     handy if you want to attach with `osascript` for ad-hoc poking.

That's it for permissions. Everything else (Notifications, Contacts,
Camera, etc.) we never touch.

## Running

From inside the VM:

```bash
cd path/to/markdown_viewer
bash scripts/test-in-vm.sh         # full suite, ~75s
```

Other modes:

```bash
bash scripts/test-in-vm.sh smoke   # ~7s — ViewerCore unit tests only
bash scripts/test-in-vm.sh quick   # ~20s — adds L3 in-process tests
bash scripts/test-in-vm.sh build   # build the .app, don't test
bash scripts/test-in-vm.sh test    # test only (must have built first)
```

Output:
- `/tmp/mdv-test-output.txt` — full swift test stdout/stderr
- `/tmp/mdv-test-results.xml` — JUnit XML (CI-consumable)
- `$TMPDIR/mdv-step-NN.json` / `.png` — per-step diagnostic dumps
  from L4/L5 tests (useful for human visual review)

## Expected result

`Executed 359 tests, with 0 failures` on a fresh VM image after the
permissions above. The full run takes about 75 seconds on a 4-vCPU
Apple Silicon VM (most of it is L4/L5 which spawn the .app and run
script flows end-to-end).

If `Files and Folders → /tmp` isn't granted, you'll see a TCC dialog
the first time a test writes a fixture there. Grant it, re-run.

## Why this works without grief on the host Mac

The script runner spawns `MarkdownViewer.app` from a non-foreground
bash. On the host that meant the spawned window was occluded behind
the test runner's terminal — AppKit then suspended drawing (the
"occlusion bug" we documented), so PNG snapshots came back blank
and you'd get random Cmd-Tab-style focus pops as tests ran. In a VM
where the test bash IS the foreground app and nothing else is
competing, the spawned window comes to the front cleanly and PNG
snapshots actually capture the rendered UI.

There's a separate `scripts/run-detached.sh` (Phase 9 prep) if you
want to run tests on the host but isolated from your interactive
session. The VM path is cleaner — strongly recommended.
