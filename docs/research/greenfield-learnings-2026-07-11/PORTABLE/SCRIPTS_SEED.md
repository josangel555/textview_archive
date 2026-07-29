# SCRIPTS_SEED — self-contained build/sign/test-infra recipes

Closes GAPS.md §5a / §5. This file stands alone: copy it out of this repo and
you can re-create the six scripts' protections from scratch, with no other
file in `docs/research/greenfield-learnings-2026-07-11/` required. Each
section names the source script it was extracted from (in the ORIGINAL repo,
`markdown_viewer`, path given for provenance only — not required to exist for
you to use this) plus: purpose, the load-bearing logic verbatim, the incident
it guards against, and adaptation notes for a from-scratch repo.

Stack this was built for: Swift app + Rust staticlib core linked via FFI/
cbindgen, SwiftPM build, local self-signed dev cert + optional Developer-ID
notarization path, XCTest-based test suite with headless/heavy tier split, a
remote macOS VM (UTM) used as the GUI/live-render test lane. If your stack
differs, the PATTERNS still generalize (see each "Adaptation" note) even where
literal paths/tool names don't.

---

## 1. xattr-safe TMPDIR staging + swap (code-signing)

**Purpose:** produce a codesign-clean app bundle when the repo lives inside an
iCloud/Dropbox/OneDrive-synced directory tree.

