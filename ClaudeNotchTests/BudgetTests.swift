import Foundation
import Testing
@testable import ClaudeNotch

@MainActor struct BudgetTests {
    func agent(_ id: String, cost: Double, priced: Bool = true) -> Agent {
        var agent = Agent(id: id, project: "p")
        agent.usage = SessionUsage(costUSD: cost, priced: priced)
        return agent
    }

    @Test func flagsSessionsAndTheTotal() {
        let budget = Budget(session: 10, total: 20)
        let agents = [agent("a", cost: 12), agent("b", cost: 9), agent("codex", cost: 50, priced: false)]
        #expect(budget.isOver(agents[0]))
        #expect(!budget.isOver(agents[1]))
        #expect(!budget.isOver(agents[2]))
        #expect(Budget.spent(agents) == 21)
        #expect(budget.isTotalOver(agents))
    }

    @Test func warnsOnceEach() {
        let budget = Budget(session: 10, total: 20)
        let agents = [agent("a", cost: 12), agent("b", cost: 9)]
        let first = budget.newWarnings(agents, warned: [])
        #expect(first.sorted() == ["session:a", "total"])
        #expect(budget.newWarnings(agents, warned: Set(first)).isEmpty)
    }

    @Test func offMeansOff() {
        #expect(Budget().isOff)
        #expect(Budget().newWarnings([agent("a", cost: 1_000)], warned: []).isEmpty)
    }
}
