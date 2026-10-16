import Foundation

/// One finished tool call, for a session's timeline.
struct Step: Equatable, Sendable, Identifiable, Codable {
    var id = UUID()
    var tool: String
    /// "Editing NotchView.swift", "Running npm test"
    var summary: String
    var at: Date
    /// How long it ran, when the start was seen.
    var duration: TimeInterval?
    var failed = false
    /// What it did to a file, for edits and writes.
    var change: FileChange?
    /// It looked like a test run (`npm test`, `xcodebuild test`, `pytest`…).
    var isTest = false
}

/// Lines added and removed in one file, with the edits themselves for a small diff view.
struct FileChange: Equatable, Sendable, Codable {
    struct Hunk: Equatable, Sendable, Codable {
        var removed: [String]
        var added: [String]
    }

    var path: String
    var added = 0
    var removed = 0
    var hunks: [Hunk] = []

    var name: String { (path as NSString).lastPathComponent }

    /// Folds another change to the same file into this one.
    mutating func merge(_ other: FileChange) {
        added += other.added
        removed += other.removed
        hunks = Array((hunks + other.hunks).suffix(Self.maxHunks))
    }

    static let maxHunks = 12
    static let maxHunkLines = 40

    /// What an edit-style tool call changes, from its input. Nil for tools that don't touch files.
    static func from(tool: String, input: [String: Any]) -> FileChange? {
        guard let path = input["file_path"] as? String ?? input["notebook_path"] as? String else { return nil }
        func hunk(_ old: String?, _ new: String?) -> Hunk {
            Hunk(removed: lines(old), added: lines(new))
        }
        var hunks: [Hunk]
        switch tool {
        case "Edit":
            hunks = [hunk(input["old_string"] as? String, input["new_string"] as? String)]
        case "MultiEdit":
            hunks = (input["edits"] as? [[String: Any]] ?? []).map { hunk($0["old_string"] as? String, $0["new_string"] as? String) }
        case "Write":
            hunks = [hunk(nil, input["content"] as? String)]
        case "NotebookEdit":
            hunks = [hunk(nil, input["new_source"] as? String)]
        default:
            return nil
        }
        // Lines common to both sides of a hunk aren't changes; count only what differs.
        var change = FileChange(path: path)
        for var h in hunks {
            let (removed, added) = difference(h.removed, h.added)
            change.removed += removed.count
            change.added += added.count
            h.removed = Array(removed.prefix(maxHunkLines))
            h.added = Array(added.prefix(maxHunkLines))
            change.hunks.append(h)
        }
        change.hunks = Array(change.hunks.suffix(maxHunks))
        return change
    }

    static func lines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    /// Lines only in `old`, and lines only in `new`, after trimming the shared start and end.
    static func difference(_ old: [String], _ new: [String]) -> (removed: [String], added: [String]) {
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] { oldEnd -= 1; newEnd -= 1 }
        return (Array(old[start..<oldEnd]), Array(new[start..<newEnd]))
    }
}

enum TestRun {
    /// Commands that look like a test run, across common toolchains.
    static func isTest(command: String) -> Bool {
        let patterns = [#"\bxcodebuild\b.*\btest\b"#, #"\bswift test\b"#, #"\b(npm|pnpm|yarn|bun)( run)? test\b"#,
                        #"\bpytest\b"#, #"\bgo test\b"#, #"\bcargo test\b"#, #"\bjest\b"#, #"\bvitest\b"#,
                        #"\brspec\b"#, #"\bmix test\b"#, #"\bgradlew?\b.*\btest\b"#, #"\bmake test\b"#]
        return patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
    }
}
