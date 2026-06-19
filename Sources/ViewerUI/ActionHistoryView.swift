import SwiftUI
import ViewerCore

/// Read-only History list (TSK-703 foundation slice). Renders the
/// `ActionHistory` recorded log oldest-first: per row, a category icon, the
/// human-readable label, a coalesced-count badge, and the timestamp. Drive
/// undo/redo from the menu/keyboard; this surface is purely the *record*.
///
/// The list logic (ordering, formatting, icon mapping) is pure and host-tested
/// in `ActionHistoryTests` / `ActionHistoryRowModelTests`; this view is the
/// thin presentation shell over `ActionHistory.log`.
public struct ActionHistoryView: View {
    @ObservedObject private var history: ActionHistory

    public init(history: ActionHistory) {
        self.history = history
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if history.log.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .accessibilityIdentifier("mdv.actionHistory")
    }

    private var header: some View {
        HStack {
            Text("History")
                .font(.headline)
            Spacer()
            Text("\(history.log.count) action\(history.log.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No actions recorded yet.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            // Oldest-first: `log` is already insertion-ordered. The newest row
            // (the next-to-undo) is at the bottom.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(history.log) { entry in
                    row(ActionHistoryRowModel(entry: entry))
                    Divider()
                }
            }
        }
    }

    private func row(_ model: ActionHistoryRowModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: model.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.label)
                if let badge = model.coalescedBadge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(model.timeString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mdv.actionHistory.row")
    }
}

/// Pure per-row presentation model (host-testable: no SwiftUI types). Maps an
/// `ActionHistoryLogEntry` to the label, category glyph, optional coalesced
/// badge, and a formatted timestamp.
public struct ActionHistoryRowModel: Equatable {
    public let label: String
    public let systemImage: String
    public let coalescedBadge: String?
    public let timeString: String

    public init(entry: ActionHistoryLogEntry, calendar: Calendar = .current) {
        self.label = entry.label
        self.systemImage = Self.systemImage(for: entry.category)
        self.coalescedBadge = entry.coalescedCount > 1 ? "×\(entry.coalescedCount)" : nil
        let f = DateFormatter()
        f.calendar = calendar
        // DateFormatter ignores `calendar.timeZone`; set it explicitly so the
        // rendered time honors the caller's timezone (host-test determinism).
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        self.timeString = f.string(from: entry.timestamp)
    }

    /// SF Symbol name per category. Stable, so the icon mapping can be host-
    /// tested without rendering.
    public static func systemImage(for category: ActionCategory) -> String {
        switch category {
        case .edit:   return "pencil"
        case .cell:   return "tablecells"
        case .tab:    return "rectangle.stack"
        case .file:   return "doc"
        case .marker: return "bookmark"
        case .other:  return "circle"
        }
    }
}
