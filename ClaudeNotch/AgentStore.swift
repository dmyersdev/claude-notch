import Foundation
import Observation

enum PermissionDecision: Equatable, Sendable {
    case allow, deny
    /// Allow, and save Claude Code's suggested rule so it stops asking.
    case always
    /// Answers to `AskUserQuestion`: question text to the chosen labels.
    case answer([String: [String]])
}

/// A permission prompt the notch is holding for a moment, so it can be answered from the card.
struct PermissionAsk: Equatable {
    let id = UUID()
    let request: PermissionRequest
    /// "Run rm -rf build"
    var summary: String { request.summary }

    init(request: PermissionRequest) { self.request = request }
    init(summary: String) { request = PermissionRequest(summary: summary) }
}

struct Agent: Identifiable, Equatable {
    let id: String
    var project: String
    /// Why it's waiting on the user, if it is.
    var need: Need?
    var waitingSince: Date?
    var startedAt = Date()
    var lastTool = "Starting up"
    var activity: Activity = .thinking
    /// Any hook event at all; a long silence while working means it may be stuck.
    var lastEventAt = Date()
    /// Sub-agents it has running, by agent ID.
    var subagents: Set<String> = []
    var ask: PermissionAsk?
    /// Tools the user said "Always" to; each shows as a sticker on its Claude.
    var trusted: Set<String> = []
    /// When the user last answered one of its questions (the Claude cheers).
    var answeredAt: Date?
    /// Waiting on the user to pick from Claude's options.
    var isAsking: Bool { ask?.request.isQuestion == true }
    /// The Claude process behind a real session; nil for demo agents.
    var pid: Int32?
    var cwd: String?
    var transcriptPath: String?
    var usage: SessionUsage?
    /// The session's title, from Claude Code's registry.
    var title: String?
    var namedByRegistry = false
    /// The user tucked it away; it comes back by itself when it does something new.
    var dismissedAt: Date?
    /// The Claude desktop app's ID for the session.
    var hostSessionID: String?
    /// The registry says it's waiting for a prompt.
    var idle = false
    var isDemo = false

    var needsAttention: Bool { need != nil }
    /// The conversation's name when it has one, otherwise its folder.
    var displayName: String { title?.isEmpty == false ? title! : project }
    /// For name tags under the notch, where space is tight.
    var shortName: String { displayName.count > 22 ? displayName.prefix(21) + "…" : displayName }
    var load: Load { usage.map { Load(fraction: $0.contextFraction) } ?? .light }

    /// Nothing to do (idle, flag already seen), or working but silent for a while: it dozes.
    func isQuiet(at now: Date) -> Bool {
        need == nil && (idle || now.timeIntervalSince(lastEventAt) > Self.quietAfter)
    }

    static let quietAfter: TimeInterval = 5 * 60

    /// Tucked away: walks back into the notch and stops holding it open. Sessions blocked on a permission
    /// prompt never go on their own (they're holding up work); the user can still tuck them away.
    func isAway(at now: Date, after delay: TimeInterval?) -> Bool {
        if dismissedAt != nil { return true }
        if need == .permission { return false }
        guard let delay else { return false }
        if need == .yourTurn { return now.timeIntervalSince(waitingSince ?? lastEventAt) > delay }
        return idle && now.timeIntervalSince(lastEventAt) > delay
    }
}

/// The agents the notch shows: Claude Code sessions reported by hooks, plus fake ones in demo mode.
@MainActor @Observable
final class AgentStore {
    static let shared = AgentStore()

    private(set) var agents: [Agent] = []
    var autoDemo = false {
        didSet {
            if autoDemo { startDemo() } else { demoTask?.cancel(); agents.removeAll(where: \.isDemo) }
        }
    }
    /// Called when a session starts waiting on the user (for the optional sound).
    @ObservationIgnored var onNeed: ((Need) -> Void)?

    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var replies: [UUID: @Sendable (PermissionDecision?) -> Void] = [:]
    private let demoTitles = ["Center the div", "Fix the flaky test (again)", "Why is CI red",
                              "Rename everything", "Make it go faster", "Delete the TODOs"]
    private let projects = ["react", "linux", "freeCodeCamp", "vscode", "build-your-own-x", "awesome"]

