import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Raw-HTML JavaScript opt-in + per-document trust (PER-TAB, default-OFF)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split). The
// per-tab raw-HTML JS opt-in + per-document "trust this local HTML" decisions.
// SECURITY: rendering a raw `.html` file runs JavaScript DEFAULT-DENY; the only
// enable paths are an explicit per-tab opt-in or a per-document trust opt-in,
// both fail-closed. The backing state stays on the main class (an extension
// can't declare instance stored properties): the `@Published htmlJavaScriptOptIn`
// set (widened private→internal so these methods can mutate it) + the public
// `htmlTrustStore`. All other deps (tabs/currentURL/currentViewMode/
// currentCategory + the HTMLTrustPolicy/HTMLDocumentPolicy/FileQuarantine
// engines) are already accessible. `purgeCaches` (on the class) still prunes the
// opt-in set on tab close.
extension DocumentModel {
    /// PER-TAB JavaScript opt-in state for the raw-HTML renderer.
    /// `false` unless the user explicitly opted this tab in. This is the
    /// single read path the view consumes; the default is OFF.
    public func htmlJavaScriptEnabled(forTabID tabID: UUID) -> Bool {
        htmlJavaScriptOptIn.contains(tabID)
    }

    /// Convenience for the currently-selected tab. `false` when there is
    /// no selected tab (fail-closed).
    public var currentHTMLJavaScriptEnabled: Bool {
        guard let id = tabs.selected?.id else { return false }
        return htmlJavaScriptEnabled(forTabID: id)
    }

    /// Set the per-tab raw-HTML JS opt-in. The toggle is a deliberate
    /// user action — flipping it on records the tab id; flipping it off
    /// removes it (returning to the secure default). Only meaningful when
    /// the current tab is an `.html` file in rendered mode; harmless
    /// otherwise (the renderer for non-HTML files never reads it).
    public func setHTMLJavaScriptEnabled(_ enabled: Bool, forTabID tabID: UUID) {
        if enabled {
            htmlJavaScriptOptIn.insert(tabID)
        } else {
            htmlJavaScriptOptIn.remove(tabID)
        }
    }

    /// Toggle the current tab's raw-HTML JS opt-in.
    public func toggleCurrentHTMLJavaScript() {
        guard let id = tabs.selected?.id else { return }
        setHTMLJavaScriptEnabled(!htmlJavaScriptEnabled(forTabID: id), forTabID: id)
    }

    /// Effective trust for a tab's raw-HTML doc: a LOCAL, non-quarantined file
    /// the user explicitly opted in. The single read path the renderer consumes
    /// to relax sanitize/CSP/JS; default OFF, fail-closed.
    public func htmlTrusted(forTabID tabID: UUID) -> Bool {
        guard let url = tabs.tabs.first(where: { $0.id == tabID })?.url else { return false }
        return HTMLTrustPolicy.isTrusted(
            url: url,
            isQuarantined: FileQuarantine.isQuarantined(path: url.path),
            userOptedIn: htmlTrustStore.isOptedIn(url: url))
    }

    /// TSK-1203 — the https hosts a TRUSTED tab may `connect-src` to. Fail-closed:
    /// an UNtrusted tab returns `[]` regardless of any stored consent, so an
    /// untrusted page's fence can never be widened. The single read path the
    /// renderer passes to `HTMLDocumentPolicy.envelope(allowedConnectHosts:)`.
    public func htmlAllowedConnectHosts(forTabID tabID: UUID) -> [String] {
        guard htmlTrusted(forTabID: tabID),
              let url = tabs.tabs.first(where: { $0.id == tabID })?.url else { return [] }
        return htmlNetworkConsent.allowedHosts(for: url)
    }

    /// Consent to `host` for THIS tab's HTML doc (a deliberate user action). Only
    /// applies to a TRUSTED, valid-host pair; fires `objectWillChange` so the
    /// renderer rebuilds the CSP with the new origin. Returns whether it took.
    @discardableResult
    public func allowHTMLNetwork(host: String, forTabID tabID: UUID) -> Bool {
        guard htmlTrusted(forTabID: tabID),
              let url = tabs.tabs.first(where: { $0.id == tabID })?.url else { return false }
        let ok = htmlNetworkConsent.allow(host: host, for: url)
        if ok { objectWillChange.send() }
        return ok
    }

    /// Revoke ALL network consent for THIS tab's doc (fence back to `connect-src 'none'`).
    public func revokeHTMLNetwork(forTabID tabID: UUID) {
        guard let url = tabs.tabs.first(where: { $0.id == tabID })?.url else { return }
        htmlNetworkConsent.revokeAll(for: url)
        objectWillChange.send()
    }

    /// Is the tab's HTML doc ELIGIBLE for trust (local + not quarantined)?
    /// Drives whether the "Trust & Run" affordance is offered (slice 3).
    public func htmlTrustEligible(forTabID tabID: UUID) -> Bool {
        guard let url = tabs.tabs.first(where: { $0.id == tabID })?.url else { return false }
        return HTMLTrustPolicy.isTrustEligible(
            url: url, isQuarantined: FileQuarantine.isQuarantined(path: url.path))
    }

    /// Set the per-document HTML trust opt-in (a deliberate user action). An
    /// opt-IN only takes effect for a trust-eligible doc; revocation always
    /// applies. Fires `objectWillChange` so the renderer re-renders trusted.
    public func setHTMLTrusted(_ trusted: Bool, forTabID tabID: UUID) {
        guard let url = tabs.tabs.first(where: { $0.id == tabID })?.url else { return }
        if trusted && !HTMLTrustPolicy.isTrustEligible(
            url: url, isQuarantined: FileQuarantine.isQuarantined(path: url.path)) { return }
        htmlTrustStore.setOptedIn(trusted, url: url)
        objectWillChange.send()
    }

    /// Should the renderer offer a "Trust & Run" affordance for this tab? True
    /// when the doc is trust-ELIGIBLE (local + not quarantined), its scripts were
    /// SUPPRESSED (so it likely renders partially), and it isn't already trusted.
    /// Pure decision over the tab's content + trust state (host-testable); the
    /// banner that consumes it is render-path.
    public func shouldOfferHTMLTrust(forTabID tabID: UUID, contents: String) -> Bool {
        guard htmlTrustEligible(forTabID: tabID), !htmlTrusted(forTabID: tabID)
        else { return false }
        return HTMLDocumentPolicy.dependsOnSuppressedScript(contents)
    }

    /// True when the current tab is an `.html` file being shown in
    /// rendered mode — i.e. when the "Enable JavaScript" toggle is
    /// meaningful. Honors the per-tab "Open As…" override.
    public var showsHTMLJavaScriptToggle: Bool {
        guard let url = currentURL else { return false }
        let cat = currentCategory ?? FileTypeDetector.category(for: url)
        return cat == .html && currentViewMode == .rendered
    }
}
