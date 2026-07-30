import Foundation
import ViewerCore

// Async tab content loaders (TSK-1110 SRP slice) — the off-main BinaryFile /
// TextFile reads that land a tab's content, each with the latest-switch-wins
// guard (a rapid HEX↔text toggle must not commit a superseded load). Called by
// `materializeIfNeeded`, which stays on DocumentModel. Behavior-preserving move
// out of DocumentModel.swift.
extension DocumentModel {

    func loadBinaryAsync(url: URL, intoTabID id: UUID) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = try? BinaryFileLoader().load(url: url)
            await MainActor.run { [weak self] in
                guard let self,
                      let idx = self.tabs.tabs.firstIndex(where: { $0.id == id }),
                      self.tabs.tabs[idx].url == url
                else { return }
                // Bug C (latest-switch-wins): `setCurrentViewMode` flips
                // `viewMode` synchronously but kicks THIS load async +
                // unguarded. A rapid HEX→Source toggle supersedes the HEX
                // request before this lands; writing `.binary` now would
                // leave HexView showing under a non-HEX picker (the
                // "mode switcher acts weird" desync, and — with a real
                // read landing into a re-materialized `.loading` slot —
                // the dropped-completion endless spinner). Only commit the
                // binary view if the tab is STILL in `.hex`; otherwise the
                // user has moved on and the corresponding text-mode load
                // owns the state.
                guard self.tabs.tabs[idx].viewMode == .hex else { return }
                var tab = self.tabs.tabs[idx]
                if let bin = loaded {
                    tab.state = .binary(bin)
                    // No-clobber baseline for the hex writer + watcher: the
                    // disk fingerprint these bytes were read at.
                    self.hexDiskBaseline[id] = HexDiskStamp.current(for: url)
                } else {
                    // CR-04: surface the failure rather than leaving the
                    // prior (stale) state. `controller.open` maps the
                    // read error to a user-facing `.error` message.
                    tab.state = self.controller.open(url: url)
                }
                self.tabCoordinator.replace(at: idx, with: tab)
                // LOADBUG: republish the model so ContentView re-bodies onto
                // the freshly-landed `.binary` state. Without it the picker
                // (synchronously flipped by setCurrentViewMode) says HEX while
                // the content pane stays on the previous mode's view — and the
                // later "Editor" pick then re-bodies on the still-`.binary`
                // state and shows HexView. See the matching note at the
                // materializeIfNeeded completion.
                self.updateDerived()
            }
        }
    }

    func loadTextAsync(url: URL, intoTabID id: UUID) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = try? TextFileLoader().load(url: url)
            await MainActor.run { [weak self] in
                guard let self,
                      let idx = self.tabs.tabs.firstIndex(where: { $0.id == id }),
                      self.tabs.tabs[idx].url == url
                else { return }
                // Bug C (latest-switch-wins): symmetric to loadBinaryAsync.
                // This load was kicked for a text-shaped mode (coming back
                // from HEX, or to seed `.editor`). If the user has since
                // switched the tab BACK to `.hex`, committing `.loaded`
                // now would drop them out of the byte grid they re-picked.
                // Drop the superseded load.
                guard self.tabs.tabs[idx].viewMode != .hex else { return }
                var tab = self.tabs.tabs[idx]
                if let text = loaded {
                    tab.state = .loaded(text)
                } else {
                    // CR-04: route the read failure through the standard
                    // error mapping so the tab shows an error placeholder
                    // instead of silently keeping stale content.
                    tab.state = self.controller.open(url: url)
                }
                self.tabCoordinator.replace(at: idx, with: tab)
                // LOADBUG: republish so ContentView re-bodies onto the
                // freshly-landed `.loaded` text state (e.g. coming back from
                // HEX to Source/Editor). Symmetric to loadBinaryAsync above.
                self.updateDerived()
            }
        }
    }
}
