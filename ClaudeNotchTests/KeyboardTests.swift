import Foundation
import Testing
@testable import ClaudeNotch

struct PanelKeyTests {
    @Test func keysMapToActions() {
        #expect(PanelKey(keyCode: 126, characters: nil) == .up)
        #expect(PanelKey(keyCode: 125, characters: nil) == .down)
        #expect(PanelKey(keyCode: 36, characters: "\r") == .jump)
        #expect(PanelKey(keyCode: 53, characters: nil) == .close)
        #expect(PanelKey(keyCode: 0, characters: "a") == .allow)
        #expect(PanelKey(keyCode: 2, characters: "D") == .deny)
        #expect(PanelKey(keyCode: 37, characters: "l") == .always)
        #expect(PanelKey(keyCode: 7, characters: "x") == .tuck)
        #expect(PanelKey(keyCode: 6, characters: "z") == .snooze)
        #expect(PanelKey(keyCode: 1, characters: "s") == .stop)
        #expect(PanelKey(keyCode: 44, characters: "/") == .search)
        #expect(PanelKey(keyCode: 43, characters: ",", command: true) == .settings)
        #expect(PanelKey(keyCode: 3, characters: "f", command: true) == .search)
        #expect(PanelKey(keyCode: 0, characters: "a", command: true) == nil)
        #expect(PanelKey(keyCode: 12, characters: "q") == nil)
    }

    @Test func flagsWiltWithTheWait() {
        #expect(Sprite.droop(after: 60) == 0)
        #expect(Sprite.droop(after: 5 * 60) == 1)
        #expect(Sprite.droop(after: 11 * 60) == 2)
    }
}

@MainActor struct PanelKeyboardTests {
    final class Replies: @unchecked Sendable { var got: [PermissionDecision?] = [] }

    func store(_ replies: Replies) -> AgentStore {
        let store = AgentStore()
        store.apply(HookEvent(sessionID: "busy", kind: .prompt))
        store.apply(HookEvent(sessionID: "done", kind: .stop))
        store.hold(HookEvent(sessionID: "blocked", kind: .permissionRequest(PermissionRequest(
            summary: "Run npm test", tool: "Bash", suggestions: Data("[]".utf8))))) { replies.got.append($0) }
        return store
    }

    @Test func movesThroughSessionsInPanelOrder() {
        let replies = Replies(), store = store(replies), state = NotchState()
        #expect(PanelKeyboard.order(store) == ["blocked", "done", "busy"])
        PanelKeyboard.perform(.down, state: state, store: store)
        #expect(state.selectedID == "blocked")
        PanelKeyboard.perform(.down, state: state, store: store)
        PanelKeyboard.perform(.down, state: state, store: store)
        PanelKeyboard.perform(.down, state: state, store: store)
        #expect(state.selectedID == "busy")
        PanelKeyboard.perform(.up, state: state, store: store)
        #expect(state.selectedID == "done")
    }

    @Test func answersTheSelectedPrompt() {
        let replies = Replies(), store = store(replies), state = NotchState()
        // Nothing selected yet: keys act on the most urgent session.
        #expect(PanelKeyboard.perform(.always, state: state, store: store))
        #expect(replies.got == [.always])
        // No prompt left to answer.
        #expect(!PanelKeyboard.perform(.allow, state: state, store: store))
    }

    @Test func tucksTheSelectedSessionAway() {
        let replies = Replies(), store = store(replies), state = NotchState()
        state.selectedID = "done"
        PanelKeyboard.perform(.tuck, state: state, store: store)
        #expect(store.away.map(\.id) == ["done"])
        #expect(state.selectedID == "blocked")
    }
}
