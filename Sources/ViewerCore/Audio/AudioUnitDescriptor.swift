import Foundation
import AVFoundation
import AudioToolbox

/// A pure, value-type description of one installed Audio Unit (TSK-956). Audio
/// Units are Apple's native audio plugin format — effects, instruments,
/// generators, etc. — discovered through `AVAudioUnitComponentManager`. This
/// struct is the host-testable model: it carries everything the UI needs to
/// list/describe/select a plugin WITHOUT holding a live `AVAudioUnitComponent`
/// (which can only be created by the real component manager), so the
/// discovery/filter/sort/select logic is exercisable on the headless host.
///
/// Built directly in tests, or adapted from a real component via
/// `init(component:)`. No audio hardware or `AVAudioSession` is touched by
/// constructing one — this is metadata only; instantiating the actual plugin
/// (and its UI) is the VM-wired step.
public struct AudioUnitDescriptor: Sendable, Equatable, Hashable, Codable, Identifiable {

    /// The coarse role of the Audio Unit, derived from its OSType component
    /// `type`. We map the common `kAudioUnitType_*` values to a stable,
    /// `Codable` enum so the UI can group/filter by role without re-deriving the
    /// four-char-code semantics, and so an unknown/rare type degrades to
    /// `.other` rather than being dropped.
    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        case effect          // aufx — insert effect (EQ, reverb, …)
        case musicEffect     // aumf — effect that also receives MIDI
        case instrument      // aumu — MIDI-driven instrument / synth
        case generator       // augn — audio generator (no input)
        case mixer           // aumx — mixer
        case panner          // aupn — panner
        case offlineEffect   // auol — offline (non-realtime) effect
        case formatConverter // aufc — format converter
        case output          // auou — output unit
        case other           // anything not in the list above

        /// Map a raw component `type` OSType to a `Kind`.
        public static func from(componentType: OSType) -> Kind {
            switch componentType {
            case kAudioUnitType_Effect:          return .effect
            case kAudioUnitType_MusicEffect:     return .musicEffect
            case kAudioUnitType_MusicDevice:     return .instrument
            case kAudioUnitType_Generator:       return .generator
            case kAudioUnitType_Mixer:           return .mixer
            case kAudioUnitType_Panner:          return .panner
            case kAudioUnitType_OfflineEffect:   return .offlineEffect
            case kAudioUnitType_FormatConverter: return .formatConverter
            case kAudioUnitType_Output:          return .output
            default:                             return .other
            }
        }
    }

    /// Stable identity for the plugin: the three OSType codes that uniquely key
    /// an Audio Unit (type / subtype / manufacturer). Two AUs with the same
    /// triple are the same plugin; this is what we'd persist to remember a
    /// user's selection across launches.
    public var id: String {
        let t = AudioUnitDescriptor.fourCC(componentType)
        let s = AudioUnitDescriptor.fourCC(componentSubType)
        let m = AudioUnitDescriptor.fourCC(manufacturer)
        return "\(t)-\(s)-\(m)"
    }

    /// Human-readable name, e.g. "Apple: AUReverb2" (the component's `name`).
    public let name: String

    /// The plugin vendor, e.g. "Apple" (the component's `manufacturerName`).
    public let manufacturerName: String

    /// Free-form version string, e.g. "1.0.0" (the component's
    /// `versionString`); may be empty if the component reports none.
    public let versionString: String

    /// Raw OSType component identity (kept so the UI can reconstruct an
    /// `AudioComponentDescription` to instantiate the AU on the VM side).
    public let componentType: OSType
    public let componentSubType: OSType
    public let manufacturer: OSType

    /// Derived role used for grouping/filtering.
    public let kind: Kind

    /// Whether the plugin ships its own Cocoa view (an AU GUI). Effects without
    /// one fall back to a generic parameter view; the UI can surface this.
    public let hasCustomView: Bool

    /// Whether the component is sandbox-safe (`isSandboxSafe`). A non-sandbox-
    /// safe AU cannot load inside an App-Sandboxed host — surfaced so the UI can
    /// warn / disable it rather than fail opaquely at instantiation.
    public let isSandboxSafe: Bool

    public init(
        name: String,
        manufacturerName: String,
        versionString: String,
        componentType: OSType,
        componentSubType: OSType,
        manufacturer: OSType,
        hasCustomView: Bool = false,
        isSandboxSafe: Bool = true
    ) {
        self.name = name
        self.manufacturerName = manufacturerName
        self.versionString = versionString
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.manufacturer = manufacturer
        self.kind = Kind.from(componentType: componentType)
        self.hasCustomView = hasCustomView
        self.isSandboxSafe = isSandboxSafe
    }

    /// Adapt a live `AVAudioUnitComponent` into the pure descriptor. Reads only
    /// metadata properties (no instantiation), so it stays cheap and host-safe
    /// where real components exist.
    public init(component: AVAudioUnitComponent) {
        let desc = component.audioComponentDescription
        self.init(
            name: component.name,
            manufacturerName: component.manufacturerName,
            versionString: component.versionString,
            componentType: desc.componentType,
            componentSubType: desc.componentSubType,
            manufacturer: desc.componentManufacturer,
            hasCustomView: component.hasCustomView,
            isSandboxSafe: component.isSandboxSafe
        )
    }

    /// Reconstruct the `AudioComponentDescription` needed to instantiate this AU
    /// (the VM-wired step). `componentFlags`/`componentFlagsMask` are zero —
    /// matching how `AVAudioUnit.instantiate(with:options:)` is typically called
    /// from a discovered descriptor.
    public var audioComponentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    /// Render an OSType as its four-char-code string (e.g. `0x61756678` → "aufx"),
    /// falling back to a hex form when the bytes aren't printable ASCII. Used for
    /// the stable `id` and for diagnostics.
    static func fourCC(_ code: OSType) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        // Printable ASCII (space..~) → the literal four-char code; otherwise hex.
        if bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
            return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
        }
        return String(format: "0x%08X", code)
    }
}
