import SwiftUI
import ViewerCore

/// TSK-1496 — the credential warn-badge render slice: a non-modal banner above
/// the editor when the viewed document contains detected secrets. Mirrors the
/// `DiskConflictBanner` placement (SwiftUI sibling composited above the CM6
/// WebView). Behind the `mdv.secretTreatment` setting (default: warn badge).
///
/// The detector (`SecretDetector`, host-tested) hands back REDACTED previews
/// only — this view never renders a secret value. The scan runs off-main keyed
/// on the content, so it re-runs when the document changes and never blocks the
/// UI. The gating/labelling lives in the host-tested `SecretBannerState`.
struct SecretWarningBanner: View {
    let contents: String
    @AppStorage(SecretDetector.treatmentDefaultsKey) private var treatmentRaw: Int = 0

    @State private var findings: [SecretDetector.Finding] = []
    @State private var dismissed = false
    @State private var showDetails = false

    var body: some View {
        // The scan `.task` MUST live on an always-present concrete view. A bare
        // `Group { if shouldShow {…} }` renders as EmptyView on the first (clean)
        // render, and `.task` on an EmptyView never fires — so the badge stayed
        // hidden even with secrets present (VM miss 2026-07-09). The zero-height
        // Color.clear is always in the tree; the banner overlays above it.
        ZStack(alignment: .top) {
            Color.clear
                .frame(height: 0)
                .task(id: contents) {
                    guard SecretBannerState.scanEnabled(treatmentRaw: treatmentRaw) else {
                        findings = []
                        return
                    }
                    let text = contents
                    let scanned = await Task.detached(priority: .utility) {
                        SecretDetector.scan(text: text)
                    }.value
                    findings = scanned
                    dismissed = false
                }
            if SecretBannerState.shouldShow(
                findingCount: findings.count, treatmentRaw: treatmentRaw, dismissed: dismissed) {
                banner
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            Text(SecretBannerState.countLabel(findings.count))
                .font(.system(size: 12, weight: .medium))
            Button("Details") { showDetails.toggle() }
                .buttonStyle(.link)
                .popover(isPresented: $showDetails, arrowEdge: .bottom) { detailsList }
                .accessibilityIdentifier("mdv.secretBanner.detailsButton")
            Spacer(minLength: 8)
            Button {
                dismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14))
        .overlay(alignment: .bottom) { Divider() }
        .compositingGroup()
        .accessibilityIdentifier("mdv.secretBanner")
    }

    private var detailsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Potential secrets")
                .font(.system(size: 12, weight: .semibold))
            Text("Detected by shape/entropy. Values are shown redacted; TextView never modifies the file.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                HStack(spacing: 8) {
                    Text("L\(f.line)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(f.kind.rawValue)
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 8)
                    Text(f.preview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .accessibilityIdentifier("mdv.secretBanner.details")
    }
}
