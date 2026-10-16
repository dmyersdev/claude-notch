import AppKit

/// VS Code-style editors (Cursor, VS Code, Windsurf) can't be told from outside which integrated terminal to show,
/// so the notch installs a tiny companion extension (integrations/terminal-focus) and asks it through a link.
enum EditorHelper {
    struct Editor: Equatable, Identifiable {
        var name: String
        var bundleID: String
        /// The editor's link scheme: `cursor://`, `vscode://`…
        var scheme: String
        var appPath: String
        /// Its command-line tool inside the app, for installing the extension.
        var cli: String
        /// Where it keeps extensions, relative to home.
        var extensionsFolder: String
        /// Its user settings, relative to home.
        var settingsFile: String
        var id: String { bundleID }
    }

    static let extensionID = "dmyersdev.claude-notch-terminal-focus"

    static let editors = [
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mt0ff1jl", scheme: "cursor",
               appPath: "/Applications/Cursor.app", cli: "Contents/Resources/app/bin/cursor",
               extensionsFolder: ".cursor/extensions", settingsFile: "Library/Application Support/Cursor/User/settings.json"),
        Editor(name: "VS Code", bundleID: "com.microsoft.VSCode", scheme: "vscode",
               appPath: "/Applications/Visual Studio Code.app", cli: "Contents/Resources/app/bin/code",
               extensionsFolder: ".vscode/extensions", settingsFile: "Library/Application Support/Code/User/settings.json"),
        Editor(name: "VS Code Insiders", bundleID: "com.microsoft.VSCodeInsiders", scheme: "vscode-insiders",
               appPath: "/Applications/Visual Studio Code - Insiders.app", cli: "Contents/Resources/app/bin/code-insiders",
               extensionsFolder: ".vscode-insiders/extensions",
               settingsFile: "Library/Application Support/Code - Insiders/User/settings.json"),
        Editor(name: "Windsurf", bundleID: "com.exafunction.windsurf", scheme: "windsurf",
               appPath: "/Applications/Windsurf.app", cli: "Contents/Resources/app/bin/windsurf",
               extensionsFolder: ".windsurf/extensions", settingsFile: "Library/Application Support/Windsurf/User/settings.json"),
    ]

    static func editor(bundleID: String?) -> Editor? { editors.first { $0.bundleID == bundleID } }

    /// Editors on this Mac.
    static var installedEditors: [Editor] {
        editors.filter { FileManager.default.fileExists(atPath: $0.appPath) }
    }

    static func hasHelper(_ editor: Editor, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let folder = home.appendingPathComponent(editor.extensionsFolder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.lowercased().hasPrefix(extensionID + "-") }
    }

    /// The link the extension answers: show and focus the terminal whose shell is one of `pids`.
    static func focusURL(_ editor: Editor, pids: [pid_t]) -> URL? {
        let list = pids.filter { $0 > 1 }.map(String.init).joined(separator: ",")
        guard !list.isEmpty else { return nil }
        return URL(string: "\(editor.scheme)://\(extensionID)/focus?pids=\(list)")
    }

    /// Zips the bundled extension into a .vsix and installs it with the editor's own command-line tool.
    static func install(_ editor: Editor) async -> Bool {
        guard let source = Bundle.main.url(forResource: "terminal-focus", withExtension: nil) else { return false }
        let vsix = FileManager.default.temporaryDirectory.appendingPathComponent("claude-notch-terminal-focus.vsix")
        try? FileManager.default.removeItem(at: vsix)
        let cli = URL(fileURLWithPath: editor.appPath).appendingPathComponent(editor.cli).path
        return await Task.detached {
            // A .vsix is a zip with the manifest at its root, which is how the folder is laid out.
            guard Shell.run("/usr/bin/ditto", ["-c", "-k", source.path, vsix.path]) != nil,
                  Shell.run(cli, ["--install-extension", vsix.path, "--force"]) != nil else { return false }
            trustLinks(in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(editor.settingsFile))
            return true
        }.value
    }

    static let trustSetting = "extensions.confirmedUriHandlerExtensionIds"

    /// Pre-approves the helper's links, so a jump never stops at "Allow this extension to open the link?".
    /// Only edits settings that are plain JSON (comments would be lost otherwise); keeps a one-off backup.
    @discardableResult
    static func trustLinks(in settings: URL) -> Bool {
        let manager = FileManager.default
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: settings), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            object = parsed
        }
        var trusted = object[trustSetting] as? [String] ?? []
        guard !trusted.contains(extensionID) else { return true }
        trusted.append(extensionID)
        object[trustSetting] = trusted
        let backup = settings.appendingPathExtension("claude-notch-backup")
        if manager.fileExists(atPath: settings.path), !manager.fileExists(atPath: backup.path) {
            try? manager.copyItem(at: settings, to: backup)
        }
        try? manager.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        return (try? data.write(to: settings, options: .atomic)) != nil
    }
}