**Incident it guards against:** when the repo sits under a synced folder
(e.g. `~/Documents`), the OS file-provider daemon re-stamps
`com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#P` extended attributes
onto files in **real time**, racing `codesign --options runtime` (which
**refuses** to sign a bundle carrying any xattr detritus). Signing in place
produces an intermittent, hard-to-repro `"resource fork ... not allowed"`
failure — intermittent because it depends on whether the sync daemon touches
the tree between your `xattr -cr` cleanup and the `codesign` call. `xattr -cr`
alone does **not** remove `com.apple.FinderInfo` (it's OS-protected); only a
`ditto --noextattr` copy strips it.

**Load-bearing logic** (from `scripts/build-app.sh`):

```bash
SIGN_IDENTITY="MarkdownViewer Local Dev"
# ... (identity probe omitted — see §2 below) ...

if [[ "$HAS_LOCAL_IDENTITY" == "1" ]]; then
  chmod -R u+w "$APP_DIR"
  # Clean + sign in a NON-synced TMPDIR, never a sibling of $APP_DIR. If the repo
  # lives under an iCloud/Dropbox-synced tree (e.g. ~/Documents), the file
  # provider re-stamps com.apple.FinderInfo / com.apple.fileprovider.fpfs#P onto
  # the resource bundles in REAL TIME, racing `codesign --options runtime` (which
  # rejects any detritus) — an intermittent "resource fork ... not allowed"
  # failure on an unchanged tree. /private/tmp is not file-provider-synced, so the
  # cleaned tree stays clean through the sign.
  SIGN_TMP="$(mktemp -d "${TMPDIR:-/private/tmp}/mdv-sign.XXXXXX")"
  SIGN_STAGE="$SIGN_TMP/$(basename "$APP_DIR")"
  ditto --norsrc --noextattr --noacl --noqtn "$APP_DIR" "$SIGN_STAGE"
  xattr -cr "$SIGN_STAGE" 2>/dev/null || true

  codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp=none \
    "$SIGN_STAGE" >/dev/null

  # Swap the signed, clean bundle back into place. dist/ may be re-stamped by the
  # file provider afterward, but xattrs added AFTER signing neither invalidate the
  # signature nor block launch — only codesign-time --options runtime rejects them.
  rm -rf "$APP_DIR"
  ditto "$SIGN_STAGE" "$APP_DIR"
  rm -rf "$SIGN_TMP"
fi
```

Key details that matter if you re-derive this yourself:

- `ditto --norsrc --noextattr --noacl --noqtn` — the four flags together are
  what actually produces an xattr-free copy; `cp -R` does not.
- The staging dir MUST be under `/private/tmp` (or any location the OS's
  file-provider sync daemon doesn't watch) — a sibling directory under the
  synced tree re-inherits the race.
- The swap-back (`rm -rf` + `ditto`) happens **after** signing succeeds, so a
  signing failure leaves the original unsigned bundle untouched for triage.
- xattrs re-added to the bundle **after** signing don't invalidate the
  signature — only xattrs present **at sign time** are rejected. So don't
  bother re-cleaning post-swap.

**Adaptation:** this pattern applies to any macOS project whose repo can live
under a synced folder. If your new repo's dev machine never syncs `~`, this
whole block degrades to a no-op risk (you can sign in place) — but it's cheap
insurance to keep even then, since you don't control where every future
contributor's checkout lives. Non-macOS build targets: n/a (this is a
`codesign`-specific problem).

---

## 2. Local self-signed identity probe (before every sign attempt)

**Purpose:** detect whether a local, persistent code-signing identity exists
(vs. falling back to ad-hoc signing), because TCC (privacy) permission grants
are tied to the **signing identity's code-directory hash** — ad-hoc signs
produce a new hash every build, so ad-hoc-signed apps re-prompt for every TCC
permission (files/folders, screen recording, etc.) on every rebuild.

**Load-bearing logic:**

```bash
SIGN_IDENTITY="MarkdownViewer Local Dev"
# Probe with codesign on a throwaway binary — find-identity's policy
# filter is too strict for self-signed certs even when codesign accepts
# them. The probe writes a Mach-O magic header so codesign attempts a
# real sign rather than refusing on file format alone.
SIGN_PROBE="$(mktemp -t mdv-sign-probe.XXXXXX)"
printf '\xcf\xfa\xed\xfe' > "$SIGN_PROBE"
if codesign --force --sign "$SIGN_IDENTITY" --identifier test "$SIGN_PROBE" 2>/dev/null; then
  rm -f "$SIGN_PROBE"
  HAS_LOCAL_IDENTITY=1
else
  rm -f "$SIGN_PROBE"
  HAS_LOCAL_IDENTITY=0
fi
```

`\xcf\xfa\xed\xfe` is the little-endian 64-bit Mach-O magic number
(`MH_MAGIC_64`) — writing just that 4-byte header is enough for `codesign` to
attempt a real signing pass rather than bailing on "not a valid Mach-O file."

**Companion — one-time local identity creation** (no separate `setup-signing.sh` file
exists in this corpus — the recipe is this paragraph): create a self-signed cert named
e.g. `"<AppName> Local Dev"` via Keychain Access or `security create-selfsigned-...`,
trust it for code signing. This is distinct from a Developer ID cert (§4) — it's purely a
local-dev-loop optimization to stabilize TCC grants across rebuilds.

**Adaptation:** if your rebuild loop doesn't grant privacy-sensitive
permissions (no filesystem/camera/mic/screen access), skip this entirely and
always ad-hoc sign — you lose nothing.

---

## 3. Inside-out signing order (Developer ID / notarization path)

**Purpose:** correctly sign a bundle containing nested Mach-O binaries
(dylibs, helper tools) for notarization, which requires each nested binary
be individually signed, hardened, and timestamped — a single `--deep` pass
(fine for local dev, see §1) is **wrong** for notarization because it
propagates the outer bundle's entitlements onto every nested binary.

**Incident it guards against:** stamping the app's entitlements file onto
every inner dylib is a notarization rejection reason (over-broad
entitlements on libraries with no business needing them). It also risks
every nested Mach-O sharing the outer bundle's exact signing identifier
instead of a unique per-file one, which stricter library-validation /
notarization checks reject.

**Load-bearing logic** (from `scripts/sign-and-notarize.sh`):

```bash
# Sign inside-out: each inner Mach-O first, then the bundle.
# `--options runtime` enables hardened runtime (REQUIRED for notarization).
# `--timestamp` requests a secure timestamp from Apple (REQUIRED).
#
# Two rules this block enforces:
#   1. Entitlements belong ONLY on the main app's signature, not on every
#      nested dylib. Stamping the entitlements file onto each inner Mach-O
#      grants those libraries entitlements they have no business carrying
#      and is a notarization red flag.
#   2. No `|| true` / `2>/dev/null` swallowing — a failed inner signature
#      under `set -e` MUST abort the run before we upload anything.
# Each inner dylib gets a unique identifier derived from its basename so
# we never ship N libraries sharing the app's identifier.

# 3a. Sign every Frameworks/*.dylib with a derived identifier:
for dylib in "$APP_DIR/Contents/Frameworks"/*.dylib; do
  dybase="$(basename "$dylib" .dylib)"
  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID.$dybase" \
    --options runtime \
    --timestamp \
    "$dylib"
done

# 3b. Sign SwiftPM/embedded resource bundles:
for resbundle in "$APP_DIR/Contents/Resources"/*.bundle; do
  codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    "$resbundle"
done

# 3c. Catch-all for any other nested Mach-O not enumerated above (helper
# tools, embedded frameworks) — still no error-swallowing:
MAIN_EXEC="$APP_DIR/Contents/MacOS/<ExecName>"
while IFS= read -r -d '' f; do
  [[ "$f" == "$MAIN_EXEC" ]] && continue
  case "$f" in
    "$APP_DIR"/Contents/Frameworks/*.dylib) continue ;;
    "$APP_DIR"/Contents/Resources/*.bundle/*) continue ;;
  esac
  if file "$f" | grep -q Mach-O; then
    codesign --force \
      --sign "$SIGN_IDENTITY" \
      --identifier "$BUNDLE_ID.$(basename "$f")" \
      --options runtime \
      --timestamp \
      "$f"
  fi
done < <(find "$APP_DIR" -type f -print0)

# 3d. LAST: sign the outer .app — entitlements applied ONLY here, no --deep:
codesign --force \
  --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP_DIR"

# 3e. Gate before upload:
codesign --verify --deep --strict --verbose=2 "$APP_DIR" \
  || die "codesign --verify --deep --strict failed; not submitting"
```

**Pre-submit fast-fail (SIGN-14 class):** a locally-signed dev build uses
`--timestamp=none` (§1) — reusing that path here would produce a bundle
notarytool silently rejects only **after** a multi-minute upload+poll. Check
the secure timestamp is actually present, locally, before submitting:

```bash
codesign -dvv "$APP_DIR" 2>&1 | grep -q 'Timestamp=' \
  || die "main bundle signature has no secure Timestamp= (was it signed with --timestamp=none?); aborting before notary upload"
```

**Adaptation:** the enumerate-then-sign-outer-last pattern generalizes to any
bundle format with nested loadable code (Electron with native modules,
.NET/.app hybrids, etc.) — the underlying rule ("sign leaves before roots;
entitlements only at the root; never swallow a nested-sign failure") is
codesign-specific but the *order-of-operations* principle (innermost-first,
verify-before-upload, fail loud on any nested failure) applies to any
multi-artifact signing pipeline (e.g. Windows Authenticode on a multi-DLL
package, or Android APK signing with embedded native libs).

---

## 4. Dual size caps (total bundle + main-executable sub-cap)

**Purpose:** catch bundle bloat AND, specifically, a **silent regression**
from dynamic-loaded/lazy modules back to static-linked-into-the-executable —
a regression class the total-size cap alone can't distinguish from
legitimate Frameworks/ growth.

**Incident it guards against:** a bundle can grow because you *correctly*
added a new dylib/plugin into `Contents/Frameworks/` (healthy — total goes
up, exec stays flat) OR because some new code path accidentally
static-linked a large dependency straight into the main executable (unhealthy
— exec balloons). A single total-size cap cannot tell these apart; only a
**separate cap on the executable alone** catches the second case.

**Load-bearing logic** (from `scripts/check-bundle-size.sh`):

```bash
BUDGET_MB="${BUDGET_MB:-${1:-80}}"      # total .app budget
EXEC_BUDGET_MB="${EXEC_BUDGET_MB:-65}"  # main-executable sub-budget
BUDGET_BYTES=$(( BUDGET_MB * 1024 * 1024 ))
EXEC_BUDGET_BYTES=$(( EXEC_BUDGET_MB * 1024 * 1024 ))

# `du -sk` reports KB on macOS. Convert to bytes.
SIZE_KB=$(/usr/bin/du -sk "$APP_DIR" | awk '{print $1}')
SIZE_BYTES=$(( SIZE_KB * 1024 ))

# Main executable — grab the largest/only file directly under Contents/MacOS/.
EXEC_PATH=$(/usr/bin/find "$APP_DIR/Contents/MacOS" -type f -depth 1 2>/dev/null | head -1 || true)
EXEC_BYTES=0
if [[ -n "$EXEC_PATH" ]]; then
  EXEC_BYTES=$(/usr/bin/stat -f%z "$EXEC_PATH" 2>/dev/null || echo 0)
fi

FAIL=0
if (( SIZE_BYTES > BUDGET_BYTES )); then FAIL=1; fi   # total cap
if (( EXEC_BUDGET_MB > 0 )) && (( EXEC_BYTES > 0 )) && (( EXEC_BYTES > EXEC_BUDGET_BYTES )); then
  FAIL=1   # exec sub-cap — catches the static-link regression specifically
fi
(( FAIL == 1 )) && exit 2
```

- Enforced from the outer build script **only on release builds** (debug
  binaries carry unstripped symbols + reflection metadata and run ~3× the
  release size — the cap targets the *shippable* artifact only).
- Caps are living numbers, not fixed forever — bump them deliberately (with a
  measured before/after in the commit message) when a legitimate feature
  lands; a red gate after an *unintentional* size jump is the signal you
  regressed static-linking, not a signal to reflexively raise the cap.
- Escape hatch for local iteration: `EXEC_BUDGET_MB=0` disables the sub-cap
  entirely (documented, not silently possible).

**Adaptation:** requires a platform where "large loadable modules" vs "the
main binary" are genuinely two different files on disk (macOS .app bundles,
Windows apps with a main EXE + DLLs, Linux AppImage-with-plugins). For a
single-binary-only distribution (e.g. a static Go/Rust CLI), collapse to one
cap — but if you ever add plugin/lazy-load infrastructure, split the cap
immediately rather than retrofitting after a silent regression ships.

---

## 5. ABI-skew / content-hash header staleness guard (cross-language FFI)

**Purpose:** the single highest-value pattern in this file. When a build
system (here: SwiftPM) links a native library whose C header is
**auto-generated by a separate toolchain build** (here: `cbindgen` from
Rust), the build system usually does **not** track that header as a tracked
build input — so a header-only ABI change (new field, re-laid-out struct)
does not trigger recompilation of dependents, and STALE compiled objects link
against a NEW ABI. This does not fail loudly; it segfaults, and the segfault
looks exactly like an unrelated FFI/unwinding bug.

**Incident it guards against (documented, hit twice):** a re-laid-out
`enum`/struct on the Rust side changed field order/size; Swift objects
compiled against the OLD header linked against the NEW `.a` at runtime. One
specific bite: a **pure-Swift** `throw SomeError.panic` (code that never
touches Rust at that call site) segfaulted, because the *type layout itself*
had shifted underneath already-compiled Swift object files elsewhere in the
same module graph — nothing about the crash pointed at "stale header," which
is exactly why this needs an automated, un-skippable guard rather than "be
careful."

**Load-bearing logic** — content-hash comparison (NOT mtime — content
identity is what actually matters) plus staged, tiered "touch to force
recompile":

```bash
# restage_core_header NEW_HEADER CMOD_HEADER ROOT_DIR [STATICLIB_CHANGED]
#
# Detect whether NEW_HEADER differs from the currently-staged CMOD_HEADER (the
# copy the build system imports); overwrite CMOD_HEADER only when it changed,
# then run the staleness touches:
#   * Touch the FFI *bridge* sources — always, when the .a OR header changed —
#     so the build system relinks the bridge module + downstream against the
#     fresh .a. (The .a itself is NOT a tracked build input to most build
#     systems, so this touch is the ONLY way an .a-only change reaches a
#     relink.)
#   * WHEN THE HEADER ITSELF CHANGED (not just the .a), widen the touch to:
#       - every TEST target that could hold stale-ABI compiled objects, AND
#       - every source file (anywhere in the tree, Sources + Tests) that
#         references the header's exported surface (grep for a stable marker
#         like an exported constant prefix or `import <CHeaderModule>`).
#     This is deliberately CONDITIONAL — an unchanged header should NOT pay
#     the wide-touch cost on every no-op build.
restage_core_header() {
  local new_header="$1" cmod_header="$2" root_dir="$3" staticlib_changed="${4:-1}"
  local changed=1
  if cmp -s "$new_header" "$cmod_header" 2>/dev/null; then
    changed=0
  fi
  if [[ "$changed" == "1" ]]; then
    cp "$new_header" "$cmod_header"
  fi

  # Relink the bridge sources when EITHER the .a or the header changed.
  if [[ "$changed" == "1" || "$staticlib_changed" == "1" ]]; then
    find "$root_dir/Sources/RustCore" -name '*.swift' -exec touch {} + 2>/dev/null || true
  fi

  if [[ "$changed" == "1" ]]; then
    echo "==> header CHANGED — touching header-referencing targets"
    find "$root_dir/Tests/RustCoreTests" -name '*.swift' -exec touch {} + 2>/dev/null || true
    grep -rl --include='*.swift' -E "MDV_CAP_|MDV_WIRE_VERSION|import CMdvCore" \
        "$root_dir/Sources" "$root_dir/Tests" 2>/dev/null | while read -r f; do
      touch "$f"
    done
  fi
  return 0
}
```

**Companion guard — detect when the build silently skipped the LINK edge
entirely** (a *second*, subtler failure mode than the header-staleness one
above: even after the header is correctly restaged and bridge sources
touched, some build systems recompile touched sources to
**byte-identical objects** and then, because the prebuilt static-library
file itself is not a tracked link input, **skip the executable relink
altogether** — silently shipping the OLD native code while reporting
success):

```bash
# TOOTH: never bundle an executable older than the staged native staticlib.
# The staged `.a`'s mtime only moves on CONTENT change (the cmp-gate above),
# so `.a` newer than the built executable means the build system skipped the
# relink. Hard fail — the deletion-forces-relink step (below) should make
# this unreachable; this guard catches any path around it.
STAGED_A="$ROOT_DIR/rust-core/link/libmdvcore_ffi.a"
if [[ -f "$STAGED_A" && "$STAGED_A" -nt "$BIN_PATH" ]]; then
  echo "Error: STALE LINK — $STAGED_A is newer than the built executable." >&2
  exit 1
fi
```

And the actual fix that makes that guard nearly never fire — when the
staticlib's **content** changed (not just re-copied with the same bytes),
delete the build system's cached link products outright so it is FORCED to
relink, because "touch the bridge sources" alone recompiles-to-identical and
still gets skipped:

```bash
STATICLIB_CHANGED=1
if [[ -f "$LINK_DIR/libmdvcore_ffi.a" ]] && cmp -s "$STATICLIB" "$LINK_DIR/libmdvcore_ffi.a"; then
  STATICLIB_CHANGED=0
else
  cp "$STATICLIB" "$LINK_DIR/libmdvcore_ffi.a"
fi

if [[ "$STATICLIB_CHANGED" == "1" ]]; then
  echo "==> staticlib CHANGED — deleting build-system link products to force relink"
  rm -f "$ROOT_DIR"/.build/debug/<ExecName> \
        "$ROOT_DIR"/.build/release/<ExecName> \
        "$ROOT_DIR"/.build/*/debug/<ExecName> \
        "$ROOT_DIR"/.build/*/release/<ExecName> 2>/dev/null || true
  find "$ROOT_DIR/.build" -maxdepth 3 -name '*.xctest' -prune -exec rm -rf {} + 2>/dev/null || true
fi
```

**Why content-hash (`cmp`), not mtime:** an unconditional `cp` re-stamps the
mtime on every run even when bytes are unchanged, which would force a full
downstream relink/recompile on every single no-op build (measured cost: tens
of seconds per gate run, paid for nothing). Comparing content first and only
touching/copying on an actual diff is what makes the guard cheap enough to
run unconditionally on every build.

**Adaptation — this is the general pattern, strip the Swift/Rust specifics:**

1. Any FFI/cross-language boundary where one toolchain generates a header/IDL
   file consumed by another toolchain's build system needs this if the
   consuming build system doesn't natively track that generated file as an
   input (most don't, by default — CMake, SwiftPM, Cargo build.rs consumers,
   Bazel-without-explicit-hdrs-deps, etc. all have variants of this gap).
2. Two independent failure modes, both need guarding:
   - Header changed but dependents weren't recompiled → **stale ABI in
     compiled objects** (fix: content-diff the header, touch/invalidate
     dependents on change).
   - Everything recompiled correctly but the FINAL LINK step was skipped
     because the linked artifact (the `.a`/`.so`/`.lib`) isn't a tracked
     link input → **stale code in the final binary despite a "successful"
     build** (fix: force-delete cached link products when the artifact's
     content changed; add a final mtime-ordering assertion as a second-line
     tooth).
3. Extract this as a **sourceable function**, not inline script logic, so a
   hermetic host test can exercise it directly over fixture directories
   without needing the actual native toolchain installed — this is what let
   the original repo pin this behavior with a fast, no-cargo-required test.

---

## 6. VM toolchain auto-select + GUI-session sudo bridge + ulimit raise

**Purpose:** run the real (non-headless) UI/live-app test tiers on a remote
disposable macOS VM, because those tiers need a real WindowServer/Aqua login
session that a CI runner or `ssh`-only session doesn't have, and because you
want the primary dev host to never spawn windows/steal focus during routine
test runs.

### 6a. Toolchain auto-select (avoid a stale-default-compiler trap)

**Incident it guards against:** the VM's OS-bundled compiler toolchain can be
older/stricter or looser than what the project actually needs (here: the
VM's *default* `swift` was 6.1.2, but the test target required 6.3's relaxed
region-isolation checking — `try await super.setUp()` in a main-actor test
class failed to compile as "sending non-Sendable self" under 6.1.2). A
newer toolchain was *installed* on the VM but not selected by default.

```bash
# Pick the NEWEST installed toolchain and export the env var that makes every
# subsequent compiler invocation use it. No-op if only the bundled default is
# present (e.g. a clean CI host).
select_toolchain() {
  local newest tcid
  # `|| true`: a no-match glob makes `ls` fail → under `set -euo pipefail` the
  # assignment would abort the whole script (NOT the no-op the comment
  # promises) without this swallow.
  newest=$(ls -d /Library/Developer/Toolchains/swift-6.*-RELEASE.xctoolchain 2>/dev/null \
             | sort -V | tail -1 || true)
  [[ -n "$newest" && -f "$newest/Info.plist" ]] || return 0
  tcid=$(plutil -extract CFBundleIdentifier raw "$newest/Info.plist" 2>/dev/null) || return 0
  [[ -n "$tcid" ]] || return 0
  export TOOLCHAINS="$tcid"
  log "toolchain: $(basename "$newest") ($tcid)"
}
```

**Companion — mixed-toolchain build-cache poisoning guard:** a shared
incremental-build cache directory built once with toolchain A and then
resumed with toolchain B produces "module compiled with Swift X cannot be
imported" errors buried deep in a build log, far from the actual cause. Stamp
the selected toolchain into a marker file inside the build cache and fail
loud, up front, on a mismatch instead:

```bash
check_toolchain_marker() {
  local marker=".build/.mdv-toolchain"
  local current="${TOOLCHAINS:-xcode-default}"
  if [[ -d .build/arm64-apple-macosx && -f "$marker" ]]; then
    local prev; prev=$(cat "$marker")
    if [[ "$prev" != "$current" ]]; then
      echo "ERROR: .build was last built with toolchain '$prev' but this run selects '$current'." >&2
      echo "       Mixed-toolchain modules break the test compile." >&2
      echo "       Remediate: bash scripts/test-in-vm.sh clean" >&2
      exit 2
    fi
  fi
  mkdir -p .build
  printf '%s' "$current" > "$marker"
}
```

### 6b. GUI-session sudo bridge (spawn tests inside a real login session over SSH)

**Incident it guards against:** driving `swift test` (or any UI-test runner)
over a plain `ssh` session runs it in a **background/headless** security
context — windows it opens are occluded/non-composited, so pixel-level
assertions on real rendering come back false (blank/black captures), even
though the same test passes when run from an actual Terminal.app session at
the console.

**Load-bearing logic** — hop into the console user's real Aqua session via
`launchctl asuser`, forwarding environment explicitly (the bridge drops the
caller's env by default) and never hardcoding the sudo secret:

```bash
swift_test() {
  if [[ "${MDV_VM_GUI_SESSION:-0}" != "1" ]]; then
    swift test "$@"      # plain path unchanged for the headless case
    return $?
  fi
  local uid; uid=$(stat -f %u /dev/console)
  local inner="cd $(printf '%q' "$ROOT_DIR") && { ulimit -n 16384 2>/dev/null || ulimit -n 8192 2>/dev/null || ulimit -n 4096 2>/dev/null || true; }"
  [[ -n "${TOOLCHAINS:-}" ]] && inner+=" && export TOOLCHAINS=$(printf '%q' "$TOOLCHAINS")"
  # Re-forward every project-prefixed env var explicitly — `launchctl asuser`
  # drops the caller's environment entirely, so without this the spawned
  # session loses every test-config knob. NEVER forward the sudo secret itself.
  local v
  for v in $(compgen -v | grep '^MDV_' || true); do
    [[ "$v" == "MDV_VM_SUDO_PASS" || "$v" == "MDV_VM_SUDO_PASSWORD" ]] && continue
    inner+=" && export $v=$(printf '%q' "${!v}")"
  done
  inner+=" && exec swift test"
  local a; for a in "$@"; do inner+=" $(printf '%q' "$a")"; done
  printf '%s\n' "${MDV_VM_SUDO_PASS:?MDV_VM_GUI_SESSION=1 needs MDV_VM_SUDO_PASS}" \
    | sudo -S launchctl asuser "$uid" /bin/bash -lc "$inner"
  local rc=$?
  # The asuser bridge runs the build/test AS ROOT, which leaves root-owned
  # files in the shared incremental-build cache — the VERY NEXT non-root build
  # then dies on a permissions error. Restore ownership unconditionally,
  # best-effort, WITHOUT masking the real test exit code.
  printf '%s\n' "$MDV_VM_SUDO_PASS" \
    | sudo -S chown -R "$uid" "$ROOT_DIR/.build" 2>/dev/null || true
  return $rc
}
```

Notes:
- `stat -f %u /dev/console` gets the UID of whoever is logged into the
  physical console — that's the identity `launchctl asuser` targets.
- `printf '%q'` quoting on every forwarded value and every positional arg is
  load-bearing — this is a nested shell invocation built as a single string,
  and unquoted values with spaces/special chars silently corrupt the inner
  command.
- The password is piped via stdin to `sudo -S`, never placed on the command
  line (would leak into `ps`/shell history) and never baked into the script.
- Self-heal root-owned build-cache residue BEFORE the next run too (belt and
  suspenders) — same `find … -not -user "$(whoami)"` + conditional chown
  pattern the original script runs at the top of both its `clean` and `test`
  modes.

### 6c. Open-file-descriptor ulimit raise (fd exhaustion false-failures)

**Incident it guards against:** a single long-running test-runner process
that accumulates many small leaks (file watchers, LSP/PTY/plugin pipes, one
fd per spawned helper process for GUI-tier tests) will, over a large test
suite (thousands of tests / dozens of spawned helper processes), exceed the
**default SSH-session soft limit** (macOS default: 256, absurdly low for
this) long before hitting the actual hard limit — producing a cascade of
`EMFILE`/"too many open files" failures that look like unrelated file-IO
bugs in whichever tests happen to run last, even though the code under test
is fine (the same tests pass in isolation).

```bash
# Raise before ANY test invocation. Hard limit is typically `unlimited`
# already; only the soft default is low. Best-effort — never abort the run
# if a platform refuses the raise (some sandboxes cap the hard limit too).
ulimit -n 16384 2>/dev/null || ulimit -n 8192 2>/dev/null || ulimit -n 4096 2>/dev/null || true
```

Apply this **twice** if you're using the GUI-session bridge (§6b): once in
the outer SSH shell, and once *again* inside the `launchctl asuser`-spawned
inner shell — `asuser` opens a **fresh** shell with its own low default, the
outer raise does not propagate into it.

**Adaptation:** none of §6 is macOS/Swift-specific in principle —
"auto-select the newest available toolchain + fail loud on cache-poisoning
mismatch," "bridge into a real GUI session for pixel-accurate UI tests over
SSH," and "raise fd limits before a fd-heavy test run" are patterns any CI/VM
test-runner setup for a headed application should carry, regardless of OS —
though the specific mechanism (`launchctl asuser`, `/dev/console`) is
macOS-only; the Linux/Windows equivalent (Xvfb + a display-bound user
session, or a real Windows interactive-desktop session for `SessionAttach`)
solves the same class of problem with different plumbing.

---

## 7. Gate sentinel file + rc marker (tier-enforcement in a test gate)

**Purpose:** the merge/CI gate must run ONLY the fast, headless-safe test
tiers, and must **fail loudly and specifically** if a heavy/UI-spawning test
tier accidentally runs in that context (e.g. because a new test's tier-skip
guard was written wrong, or a test was mis-filed under the wrong base class).
"It happened to skip today" is not a guarantee — this needs an active,
in-process check.

**Load-bearing logic** (from `scripts/test-headless-gate.sh`):

```bash
SENTINEL="${MDV_HEADLESS_GATE_SENTINEL:-${TMPDIR:-/tmp}/mdv-headless-gate-violations.txt}"
export MDV_HEADLESS_GATE_SENTINEL="$SENTINEL"
export MDV_HEADLESS_GATE=1     # tells the app/test harness "this is the gate context"

# Start clean: a stale sentinel from a PREVIOUS run must not fail THIS run.
rm -f "$SENTINEL"

# ... build + swift build --build-tests ...

# Don't let a test failure abort the script before we report the tier verdict —
# we need BOTH signals (test pass/fail AND tier-violation) independently.
set +e
swift test --parallel --scratch-path "$GATE_SCRATCH" --disable-index-store
TEST_RC=$?
set -e

# Tier verdict: an in-process observer (see below) wrote the sentinel iff a
# heavy-tier test ran its body. (No file / empty file == clean.)
GATE_RC=0
if [[ -s "$SENTINEL" ]]; then
  echo "HEADLESS GATE FAILED — heavy-tier test(s) ran in the gate:"
  sed 's/^/  - /' "$SENTINEL"
  GATE_RC=1
else
  log "tier enforcement: OK — no heavy-tier test ran in the gate"
fi

if [[ $TEST_RC -ne 0 ]]; then exit "$TEST_RC"; fi
if [[ $GATE_RC -ne 0 ]]; then exit "$GATE_RC"; fi
```

**The in-process half (conceptual — belongs in your test framework, not the
shell script):** a base test-case class hierarchy where "heavy" tiers (spawn
a real app process, capture real screen pixels) inherit from a common base;
that base's `setUp()`/equivalent checks `MDV_HEADLESS_GATE=1` and, if it
finds itself about to run its body anyway (i.e. its own skip-guard failed to
fire), **appends its own test name to the sentinel file** before either
skipping or proceeding. This makes "tier" a property enforced by the type
system + a runtime check, not a convention every new test author has to
remember. A new heavy test that forgets its skip guard, or gets filed under
the wrong base class, turns the gate red — the failure mode is "we accidentally
tested something," not "we silently didn't."

**Why a sentinel file, not just the test-runner's own exit code:** the
runner's aggregate exit code conflates "a legitimate headless test failed
its assertions" with "a heavy test ran when it shouldn't have" — you need
BOTH signals independently reported (the script above checks them
separately and exits non-zero on either). A background-run wrapper's own
exit code being 0 does NOT mean the gate passed — always read the actual
result marker/sentinel, never trust a wrapper's exit status alone,
especially for anything invoked via a backgrounded/detached process.

**Adaptation:** the pattern — "tag the context you're running in via an env
var; have the heavy-tier base class assert against that tag and self-report
a violation to a sentinel; the driving script checks the sentinel
independently of the test runner's own pass/fail exit code" — is
framework-agnostic (works with pytest markers + a fixture, JUnit categories +
a listener, Go build tags + `TestMain`, etc.). The concrete mechanism
(sentinel file path via env var, `-s` file-non-empty check) is trivially
portable to any language/CI system.

---

## Summary table

| # | Guard | Guards against | Extracted from |
|---|---|---|---|
| 1 | xattr-safe TMPDIR stage+swap | intermittent codesign failure under synced dirs | `build-app.sh` |
| 2 | Local-identity probe (Mach-O magic write) | ad-hoc-sign TCC re-prompt churn | `build-app.sh` |
| 3 | Inside-out signing order | notarization rejection (bad entitlement scope / shared identifiers) | `sign-and-notarize.sh` |
| 4 | Dual size caps (total + exec sub-cap) | silent static-link regression hidden inside overall growth | `check-bundle-size.sh` |
| 5 | Content-hash header/link staleness guard | stale-ABI segfaults + silently-stale-binary "successful" builds | `build-rust-core.sh` + `lib/restage-header.sh` |
| 6a | VM toolchain auto-select + cache-poison marker | stale-default-compiler failures + cross-toolchain cache corruption | `test-in-vm.sh` |
| 6b | GUI-session sudo bridge | occluded/non-composited windows under plain SSH | `test-in-vm.sh` |
| 6c | ulimit raise (pre-test, and again inside the bridge) | fd-exhaustion false test failures | `test-in-vm.sh` |
| 7 | Gate sentinel + explicit rc check | heavy/UI tests silently running in (or silently passing) the merge gate | `test-headless-gate.sh` |