    /// How long an idle or finished session waits before it's tucked away; nil never tucks.
    var tuckAwayAfter: TimeInterval? = 15 * 60 { didSet { refreshPresence() } }
    /// Sessions tucked away right now. Kept as state, not computed, so views update when time passes.
    private(set) var awayIDs: Set<String> = []

    /// The sessions on show: everything not tucked away.
    var present: [Agent] { agents.filter { !awayIDs.contains($0.id) } }
    var away: [Agent] { agents.filter { awayIDs.contains($0.id) } }

    var anyNeedsAttention: Bool { present.contains(where: \.needsAttention) }

    /// Which side of the notch the user dragged each Claude to.
    private(set) var wings: [String: Wing] = [:]

    func setWing(_ wing: Wing, for id: String) { wings[id] = wing }

    /// Who to jump to: permission prompts first, then whoever has waited longest.
    var longestWaiting: Agent? {
        present.filter(\.needsAttention).min {
            ($0.need == .permission ? 0 : 1, $0.waitingSince ?? .distantFuture)
                < ($1.need == .permission ? 0 : 1, $1.waitingSince ?? .distantFuture)
        }
    }

    func spawn() {
        let used = Set(agents.map(\.project))
        let project = projects.first(where: { !used.contains($0) }) ?? "agent \(agents.count + 1)"
        let title = demoTitles[agents.count % demoTitles.count]
        agents.append(Agent(id: UUID().uuidString, project: project, title: title, isDemo: true))
    }

    /// Feeds one hook event in. Sessions that were already running show up on their next event.
    func apply(_ event: HookEvent, now: Date = Date()) {
        if event.kind == .sessionEnd {
            if let index = agents.firstIndex(where: { $0.id == event.sessionID }) { release(index) }
            agents.removeAll { $0.id == event.sessionID }
            return
        }
        let index = agents.firstIndex(where: { $0.id == event.sessionID }) ?? {
            let project = event.cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude"
            agents.append(Agent(id: event.sessionID, project: project, startedAt: now, lastEventAt: now))
            return agents.count - 1
        }()
        if let pid = event.pid { agents[index].pid = pid }
        if let cwd = event.cwd { agents[index].cwd = cwd }
        if let path = event.transcriptPath { agents[index].transcriptPath = path }
        agents[index].lastEventAt = now
        defer { refreshPresence(now: now) }
        switch event.kind {
        case .prompt, .toolStart, .permissionRequest, .needs(.permission), .subagentStart:
            // Doing something new brings a tucked-away session back. (An idle reminder isn't new.)
            agents[index].dismissedAt = nil
        default: break
        }
        switch event.kind {
        case .prompt:
            agents[index].idle = false
            release(index)
            setNeed(nil, at: index, now: now)
            agents[index].activity = .thinking
            agents[index].lastTool = "Thinking"
        case .toolStart(let name, let summary):
            release(index)
            setNeed(nil, at: index, now: now)
            agents[index].activity = .of(tool: name)
            agents[index].lastTool = summary
        case .toolEnd:
            // The tool ran, so any permission prompt was answered somewhere.
            release(index)
            setNeed(nil, at: index, now: now)
            agents[index].activity = .thinking
        case .needs(let need):
            setNeed(need, at: index, now: now)
        case .permissionRequest(let request):
            setNeed(.permission, at: index, now: now)
            agents[index].lastTool = request.summary
        case .stop:
            // Background sub-agents keep running after the turn ends; SubagentStop takes them away.
            agents[index].idle = true
            release(index)
            setNeed(.yourTurn, at: index, now: now)
        case .subagentStart(let id): agents[index].subagents.insert(id)
        case .subagentStop(let id): agents[index].subagents.remove(id)
        case .sessionStart, .sessionEnd, .other: break
        }
    }

    private func setNeed(_ need: Need?, at index: Int, now: Date) {
        let before = agents[index].need
        agents[index].need = need
        if need == nil {
            agents[index].waitingSince = nil
        } else if before == nil {
            agents[index].waitingSince = now
        }
        if let need, need != before, !agents[index].isDemo { onNeed?(need) }
    }

