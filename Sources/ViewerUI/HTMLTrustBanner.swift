import SwiftUI

/// TSK-1189 slice 3 — the "Trust & Run" affordance for a LOCAL HTML doc whose
/// own scripts were stripped for safety (so it renders only partially). Shown
/// (driven by `DocumentModel.shouldOfferHTMLTrust`) only when the doc is
/// trust-eligible, script-dependent, and not yet trusted. Tapping it records a
/// per-document opt-in (`setHTMLTrusted`) → the renderer re-renders with the
/// bounded relaxation (scripts run; the anti-exfil fence — `connect-src 'none'`,
/// no remote/file-URL access — stays). Browser-equivalent for a file you trust.
struct HTMLTrustBanner: View {
    let fileName: String
    let onTrust: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("“\(fileName)” needs its own scripts to render fully.")
                    .font(.callout)
                Text("They were removed for safety. Trust this local file to run them?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Trust & Run", action: onTrust)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.18))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("mdv.html.trustBanner")
    }
}
