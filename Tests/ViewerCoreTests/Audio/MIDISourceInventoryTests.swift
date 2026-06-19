import XCTest
import CoreMIDI
@testable import ViewerCore

/// Teeth for the host-testable CoreMIDI source model (TSK-956): the descriptor's
/// identity, the deterministic sort, and the search/lookup logic. Reading
/// properties off a live `MIDIEndpointRef` needs a running MIDI server (VM), so
/// here we drive the pure logic with synthetic descriptors plus the injectable
/// discovery seam.
final class MIDISourceInventoryTests: XCTestCase {

    private func src(_ name: String, id: Int32, device: String = "") -> MIDISourceDescriptor {
        MIDISourceDescriptor(uniqueID: id, displayName: name, manufacturerOrModel: device)
    }

    // MARK: Descriptor

    func test_id_isUniqueID() {
        XCTAssertEqual(src("Keys", id: 42).id, 42)
    }

    func test_descriptor_isCodableRoundTrip() throws {
        let d = src("MPK Mini", id: -7, device: "Akai")
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(MIDISourceDescriptor.self, from: data)
        XCTAssertEqual(back, d)
    }

    // MARK: Sort

    func test_sorted_byDisplayName_caseInsensitive_thenUniqueID() {
        let sources = [
            src("zeta", id: 3),
            src("Alpha", id: 9),
            src("alpha", id: 2),
        ]
        let out = MIDIInventory.sorted(sources)
        // "Alpha"/"alpha" tie on name (case-insensitive) → broken by uniqueID asc.
        XCTAssertEqual(out.map(\.uniqueID), [2, 9, 3])
    }

    // MARK: Search / lookup

    func test_search_matchesNameAndDevice_caseInsensitive() {
        let sources = [
            src("Port A", id: 1, device: "Akai MPK"),
            src("Virtual Out", id: 2, device: "GarageBand"),
        ]
        XCTAssertEqual(MIDIInventory.search(sources, query: "akai").map(\.uniqueID), [1])
        XCTAssertEqual(MIDIInventory.search(sources, query: "VIRTUAL").map(\.uniqueID), [2])
    }

    func test_search_emptyQueryReturnsAll() {
        let sources = [src("A", id: 1), src("B", id: 2)]
        XCTAssertEqual(MIDIInventory.search(sources, query: "  ").count, 2)
    }

    func test_sourceWithUniqueID_findsAndMissesGracefully() {
        let target = src("Keys", id: 1234)
        let sources = [src("Other", id: 1), target]
        XCTAssertEqual(MIDIInventory.source(withUniqueID: 1234, in: sources), target)
        XCTAssertNil(MIDIInventory.source(withUniqueID: 9999, in: sources))
    }

    // MARK: Discovery seam

    func test_discover_withEmptySource_returnsEmpty() {
        XCTAssertTrue(MIDIInventory.discover(endpointSource: { [] }).isEmpty)
    }

    func test_discover_adaptsAndSorts_viaInjectedRefs_noLiveServer() {
        // Endpoint refs are opaque integers; with no client created,
        // descriptor(for:) reads no real properties → degrades to id 0 / empty
        // name. We still exercise the adapt + sort path end-to-end.
        let refs: [MIDIEndpointRef] = [0, 0]
        let out = MIDIInventory.discover(endpointSource: { refs })
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out, MIDIInventory.sorted(out))
    }

    /// The default endpoint source walks the system MIDI registry. We only
    /// assert it is non-crashing and returns a sorted list (host/VM may have
    /// zero or more sources).
    func test_defaultDiscovery_isNonCrashing() {
        let out = MIDIInventory.discover()
        XCTAssertEqual(out, MIDIInventory.sorted(out))
    }
}
