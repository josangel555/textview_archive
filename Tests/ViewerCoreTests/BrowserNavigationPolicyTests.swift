import XCTest
@testable import ViewerCore

/// REGRESSION-CRITICAL allowlist for the built-in **localhost browser tab**
/// (`BrowserNavigationPolicy`, epic TSK-676). These host-safe tests pin the
/// pure URL decision kernel that a `WKNavigationDelegate` forwards to — they
/// catch the security regressions WITHOUT a live `WKWebView`:
///
///   * top-level nav: allow ONLY loopback http/https/ws/wss; cancel every
///     off-host origin and every `file://`.
///   * sub-resources: strict (loopback only) vs permissive (off-host CDN
///     fetch allowed, but never `file://`).
///   * loopback-host matcher: localhost / 127.0.0.0-8 / ::1, segment-aware
///     so look-alikes (`127.0.0.1.evil.com`) do NOT match.
///
/// The live WKWebView wiring (3rd-party cookie block, ATS exception) is the
/// separate VM-validated slice; the policy lives here.
final class BrowserNavigationPolicyTests: XCTestCase {

    private func url(_ s: String) -> URL {
        guard let u = URL(string: s) else {
            XCTFail("test URL did not parse: \(s)")
            return URL(string: "about:blank")!
        }
        return u
    }

    // MARK: - Top-level: allowed loopback origins

    func test_topLevel_loopback_allowed() {
        // (input URL, why) — every one is a loopback origin on an allowed
        // scheme + arbitrary port, so all must ALLOW.
        let allowed = [
            "http://localhost:8787",
            "http://localhost:8787/lab?token=abc",
            "https://localhost",
            "http://127.0.0.1:9000/",
            "https://127.0.0.1",
            "http://127.1.2.3:5000",            // anywhere in 127.0.0.0/8
            "ws://localhost:8888/ws",
            "wss://127.0.0.1:443/socket",
            "http://[::1]:8080/",               // IPv6 loopback
            "https://[::1]",
            "http://LOCALHOST:3000",            // case-insensitive
            "http://localhost.:8787",           // trailing-dot FQDN form
        ]
        for s in allowed {
            XCTAssertEqual(
                BrowserNavigationPolicy.decideTopLevel(url: url(s)), .allow,
                "expected ALLOW for loopback top-level nav: \(s)"
            )
        }
    }

    // MARK: - Top-level: cancelled off-host + dangerous schemes

    func test_topLevel_offHost_cancelled() {
        let cancelled = [
            "http://evil.com",
            "https://evil.com/page",
            "http://cdn.jsdelivr.net/npm/thing.js",
            "https://127.0.0.1.evil.com",       // look-alike: NOT loopback
            "https://notlocalhost.com",
            "http://localhost.evil.com",        // localhost is a sub-label only
            "https://0.0.0.0:8787",             // 0.0.0.0 is NOT 127/8
            "https://10.0.0.5",                 // private but not loopback
            "https://[::2]",                    // not the loopback address
        ]
        for s in cancelled {
            XCTAssertEqual(
                BrowserNavigationPolicy.decideTopLevel(url: url(s)), .cancel,
                "expected CANCEL for off-host top-level nav: \(s)"
            )
        }
    }

    func test_topLevel_file_alwaysCancelled() {
        // file:// at the top level is the local-file-read escape — always
        // cancel, even pointing inside a "loopback-looking" path.
        for s in ["file:///etc/passwd",
                  "file:///Users/me/.ssh/id_rsa",
                  "file://localhost/etc/passwd"] {  // file: with loopback host
            XCTAssertEqual(
                BrowserNavigationPolicy.decideTopLevel(url: url(s)), .cancel,
                "expected CANCEL for file:// top-level nav: \(s)"
            )
        }
    }

    func test_topLevel_dangerousSchemes_cancelled() {
        for s in ["javascript:alert(1)",
                  "data:text/html,<script>evil()</script>",
                  "about:blank",
                  "ftp://localhost/file",          // ftp not in the scheme set
                  "vbscript:msgbox"] {
            XCTAssertEqual(
                BrowserNavigationPolicy.decideTopLevel(url: url(s)), .cancel,
                "expected CANCEL for dangerous-scheme top-level nav: \(s)"
            )
        }
    }

    func test_topLevel_nil_failsClosed() {
        XCTAssertEqual(BrowserNavigationPolicy.decideTopLevel(url: nil), .cancel)
    }

    // MARK: - Sub-resources: loopback always allowed

