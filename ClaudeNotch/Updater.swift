import AppKit
import Observation

/// Checks GitHub once a day for a newer release, and installs it on request: download, check the signature and
/// bundle ID, swap it in for this copy, relaunch. Copies that aren't in an Applications folder (a build from Xcode,
/// say) only get a link to the release.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let repository = "dmyersdev/claude-notch"
    static let checkEvery: TimeInterval = 24 * 3600

    struct Release: Equatable, Sendable {
        var version: String
        var page: URL
        var download: URL?
    }

    enum Status: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    private(set) var available: Release?
    private(set) var status: Status = .idle
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let lastCheckKey = "lastUpdateCheck"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Installed where an update can replace it.
    static var canInstall: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path.hasSuffix("/Applications")
    }

    /// "2.10" is newer than "2.9"; a leading "v" is ignored.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// GitHub's "latest release" JSON: the tag, its page, and the zip we publish.
    nonisolated static func parse(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = object["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }?["browser_download_url"] as? String
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), page: page,
                       download: zip.flatMap(URL.init(string:)))
    }

    func checkIfDue() {
        guard Preferences.shared.checkForUpdates, Self.canInstall else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.checkEvery else { return }
        Task { await check() }
    }

    func check() async {
        status = .checking
        defaults.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, let release = Self.parse(data) else {
            status = .failed("Couldn't reach GitHub")
            return
        }
        available = Self.isNewer(release.version, than: Self.currentVersion) ? release : nil
        status = available == nil ? .upToDate : .idle
    }

    func install() async {
        guard let release = available else { return }
        guard Self.canInstall, let download = release.download else {
            NSWorkspace.shared.open(release.page)
            return
        }
        status = .downloading
        do {
            let (zip, _) = try await URLSession.shared.download(from: download)
            status = .installing
            let app = try await Task.detached { try Self.unpack(zip) }.value
            try Self.replace(Bundle.main.bundleURL, with: app)
            Self.relaunch(Bundle.main.bundleURL)
        } catch {
            status = .failed("Update failed: \(error.localizedDescription)")
            NSWorkspace.shared.open(release.page)
        }
    }

    /// Unzips the download and returns the app inside, once its bundle ID and signature check out.
    nonisolated static func unpack(_ zip: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-notch-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) != nil,
              let name = try FileManager.default.contentsOfDirectory(atPath: folder.path).first(where: { $0.hasSuffix(".app") })
        else { throw CocoaError(.fileReadCorruptFile) }
        let app = folder.appendingPathComponent(name)
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) != nil
        else { throw CocoaError(.fileReadCorruptFile) }
        return app
    }

    /// The old copy goes to the Trash (so it can be fished back out); the new one takes its place.
    static func replace(_ current: URL, with new: URL) throws {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
        do {
            try FileManager.default.moveItem(at: new, to: current)
        } catch {
            if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: current) }
            throw error
        }
    }

    static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
