import Foundation
import Testing
@testable import ClaudeNotch

@MainActor struct PresenceTests {
    let start = Date(timeIntervalSinceReferenceDate: 10_000)
    func minutes(_ n: Double) -> Date { start.addingTimeInterval(n * 60) }

    func store() -> AgentStore {
        let store = AgentStore()
        store.tuckAwayAfter = 15 * 60
        return store
    }

    @Test func idleSessionsTuckAwayAfterTheDelay() {
        let store = store()
        store.syncRegistry([RegisteredSession(pid: 1, sessionID: "s", status: "idle", statusSince: start)], now: start)
        store.refreshPresence(now: minutes(10))
        #expect(store.present.map(\.id) == ["s"])
        store.refreshPresence(now: minutes(16))
        #expect(store.present.isEmpty)
        #expect(store.away.map(\.id) == ["s"])
    }

    @Test func finishedTurnsTuckAwayButBlockedOnesStay() {
        let store = store()
        store.apply(HookEvent(sessionID: "done", kind: .stop), now: start)
        store.apply(HookEvent(sessionID: "blocked", kind: .needs(.permission)), now: start)
        store.refreshPresence(now: minutes(60))
        #expect(store.present.map(\.id) == ["blocked"])
        #expect(!store.away.contains { $0.id == "blocked" })
    }

    @Test func busySessionsNeverTuckAway() {
        let store = store()
        store.syncRegistry([RegisteredSession(pid: 1, sessionID: "s", status: "busy", statusSince: start)], now: start)
        store.refreshPresence(now: minutes(120))
        #expect(store.present.map(\.id) == ["s"])
    }

    @Test func tuckingAwayLastsUntilSomethingNewHappens() {
        let store = store()
        store.apply(HookEvent(sessionID: "s", kind: .stop), now: start)
        store.tuckAway("s", now: minutes(1))
        #expect(store.present.isEmpty)
        // An idle reminder isn't new activity.
        store.apply(HookEvent(sessionID: "s", kind: .needs(.yourTurn)), now: minutes(2))
        #expect(store.present.isEmpty)
        store.apply(HookEvent(sessionID: "s", kind: .prompt), now: minutes(3))
        #expect(store.present.map(\.id) == ["s"])
    }

    @Test func wakingUpInTheRegistryBringsItBack() {
        let store = store()
        store.syncRegistry([RegisteredSession(pid: 1, sessionID: "s", status: "idle", statusSince: start)], now: start)
        store.tuckAway("s", now: minutes(1))
        store.syncRegistry([RegisteredSession(pid: 1, sessionID: "s", status: "busy", statusSince: minutes(2))], now: minutes(2))
        #expect(store.present.map(\.id) == ["s"])
    }

    @Test func bringingBackRestartsTheClock() {
        let store = store()
        store.apply(HookEvent(sessionID: "s", kind: .stop), now: start)
        store.refreshPresence(now: minutes(20))
        #expect(store.present.isEmpty)
        store.bringBack("s", now: minutes(20))
        store.refreshPresence(now: minutes(30))
        #expect(store.present.map(\.id) == ["s"])
    }

    @Test func tuckedAwaySessionsDontRaiseTheFlag() {
        let store = store()
        store.apply(HookEvent(sessionID: "s", kind: .stop), now: start)
        #expect(store.anyNeedsAttention)
        store.tuckAway("s", now: minutes(1))
        #expect(!store.anyNeedsAttention)
        #expect(store.longestWaiting == nil)
    }

    @Test func neverMeansNever() {
        let store = store()
        store.tuckAwayAfter = nil
        store.syncRegistry([RegisteredSession(pid: 1, sessionID: "s", status: "idle", statusSince: start)], now: start)
        store.refreshPresence(now: minutes(600))
        #expect(store.present.map(\.id) == ["s"])
    }

    @Test func tuckingAwayHandsBackAHeldPrompt() {
        final class Replies: @unchecked Sendable { var got: [PermissionDecision?] = [] }
        let store = store(), replies = Replies()
        store.hold(HookEvent(sessionID: "s", kind: .permissionRequest(summary: "Run ls"))) { replies.got.append($0) }
        store.tuckAway("s")
        #expect(replies.got == [nil])
    }

    @Test func theAwayRowMakesRoom() {
        let metrics = NotchMetrics.make(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
                                        leftArea: nil, rightArea: nil, visibleMaxY: 1056)
        let without = metrics.openSize(PanelLayout(tiles: 1)).height
        let with = metrics.openSize(PanelLayout(tiles: 1, away: 3)).height
        #expect(with > without)
    }
}
