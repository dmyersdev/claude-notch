import Foundation
import Testing
@testable import ClaudeNotch

@MainActor struct PhoneAlertTests {
    let now = Date(timeIntervalSinceReferenceDate: 100_000)
    var settings: PhoneAlerts.Settings { PhoneAlerts.Settings(enabled: true, topic: "my-notch-topic", delay: 300) }

    func waiting(_ id: String, _ need: Need, minutes: Double, question: Bool = false) -> Agent {
        var agent = Agent(id: id, project: "react", need: need, waitingSince: now.addingTimeInterval(-minutes * 60))
        agent.title = "Center the div"
        if question {
            agent.ask = PermissionAsk(request: PermissionRequest(summary: "Q?", tool: "AskUserQuestion",
                questions: [Question(text: "Q?", options: [.init(label: "A")], multiSelect: false)]))
        }
        return agent
    }

    @Test func blockedSessionsPingOnceAfterTheDelayWhileAway() {
        let agents = [waiting("a", .permission, minutes: 6), waiting("b", .permission, minutes: 2)]
        let due = PhoneAlerts.due(agents, settings: settings, away: true, now: now, alreadySent: [])
        #expect(due.map(\.key).count == 1)
        #expect(due.first?.title == "Center the div is blocked")
        #expect(due.first?.message == "Waiting 6 min for permission (react).")
        #expect(due.first?.urgent == true)
        // Already sent for this wait: nothing new.
        #expect(PhoneAlerts.due(agents, settings: settings, away: true, now: now, alreadySent: Set(due.map(\.key))).isEmpty)
    }

    @Test func nothingWhileYoureAtTheMac() {
        #expect(PhoneAlerts.due([waiting("a", .permission, minutes: 30)], settings: settings, away: false,
                                now: now, alreadySent: []).isEmpty)
    }

    @Test func finishedTurnsOnlyWhenAskedFor() {
        let done = [waiting("a", .yourTurn, minutes: 10)]
        #expect(PhoneAlerts.due(done, settings: settings, away: true, now: now, alreadySent: []).isEmpty)
        var both = settings
        both.includeFinished = true
        #expect(PhoneAlerts.due(done, settings: both, away: true, now: now, alreadySent: []).first?.urgent == false)
    }

    @Test func questionsSayTheyNeedAnAnswer() {
        let due = PhoneAlerts.due([waiting("q", .permission, minutes: 8, question: true)], settings: settings,
                                  away: true, now: now, alreadySent: [])
        #expect(due.first?.message.contains("an answer") == true)
    }

    @Test func topicsMustBeSafeAndPresent() {
        var off = settings
        off.enabled = false
        #expect(off.endpoint == nil)
        var blank = settings
        blank.topic = "  "
        #expect(blank.endpoint == nil)
        var sneaky = settings
        sneaky.topic = "../admin"
        #expect(sneaky.endpoint == nil)
        #expect(settings.endpoint?.absoluteString == "https://ntfy.sh/my-notch-topic")
    }

    @Test func awayMeansLockedOrIdle() {
        #expect(PhoneAlerts.isAway(idleSeconds: 10, locked: true))
        #expect(PhoneAlerts.isAway(idleSeconds: 200, locked: false))
        #expect(!PhoneAlerts.isAway(idleSeconds: 30, locked: false))
    }

    @Test func requestsUseNtfysFormat() {
        let alert = PhoneAlerts.Alert(key: "k", title: "T", message: "M", urgent: true)
        let request = PhoneAlerts.request(for: alert, to: URL(string: "https://ntfy.sh/topic")!)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Title") == "T")
        #expect(request.value(forHTTPHeaderField: "Priority") == "high")
        #expect(request.httpBody == Data("M".utf8))
    }
}
