import Foundation
import CoreMIDI

/// A pure, value-type description of one CoreMIDI source endpoint (TSK-956) —
/// e.g. a connected MIDI keyboard or a virtual source from another app. This is
/// the host-testable model: it carries the endpoint's display name and unique
/// id without holding a live `MIDIEndpointRef`, so the enumeration/sort/lookup
/// logic is exercisable on the headless host with synthetic endpoints.
///
/// Enumerating sources (`MIDIInventory.discover`) opens no audio/MIDI hardware
/// and registers no client — it only reads the system's endpoint list — but the
/// CoreMIDI server is only present in a full session, so the real path is the
/// VM-wired step; the pure logic below is host-covered.
public struct MIDISourceDescriptor: Sendable, Equatable, Hashable, Codable, Identifiable {

    /// The endpoint's `kMIDIPropertyUniqueID` — stable across reconnects, so it
    /// is what we'd persist to remember a chosen input. CoreMIDI types this as a
    /// signed `MIDIUniqueID` (`Int32`).
    public let uniqueID: Int32

    /// The endpoint's display name (`kMIDIPropertyDisplayName`, falling back to
    /// `kMIDIPropertyName`). May be empty if the device reports none.
    public let displayName: String

    /// The owning device/entity name when available (`kMIDIPropertyName` of the
    /// containing entity), for disambiguating two same-named ports. Empty when
    /// unknown.
    public let manufacturerOrModel: String

    /// `uniqueID` is the natural identity.
    public var id: Int32 { uniqueID }

    public init(uniqueID: Int32, displayName: String, manufacturerOrModel: String = "") {
        self.uniqueID = uniqueID
        self.displayName = displayName
        self.manufacturerOrModel = manufacturerOrModel
    }
}

/// Enumerates CoreMIDI source endpoints and provides host-testable
/// sort/search/lookup logic over them (TSK-956). The discovery call walks
/// `MIDIGetNumberOfSources()` / `MIDIGetSource(_:)`; the pure logic operates on
/// a plain `[MIDISourceDescriptor]`.
public enum MIDIInventory {

    // MARK: Discovery (live)

    /// All current MIDI source endpoints, adapted to pure descriptors and
    /// sorted. `endpointSource` is injectable so tests drive adapt+sort without
    /// a running MIDI server.
    public static func discover(
        endpointSource: () -> [MIDIEndpointRef] = defaultEndpointSource
    ) -> [MIDISourceDescriptor] {
        sorted(endpointSource().map(descriptor(for:)))
    }

    /// Snapshot the system's MIDI source endpoints.
    public static func defaultEndpointSource() -> [MIDIEndpointRef] {
        let count = MIDIGetNumberOfSources()
        guard count > 0 else { return [] }
        return (0..<count).map { MIDIGetSource($0) }
    }

    /// Adapt a live endpoint ref into a pure descriptor by reading its string +
    /// integer properties. Missing properties degrade to empty / zero rather
    /// than throwing, so a partially-described endpoint still lists.
    public static func descriptor(for endpoint: MIDIEndpointRef) -> MIDISourceDescriptor {
        MIDISourceDescriptor(
            uniqueID: integerProperty(endpoint, kMIDIPropertyUniqueID),
            displayName: stringProperty(endpoint, kMIDIPropertyDisplayName)
                ?? stringProperty(endpoint, kMIDIPropertyName)
                ?? "",
            manufacturerOrModel: stringProperty(endpoint, kMIDIPropertyManufacturer)
                ?? stringProperty(endpoint, kMIDIPropertyModel)
                ?? ""
        )
    }

    private static func stringProperty(_ obj: MIDIObjectRef, _ key: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(obj, key, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func integerProperty(_ obj: MIDIObjectRef, _ key: CFString) -> Int32 {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(obj, key, &value) == noErr else { return 0 }
        return value
    }

    // MARK: Pure logic (host-testable)

    /// Deterministic ordering: by display name (case-insensitive), then by
    /// `uniqueID` to break ties.
    public static func sorted(_ sources: [MIDISourceDescriptor]) -> [MIDISourceDescriptor] {
        sources.sorted { a, b in
            let n = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
            if n != .orderedSame { return n == .orderedAscending }
            return a.uniqueID < b.uniqueID
        }
    }

    /// Case-insensitive substring search across display name and device name.
    /// An empty/whitespace query returns the input unchanged.
    public static func search(_ sources: [MIDISourceDescriptor], query: String) -> [MIDISourceDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sources }
        return sources.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.manufacturerOrModel.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Resolve a source by its persisted `uniqueID`; `nil` when disconnected.
    public static func source(withUniqueID uniqueID: Int32, in sources: [MIDISourceDescriptor]) -> MIDISourceDescriptor? {
        sources.first { $0.uniqueID == uniqueID }
    }
}
