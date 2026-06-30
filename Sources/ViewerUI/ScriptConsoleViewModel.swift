import Foundation
import ViewerCore

/// TSK-698 slice 3 (host-testable core) — the controller for the Script Console: the
/// user types a JS `expression` to run over the active buffer's `inputContent`
/// (interpreted per `inputFormat` — JSON or log lines), and gets back pretty-printed
/// `output` or a human `errorMessage`. Runs OFF the main thread with a soft timeout
/// (slice 2) so a runaway script never hangs the UI.
///
/// This is the host-tested model layer; the SwiftUI panel that binds to it (a query
/// field + results view + the menu trigger + "apply to a new tab") is the render tail.
@MainActor
public final class ScriptConsoleViewModel: ObservableObject {

    /// The raw text the transform runs over (the active buffer's contents).
    @Published public var inputContent: String
    /// How to interpret `inputContent` before binding it to `input`/`$`.
    @Published public var inputFormat: JSTransform.InputFormat = .json
    /// The JS expression to evaluate (`input` / `$` are the parsed buffer).
    @Published public var expression: String = "input"

    /// The last successful result (pretty JSON), or "" before the first run / on error.
    @Published public private(set) var output: String = ""
    /// A human-readable error from the last run, or nil when it succeeded.
    @Published public private(set) var errorMessage: String?
    /// True while a run is in flight (drives a spinner / disables re-run in the view).
    @Published public private(set) var isRunning = false

    public init(inputContent: String = "") {
        self.inputContent = inputContent
    }

    /// Run `expression` over `inputContent`/`inputFormat` off-main with a soft timeout,
    /// publishing `output` / `errorMessage` / `isRunning`. Safe to call repeatedly.
    public func run(timeout: TimeInterval = 2.0) async {
        isRunning = true
        errorMessage = nil
        let content = inputContent
        let format = inputFormat
        let expr = expression
        let result = await JSTransform.runAsync(
            content: content, as: format, expression: expr, timeout: timeout)
        isRunning = false
        switch result {
        case .success(let s):
            output = s
            errorMessage = nil
        case .failure(let e):
            output = ""
            errorMessage = Self.describe(e)
        }
    }

    /// Map a transform error to a one-line message for the console's status area.
    static func describe(_ error: JSTransform.TransformError) -> String {
        switch error {
        case .invalidJSON:
            return "Input is not valid JSON (try the “Lines” format for logs)."
        case .jsException(let message):
            return "JavaScript error: \(message)"
        case .unserializableResult:
            return "The result can’t be serialized to JSON (undefined / a function?)."
        case .timedOut(let seconds):
            return "Script timed out after \(seconds)s — check for an infinite loop."
        }
    }
}
