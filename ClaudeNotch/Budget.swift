import Foundation

/// Spending limits, as warnings: a hook can only stop tool calls that ask permission, so the notch flags a session
/// that's over and pings you once, rather than pretending it can halt it.
struct Budget: Equatable {
    /// Dollars at API prices; 0 is off.
    var session: Double = 0
    var total: Double = 0

    var isOff: Bool { session <= 0 && total <= 0 }

    func isOver(_ agent: Agent) -> Bool {
        guard session > 0, let usage = agent.usage, usage.priced else { return false }
        return usage.costUSD >= session
    }

    /// What the running sessions have cost together.
    static func spent(_ agents: [Agent]) -> Double {
        agents.compactMap { $0.usage }.filter(\.priced).reduce(0) { $0 + $1.costUSD }
    }

    func isTotalOver(_ agents: [Agent]) -> Bool { total > 0 && Self.spent(agents) >= total }

    /// Warnings not yet given: each over-budget session once, and the total once.
    func newWarnings(_ agents: [Agent], warned: Set<String>) -> [String] {
        var keys = agents.filter(isOver).map { "session:\($0.id)" }
        if isTotalOver(agents) { keys.append("total") }
        return keys.filter { !warned.contains($0) }
    }
}
