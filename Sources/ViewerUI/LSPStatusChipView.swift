import SwiftUI
import ViewerCore

/// Status-bar chip surfacing the language server state for the focused file
/// (TSK-1444). Fixes the "LSP degrades silently" gap: hover / go-to-def /
/// completion just "do nothing" today when the server never started,
/// crashed, or isn't installed — with no signal. This chip reads
/// `LSPStatusChip.classify` (pure, host-tested) over `pool.snapshot()` +
/// registry-derived binary availability, and offers a click-through popover
/// listing every language server's availability plus a **Restart** action.
///
/// Its own view (not inlined into `StatusBar`) so the ~3s poll tick
/// re-bodies only this chip, never the whole footer (narrow-observation
/// invariant; ChromeBodyEvalCountTests). Hidden entirely when the focused
/// file has no LSP-eligible extension.
struct LSPStatusChipView: View {
    let pool: LSPPool
    let currentURL: URL?
    let fontSize: CGFloat

    @StateObject private var vm: LSPStatusChipModel
    @State private var showPopover = false

    init(pool: LSPPool, currentURL: URL?, fontSize: CGFloat) {
        self.pool = pool
        self.currentURL = currentURL
        self.fontSize = fontSize
        _vm = StateObject(wrappedValue: LSPStatusChipModel(pool: pool))
    }

    var body: some View {
        content
            // Anchor the async work on the ALWAYS-PRESENT `content` (the
            // else-branch renders a zero-size Color.clear, never EmptyView),
            // so the poll loop fires even before the first refresh populates
            // `chip` — a `.task` on a conditionally-empty Group never fires
            // (LESSONS). Re-runs when the focused file changes.
            .task(id: currentURL) { await vm.run(url: currentURL) }
    }

    @ViewBuilder
    private var content: some View {
        if let chip = vm.chip {
            Button { showPopover.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: chip.symbolName)
                        .font(.system(size: fontSize))
                    Text(chip.label)
                        .font(.system(size: fontSize, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(Self.color(for: chip.tint))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(chip.accessibilityDescription)
            .accessibilityIdentifier("mdv.statusBar.lsp")
            .accessibilityLabel(chip.accessibilityDescription)
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                LSPStatusPopover(pool: pool, chip: chip, onRestart: {
                    Task { await vm.restart(language: chip.language) }
                })
            }
        } else {
            // Always-present zero-size anchor: keeps `content` non-empty so
            // the `.task` above fires even while `chip == nil`.
            Color.clear.frame(width: 0, height: 0)
        }
    }

    static func color(for tint: LSPStatusChip.Tint) -> Color {
        switch tint {
        case .ok:      return .green
        case .neutral: return .secondary
        case .error:   return .red
        case .warning: return .orange
        }
    }
}

/// Poll model for the LSP status chip. `@MainActor` for the published state;
/// the pool `snapshot()` (actor hop) and the binary-availability probe
/// (shells out — must stay off-main) are awaited off the main actor.
@MainActor
final class LSPStatusChipModel: ObservableObject {
    @Published private(set) var chip: LSPStatusChip?

    private let pool: LSPPool
    /// Session cache of per-language binary availability. Availability
    /// rarely changes within a run; a fresh probe on every poll would shell
    /// out needlessly. Cleared for a language on Restart so an install done
    /// mid-session is re-detected.
    private var availabilityCache: [LSPLanguage: Bool] = [:]

    init(pool: LSPPool) { self.pool = pool }

    /// Entry point wired to `.task(id: currentURL)`: refresh immediately for
    /// the new file, then poll until the task is cancelled (file change /
    /// view teardown). Structured so cancellation ends the loop cleanly.
    func run(url: URL?) async {
        await refresh(url: url)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { break }
            await refresh(url: url)
        }
    }

    func restart(language: LSPLanguage) async {
        await pool.restart(language: language)
        // A user-driven restart is the moment to re-probe availability (they
        // may have just installed the server) and reflect the fresh state.
        availabilityCache[language] = nil
        await refresh(url: lastURL)
    }

    private var lastURL: URL?

    private func refresh(url: URL?) async {
        lastURL = url

        // UAT / test override: a forced state for deterministic scene capture.
        if let forced = ProcessInfo.processInfo.environment["MDV_LSP_STATUS_FAKE"],
           let fake = LSPStatusChip.fake(fromEnvValue: forced) {
            assign(fake)
            return
        }

        guard let url,
              let language = pool.registry.language(for: url)?.language else {
            assign(nil)
            return
        }

        let available = await binaryAvailable(language)
        let snapshot = await pool.snapshot()
        // Root-precision matching is skipped (nil): a single window with two
        // roots serving the SAME language is rare, and `bestMatch` falls back
        // to live>dead>any, which is correct for the common single-root case.
        let next = LSPStatusChip.classify(
            language: language,
            workspaceRoot: nil,
            binaryAvailable: available,
            snapshot: snapshot)
        assign(next)
    }

    /// Change-detection guard: only republish when the chip actually changed,
    /// so the ~3s poll doesn't re-body the chip (and its StatusBar host)
    /// every tick when nothing moved.
    private func assign(_ next: LSPStatusChip?) {
        if next != chip { chip = next }
    }

    private func binaryAvailable(_ language: LSPLanguage) async -> Bool {
        if let cached = availabilityCache[language] { return cached }
        // `discoverServerBinary` probes PATH / toolchain (shells out) — run
        // it off the main actor.
        let available = await Task.detached {
            LSPLanguageRegistry.discoverServerBinary(for: language) != nil
        }.value
        availabilityCache[language] = available
        return available
    }
}

/// Click-through popover behind the LSP chip: the focused file's server
/// state up top, every supported language's availability below (U4), and a
/// Restart action (U3). `languageStatuses()` shells out, so it loads in a
/// `.task` off the body path.
private struct LSPStatusPopover: View {
    let pool: LSPPool
    let chip: LSPStatusChip
    let onRestart: () -> Void

    @State private var statuses: [LSPLanguageRegistry.LanguageStatus] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Current file's server — the headline state.
            HStack(spacing: 6) {
                Image(systemName: chip.symbolName)
                    .foregroundStyle(LSPStatusChipView.color(for: chip.tint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(chip.language.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(stateHeadline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Restart", action: onRestart)
                    .controlSize(.small)
                    .help("Shut down and respawn the \(chip.language.shortName) server")
                    .accessibilityIdentifier("mdv.lsp.restart")
            }
            if let detail = chip.detail, chip.state == .notInstalled {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.12)))
            }

            Divider()

            Text("Language servers")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(statuses, id: \.language) { s in
                HStack(spacing: 6) {
                    Image(systemName: s.available ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(s.available ? Color.green : Color.orange)
                        .font(.system(size: 10))
                    Text(s.language.shortName)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 54, alignment: .leading)
                    Text(s.available ? (s.resolvedPath ?? "available") : "not installed")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !loaded {
                Text("Probing…").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 340)
        .accessibilityIdentifier("mdv.lsp.popover")
        .task {
            // Off-main: `languageStatuses()`'s default resolver shells out.
            let result = await Task.detached { LSPLanguageRegistry.languageStatuses() }.value
            statuses = result
            loaded = true
        }
    }

    private var stateHeadline: String {
        switch chip.state {
        case .running:      return "Running" + (chip.detail.map { " · \($0)" } ?? "")
        case .idle:         return "Ready (not started)"
        case .failed:       return "Failed" + (chip.detail.map { " · \($0)" } ?? "")
        case .notInstalled: return "Not installed"
        }
    }
}
