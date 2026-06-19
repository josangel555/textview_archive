import Foundation

/// Parses an open project's manifests into a normalized `[RunnableTask]`.
/// PURE host logic — the only side effect is READING manifest files (no spawn,
/// no network). Each manifest gets its own small parser; unknown/invalid input
/// is skipped (never throws to the caller — a malformed `package.json` simply
/// yields no npm tasks). Foundation slice for the task/command runner (TSK-722).
///
/// Scope of this slice: parses the manifests found directly in `projectRoot`
/// (non-recursive). Workspace/monorepo recursion is deferred to the epic tail.
public enum RunnableTaskDiscovery {

    /// Discover all runnable tasks at `projectRoot`. Order is deterministic and
    /// grouped by source: package.json scripts (manifest order preserved via the
    /// raw-key scan), then Cargo, then Makefile, then common test commands. The
    /// result is de-duplicated by `RunnableTask.id` (first occurrence wins).
    public static func discover(
        projectRoot: URL,
        fileManager: FileManager = .default
    ) -> [RunnableTask] {
        var tasks: [RunnableTask] = []
        tasks += packageJsonTasks(projectRoot: projectRoot, fileManager: fileManager)
        tasks += cargoTasks(projectRoot: projectRoot, fileManager: fileManager)
        tasks += makefileTasks(projectRoot: projectRoot, fileManager: fileManager)
        tasks += commonTestCommandTasks(projectRoot: projectRoot, fileManager: fileManager)

        // De-dupe by id, first occurrence wins (preserves source grouping order).
        var seen = Set<String>()
        return tasks.filter { seen.insert($0.id).inserted }
    }

    // MARK: - package.json

    /// Each key under top-level `"scripts"` → an `npm run <name>` task. JSON
    /// objects don't preserve key order, so we recover the author's declared
    /// order by scanning the raw text for `"<key>"` occurrences inside the
    /// scripts block — the picker should list scripts the way the file does.
    static func packageJsonTasks(
        projectRoot: URL,
        fileManager: FileManager
    ) -> [RunnableTask] {
        let url = projectRoot.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = obj["scripts"] as? [String: Any], !scripts.isEmpty
        else { return [] }

        let text = String(data: data, encoding: .utf8) ?? ""
        let ordered = orderedScriptKeys(declaredKeys: Array(scripts.keys), in: text)

        return ordered.map { name in
            RunnableTask(
                name: name,
                command: "npm",
                arguments: ["run", name],
                workingDirectory: projectRoot,
                source: .packageJson
            )
        }
    }

    /// Best-effort recovery of declared key order: sort the known script keys by
    /// the byte offset of their first `"<key>"` appearance in the source text.
    /// Keys not located (shouldn't happen for valid JSON) fall to the end in
    /// alphabetical order so output stays deterministic.
    private static func orderedScriptKeys(declaredKeys: [String], in text: String) -> [String] {
        func firstOffset(of key: String) -> Int? {
            let needle = "\"\(key)\""
            guard let range = text.range(of: needle) else { return nil }
            return text.distance(from: text.startIndex, to: range.lowerBound)
        }
        return declaredKeys.sorted { a, b in
            switch (firstOffset(of: a), firstOffset(of: b)) {
            case let (oa?, ob?): return oa < ob
            case (_?, nil):      return true
            case (nil, _?):      return false
            case (nil, nil):     return a < b
            }
        }
    }

    // MARK: - Cargo.toml

    /// A Cargo workspace gets two kinds of tasks:
    ///   • `cargo test` (always — every cargo crate is testable),
    ///   • one `cargo run --bin <name>` per `[[bin]]` table with a `name`.
    /// A crate with no explicit `[[bin]]` still has the implicit binary, but we
    /// only surface what's declared (the implicit one is covered by a plain
    /// `cargo run`, which we add when a `[package]` exists and no bins are
    /// declared). TOML is parsed with a minimal line scanner — enough for
    /// `[[bin]]`/`name = "…"`/`[package]`, NOT a general TOML parser.
    static func cargoTasks(
        projectRoot: URL,
        fileManager: FileManager
    ) -> [RunnableTask] {
        let url = projectRoot.appendingPathComponent("Cargo.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var tasks: [RunnableTask] = []
        var hasPackage = false
        var binNames: [String] = []
        var inBinTable = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripTomlComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line == "[package]" { hasPackage = true; inBinTable = false; continue }
            if line == "[[bin]]" { inBinTable = true; continue }
            // Any other section header ends the current bin table.
            if line.hasPrefix("[") { inBinTable = false; continue }

            if inBinTable, let name = tomlStringValue(forKey: "name", in: line) {
                binNames.append(name)
            }
        }

        guard hasPackage || !binNames.isEmpty else { return [] }

        // `cargo test` first.
        tasks.append(RunnableTask(
            name: "test",
            command: "cargo",
            arguments: ["test"],
            workingDirectory: projectRoot,
            source: .cargo
        ))

        if binNames.isEmpty {
            // Implicit binary (or lib-only crate — harmless `cargo run` either way).
            tasks.append(RunnableTask(
                name: "run",
                command: "cargo",
                arguments: ["run"],
                workingDirectory: projectRoot,
                source: .cargo
            ))
        } else {
            for bin in binNames {
                tasks.append(RunnableTask(
                    name: "run \(bin)",
                    command: "cargo",
                    arguments: ["run", "--bin", bin],
                    workingDirectory: projectRoot,
                    source: .cargo
                ))
            }
        }
        return tasks
    }

