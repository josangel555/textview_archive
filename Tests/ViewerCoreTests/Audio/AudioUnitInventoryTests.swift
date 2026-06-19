import XCTest
import AVFoundation
import AudioToolbox
@testable import ViewerCore

/// Teeth for the host-testable Audio-Unit discovery model (TSK-956): the
/// descriptor's id/kind/fourCC derivation, the deterministic sort, and the
/// filter/search/group/lookup logic. The live `AVAudioUnitComponentManager`
/// query is exercised only through the injectable `componentSource` seam (the
/// real registry is VM-wired), so this whole suite runs on the headless host.
final class AudioUnitInventoryTests: XCTestCase {

    // Build a four-char-code OSType from a 4-byte ASCII string (test helper that
    // mirrors how the real component types are spelled, e.g. "aufx").
    private func fourCC(_ s: String) -> OSType {
        let bytes = Array(s.utf8)
        precondition(bytes.count == 4, "fourCC needs exactly 4 bytes")
        return bytes.reduce(0) { ($0 << 8) | OSType($1) }
    }

    private func au(
        _ name: String,
        manufacturer: String = "Acme",
        version: String = "1.0",
        subType: String = "subT",
        mfrCode: String = "Acme",
        type: OSType? = nil
    ) -> AudioUnitDescriptor {
        AudioUnitDescriptor(
            name: name,
            manufacturerName: manufacturer,
            versionString: version,
            componentType: type ?? kAudioUnitType_Effect,
            componentSubType: fourCC(subType),
            manufacturer: fourCC(mfrCode)
        )
    }

    // MARK: Descriptor derivation

    func test_kind_mapsKnownComponentTypes() {
        XCTAssertEqual(AudioUnitDescriptor.Kind.from(componentType: kAudioUnitType_Effect), .effect)
        XCTAssertEqual(AudioUnitDescriptor.Kind.from(componentType: kAudioUnitType_MusicEffect), .musicEffect)
        XCTAssertEqual(AudioUnitDescriptor.Kind.from(componentType: kAudioUnitType_MusicDevice), .instrument)
        XCTAssertEqual(AudioUnitDescriptor.Kind.from(componentType: kAudioUnitType_Generator), .generator)
        XCTAssertEqual(AudioUnitDescriptor.Kind.from(componentType: kAudioUnitType_Output), .output)
    }

    func test_kind_unknownTypeDegradesToOther() {
        XCTAssertEqual(AudioUnitDescriptor.Kind.from(componentType: fourCC("zzzz")), .other)
    }

    func test_kind_isStoredOnDescriptor() {
        let inst = au("Synth", type: kAudioUnitType_MusicDevice)
        XCTAssertEqual(inst.kind, .instrument)
    }

    func test_id_isTypeSubtypeManufacturerTriple_andStable() {
        let d = au("EQ", subType: "peq2", mfrCode: "appl", type: kAudioUnitType_Effect)
        // kAudioUnitType_Effect == 'aufx'
        XCTAssertEqual(d.id, "aufx-peq2-appl")
    }

    func test_fourCC_nonPrintableFallsBackToHex() {
        // 0x00000001 isn't printable ASCII → hex form.
        XCTAssertEqual(AudioUnitDescriptor.fourCC(0x0000_0001), "0x00000001")
    }

    func test_audioComponentDescription_roundTripsCodes() {
        let d = au("X", subType: "sub1", mfrCode: "mfr1", type: kAudioUnitType_Generator)
        let acd = d.audioComponentDescription
        XCTAssertEqual(acd.componentType, kAudioUnitType_Generator)
        XCTAssertEqual(acd.componentSubType, fourCC("sub1"))
        XCTAssertEqual(acd.componentManufacturer, fourCC("mfr1"))
        XCTAssertEqual(acd.componentFlags, 0)
        XCTAssertEqual(acd.componentFlagsMask, 0)
    }

