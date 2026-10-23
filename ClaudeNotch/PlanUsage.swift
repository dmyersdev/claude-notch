import Foundation

/// Your plan's 5-hour and weekly usage, from the Claude app's own cache. It's written only when the Claude app
/// fetches usage (at most every few minutes, while its usage display is in use), so it's shown with its age and
/// hidden once it's over an hour old. We never fetch it ourselves: that would need your login token.
struct PlanUsage: Equatable, Sendable {
    /// Percent of the 5-hour window used.
    var fiveHour: Int
    /// Percent of the weekly limit used.
    var weekly: Int
    var at: Date

    static let staleAfter: TimeInterval = 3600
    static let warnAt = 80

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    /// The newest sample; `fh` is the 5-hour percentage and `sd` the 7-day one.
    static func parse(_ data: Data) -> PlanUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = object["samples"] as? [[String: Any]] else { return nil }
        let latest = samples.compactMap { sample -> PlanUsage? in
            guard let t = (sample["t"] as? NSNumber)?.doubleValue, let u = sample["u"] as? [String: Any] else { return nil }
            return PlanUsage(fiveHour: (u["fh"] as? NSNumber)?.intValue ?? 0, weekly: (u["sd"] as? NSNumber)?.intValue ?? 0,
                             at: Date(timeIntervalSince1970: t / 1000))
        }.max { $0.at < $1.at }
        return latest
    }

    static func read(now: Date = Date()) -> PlanUsage? {
        guard let data = try? Data(contentsOf: url), let usage = parse(data),
              now.timeIntervalSince(usage.at) < staleAfter else { return nil }
        return usage
    }

    var isHigh: Bool { max(fiveHour, weekly) >= Self.warnAt }
}

/// Whether a macOS Focus (Do Not Disturb and friends) is on. macOS keeps this in a file only apps with Full Disk
/// Access can read, so without it the answer is "don't know" (nil) and only the manual Quiet switch counts.
enum FocusStatus {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
    }

    static func read() -> Bool? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// On when any store record holds an assertion.
    static func parse(_ data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["data"] as? [[String: Any]] else { return nil }
        return records.contains { record in
            !((record["storeAssertionRecords"] as? [Any]) ?? []).isEmpty
        }
    }
}