    /// Drop a trailing `#…` comment from a TOML line (respecting `#` inside a
    /// double-quoted string — `name = "a#b"` keeps the `#`).
    private static func stripTomlComment(_ line: String) -> String {
        var inString = false
        var result = ""
        for ch in line {
            if ch == "\"" { inString.toggle() }
            if ch == "#" && !inString { break }
            result.append(ch)
        }
        return result
    }

    /// Extract a double-quoted value for `key` from a `key = "value"` TOML line,
    /// or nil if the line isn't that assignment.
    private static func tomlStringValue(forKey key: String, in line: String) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespaces) == key
        else { return nil }
        let rhs = parts[1].trimmingCharacters(in: .whitespaces)
        guard rhs.hasPrefix("\""), rhs.hasSuffix("\""), rhs.count >= 2 else { return nil }
        return String(rhs.dropFirst().dropLast())
    }

    // MARK: - Makefile

    /// Each non-pattern, non-special target → a `make <target>` task. A target
    /// line is `name: prereqs` at column 0 (recipe lines are TAB-indented and
    /// skipped). We skip:
    ///   • `.PHONY`/`.SUFFIXES`/etc. dot-targets (special targets),
    ///   • pattern rules (`%`-containing) and the static-pattern `:` form,
    ///   • variable assignments (`FOO := …`, `FOO = …`, `FOO ::= …`, `FOO ?= …`,
    ///     `FOO += …`).
    /// `.PHONY` *declared* names are NOT auto-added; only real target lines are.
    static func makefileTasks(
        projectRoot: URL,
        fileManager: FileManager
    ) -> [RunnableTask] {
        // Both common casings; `Makefile` wins if both exist.
        let candidates = ["Makefile", "makefile", "GNUmakefile"]
        let url = candidates
            .map { projectRoot.appendingPathComponent($0) }
            .first { fileManager.fileExists(atPath: $0.path) }
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var tasks: [RunnableTask] = []
        var seen = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // Recipe lines are TAB-indented — not targets.
            if line.hasPrefix("\t") { continue }
            guard let name = makefileTargetName(in: line), seen.insert(name).inserted else { continue }
            tasks.append(RunnableTask(
                name: name,
                command: "make",
                arguments: [name],
                workingDirectory: projectRoot,
                source: .makefile
            ))
        }
        return tasks
    }

    /// Extract a runnable target name from a Makefile line, or nil if the line
    /// isn't a plain target rule we want to surface.
    private static func makefileTargetName(in line: String) -> String? {
        // Strip comment.
        let noComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
        let trimmed = noComment.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }

        // Must contain a `:` to be a rule.
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }

        // Reject variable assignments: `=`, `:=`, `::=`, `?=`, `+=` before/at `:`.
        // Check the char before/after the colon and for `=` ahead of the colon.
        let head = String(trimmed[trimmed.startIndex..<colon])
        if head.contains("=") || head.contains("?") || head.contains("+") { return nil }
        let afterColonIdx = trimmed.index(after: colon)
        if afterColonIdx < trimmed.endIndex {
            let after = trimmed[afterColonIdx]
            // `:=` (simple) and `::=` (POSIX immediate) assignments both have a
            // non-space operator char right after the first colon.
            if after == "=" || after == ":" { return nil }
        }

        let target = head.trimmingCharacters(in: .whitespaces)
        if target.isEmpty { return nil }
        // Skip special dot-targets and pattern rules and multi-target lines.
        if target.hasPrefix(".") { return nil }
        if target.contains("%") { return nil }
        if target.contains(" ") { return nil }   // multiple targets — skip (ambiguous)
        if target.contains("$") { return nil }    // variable-expanded target name
        return target
    }

    // MARK: - Common test commands (heuristic fallback)

    /// When a project advertises a well-known test runner via a sentinel file
    /// but no manifest task covers it, surface a sensible default. Conservative
    /// by design — only fires on unambiguous markers:
    ///   • `pytest.ini` / `tox.ini` / `setup.py` (and no package.json/Cargo) → `pytest`
    ///   • `go.mod` → `go test ./...`
    /// These are LAST so a manifest-declared task with the same name wins the
    /// de-dupe.
    static func commonTestCommandTasks(
        projectRoot: URL,
        fileManager: FileManager
    ) -> [RunnableTask] {
        var tasks: [RunnableTask] = []
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: projectRoot.appendingPathComponent(name).path)
        }

        if exists("pytest.ini") || exists("tox.ini") || exists("pyproject.toml") || exists("setup.py") {
            tasks.append(RunnableTask(
                name: "pytest",
                command: "pytest",
                arguments: [],
                workingDirectory: projectRoot,
                source: .commonTestCommand
            ))
        }
        if exists("go.mod") {
            tasks.append(RunnableTask(
                name: "go test",
                command: "go",
                arguments: ["test", "./..."],
                workingDirectory: projectRoot,
                source: .commonTestCommand
            ))
        }
        return tasks
    }
}
