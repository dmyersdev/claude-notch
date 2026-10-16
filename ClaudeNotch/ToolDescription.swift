import Foundation

/// Turns a tool call into words for a card: "Editing NotchView.swift", or "Run rm -rf build" for a permission ask.
enum ToolDescription {
    enum Style { case doing, asking }

    static func describe(tool: String, input: [String: Any]?, style: Style = .doing) -> String {
        let input = input ?? [:]
        let (doing, asking, detail) = phrase(for: tool, input: input)
        let verb = style == .doing ? doing : asking
        guard let detail = shorten(detail) else { return verb }
        return "\(verb) \(detail)"
    }

    /// The verb in both styles, and what it acts on.
    private static func phrase(for tool: String, input: [String: Any]) -> (String, String, String?) {
        let file = (input["file_path"] as? String ?? input["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }
        let text = { (key: String) in input[key] as? String }
        switch tool {
        case "Read": return ("Reading", "Read", file)
        case "Edit", "MultiEdit", "NotebookEdit": return ("Editing", "Edit", file)
        case "Write": return ("Writing", "Write", file)
        case "Bash": return ("Running", "Run", text("command"))
        case "BashOutput": return ("Checking on a command", "Check on a command", nil)
        case "KillShell", "KillBash": return ("Stopping a command", "Stop a command", nil)
        case "Grep": return ("Searching for", "Search for", text("pattern").map { "“\($0)”" })
        case "Glob": return ("Finding", "Find", text("pattern"))
        case "LS": return ("Listing", "List", text("path").map { ($0 as NSString).lastPathComponent })
        case "WebSearch": return ("Searching the web for", "Search the web for", text("query").map { "“\($0)”" })
        case "WebFetch": return ("Reading", "Read", text("url").flatMap { URL(string: $0)?.host() } ?? text("url"))
        case "Task", "Agent": return ("Delegating:", "Delegate:", text("description"))
        case "TodoWrite": return ("Updating the to-do list", "Update the to-do list", nil)
        case "Skill": return ("Using skill", "Use skill", text("skill") ?? text("name"))
        case "ExitPlanMode": return ("Presenting a plan", "Present a plan", nil)
        case "AskUserQuestion": return ("Asking you a question", "Ask you a question", nil)
        default:
            if let mcp = mcpName(tool) {
                let action = mcp.server.map { "\($0): \(mcp.tool)" } ?? mcp.tool.capitalizedFirst
                return (action, action, nil)
            }
            let name = humanize(tool)
            return ("Using \(name)", "Use \(name)", text("description"))
        }
    }

    /// `mcp__claude-in-chrome__navigate` → (server "Chrome", tool "navigate").
    static func mcpName(_ tool: String) -> (server: String?, tool: String)? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return nil }
        return (serverName(parts[0]), humanize(parts.dropFirst().joined(separator: " ")))
    }

    /// A readable name for an MCP server, or nil when it's just an ID.
    static func serverName(_ raw: String) -> String? {
        var name = raw
        if name.hasPrefix("plugin_") {
            // plugin_<plugin>_<server>, often the same name twice: keep one.
            name = String(name.dropFirst(7))
            let middle = name.index(name.startIndex, offsetBy: name.count / 2)
            if name.count % 2 == 1, name[middle] == "_", name[..<middle] == name[name.index(after: middle)...] {
                name = String(name[..<middle])
            }
        }
        let known: [String: String] = ["claude-in-chrome": "Chrome", "Claude_Browser": "Browser",
                                       "Claude_Code_iOS_Simulator": "Simulator", "visualize": "Visualizer",
                                       "terminal": "Terminal", "scheduled-tasks": "Scheduler"]
        if let friendly = known[name] { return friendly }
        if name.hasPrefix("ccd_") { return "Claude app" }
        // Server IDs like 1a59c906-04da-… say nothing.
        if name.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}"#, options: .regularExpression) != nil { return nil }
        let words = humanize(name)
        return words.count <= 24 ? words.capitalizedFirst : nil
    }

    /// `wrap_up` → "wrap up", `get_page_text` → "get page text", `listDirectory` → "list directory".
    static func humanize(_ identifier: String) -> String {
        var spaced = ""
        for character in identifier {
            if character == "_" || character == "-" { spaced.append(" ") }
            else if character.isUppercase, let last = spaced.last, last.isLowercase { spaced += " " + character.lowercased() }
            else { spaced.append(character) }
        }
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// First line only, and short enough for a card.
    private static func shorten(_ detail: String?) -> String? {
        guard let line = detail?.split(whereSeparator: \.isNewline).first.map(String.init), !line.isEmpty else { return nil }
        return line.count > 48 ? line.prefix(47) + "…" : line
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
