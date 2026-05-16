#!/usr/bin/env swift
// Build an .icns by concatenating PNGs verbatim. Apple's `iconutil`
// recompresses each PNG with its default (uncompressed) ImageIO
// settings, throwing away the work of oxipng/pngcrush on the input
// PNGs. Hand-rolled writer keeps the optimized bytes — typical
// savings: ~40% off the .icns size.
//
// Format (per Apple's IconStorage docs):
//   ┌──────────┬────────────────────────────┐
//   │  icns    │ 4-byte ASCII magic         │
//   │  <size>  │ 4-byte big-endian total    │
//   ├──────────┴────────────────────────────┤
//   │  Element 1: <4-byte OSType>           │
//   │             <4-byte big-endian size>  │  ← includes the 8-byte header
//   │             <PNG bytes>               │
//   ├──────────┬────────────────────────────┤
//   │  Element N: …                         │
//   └───────────────────────────────────────┘
//
// OSTypes for PNG-payload elements:
//   ic07: 128×128       ic08: 256×256       ic09: 512×512
//   ic10: 1024×1024     ic11: 16×16@2x      ic12: 32×32@2x
//   ic13: 128×128@2x    ic14: 256×256@2x    icp4: 16×16
//   icp5: 32×32
//
// Usage: swift pack-icns.swift <iconset-dir> <output.icns>

import Foundation

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(msg)\n".utf8))
    exit(2)
}

let args = CommandLine.arguments
guard args.count == 3 else { die("usage: \(args[0]) <iconset-dir> <output.icns>") }

let iconsetDir = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

// Filename → OSType (4-char ASCII).
let map: [(String, String)] = [
    ("icon_16x16.png",      "icp4"),
    ("icon_16x16@2x.png",   "ic11"),
    ("icon_32x32.png",      "icp5"),
    ("icon_32x32@2x.png",   "ic12"),
    ("icon_128x128.png",    "ic07"),
    ("icon_128x128@2x.png", "ic13"),
    ("icon_256x256.png",    "ic08"),
    ("icon_256x256@2x.png", "ic14"),
    ("icon_512x512.png",    "ic09"),
    ("icon_512x512@2x.png", "ic10"),
]

func bigEndianUInt32(_ v: UInt32) -> Data {
    var be = v.bigEndian
    return Data(bytes: &be, count: 4)
}

var elements = Data()
for (filename, osType) in map {
    let url = iconsetDir.appendingPathComponent(filename)
    guard let png = try? Data(contentsOf: url) else {
        die("missing PNG: \(url.path)")
    }
    let osTypeBytes = Data(osType.utf8)
    precondition(osTypeBytes.count == 4, "OSType must be exactly 4 ASCII chars")
    elements.append(osTypeBytes)
    elements.append(bigEndianUInt32(UInt32(png.count + 8)))
    elements.append(png)
}

let totalSize = UInt32(8 + elements.count)
var icns = Data()
icns.append(Data("icns".utf8))
icns.append(bigEndianUInt32(totalSize))
icns.append(elements)

try icns.write(to: outURL)
FileHandle.standardError.write(Data("packed \(icns.count) bytes → \(outURL.path)\n".utf8))
