import SwiftUI
import ViewerCore

/// Hex + ASCII viewer for binary files. Bytes-per-row is computed from the
/// viewport width and snapped to a meaningful power-of-two-ish step
/// (8 / 16 / 32 / 64) so the layout reads as a clean grid rather than a
/// fractional column count.
struct HexView: View {
    let file: BinaryFile
    let fontSize: CGFloat

    @State private var bytesPerRow: Int = 16

    private static let bytesPerRowSteps = [8, 16, 24, 32, 48, 64]
    private static let charWidthFactor: CGFloat = 0.605  // monospaced

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if file.isTruncated {
                        HexHeader(file: file, fontSize: fontSize)
                        Divider()
                    }
                    ForEach(rowOffsets(), id: \.self) { offset in
                        HexRow(
                            offset: offset,
                            bytes: bytes(startingAt: offset),
                            bytesPerRow: bytesPerRow,
                            fontSize: fontSize
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear {
                bytesPerRow = computeBytesPerRow(width: geo.size.width)
            }
            .onChange(of: geo.size.width) { _, w in
                bytesPerRow = computeBytesPerRow(width: w)
            }
            .onChange(of: fontSize) { _, _ in
                bytesPerRow = computeBytesPerRow(width: geo.size.width)
            }
        }
    }

    private func rowOffsets() -> [Int] {
        stride(from: 0, to: file.byteCount, by: bytesPerRow).map { $0 }
    }

    private func bytes(startingAt offset: Int) -> [UInt8] {
        let end = min(offset + bytesPerRow, file.byteCount)
        return Array(file.data[offset..<end])
    }

    /// Choose the largest steps-table entry that fits the available width.
    /// Layout: 8-char offset | space | N × "XX " hex column | space | N ASCII.
    /// Per-byte cost ≈ 4 chars (3 hex + space averaged, then 1 ASCII).
    private func computeBytesPerRow(width: CGFloat) -> Int {
        let charW = fontSize * Self.charWidthFactor
        let chrome: CGFloat = (8 + 4) * charW  // offset + separators + padding
        let perByte: CGFloat = 4 * charW
        let fits = Int(max(width - chrome, 0) / perByte)
        var snap = Self.bytesPerRowSteps.first ?? 8
        for c in Self.bytesPerRowSteps where c <= fits {
            snap = c
        }
        return snap
    }
}

private struct HexHeader: View {
    let file: BinaryFile
    let fontSize: CGFloat
    var body: some View {
        Text("Showing first \(file.byteCount) of \(file.totalByteCount) bytes")
            .font(.system(size: fontSize - 1, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }
}

private struct HexRow: View {
    let offset: Int
    let bytes: [UInt8]
    let bytesPerRow: Int
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 16) {
            Text(String(format: "%08x", offset))
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(hexColumn)
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
            Text(asciiColumn)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .lineLimit(1)
    }

    /// Hex bytes separated by single spaces, padded with two spaces for any
    /// missing bytes on the last row so the ASCII column stays aligned.
    private var hexColumn: String {
        var s = ""
        for i in 0..<bytesPerRow {
            if i < bytes.count {
                s += String(format: "%02x", bytes[i])
            } else {
                s += "  "
            }
            if i != bytesPerRow - 1 { s += " " }
        }
        return s
    }

    private var asciiColumn: String {
        String(bytes.map { byte -> Character in
            (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
        })
    }
}
