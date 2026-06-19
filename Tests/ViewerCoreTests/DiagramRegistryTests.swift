import XCTest
@testable import ViewerCore

/// Host tests for the DiagramRenderer registry + fence-language routing
/// foundation slice (TSK-713). Pure-logic: registry resolution, the new
/// PlantUML detector, order-independence, and duplicate-language collision.
final class DiagramRegistryTests: XCTestCase {

    // MARK: - Resolution per language

    func test_standardRegistry_resolvesMermaid() {
        let r = DiagramRegistry.standard.renderer(forLanguage: "mermaid")
        XCTAssertEqual(r?.kind, .mermaid)
    }

    func test_standardRegistry_resolvesDotAliases() {
        for token in ["dot", "gv", "graphviz"] {
            XCTAssertEqual(DiagramRegistry.standard.renderer(forLanguage: token)?.kind, .dot,
                           "'\(token)' should route to the dot renderer")
        }
    }

    func test_standardRegistry_resolvesPlantUMLAliases() {
        for token in ["plantuml", "puml", "uml"] {
            XCTAssertEqual(DiagramRegistry.standard.renderer(forLanguage: token)?.kind, .plantuml,
                           "'\(token)' should route to the plantuml renderer")
        }
    }

    func test_languageResolution_isCaseInsensitive() {
        XCTAssertEqual(DiagramRegistry.standard.renderer(forLanguage: "MERMAID")?.kind, .mermaid)
        XCTAssertEqual(DiagramRegistry.standard.renderer(forLanguage: "Dot")?.kind, .dot)
        XCTAssertEqual(DiagramRegistry.standard.renderer(forLanguage: "PlantUML")?.kind, .plantuml)
    }

    func test_fileExtensionResolution() {
        XCTAssertEqual(DiagramRegistry.standard.renderer(forFileExtension: "mmd")?.kind, .mermaid)
        XCTAssertEqual(DiagramRegistry.standard.renderer(forFileExtension: "mermaid")?.kind, .mermaid)
        XCTAssertEqual(DiagramRegistry.standard.renderer(forFileExtension: "dot")?.kind, .dot)
        XCTAssertEqual(DiagramRegistry.standard.renderer(forFileExtension: "gv")?.kind, .dot)
        XCTAssertEqual(DiagramRegistry.standard.renderer(forFileExtension: "puml")?.kind, .plantuml)
    }

    // MARK: - Unknown languages fall through

    func test_unknownLanguage_returnsNil() {
        XCTAssertNil(DiagramRegistry.standard.renderer(forLanguage: "swift"))
        XCTAssertNil(DiagramRegistry.standard.renderer(forLanguage: "python"))
        XCTAssertNil(DiagramRegistry.standard.renderer(forLanguage: ""))
        XCTAssertNil(DiagramRegistry.standard.descriptor(for: "noop", language: "rust"))
    }

    func test_unknownFileExtension_returnsNil() {
        XCTAssertNil(DiagramRegistry.standard.renderer(forFileExtension: "md"))
        XCTAssertNil(DiagramRegistry.standard.renderer(forFileExtension: "png"))
    }

    // MARK: - Descriptors

    func test_mermaidDescriptor_carriesIdAndStepCount() {
        let source = "%% @id login-flow\n%% @step 1\nflowchart LR\n  A --> B\n"
        let d = DiagramRegistry.standard.descriptor(for: source, language: "mermaid")
        XCTAssertEqual(d?.kind, .mermaid)
        XCTAssertEqual(d?.id, "login-flow")
        XCTAssertEqual(d?.source, source, "descriptor must preserve source verbatim")
        XCTAssertEqual(d?.metadata["stepCount"], "1")
    }

