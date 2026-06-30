import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1335 — the existing Edit ▸ Convert Encoding submenu is now also ⌘K-palette
/// reachable: one command per menu encoding, each dispatching the existing
/// DocumentModel.convertActiveFileEncoding via a `convert-encoding <id>` verb.
@MainActor
final class ConvertEncodingPaletteCommandTests: XCTestCase {

    private var convertCommands: [CommandDescriptor] {
        CommandRegistry.builtIn.commands.filter { $0.id.hasPrefix("edit.convertEncoding.") }
    }

    func test_fourConvertEncodingCommands_exist_palette_invokable_macroExcluded() {
        XCTAssertEqual(convertCommands.count, 4, "one palette command per menu encoding choice")
        for cmd in convertCommands {
            XCTAssertTrue(cmd.isPaletteInvokable, "\(cmd.id) must carry a script verb")
            XCTAssertEqual(cmd.category, .edit)
            XCTAssertEqual(cmd.replayability, .excluded,
                           "a disk-write re-encode keyed on the active file is excluded from macros")
        }
    }

    func test_eachCommandsVerbArg_mapsToAnEncoding() {
        for cmd in convertCommands {
            let parts = cmd.scriptVerb!.split(separator: " ", maxSplits: 1).map(String.init)
            XCTAssertEqual(parts.first, "convert-encoding", "\(cmd.id) dispatches the convert verb")
            let arg = parts.count > 1 ? parts[1] : ""
            XCTAssertNotNil(ScriptVerb.encodingForConvertID(arg),
                            "\(cmd.id) verb arg '\(arg)' must map to a known encoding (no drift)")
        }
    }

    func test_encodingForConvertID_mapsTheMenuEncodings() {
        XCTAssertEqual(ScriptVerb.encodingForConvertID("utf-8"), .utf8)
        XCTAssertEqual(ScriptVerb.encodingForConvertID("utf-16"), .utf16)
        XCTAssertEqual(ScriptVerb.encodingForConvertID("windows-1252"), .windowsCP1252)
        XCTAssertEqual(ScriptVerb.encodingForConvertID("iso-latin-1"), .isoLatin1)
        XCTAssertNil(ScriptVerb.encodingForConvertID("bogus"), "an unknown id is a recognized no-op")
    }

    func test_alignTablesCommand_exists_paletteInvokable() {
        let cmd = CommandRegistry.builtIn.commands.first { $0.id == "edit.alignTables" }
        XCTAssertNotNil(cmd, "Align Markdown Tables should be a ⌘K palette command (TSK-1335)")
        XCTAssertEqual(cmd?.scriptVerb, "align-tables")
        XCTAssertTrue(cmd?.isPaletteInvokable ?? false)
        XCTAssertEqual(cmd?.category, .edit)
    }
}
