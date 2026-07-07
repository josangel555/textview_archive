import Foundation

/// TSK-1478 — the plugins pane's INSTALL / REMOVE lifecycle ops (the
/// registry already owns load/enable/disable/grants). Host-tested on temp
/// dirs; the pane's folder-pick, confirm dialogs, and per-plugin error rows
/// are the render tail.
///
/// Safety posture: `install` VALIDATES the manifest BEFORE copying anything
/// (no code lands in the plugins dir unless plugin.json parses and the
/// version is supported), refuses to overwrite an existing folder, and
/// refuses a duplicate plugin id anywhere in the dir (two folders serving
/// one id = undefined load order). `remove` routes through an injectable
/// remover — the pane's default is Trash (recoverable), never a hard delete.
public enum PluginLifecycle {

    public enum InstallOutcome: Equatable, Sendable {
        /// Copied into the plugins dir; `folder` is the installed location.
        case installed(id: String, folder: String)
        /// The source isn't a valid plugin (missing/unparseable plugin.json,
        /// unsupported manifestVersion, blank id) — nothing was copied.
        case refusedInvalid(reason: String)
        /// A folder with that name — or another folder already serving the
        /// same plugin id — exists; nothing was copied (never overwrite).
        case refusedDuplicate(id: String)
        /// The copy itself failed (IO).
        case failed(String)
    }

    /// Install the plugin folder at `source` into `pluginsDir`.
    public static func install(from source: URL, into pluginsDir: URL) -> InstallOutcome {
        // 1) Validate BEFORE any copy.
        let manifestURL = source.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .refusedInvalid(reason: "missing plugin.json in \(source.lastPathComponent)")
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            return .refusedInvalid(reason: "manifest parse error: \(error.localizedDescription)")
        }
        guard manifest.manifestVersion == 1 else {
            return .refusedInvalid(
                reason: "unsupported manifestVersion \(manifest.manifestVersion)")
        }
        let id = manifest.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return .refusedInvalid(reason: "plugin id is blank")
        }

        // 2) Refuse duplicates: same folder name, or the same id served by
        //    any other installed folder.
        let dest = pluginsDir.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            return .refusedDuplicate(id: id)
        }
        if installedFolder(forID: id, in: pluginsDir) != nil {
            return .refusedDuplicate(id: id)
        }

        // 3) Copy (creating the plugins dir on first install).
        do {
            try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .installed(id: id, folder: dest.path)
    }

    public enum RemoveOutcome: Equatable, Sendable {
        /// The plugin's folder was handed to the remover (Trash by default).
        case removed(id: String, folder: String)
        /// No installed folder serves that id.
        case notFound(id: String)
        /// The remover threw.
        case failed(String)
    }

    /// Remove the installed plugin serving `id`. `remover` receives the
    /// plugin's folder; the pane's default trashes it (recoverable) — tests
    /// inject a recorder/deleter.
    public static func remove(
        id: String,
        from pluginsDir: URL,
        using remover: (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    ) -> RemoveOutcome {
        guard let folder = installedFolder(forID: id, in: pluginsDir) else {
            return .notFound(id: id)
        }
        do {
            try remover(folder)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .removed(id: id, folder: folder.path)
    }

    /// The installed folder whose plugin.json serves `id`, if any.
    public static func installedFolder(forID id: String, in pluginsDir: URL) -> URL? {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir,
                  let data = try? Data(contentsOf: child.appendingPathComponent("plugin.json")),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
            else { continue }
            if manifest.id == id { return child }
        }
        return nil
    }
}
