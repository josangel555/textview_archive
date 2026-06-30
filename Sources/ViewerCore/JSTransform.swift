import Foundation
import JavaScriptCore

/// Slice 1 of the script console (TSK-698): evaluate a JavaScript expression
/// against the active buffer's parsed JSON and return the result as pretty
/// JSON — "JS-type manipulation of JSON" the owner asked for.
///
/// Runs in a FRESH `JSContext` sandbox: pure ECMAScript only (Math, JSON,
/// String, Array, …). There is NO `fetch`, no `require`, no filesystem, no DOM,
/// no network — `JSContext` exposes none of that — so a transform can read and
/// reshape the in-memory JSON but cannot do I/O or exfiltrate data. The parsed
/// JSON is bound to both `input` and `$`.
///
/// `evaluateScript` is synchronous and not preemptible, so a runaway script
/// (`while(true){}`) would block its thread. The engine itself stays pure +
/// synchronous for testability; `runAsync` (below, TSK-698 slice 2) runs it OFF the
/// main thread with a SOFT deadline so the console UI (slice 3) never hangs on
/// arbitrary input.
public enum JSTransform {

    public enum TransformError: Error, Equatable {
        case invalidJSON
        case jsException(String)
        case unserializableResult
        /// The script exceeded the soft execution deadline (TSK-698 slice 2, approach B).
        case timedOut(TimeInterval)
    }

    /// Evaluate `expression` with the parsed `json` bound to `input`/`$`,
    /// returning the result re-serialized as 2-space-indented JSON.
    public static func run(json: String, expression: String) -> Result<String, TransformError> {
        // Validate the input JSON up front so a parse failure is reported
        // distinctly from an error in the user's expression.
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else { return .failure(.invalidJSON) }

        guard let ctx = JSContext() else { return .failure(.jsException("no JS context")) }
        var thrown: String?
        ctx.exceptionHandler = { _, exc in thrown = exc?.toString() ?? "JS exception" }
        ctx.setObject(json, forKeyedSubscript: "__mdv_raw" as NSString)

        // Wrap the expression so the user writes an expression (`input.foo`),
        // not statements; bind input/$ to the parsed value; stringify the result.
        let script = """
        (function () {
          var input = JSON.parse(__mdv_raw);
          var $ = input;
          void $;
          return JSON.stringify((\(expression)), null, 2);
        })()
        """
        let value = ctx.evaluateScript(script)
        if let thrown { return .failure(.jsException(thrown)) }
        guard let value, value.isString, let s = value.toString() else {
            // JSON.stringify returns `undefined` for undefined / a function /
            // a value with no JSON representation.
            return .failure(.unserializableResult)
        }
        return .success(s)
    }

    /// TSK-698 slice 2 — run the transform OFF the main thread with a SOFT timeout
    /// (owner-approved approach B, seq 8793). The sandboxed `run` is synchronous and
    /// non-preemptible, so a runaway script (`while(true){}`) would block its thread;
    /// this races the eval (on a detached thread) against `timeout` and returns
    /// `.failure(.timedOut)` if the deadline wins, so the caller / UI never hangs. A
    /// genuinely non-terminating script leaks that ONE spinning thread until the app
    /// exits — the documented, rare, user-authored edge of approach B (SPI preemption
    /// and subprocess isolation were both weighed and rejected for v1). The
    /// eval/timeout race resolves the continuation EXACTLY once (first wins) via `OneShot`.
    public static func runAsync(
        json: String, expression: String, timeout: TimeInterval = 2.0
    ) async -> Result<String, TransformError> {
        await withCheckedContinuation {
            (cont: CheckedContinuation<Result<String, TransformError>, Never>) in
            let once = OneShot(cont)
            Thread.detachNewThread {
                let result = JSTransform.run(json: json, expression: expression)
                once.resume(result)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(.timedOut(timeout)))
            }
        }
    }
}

/// Resolves a `CheckedContinuation` EXACTLY ONCE under a lock — the eval thread and the
/// timeout both call `resume`; the first wins, later calls are no-ops. (TSK-698 slice 2.)
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Result<String, JSTransform.TransformError>, Never>?
    init(_ cont: CheckedContinuation<Result<String, JSTransform.TransformError>, Never>) {
        self.cont = cont
    }
    func resume(_ value: Result<String, JSTransform.TransformError>) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
