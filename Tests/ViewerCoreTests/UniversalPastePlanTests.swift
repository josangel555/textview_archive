import Testing
@testable import ViewerCore

/// Host coverage for the Universal Paste materialization plan (TSK-1163). The
/// AppKit shell (read bytes, write temp, open) is the VM tail; this is the
/// host-validated decision — target → how to materialize an openable file.
struct UniversalPastePlanTests {

    @Test func fileURL_usesDirectURL_noTempFile() {
        #expect(UniversalPastePlan.plan(for: .fileURL).source == .fileURL)
    }

    @Test func image_prefersPNG_fallbackTIFF_pngExtension() {
        guard case let .data(type, fallbacks, ext) = UniversalPastePlan.plan(for: .image).source
        else { Issue.record("expected .data"); return }
        #expect(type == "public.png")
        #expect(fallbacks.contains("public.tiff"))
        #expect(ext == "png")
    }

    @Test func table_readsTSV_tsvExtension() {
        guard case let .data(type, _, ext) = UniversalPastePlan.plan(for: .table).source
        else { Issue.record("expected .data"); return }
        #expect(type == "public.tab-separated-values-text")
        #expect(ext == "tsv")
    }

    @Test func richText_readsRTF_rtfExtension() {
        guard case let .data(type, _, ext) = UniversalPastePlan.plan(for: .richText).source
        else { Issue.record("expected .data"); return }
        #expect(type == "public.rtf")
        #expect(ext == "rtf")
    }

    @Test func plainText_readsString_txtExtension() {
        guard case let .string(ext) = UniversalPastePlan.plan(for: .plainText).source
        else { Issue.record("expected .string"); return }
        #expect(ext == "txt")
    }

    @Test func everyTargetHasAPlan_noDefaultGap() {
        // Exhaustive: every PasteTarget maps to a plan (a new case must add one).
        for t in PasteDispatch.PasteTarget.allCases {
            _ = UniversalPastePlan.plan(for: t)
        }
    }

    @Test func materializedTargets_haveNonEmptyExtension() {
        for t in PasteDispatch.PasteTarget.allCases {
            switch UniversalPastePlan.plan(for: t).source {
            case .fileURL: break
            case .data(_, _, let ext), .string(let ext): #expect(!ext.isEmpty)
            }
        }
    }
}