    /// Folds in Claude Code's list of running sessions, so ones that haven't fired a hook still show up.
    func syncRegistry(_ sessions: [RegisteredSession], now: Date = Date()) {
        for session in sessions {
            let index = agents.firstIndex(where: { $0.id == session.sessionID }) ?? {
                let project = session.cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude"
                agents.append(Agent(id: session.sessionID, project: project, startedAt: session.startedAt ?? now,
                                    lastTool: session.isIdle ? "Waiting for a prompt" : "Working",
                                    lastEventAt: session.statusSince ?? now))
                return agents.count - 1
            }()
            agents[index].pid = session.pid
            if let cwd = session.cwd { agents[index].cwd = cwd }
            if let name = session.name, !name.isEmpty {
                agents[index].title = name
                agents[index].namedByRegistry = true
            }
            agents[index].hostSessionID = session.hostSessionID ?? agents[index].hostSessionID
            if agents[index].transcriptPath == nil { agents[index].transcriptPath = session.transcriptPath() }
            if agents[index].idle != session.isIdle {
                if agents[index].idle { agents[index].dismissedAt = nil } // woke up: back on show
                agents[index].idle = session.isIdle
            }
            // Sessions the hooks haven't told us about yet only know this much.
            if ["Waiting for a prompt", "Working"].contains(agents[index].lastTool) {
                agents[index].lastTool = session.isIdle ? "Waiting for a prompt" : "Working"
            }
            if let since = session.statusSince, since > agents[index].lastEventAt { agents[index].lastEventAt = since }
        }
        refreshPresence(now: now)
    }

    // MARK: Tucking away

    /// Recomputes who is tucked away. Runs on every change and on a timer, since waiting is time-based.
    func refreshPresence(now: Date = Date()) {
        let away = Set(agents.filter { $0.isAway(at: now, after: tuckAwayAfter) }.map(\.id))
        if away != awayIDs { awayIDs = away }
    }