    func test_dotDescriptor_carriesGraphStructure() {
        let source = "digraph G {\n  a -> b -> c;\n}\n"
        let d = DiagramRegistry.standard.descriptor(for: source, language: "dot")
        XCTAssertEqual(d?.kind, .dot)
        XCTAssertEqual(d?.metadata["directed"], "true")
        XCTAssertEqual(d?.metadata["nodeCount"], "3")
        XCTAssertEqual(d?.metadata["edgeCount"], "2")
        XCTAssertEqual(d?.metadata["name"], "G")
        XCTAssertEqual(d?.id, "G")
    }

    func test_dotDescriptor_undirectedGraph() {
        let source = "graph {\n  x -- y;\n}\n"
        let d = DiagramRegistry.standard.descriptor(for: source, language: "gv")
        XCTAssertEqual(d?.metadata["directed"], "false")
        XCTAssertEqual(d?.metadata["nodeCount"], "2")
    }

    func test_dotDescriptor_invalidSource_marksParsedFalse() {
        let d = DiagramRegistry.standard.descriptor(for: "this is not a graph", language: "dot")
        XCTAssertEqual(d?.kind, .dot)
        XCTAssertEqual(d?.metadata["parsed"], "false")
    }

    // MARK: - New format: PlantUML detection

    func test_plantUML_detectsStartUML() {
        XCTAssertTrue(PlantUMLDiagramRenderer.isPlantUML("@startuml\nA -> B\n@enduml"))
        XCTAssertEqual(PlantUMLDiagramRenderer.detectedType(in: "@startuml\nA -> B\n@enduml"), "uml")
    }

    func test_plantUML_detectsAlternateDiagramTypes() {
        XCTAssertEqual(PlantUMLDiagramRenderer.detectedType(in: "@startmindmap\n* root\n@endmindmap"), "mindmap")
        XCTAssertEqual(PlantUMLDiagramRenderer.detectedType(in: "@startgantt\n[Task] lasts 3 days\n@endgantt"), "gantt")
        XCTAssertEqual(PlantUMLDiagramRenderer.detectedType(in: "@startjson\n{}\n@endjson"), "json")
    }

    func test_plantUML_caseInsensitiveAndLeadingWhitespace() {
        XCTAssertEqual(PlantUMLDiagramRenderer.detectedType(in: "   @STARTUML\n@enduml"), "uml")
    }

    func test_plantUML_startWithName_extractsTypeOnly() {
        XCTAssertEqual(PlantUMLDiagramRenderer.detectedType(in: "@startuml MyDiagram\n@enduml"), "uml")
    }

    func test_plantUML_bareStart_normalizesToUml() {
        XCTAssertEqual(PlantUMLDiagramRenderer.detectedType(in: "@start\nstuff\n@end"), "uml")
    }

    func test_plantUML_nonPlantUMLSource_notDetected() {
        XCTAssertFalse(PlantUMLDiagramRenderer.isPlantUML("just some plain text"))
        XCTAssertNil(PlantUMLDiagramRenderer.detectedType(in: "no directive here"))
    }

    func test_plantUMLDescriptor_carriesDetectedType() {
        let source = "@startuml\nAlice -> Bob: hi\n@enduml"
        let d = DiagramRegistry.standard.descriptor(for: source, language: "plantuml")
        XCTAssertEqual(d?.kind, .plantuml)
        XCTAssertEqual(d?.metadata["detected"], "true")
        XCTAssertEqual(d?.metadata["diagramType"], "uml")
        XCTAssertEqual(d?.source, source)
    }

    func test_plantUMLDescriptor_nonDiagramSource_marksNotDetected() {
        let d = DiagramRegistry.standard.descriptor(for: "plain", language: "puml")
        XCTAssertEqual(d?.metadata["detected"], "false")
        XCTAssertNil(d?.metadata["diagramType"])
    }

    // MARK: - Registration: order-independent + collision-checked

