import Foundation
import Observation

/// A guardrail: what to do with a permission prompt for a tool whose target matches a pattern.
struct Rule: Codable, Equatable, Identifiable, Sendable {
    enum Action: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Answer Allow at once, without showing the prompt.
        case allow
        /// Answer Deny at once, telling Claude a rule blocked it.
        case deny
        /// Always ask, even if an allow rule matches too.
        case ask

        var id: Self { self }
        var title: String {
            switch self {
            case .allow: "Allow"
            case .deny: "Deny"
            case .ask: "Always ask"
            }
        }
    }

    var id = UUID()
    /// A tool name ("Bash", "Edit", "mcp__github__create_pr"), or "*" for any tool.
    var tool: String
    /// Matched against the command, file path or URL. `*` matches anything, `?` one character; "*" alone, any target.
    var pattern: String
    var action: Action
    var enabled = true

    var summary: String {
        let target = pattern == "*" || pattern.isEmpty ? "" : " \(pattern)"
        return "\(action.title): \(tool == "*" ? "any tool" : tool)\(target)"
    }
}

/// Decides permission prompts by rule before they're held for the user. Pure, so it's tested.
enum PolicyEngine {
    /// What a rule matches against for each kind of tool.
    static func target(of request: PermissionRequest) -> String {
        let input = (try? JSONSerialization.jsonObject(with: request.input)) as? [String: Any] ?? [:]
        for key in ["command", "file_path", "notebook_path", "path", "url", "pattern", "query"] {
            if let value = input[key] as? String { return value }
        }
        return ""
    }

    /// The rule that decides this request, if any. Questions are never decided by rule. A matching "ask" wins over
    /// everything, then "deny", then "allow".
    static func decide(_ request: PermissionRequest, rules: [Rule]) -> Rule? {
        guard !request.isQuestion else { return nil }
        let target = target(of: request)
        let matching = rules.filter { $0.enabled && matches($0, tool: request.tool, target: target) }
        for action in [Rule.Action.ask, .deny, .allow] {
            if let rule = matching.first(where: { $0.action == action }) { return rule }
        }
        return nil
    }

    static func matches(_ rule: Rule, tool: String, target: String) -> Bool {
        guard rule.tool == "*" || rule.tool == tool else { return false }
        let pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
        return pattern.isEmpty || pattern == "*" || glob(pattern, matches: target)
    }

    /// Shell-style matching over the whole target: `*` is any run of characters (slashes included), `?` is one.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Starting points offered in Settings.
    static let presets: [(title: String, rules: [Rule])] = [
        ("Allow reading and searching", ["Read", "Glob", "Grep", "LS"].map { Rule(tool: $0, pattern: "*", action: .allow) }),
        ("Allow git status, diff and log", ["git status*", "git diff*", "git log*"].map { Rule(tool: "Bash", pattern: $0, action: .allow) }),
        ("Always ask before git push", [Rule(tool: "Bash", pattern: "git push*", action: .ask)]),
        ("Always ask about .env files", [Rule(tool: "*", pattern: "*.env*", action: .ask)]),
        ("Deny rm -rf", [Rule(tool: "Bash", pattern: "*rm -rf*", action: .deny)]),
    ]
}

/// The user's rules, saved as JSON in Application Support.
@MainActor @Observable
final class RuleStore {
    static let shared = RuleStore()

    var rules: [Rule] { didSet { save() } }
    @ObservationIgnored private let url: URL

    init(url: URL = AppFolder.url.appendingPathComponent("rules.json")) {
        self.url = url
        rules = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? []
    }

    func add(_ new: [Rule]) {
        // Skip ones already there (same tool, pattern and action).
        let fresh = new.filter { rule in !rules.contains { $0.tool == rule.tool && $0.pattern == rule.pattern && $0.action == rule.action } }
        rules += fresh
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Every answer to a permission prompt, by you or a rule, one JSON line each.
final class AuditLog: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var at: Date
        var session: String
        var project: String
        var tool: String
        var target: String
        /// allow, always, deny, answer, rule-allow, rule-deny, timed-out
        var decision: String
        /// "you", "rule: …", or "Claude's window"
        var by: String
    }

    static let shared = AuditLog()
    let url: URL
    private let queue = DispatchQueue(label: "claude-notch.audit")

    init(url: URL = AppFolder.url.appendingPathComponent("audit.jsonl")) { self.url = url }

    func append(_ entry: Entry) {
        let url = url
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .sortedKeys
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// The newest entries, newest first.
    func recent(_ limit: Int = 200) -> [Entry] {
        queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return text.split(separator: "\n").suffix(limit).reversed()
                .compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
        }
    }
}

/// `~/Library/Application Support/Claude Notch`.
enum AppFolder {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Notch")
    }
}
