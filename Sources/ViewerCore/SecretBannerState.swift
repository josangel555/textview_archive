import Foundation

/// Pure, host-testable gating + labelling for the secret warn-badge render slice
/// (TSK-1496). The `SecretWarningBanner` SwiftUI view is a thin shell over this;
/// keeping the decision logic here means the "when does the badge show / what
/// does it say" contract is pinned by unit tests, not by a pixel.
///
/// Treatment is the `mdv.secretTreatment` default (SecretDetector.treatmentDefaultsKey):
/// `0` = warn badge (default), `1` = mask-with-reveal (a later slice — treated as
/// warn for now), `2` = off. The badge shows for anything other than `off`.
public enum SecretBannerState {

    /// Off — the user opted the treatment out entirely.
    public static let treatmentOff = 2

    /// Whether the warn badge should be on screen: the treatment isn't off, at
    /// least one secret was detected, and the user hasn't dismissed this banner.
    public static func shouldShow(findingCount: Int, treatmentRaw: Int, dismissed: Bool) -> Bool {
        treatmentRaw != treatmentOff && findingCount > 0 && !dismissed
    }

    /// Whether a scan should even run — skipped when the treatment is off (no
    /// point paying the scan for a badge that can never show).
    public static func scanEnabled(treatmentRaw: Int) -> Bool {
        treatmentRaw != treatmentOff
    }

    /// The badge headline. Never contains a secret value — the detector only
    /// ever hands us redacted previews, and the count is a plain integer.
    public static func countLabel(_ count: Int) -> String {
        let noun = count == 1 ? "secret" : "secrets"
        return "\(count) potential \(noun) detected — values are hidden"
    }
}