    /// Out of sight until it does something new. A held prompt goes back to Claude's own window.
    func tuckAway(_ id: String, now: Date = Date()) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        release(index)
        agents[index].dismissedAt = now
        refreshPresence(now: now)
    }

    /// Back on show, and its idle clock starts again.
    func bringBack(_ id: String, now: Date = Date()) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].dismissedAt = nil
        agents[index].lastEventAt = now
        if agents[index].need == .yourTurn { agents[index].waitingSince = now }
        refreshPresence(now: now)
    }

    func setUsage(_ usage: SessionUsage, for id: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }), agents[index].usage != usage else { return }
        agents[index].usage = usage
        // The registry's name wins; the transcript's covers sessions the registry doesn't list.
        if !agents[index].namedByRegistry, let title = usage.title, agents[index].title != title {
            agents[index].title = title
        }
    }

    // MARK: Answering permission prompts

    /// Holds a permission prompt until the user answers on the card, the session moves on, or it expires.
    /// `reply` gets nil when the notch steps aside and Claude should ask as usual.
    @discardableResult
    func hold(_ event: HookEvent, reply: @escaping @Sendable (PermissionDecision?) -> Void) -> UUID? {
        guard case .permissionRequest(let request) = event.kind else { reply(nil); return nil }
        apply(event)
        guard let index = agents.firstIndex(where: { $0.id == event.sessionID }) else { reply(nil); return nil }
        release(index)
        let ask = PermissionAsk(request: request)
        agents[index].ask = ask
        replies[ask.id] = reply
        return ask.id
    }

    func answer(_ agentID: String, _ decision: PermissionDecision, now: Date = Date()) {
        guard let index = agents.firstIndex(where: { $0.id == agentID }), let ask = agents[index].ask else { return }
        replies.removeValue(forKey: ask.id)?(decision)
        agents[index].ask = nil
        setNeed(nil, at: index, now: now)
        switch decision {
        case .allow: agents[index].lastTool = "Allowed: " + ask.summary
        case .deny: agents[index].lastTool = "Denied: " + ask.summary
        case .always:
            agents[index].trusted.insert(ask.request.tool)
            agents[index].lastTool = "Always allowed: " + ask.summary
        case .answer(let answers):
            agents[index].answeredAt = now
            agents[index].lastTool = "Answered: " + answers.values.flatMap { $0 }.joined(separator: ", ")
        }
    }

    /// The hold ran out: Claude shows its own prompt, and the flag stays up.
    func expire(_ askID: UUID) {
        replies.removeValue(forKey: askID)?(nil)
        if let index = agents.firstIndex(where: { $0.ask?.id == askID }) { agents[index].ask = nil }
    }

    /// Lets Claude ask in its own window instead.
    private func release(_ index: Int) {
        guard let ask = agents[index].ask else { return }
        replies.removeValue(forKey: ask.id)?(nil)
        agents[index].ask = nil
    }

    // MARK: Housekeeping

    /// Sessions whose process died recently: their Claudes vanish in a puff instead of walking home.
    private(set) var died: Set<String> = []

    /// Drops sessions whose Claude process has gone (a killed terminal never sends SessionEnd).
    func removeDeadSessions(isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        let dead = agents.indices.filter { agents[$0].pid.map { !isAlive($0) } ?? false }
        guard !dead.isEmpty else { return }
        let ids = Set(dead.map { agents[$0].id })
        dead.forEach(release)
        agents.removeAll { ids.contains($0.id) }
        died.formUnion(ids)
        // Long enough for every stage to notice; then forget them.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.died.subtract(ids)
        }
    }

    func removeLast() {
        guard !agents.isEmpty else { return }
        release(agents.count - 1)
        agents.removeLast()
    }

    func flagRandom() {
        guard let index = agents.indices.filter({ !agents[$0].needsAttention }).randomElement() else { return }
        setNeed(Bool.random() ? .permission : .yourTurn, at: index, now: Date())
    }

    /// The user is heading to the session: the flag comes down, and any held prompt goes back to Claude.
    func acknowledge(_ id: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        release(index)
        setNeed(nil, at: index, now: Date())
    }

    func clearFlags() {
        for index in agents.indices {
            release(index)
            setNeed(nil, at: index, now: Date())
        }
    }

    // MARK: Demo

    /// Spawns, flags and retires fake agents so there is always something to watch.
    func startDemo() {
        demoTask?.cancel()
        if !agents.contains(where: \.isDemo) { spawn(); spawn() }
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.demoStep()
            }
        }
    }

    private let tools: [(String, [String: Any])] = [
        ("Read", ["file_path": "/x/Stage.swift"]), ("Edit", ["file_path": "/x/NotchView.swift"]),
        ("Bash", ["command": "xcodebuild test"]), ("Grep", ["pattern": "hover"]),
        ("Write", ["file_path": "/x/README.md"]), ("WebSearch", ["query": "notch apps"]),
    ]

    private func demoStep() {
        let demo = agents.indices.filter { agents[$0].isDemo }
        for index in demo {
            var usage = agents[index].usage ?? SessionUsage(model: "claude-opus-5-5")
            usage.contextTokens = min(usage.contextWindow, usage.contextTokens + .random(in: 20_000...90_000))
            usage.costUSD += .random(in: 0.05...0.6)
            agents[index].usage = usage
        }
        if let index = demo.randomElement() {
            let (tool, input) = tools.randomElement()!
            agents[index].lastTool = ToolDescription.describe(tool: tool, input: input)
            agents[index].activity = .of(tool: tool)
            agents[index].subagents = Int.random(in: 0..<4) == 0 ? ["a", "b"] : []
        }
        if demo.contains(where: { agents[$0].needsAttention }) {
            for index in demo { setNeed(nil, at: index, now: Date()) }
            return
        }
        switch Int.random(in: 0..<10) {
        case 0..<4:
            if let index = demo.randomElement() { setNeed(Bool.random() ? .permission : .yourTurn, at: index, now: Date()) }
        case 4..<6 where demo.count < 4: spawn()
        case 6 where demo.count > 1: agents.remove(at: demo.last!)
        default: break
        }
    }
}