    func test_subresource_loopback_allowedBothModes() {
        for s in ["http://localhost:8787/static/app.js",
                  "https://127.0.0.1/style.css",
                  "ws://localhost:8888/ws",
                  "http://[::1]:9000/data.json"] {
            XCTAssertEqual(
                BrowserNavigationPolicy.decideSubresource(url: url(s), permissive: false),
                .allow, "strict: loopback sub-resource must allow: \(s)")
            XCTAssertEqual(
                BrowserNavigationPolicy.decideSubresource(url: url(s), permissive: true),
                .allow, "permissive: loopback sub-resource must allow: \(s)")
        }
    }

    // MARK: - Sub-resources: off-host = the strict/permissive fork

    func test_subresource_offHost_strictCancels_permissiveAllows() {
        // The canonical case from the task: a localhost page pulling a
        // cdn.jsdelivr sub-resource — allowed ONLY when permissive.
        let offHost = [
            "https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js",
            "https://fonts.googleapis.com/css?family=Roboto",
            "http://evil.com/track.gif",
            "https://127.0.0.1.evil.com/x.js",   // look-alike host
        ]
        for s in offHost {
            XCTAssertEqual(
                BrowserNavigationPolicy.decideSubresource(url: url(s), permissive: false),
                .cancel, "strict: off-host sub-resource must cancel: \(s)")
            XCTAssertEqual(
                BrowserNavigationPolicy.decideSubresource(url: url(s), permissive: true),
                .allow, "permissive: off-host sub-resource must allow: \(s)")
        }
    }

    func test_subresource_file_alwaysCancelled_evenPermissive() {
        // The permissive switch relaxes off-host NETWORK fetches only — it
        // must NEVER unlock local-file access.
        for s in ["file:///etc/passwd", "file:///Users/me/secret.txt"] {
            XCTAssertEqual(
                BrowserNavigationPolicy.decideSubresource(url: url(s), permissive: false),
                .cancel, "strict: file:// sub-resource must cancel: \(s)")
            XCTAssertEqual(
                BrowserNavigationPolicy.decideSubresource(url: url(s), permissive: true),
                .cancel, "permissive must STILL cancel file:// sub-resource: \(s)")
        }
    }

    func test_subresource_dangerousSchemes_cancelled() {
        for s in ["javascript:evil()", "vbscript:x", "ftp://cdn/x"] {
            XCTAssertEqual(
                BrowserNavigationPolicy.decideSubresource(url: url(s), permissive: true),
                .cancel, "permissive must cancel dangerous-scheme sub-resource: \(s)")
        }
    }

    func test_subresource_dataAndAbout_allowed() {
        // Inert data:/about: are not network or file access.
        for s in ["data:image/png;base64,AAAA", "about:blank"] {
            XCTAssertEqual(
                BrowserNavigationPolicy.decideSubresource(url: url(s), permissive: false),
                .allow, "data:/about: sub-resource should allow: \(s)")
        }
    }

    func test_subresource_nil_failsClosed() {
        XCTAssertEqual(
            BrowserNavigationPolicy.decideSubresource(url: nil, permissive: true), .cancel)
        XCTAssertEqual(
            BrowserNavigationPolicy.decideSubresource(url: nil, permissive: false), .cancel)
    }

    // MARK: - Loopback host matcher (segment-aware)

    func test_isLoopbackHostName_positives() {
        for h in ["localhost", "LocalHost", "localhost.",
                  "127.0.0.1", "127.0.0.0", "127.255.255.255", "127.1.2.3",
                  "::1", "[::1]"] {
            XCTAssertTrue(
                BrowserNavigationPolicy.isLoopbackHostName(h),
                "expected loopback: \(h)")
        }
    }

    func test_isLoopbackHostName_negatives() {
        for h in ["", ".", "evil.com", "localhost.evil.com",
                  "127.0.0.1.evil.com",          // look-alike
                  "0.0.0.0", "10.0.0.1", "192.168.0.1", "126.0.0.1", "128.0.0.1",
                  "1270.0.0.1",                   // not a valid octet
                  "127.0.0.256",                  // octet out of range
                  "127.0.0",                      // too few octets
                  "127.0.0.0.1",                  // too many octets
                  "::2", "fe80::1", "myhost"] {
            XCTAssertFalse(
                BrowserNavigationPolicy.isLoopbackHostName(h),
                "expected NOT loopback: \(h)")
        }
    }

    func test_isLoopbackHost_urlForm() {
        XCTAssertTrue(BrowserNavigationPolicy.isLoopbackHost(url("http://127.0.0.1:8787/x")))
        XCTAssertTrue(BrowserNavigationPolicy.isLoopbackHost(url("http://[::1]:8080/")))
        XCTAssertFalse(BrowserNavigationPolicy.isLoopbackHost(url("http://evil.com")))
        // A URL with no host (e.g. a scheme-only / opaque URL) is not loopback.
        XCTAssertFalse(BrowserNavigationPolicy.isLoopbackHost(url("javascript:alert(1)")))
    }
}
