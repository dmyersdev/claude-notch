import AppKit

/// Just enough git to offer "Open PR": the repo's web page and the current branch, read from the session's folder.
enum GitInfo {
    /// `git@github.com:owner/repo.git` or `https://github.com/owner/repo.git` → `https://github.com/owner/repo`.
    static func webURL(fromRemote remote: String) -> URL? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        if let match = text.firstMatch(of: /^(?:ssh:\/\/)?git@([^:\/]+)[:\/](.+)$/) {
            return URL(string: "https://\(match.1)/\(match.2)")
        }
        if let match = text.firstMatch(of: /^https?:\/\/(?:[^@\/]+@)?([^\/]+)\/(.+)$/) {
            return URL(string: "https://\(match.1)/\(match.2)")
        }
        return nil
    }

    /// GitHub's "open a pull request" page for `branch`; nil on the default branch, where there's nothing to propose.
    static func compareURL(remote: String, branch: String, defaultBranch: String?) -> URL? {
        guard !branch.isEmpty, branch != (defaultBranch ?? "main"), let base = webURL(fromRemote: remote),
              let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(base.absoluteString)/compare/\(escaped)?expand=1")
    }

    /// Opens the pull request page for the folder's current branch, or beeps when there isn't one to open.
    static func openPullRequest(in folder: String) {
        Task.detached {
            let remote = git(["remote", "get-url", "origin"], in: folder)
            let branch = git(["branch", "--show-current"], in: folder)
            let head = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: folder)
            let defaultBranch = head.map { String($0.split(separator: "/").last ?? "") }
            let url = remote.flatMap { remote in
                branch.flatMap { compareURL(remote: remote, branch: $0, defaultBranch: defaultBranch) }
            }
            await MainActor.run {
                if let url { NSWorkspace.shared.open(url) } else { NSSound.beep() }
            }
        }
    }

    private static func git(_ arguments: [String], in folder: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
