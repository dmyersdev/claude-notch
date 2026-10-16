import AppKit

/// Keyboard control of the open panel, once it's been clicked: move the selection, answer, jump, tuck away.
enum PanelKey: Equatable {
    case up, down, allow, deny, always, jump, tuck, close

    /// The hint shown in the panel while keys are live.
    static let hint = "↑↓ select · A allow · D deny · L always · ↩ jump · X tuck away · esc"

    init?(keyCode: UInt16, characters: String?) {
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 36, 76: self = .jump
        case 53: self = .close
        default:
            switch characters?.lowercased() {
            case "k": self = .up
            case "j": self = .down
            case "a": self = .allow
            case "d": self = .deny
            case "l": self = .always
            case "x": self = .tuck
            default: return nil
            }
        }
    }
}

@MainActor
enum PanelKeyboard {
    /// Everyone selectable, in the order the panel shows them.
    static func order(_ store: AgentStore) -> [String] {
        let sections = PanelLayout.sections(store.present)
        return (sections.waiting + sections.others).map(\.id)
    }

    /// Applies a key. Returns false for keys it leaves to the caller (`close`) or that don't apply.
    @discardableResult
    static func perform(_ key: PanelKey, state: NotchState, store: AgentStore) -> Bool {
        let ids = order(store)
        guard !ids.isEmpty else { return false }
        let index = state.selectedID.flatMap { ids.firstIndex(of: $0) }
        // With nothing selected yet, keys act on the first row: the most urgent session.
        let current = ids[index ?? 0]
        let selected = store.agents.first { $0.id == current }
        switch key {
        case .up:
            state.selectedID = ids[max(0, (index ?? 0) - 1)]
        case .down:
            state.selectedID = ids[min(ids.count - 1, (index ?? -1) + 1)]
        case .allow, .deny, .always:
            guard let agent = selected, let request = agent.ask?.request, !request.isQuestion else { return false }
            if key == .always && !request.canAlways { return false }
            store.answer(agent.id, key == .allow ? .allow : key == .deny ? .deny : .always)
            state.selectedID = order(store).first
        case .jump:
            guard let agent = selected else { return false }
            store.acknowledge(agent.id)
            WindowFocuser.focus(agent)
        case .tuck:
            guard let agent = selected else { return false }
            store.tuckAway(agent.id)
            state.selectedID = order(store).first
        case .close:
            return false
        }
        return true
    }
}
