import Foundation
import Accelerate

/// A windowed FFT magnitude spectrum over one sample window — the data a
/// frequency-spectrum view draws (bars / heatmap column).
public struct SpectrumBins: Equatable, Sendable {
    /// One magnitude per bin in dB (relative; `floorDB` for silence). Covers
    /// `[0, sampleRate/2)` — `fftSize/2` bins (the Nyquist term is dropped).
    public let magnitudesDB: [Float]
    /// Centre frequency (Hz) of each bin: `i * sampleRate / fftSize`.
    public let binFrequencies: [Float]
    public let sampleRate: Double
    public let fftSize: Int
    /// The dB floor silence/empty bins sit at — the bottom of the magnitude
    /// range. Carried so a renderer can normalise `[floorDB, 0] → [0, 1]`
    /// without hard-coding the analyzer's floor.
    public let floorDB: Float
    /// Hz per bin — the spectral resolution.
    public var binResolution: Double { sampleRate / Double(fftSize) }

    public init(magnitudesDB: [Float], binFrequencies: [Float], sampleRate: Double, fftSize: Int, floorDB: Float) {
        self.magnitudesDB = magnitudesDB
        self.binFrequencies = binFrequencies
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.floorDB = floorDB
    }

    /// Index of the loudest bin (0 if empty) — the dominant frequency component.
    public var peakBin: Int {
        guard var best = magnitudesDB.first else { return 0 }
        var idx = 0
        for (i, v) in magnitudesDB.enumerated() where v > best { best = v; idx = i }
        return idx
    }
}

/// Pure, deterministic frequency analysis (TSK-526): a Hann-windowed real FFT
/// over a sample window → per-bin magnitude in dB, with the sample-rate→bin
/// frequency mapping. Uses Accelerate/vDSP (a system framework — no new deps).
/// SwiftUI-free; the spectrum RENDER is the separate VM-gated viz UI.
public enum SpectrumAnalyzer {

    /// Compute the spectrum of `samples` (truncated / zero-padded to `fftSize`,
    /// which MUST be a power of two ≥ 2). Returns `nil` for an invalid size or
    /// non-positive sample rate. Magnitudes are relative dB, floored at `floorDB`.
    public static func analyze(
        _ samples: [Float],
        sampleRate: Double,
        fftSize: Int = 2048,
        floorDB: Float = -120
    ) -> SpectrumBins? {
        guard fftSize >= 2, (fftSize & (fftSize - 1)) == 0, sampleRate > 0 else { return nil }
        let n = fftSize
        let half = n / 2
        let log2n = vDSP_Length(log2(Double(n)).rounded())

        // Truncate / zero-pad to n, then apply a Hann window.
        var windowed = [Float](repeating: 0, count: n)
        let copyCount = Swift.min(samples.count, n)
        if copyCount > 0 { windowed.replaceSubrange(0..<copyCount, with: samples[0..<copyCount]) }
        var hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(windowed, 1, hann, 1, &windowed, 1, vDSP_Length(n))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                // Pack the real signal into split-complex (even→real, odd→imag).
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                // zrip packs Nyquist in imag[0]; drop it so bin 0 is pure DC.
                ip[0] = 0
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // Normalise + convert to dB, floored.
        let norm = Float(n)
        let floorMag = powf(10, floorDB / 20)   // magnitude that maps to the floor
        var magsDB = [Float](repeating: floorDB, count: half)
        for i in 0..<half {
            let m = mags[i] / norm
            magsDB[i] = m > floorMag ? Swift.max(20 * log10f(m), floorDB) : floorDB
        }

        let freqs = (0..<half).map { Float(Double($0) * sampleRate / Double(n)) }
        return SpectrumBins(magnitudesDB: magsDB, binFrequencies: freqs,
                            sampleRate: sampleRate, fftSize: n, floorDB: floorDB)
    }
}
