import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1161 — the Structural Search controller. Pins query→parse→search→matches/error
/// over the host engine (TreeSitterEngine.structuralSearch, Swift grammar). The SwiftUI
/// panel is the render companion (VM-validated separately).
@MainActor
final class StructuralSearchViewModelTests: XCTestCase {

    func test_run_findsFunctionDeclarations_inSwift() {
        let vm = StructuralSearchViewModel(
            inputText: "func greet() { }\nfunc add() { }", language: .swift)
        vm.query = "function_declaration"
        vm.run()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.matches.count, 2, "two top-level funcs")
        XCTAssertEqual(vm.matches.first?.kind, "function_declaration")
        XCTAssertTrue(vm.didRun)
    }

    func test_run_capturesFieldByName() {
        let vm = StructuralSearchViewModel(inputText: "func greet() { }", language: .swift)
        vm.query = "function_declaration name=$X"
        vm.run()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.matches.first?["X"]?.text, "greet")
    }

    func test_run_badQuery_setsError_clearsMatches() {
        let vm = StructuralSearchViewModel(inputText: "func f() { }", language: .swift)
        vm.query = "function_declaration name="   // no value → parse error
        vm.run()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.matches.isEmpty)
    }

    func test_run_plainText_returnsNoMatches_noError() {
        let vm = StructuralSearchViewModel(inputText: "func f() { }", language: .plainText)
        vm.query = "function_declaration"
        vm.run()
        XCTAssertNil(vm.errorMessage, "plainText isn't a parse error — just no structural matches")
        XCTAssertTrue(vm.matches.isEmpty)
    }
}
