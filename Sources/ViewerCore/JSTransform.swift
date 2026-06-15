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
/// NOTE (next slice): `evaluateScript` is synchronous and not preemptible, so a
/// runaway script (`while(true){}`) would block the caller. The console UI slice
/// must run this off the main thread with a soft deadline before exposing it to
/// arbitrary input; the engine itself stays pure + synchronous for testability.
public enum JSTransform {

    public enum TransformError: Error, Equatable {
        case invalidJSON
        case jsException(String)
        case unserializableResult
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
}
