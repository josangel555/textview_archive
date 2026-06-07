import Foundation

/// Shared POSIX extended-attribute read/replay used by the file writers
/// (`EditorBuffer`'s `ExistingFileMeta`, `HexEditBuffer`'s `HexFileMeta`).
/// Both preserve an existing file's xattrs (quarantine, ACL-as-xattr, …)
/// across an atomic rewrite; the byte-identical `readXattrs` / `readOneXattr`
/// / `setxattr`-replay code was copy-pasted in both (TSK-473). One home now.
enum XattrIO {

    /// One extended attribute: its name and raw value bytes.
    typealias Entry = (name: String, value: Data)

    /// Read every extended attribute off `fd` via `flistxattr`/`fgetxattr`.
    /// `XATTR_NOFOLLOW` is implied by the fd already being opened no-follow.
    /// Quarantine (`com.apple.quarantine`) and any ACL-as-xattr ride along.
    static func read(fd: Int32) -> [Entry] {
        let listLen = flistxattr(fd, nil, 0, 0)
        guard listLen > 0 else { return [] }
        var nameBuf = [CChar](repeating: 0, count: listLen)
        let got = flistxattr(fd, &nameBuf, listLen, 0)
        guard got > 0 else { return [] }

        var result: [Entry] = []
        // The buffer is a sequence of NUL-terminated names. Reinterpret the
        // CChar bytes as UInt8 and split on NUL.
        let raw = nameBuf.prefix(got).map { UInt8(bitPattern: $0) }
        var start = 0
        for i in 0 ..< raw.count where raw[i] == 0 {
            if i > start, let name = String(bytes: raw[start ..< i], encoding: .utf8),
               let value = readOne(fd: fd, name: name) {
                result.append((name: name, value: value))
            }
            start = i + 1
        }
        return result
    }

    /// Read a single attribute's value, or nil if it can't be read.
    static func readOne(fd: Int32, name: String) -> Data? {
        let valLen = fgetxattr(fd, name, nil, 0, 0, 0)
        guard valLen >= 0 else { return nil }
        if valLen == 0 { return Data() }
        var buf = Data(count: valLen)
        let got = buf.withUnsafeMutableBytes { rawBuf in
            fgetxattr(fd, name, rawBuf.baseAddress, valLen, 0, 0)
        }
        guard got >= 0 else { return nil }
        if got < valLen { buf.removeLast(valLen - got) }
        return buf
    }

    /// Best-effort replay of `xattrs` onto `path`. Each step is independent —
    /// a failure to set one attribute must not block the others.
    static func apply(_ xattrs: [Entry], toPath path: String) {
        for attr in xattrs {
            attr.value.withUnsafeBytes { raw in
                _ = setxattr(path, attr.name, raw.baseAddress, raw.count, 0, 0)
            }
        }
    }
}
