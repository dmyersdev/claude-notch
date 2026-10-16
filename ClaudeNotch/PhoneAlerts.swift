import AppKit
import CoreGraphics

/// Pings your phone through ntfy (https://ntfy.sh, or your own server) when a session has waited on you a while
/// and you're away from the Mac. Opt-in; says which session and why, never the command.
@MainActor
final class PhoneAlerts {
    struct Settings: Equatable {
        var enabled = false
        var server = "https://ntfy.sh"
        var topic = ""
        /// How long a session waits before your phone hears about it.
        var delay: TimeInterval = 5 * 60
        /// Also for finished turns, not just blocked ones.
        var includeFinished = false

        var endpoint: URL? {
            let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard enabled, !topic.isEmpty, topic.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
            else { return nil }
            return URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines))?.appendingPathComponent(topic)
        }
    }

    struct Alert: Equatable {
        var key: String
        var title: String
        var message: String
        var urgent: Bool
    }

    /// One alert per wait: a session's ID with when it started waiting.
    private var sent: Set<String> = []

    /// Away means the screen is locked or nobody has touched the Mac for two minutes.
    static func isAway(idleSeconds: TimeInterval, locked: Bool) -> Bool { locked || idleSeconds >= 120 }

    /// The alerts due now, given who's waiting. Pure, so it's tested.
    static func due(_ agents: [Agent], settings: Settings, away: Bool, now: Date, alreadySent: Set<String>) -> [Alert] {
        guard settings.endpoint != nil, away else { return [] }
        return agents.compactMap { agent in
            guard let need = agent.need, let since = agent.waitingSince,
                  need == .permission || settings.includeFinished,
                  now.timeIntervalSince(since) >= settings.delay else { return nil }
            let key = "\(agent.id)@\(Int(since.timeIntervalSince1970))"
            guard !alreadySent.contains(key) else { return nil }
            let minutes = Int(now.timeIntervalSince(since) / 60)
            return need == .permission
                ? Alert(key: key, title: "\(agent.displayName) is blocked",
                        message: "Waiting \(minutes) min for \(agent.isAsking ? "an answer" : "permission") (\(agent.project)).",
                        urgent: true)
                : Alert(key: key, title: "\(agent.displayName) is done",
                        message: "Finished \(minutes) min ago (\(agent.project)).", urgent: false)
        }
    }

    func check(_ agents: [Agent], settings: Settings, now: Date = Date()) {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let alerts = Self.due(agents, settings: settings, away: Self.isAway(idleSeconds: idle, locked: PowerState.isLocked),
                              now: now, alreadySent: sent)
        guard let endpoint = settings.endpoint else { return }
        for alert in alerts {
            sent.insert(alert.key)
            Self.send(alert, to: endpoint)
        }
    }

    /// A one-off message (budget warnings), if phone alerts are set up.
    static func send(title: String, message: String, settings: Settings) {
        guard let endpoint = settings.endpoint else { return }
        send(Alert(key: title, title: title, message: message, urgent: false), to: endpoint)
    }

    /// For the Settings button.
    static func sendTest(settings: Settings) {
        guard let endpoint = settings.endpoint else { NSSound.beep(); return }
        send(Alert(key: "test", title: "Claude Notch", message: "Phone alerts are working.", urgent: false), to: endpoint)
    }

    /// ntfy's publish format: the body is the message; title, priority and tags go in headers.
    static func request(for alert: Alert, to endpoint: URL) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(alert.message.utf8)
        request.setValue(alert.title, forHTTPHeaderField: "Title")
        request.setValue(alert.urgent ? "high" : "default", forHTTPHeaderField: "Priority")
        request.setValue(alert.urgent ? "red_circle" : "white_check_mark", forHTTPHeaderField: "Tags")
        return request
    }

    private static func send(_ alert: Alert, to endpoint: URL) {
        URLSession.shared.dataTask(with: request(for: alert, to: endpoint)) { _, _, error in
            if let error { hookLog.error("phone alert failed: \(error.localizedDescription, privacy: .public)") }
        }.resume()
    }
}
