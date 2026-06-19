import Foundation
import AVFoundation
import AudioToolbox

/// Enumerates installed Audio Units and provides the host-testable
/// filter/sort/group/select logic over them (TSK-956).
///
/// The actual discovery (`discover()`) calls `AVAudioUnitComponentManager`,
/// which talks to the system audio component registry — that part is only
/// exercised live. Everything ELSE (filtering by kind, searching by name,
/// grouping by manufacturer, deterministic sort, lookup by id) operates on a
/// plain `[AudioUnitDescriptor]` array, so it is fully covered on the headless
/// host with synthetic descriptors. This mirrors `FFmpegLocator`'s pure +
/// injectable shape.
public enum AudioUnitInventory {

    // MARK: Discovery (live)

    /// All installed Audio Units, adapted to pure descriptors and sorted
    /// (`sorted(_:)`). Uses a wildcard `AudioComponentDescription` (all zero) so
    /// the component manager returns every component. Safe to call off the main
    /// thread; touches no audio hardware (metadata only).
    ///
    /// `componentSource` is injectable so tests can drive the adapt+sort path
    /// without a real registry; production passes the real manager query.
    public static func discover(
        componentSource: () -> [AVAudioUnitComponent] = defaultComponentSource
    ) -> [AudioUnitDescriptor] {
        sorted(componentSource().map(AudioUnitDescriptor.init(component:)))
    }

    /// The real component-manager query (all components). Factored out so
    /// `discover` stays injectable.
    public static func defaultComponentSource() -> [AVAudioUnitComponent] {
        var anyDescription = AudioComponentDescription()
        anyDescription.componentType = 0
        anyDescription.componentSubType = 0
        anyDescription.componentManufacturer = 0
        anyDescription.componentFlags = 0
        anyDescription.componentFlagsMask = 0
        return AVAudioUnitComponentManager.shared().components(matching: anyDescription)
    }

    // MARK: Pure logic (host-testable)

    /// Deterministic ordering: by manufacturer (case-insensitive), then by name
    /// (case-insensitive), then by stable `id` to break exact ties. A stable
    /// order matters for a list UI and for snapshotting selections.
    public static func sorted(_ units: [AudioUnitDescriptor]) -> [AudioUnitDescriptor] {
        units.sorted { a, b in
            let m = a.manufacturerName.localizedCaseInsensitiveCompare(b.manufacturerName)
            if m != .orderedSame { return m == .orderedAscending }
            let n = a.name.localizedCaseInsensitiveCompare(b.name)
            if n != .orderedSame { return n == .orderedAscending }
            return a.id < b.id
        }
    }

    /// Keep only units of the given `kind`. The order of the input is preserved.
    public static func filter(_ units: [AudioUnitDescriptor], kind: AudioUnitDescriptor.Kind) -> [AudioUnitDescriptor] {
        units.filter { $0.kind == kind }
    }

    /// Case-insensitive substring search across name and manufacturer. An empty
    /// (or whitespace-only) query returns the input unchanged.
    public static func search(_ units: [AudioUnitDescriptor], query: String) -> [AudioUnitDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return units }
        return units.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.manufacturerName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Group units by manufacturer name, returning manufacturer-sorted sections
    /// (each section's units kept in input order). Handy for a sectioned plugin
    /// picker.
    public static func groupedByManufacturer(
        _ units: [AudioUnitDescriptor]
    ) -> [(manufacturer: String, units: [AudioUnitDescriptor])] {
        var order: [String] = []
        var buckets: [String: [AudioUnitDescriptor]] = [:]
        for u in units {
            if buckets[u.manufacturerName] == nil { order.append(u.manufacturerName) }
            buckets[u.manufacturerName, default: []].append(u)
        }
        return order
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { (manufacturer: $0, units: buckets[$0] ?? []) }
    }

    /// Resolve a descriptor by its stable `id` (the type/subtype/manufacturer
    /// triple) — used to re-select a persisted plugin choice. `nil` if the saved
    /// plugin is no longer installed.
    public static func descriptor(withID id: String, in units: [AudioUnitDescriptor]) -> AudioUnitDescriptor? {
        units.first { $0.id == id }
    }
}
