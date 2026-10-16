import Foundation
import Testing
@testable import ClaudeNotch

struct EditorHelperTests {
    let cursor = EditorHelper.editor(bundleID: "com.todesktop.230313mt0ff1jl")!

    @Test func knowsTheEditors() {
        #expect(cursor.name == "Cursor" && cursor.scheme == "cursor")
        #expect(EditorHelper.editor(bundleID: "com.microsoft.VSCode")?.scheme == "vscode")
        #expect(EditorHelper.editor(bundleID: "com.example.other") == nil)
    }

    @Test func linksCarryTheProcessChain() {
        #expect(EditorHelper.focusURL(cursor, pids: [812, 640, 1])?.absoluteString
                == "cursor://dmyersdev.claude-notch-terminal-focus/focus?pids=812,640")
        #expect(EditorHelper.focusURL(cursor, pids: [1]) == nil)
    }

    @Test func spotsAnInstalledHelper() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let folder = home.appendingPathComponent(".cursor/extensions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(!EditorHelper.hasHelper(cursor, home: home))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dmyersdev.claude-notch-terminal-focus-1.0.0"),
                                                withIntermediateDirectories: true)
        #expect(EditorHelper.hasHelper(cursor, home: home))
    }

    @Test func preApprovesLinksOnceAndKeepsOtherSettings() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        try Data(#"{"window.commandCenter": true}"#.utf8).write(to: file)
        #expect(EditorHelper.trustLinks(in: file))
        #expect(EditorHelper.trustLinks(in: file))
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(settings?["window.commandCenter"] as? Bool == true)
        #expect(settings?[EditorHelper.trustSetting] as? [String] == [EditorHelper.extensionID])
        #expect(FileManager.default.fileExists(atPath: file.path + ".claude-notch-backup"))
    }

    @Test func leavesSettingsWithCommentsAlone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        let original = "{\n  // my favourite\n  \"editor.fontSize\": 14\n}"
        try Data(original.utf8).write(to: file)
        #expect(!EditorHelper.trustLinks(in: file))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test func theExtensionShipsInTheApp() throws {
        let manifest = try #require(Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/terminal-focus/extension/package.json") as URL?)
        let package = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        #expect(package?["publisher"] as? String == "dmyersdev")
        #expect(package?["name"] as? String == "claude-notch-terminal-focus")
    }
}

private final class BundleMarker {}
