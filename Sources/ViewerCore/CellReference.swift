import Foundation

/// TSK-673 — A1-style cell addressing for the sheet/CSV formula engine.
///
/// A spreadsheet addresses cells by a column letter run plus a 1-based row
/// number (`A1`, `B12`, `AA3`, `ZZ100`). Internally the grid is 0-based
/// `(row, column)`, so this is the pure, host-testable bijection between the
/// user-facing `A1` text and the grid's integer coordinates.
///
/// Column letters are **bijective base-26** (NOT plain base-26): `A…Z` =
/// 1…26, `AA` = 27, `AB` = 28, … `AZ` = 52, `BA` = 53. There is no "zero
/// digit", which is why `Z` (26) rolls to `AA` (27) rather than to a
/// two-letter form of 26. The conversion handles that off-by-one explicitly.
///
/// Parsing is intentionally strict and side-effect-free: it accepts ONLY a
/// `[A-Za-z]+[0-9]+` run (case-insensitive letters, normalized to upper) with
/// no `$` absolute markers, no sheet qualifiers, and no surrounding
/// whitespace. The formula tokenizer trims/uppercases before handing text
/// here, so this stays a clean value type the rest of the engine can rely on.
public struct CellReference: Hashable, Sendable, Comparable {

    /// 0-based row index into the grid (A1 → row 0).
    public let row: Int
    /// 0-based column index into the grid (A1 → column 0).
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    // MARK: - Column letters ⇄ index (bijective base-26)

    /// Convert a 0-based column index to its A1 letters: 0 → "A", 25 → "Z",
    /// 26 → "AA", 701 → "ZZ", 702 → "AAA". Negative indices yield "" (the
    /// engine never addresses a negative column, but we stay total).
    public static func columnLetters(_ index: Int) -> String {
        guard index >= 0 else { return "" }
        var n = index + 1               // shift to 1-based for bijective base-26
        var letters = [Character]()
        while n > 0 {
            let rem = (n - 1) % 26      // 0…25 → A…Z
            letters.append(Character(UnicodeScalar(UInt8(65 + rem))))
            n = (n - 1) / 26
        }
        return String(letters.reversed())
    }

    /// Convert a run of A1 column letters to its 0-based index, or nil if the
    /// run contains a non-letter or is empty. Case-insensitive ("a" == "A").
    /// "A" → 0, "Z" → 25, "AA" → 26, "ZZ" → 701.
    public static func columnIndex(fromLetters letters: some StringProtocol) -> Int? {
        guard !letters.isEmpty else { return nil }
        var n = 0
        for ch in letters {
            guard let v = letterValue(ch) else { return nil }
            // Overflow guard: a column run longer than the grid could ever hold
            // can't multiply past Int.max here in practice, but keep it total.
            let (mul, ovf1) = n.multipliedReportingOverflow(by: 26)
            guard !ovf1 else { return nil }
            let (add, ovf2) = mul.addingReportingOverflow(v)
            guard !ovf2 else { return nil }
            n = add
        }
        return n - 1                    // back to 0-based
    }

    /// 1…26 for A/a…Z/z, nil otherwise.
    private static func letterValue(_ ch: Character) -> Int? {
        guard let ascii = ch.asciiValue else { return nil }
        switch ascii {
        case 65...90:  return Int(ascii - 65) + 1   // A–Z
        case 97...122: return Int(ascii - 97) + 1   // a–z
        default:       return nil
        }
    }

    // MARK: - A1 text ⇄ reference

    /// The canonical A1 string for this reference (uppercase letters + 1-based
    /// row), e.g. `(row: 0, column: 0)` → "A1". A negative coordinate clamps to
    /// the "" / 1 edge rather than producing garbage; the engine never builds a
    /// negative reference, so this is only a totality guard.
    public var a1: String {
        let letters = Self.columnLetters(column)
        return "\(letters)\(max(0, row) + 1)"
    }

    /// Parse an A1 reference from `text` (e.g. "A1", "bc42"). Requires exactly
    /// one or more letters followed by one or more digits, nothing else.
    /// Returns nil for malformed input ("1A", "A", "12", "A 1", "$A$1", "").
    public init?(a1 text: some StringProtocol) {
        // Find the letter/digit boundary in a single pass; reject empties and
        // anything that isn't letters-then-digits.
        var splitIndex = text.startIndex
        var sawLetter = false
        var i = text.startIndex
        while i < text.endIndex, text[i].isLetterASCII {
            sawLetter = true
            i = text.index(after: i)
        }
        splitIndex = i
        guard sawLetter, splitIndex < text.endIndex else { return nil }

        let letters = text[text.startIndex..<splitIndex]
        let digits = text[splitIndex...]
        guard digits.allSatisfy({ $0.isASCIIDigit }) else { return nil }
        guard let col = Self.columnIndex(fromLetters: letters) else { return nil }
        guard let oneBasedRow = Int(digits), oneBasedRow >= 1 else { return nil }

        self.row = oneBasedRow - 1
        self.column = col
    }

    // MARK: - Comparable (row-major: useful for stable range iteration)

    public static func < (lhs: CellReference, rhs: CellReference) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// An A1 range like `A1:B3` — an inclusive rectangle of cells. The two corners
/// are normalized so `top`/`left` are the minima and `bottom`/`right` the
/// maxima regardless of which order the user typed them (`B3:A1` == `A1:B3`).
public struct CellRange: Hashable, Sendable {
    public let top: Int
    public let left: Int
    public let bottom: Int
    public let right: Int

    public init(_ a: CellReference, _ b: CellReference) {
        self.top = min(a.row, b.row)
        self.bottom = max(a.row, b.row)
        self.left = min(a.column, b.column)
        self.right = max(a.column, b.column)
    }

    /// Number of cells the rectangle covers.
    public var count: Int { (bottom - top + 1) * (right - left + 1) }

    /// All cell references in the rectangle, row-major (top→bottom, left→right).
    /// Used by range-aware functions (SUM/AVERAGE/…) to walk the rectangle.
    public var cells: [CellReference] {
        var out = [CellReference]()
        out.reserveCapacity(count)
        for r in top...bottom {
            for c in left...right {
                out.append(CellReference(row: r, column: c))
            }
        }
        return out
    }
}

extension Character {
    /// ASCII letter A–Z / a–z (no Unicode letters — formula refs are ASCII).
    var isLetterASCII: Bool {
        guard let a = asciiValue else { return false }
        return (65...90).contains(a) || (97...122).contains(a)
    }
    /// ASCII digit 0–9.
    var isASCIIDigit: Bool {
        guard let a = asciiValue else { return false }
        return (48...57).contains(a)
    }
}