    func test_descriptor_isCodableRoundTrip() throws {
        let d = au("Reverb", manufacturer: "Apple", version: "2.1",
                   subType: "rvb2", mfrCode: "appl", type: kAudioUnitType_Effect)
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(AudioUnitDescriptor.self, from: data)
        XCTAssertEqual(back, d)
        XCTAssertEqual(back.kind, .effect)   // kind re-derived from componentType on decode
    }

    // MARK: Sort

    func test_sorted_byManufacturerThenName_caseInsensitive() {
        let units = [
            au("Zeta", manufacturer: "bravo"),
            au("alpha", manufacturer: "Bravo"),
            au("Mid", manufacturer: "Alpha"),
        ]
        let names = AudioUnitInventory.sorted(units).map(\.name)
        // Alpha manufacturer first, then Bravo's "alpha" before "Zeta".
        XCTAssertEqual(names, ["Mid", "alpha", "Zeta"])
    }

    func test_sorted_breaksExactTieByID_stable() {
        let a = au("Same", manufacturer: "Co", subType: "aaaa", mfrCode: "Co12")
        let b = au("Same", manufacturer: "Co", subType: "bbbb", mfrCode: "Co12")
        let out = AudioUnitInventory.sorted([b, a])
        XCTAssertEqual(out.map(\.id), [a.id, b.id])  // aaaa < bbbb
    }

    // MARK: Filter / search / group / lookup

    func test_filter_byKind() {
        let fx = au("FX", type: kAudioUnitType_Effect)
        let synth = au("Synth", type: kAudioUnitType_MusicDevice)
        let out = AudioUnitInventory.filter([fx, synth], kind: .instrument)
        XCTAssertEqual(out.map(\.name), ["Synth"])
    }

    func test_search_matchesNameAndManufacturer_caseInsensitive() {
        let units = [
            au("Massive Synth", manufacturer: "NI"),
            au("Reverb", manufacturer: "Valhalla"),
        ]
        XCTAssertEqual(AudioUnitInventory.search(units, query: "massive").map(\.name), ["Massive Synth"])
        XCTAssertEqual(AudioUnitInventory.search(units, query: "valhalla").map(\.name), ["Reverb"])
    }

    func test_search_emptyQueryReturnsAll() {
        let units = [au("A"), au("B")]
        XCTAssertEqual(AudioUnitInventory.search(units, query: "   ").count, 2)
    }

    func test_groupedByManufacturer_sortedSections_preservesInnerOrder() {
        let units = [
            au("B2", manufacturer: "Beta"),
            au("A1", manufacturer: "Alpha"),
            au("B1", manufacturer: "Beta"),
        ]
        let groups = AudioUnitInventory.groupedByManufacturer(units)
        XCTAssertEqual(groups.map(\.manufacturer), ["Alpha", "Beta"])
        XCTAssertEqual(groups[1].units.map(\.name), ["B2", "B1"])  // input order within Beta
    }

    func test_descriptorWithID_findsAndMissesGracefully() {
        let d = au("X", subType: "peq2", mfrCode: "appl", type: kAudioUnitType_Effect)
        let units = [au("Y"), d]
        XCTAssertEqual(AudioUnitInventory.descriptor(withID: "aufx-peq2-appl", in: units), d)
        XCTAssertNil(AudioUnitInventory.descriptor(withID: "nope-nope-nope", in: units))
    }

    // MARK: Discovery seam (injectable, no real registry)

    func test_discover_withEmptySource_returnsEmpty() {
        XCTAssertTrue(AudioUnitInventory.discover(componentSource: { [] }).isEmpty)
    }

    /// The default component source talks to the real registry. We don't assert
    /// on its contents (host-dependent), only that the call is non-crashing and
    /// returns metadata-only descriptors — a smoke that the AVFoundation seam is
    /// wired. (Apple ships a handful of system AUs, so this is usually non-empty,
    /// but we don't require that on an arbitrary host/VM.)
    func test_defaultDiscovery_isNonCrashing() {
        let units = AudioUnitInventory.discover()
        // Output is already sorted; verify the invariant holds on whatever the
        // host returns.
        XCTAssertEqual(units, AudioUnitInventory.sorted(units))
    }
}
