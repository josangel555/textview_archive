import Foundation

/// Follows an externally-renamed file by inode (TSK-929). A single-file watcher
/// learns the file "disappeared" from its path but not where it went; if the
/// file was renamed/moved WITHIN its folder, the same inode is still there under
/// a new name. Matching the captured inode against the folder's current entries
/// recovers the new path so the open tab can follow the rename instead of
/// showing "file not found". Returns nil for a true delete or a move OUT of the
/// folder. Host-testable against a real temp dir.
public enum RenameFollower {

    public static func findRenamed(inode: Int, inDirectory directory: URL) -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names {
            let entry = directory.appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: entry.path),
               (attrs[.systemFileNumber] as? Int) == inode {
                return entry
            }
        }
        return nil
    }

    /// The inode of `url`, or nil when it can't be stat'd (gone / unreadable).
    public static func inode(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int
    }
}
