import Foundation
import AppKit

/// Abstraction over the system pasteboard so `TextToolRunner` is unit-testable
/// WITHOUT touching `NSPasteboard.general` (which would clobber the developer's
/// real clipboard during a test run). Production uses `SystemPasteboard`; tests
/// inject a fake.
public protocol PasteboardIO: AnyObject {
    func readString() -> String?
    func writeString(_ s: String)
}

/// Production `PasteboardIO` backed by the system pasteboard.
public final class SystemPasteboard: PasteboardIO {
    public init() {}
    public func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
    public func writeString(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

/// Runs a `TextToolVerb` against a pasteboard and returns a short human status
/// (for a toast / status line). Generators (`.generateUUID`) ignore the current
/// clipboard and write fresh output; transforms read the clipboard and, on
/// success, overwrite it with the result. The actual transform stays in
/// `TextTools` (tested independently); this layer only does the clipboard IO +
/// status, so any invoker (command palette, menu, automation verb) shares one
/// tested entry point. This is the clipboard surface for TSK-292/294/295.
public enum TextToolRunner {
    @discardableResult
    public static func run(_ verb: TextToolVerb, pasteboard pb: PasteboardIO) -> String {
        guard verb.transformsInput else {
            let out = TextTools.apply(verb, to: nil) ?? ""
            pb.writeString(out)
            return "\(verb.title): copied to clipboard"
        }
        guard let input = pb.readString(), !input.isEmpty else {
            return "\(verb.title): clipboard is empty"
        }
        guard let out = TextTools.apply(verb, to: input) else {
            return "\(verb.title): clipboard isn’t valid input for this tool"
        }
        pb.writeString(out)
        return "\(verb.title): result copied to clipboard"
    }
}
