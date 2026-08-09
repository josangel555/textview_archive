import SwiftUI

/// Full-window HUD shown while a session switch is in flight (owner
/// 2026-08-09): the synchronous snapshot-current + materialize-target work
/// can take long enough to read as a hang — this names the wait and soaks
/// up clicks that would otherwise land mid-switch.
///
/// Observes ONLY the sessions coordinator (not DocumentModel), so the flag
/// flip re-bodies just this overlay.
struct SessionSwitchHUD: View {
    @ObservedObject var sessions: SessionsAppCoordinator

    var body: some View {
        if sessions.isSwitchingSession {
            ZStack {
                Color.black.opacity(0.15)
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Switching session…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 20)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .accessibilityIdentifier("mdv.sessionSwitchHUD")
        }
    }
}