    func test_registration_isOrderIndependent() throws {
        let forward = DiagramRegistry()
        try forward.register(MermaidDiagramRenderer())
        try forward.register(DotDiagramRenderer())
        try forward.register(PlantUMLDiagramRenderer())

        let reverse = DiagramRegistry()
        try reverse.register(PlantUMLDiagramRenderer())
        try reverse.register(DotDiagramRenderer())
        try reverse.register(MermaidDiagramRenderer())

        for token in ["mermaid", "dot", "gv", "graphviz", "plantuml", "puml", "uml"] {
            XCTAssertEqual(forward.renderer(forLanguage: token)?.kind,
                           reverse.renderer(forLanguage: token)?.kind,
                           "resolution of '\(token)' must not depend on registration order")
        }
        XCTAssertEqual(forward.registeredLanguages, reverse.registeredLanguages)
        XCTAssertEqual(forward.registeredExtensions, reverse.registeredExtensions)
    }

    func test_duplicateLanguage_throwsCollision() {
        let registry = DiagramRegistry()
        XCTAssertNoThrow(try registry.register(MermaidDiagramRenderer()))
        XCTAssertThrowsError(try registry.register(CollidingLanguageRenderer())) { error in
            guard case DiagramRegistry.RegistrationError.duplicateLanguage(let lang, _, _) = error else {
                return XCTFail("expected duplicateLanguage, got \(error)")
            }
            XCTAssertEqual(lang, "mermaid")
        }
    }

    func test_duplicateExtension_throwsCollision() {
        let registry = DiagramRegistry()
        XCTAssertNoThrow(try registry.register(DotDiagramRenderer()))
        XCTAssertThrowsError(try registry.register(CollidingExtensionRenderer())) { error in
            guard case DiagramRegistry.RegistrationError.duplicateExtension(let ext, _, _) = error else {
                return XCTFail("expected duplicateExtension, got \(error)")
            }
            XCTAssertEqual(ext, "gv")
        }
    }

    func test_collidingRegistration_leavesTableUnmutated() {
        let registry = DiagramRegistry()
        try? registry.register(MermaidDiagramRenderer())
        // Renderer claims a fresh language ("foo") AND a colliding one
        // ("mermaid"); the collision must roll back the whole renderer, so
        // "foo" must NOT have leaked into the table.
        XCTAssertThrowsError(try registry.register(PartialCollisionRenderer()))
        XCTAssertNil(registry.renderer(forLanguage: "foo"),
                     "a failed registration must not partially populate the table")
    }

    func test_standardRegistry_hasNoTokenCollisions() {
        // The static `.standard` is built with `try!`-equivalent semantics; if
        // the built-ins collided it would trap on first access. Reaching here
        // (any earlier test touched it) plus an explicit fresh build proves the
        // built-in set is collision-free.
        XCTAssertNoThrow(try {
            let r = DiagramRegistry()
            try r.register(MermaidDiagramRenderer())
            try r.register(DotDiagramRenderer())
            try r.register(PlantUMLDiagramRenderer())
        }())
    }

    // MARK: - Test doubles

    private struct CollidingLanguageRenderer: DiagramRenderer {
        let kind: DiagramKind = .dot
        let languages: [String] = ["mermaid"]   // collides with MermaidDiagramRenderer
        let fileExtensions: [String] = ["xyz"]
        func descriptor(for source: String, language: String) -> DiagramDescriptor {
            DiagramDescriptor(kind: kind, source: source, language: language)
        }
    }

    private struct CollidingExtensionRenderer: DiagramRenderer {
        let kind: DiagramKind = .plantuml
        let languages: [String] = ["brandnew"]
        let fileExtensions: [String] = ["gv"]    // collides with DotDiagramRenderer
        func descriptor(for source: String, language: String) -> DiagramDescriptor {
            DiagramDescriptor(kind: kind, source: source, language: language)
        }
    }

    private struct PartialCollisionRenderer: DiagramRenderer {
        let kind: DiagramKind = .dot
        let languages: [String] = ["foo", "mermaid"]   // "foo" fresh, "mermaid" collides
        let fileExtensions: [String] = []
        func descriptor(for source: String, language: String) -> DiagramDescriptor {
            DiagramDescriptor(kind: kind, source: source, language: language)
        }
    }
}
