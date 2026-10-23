import SwiftUI

/// Colours and type for the open panel, kept in one place so rows and tiles agree.
enum Panel {
    static let primary = Color.white
    /// Secondary text at 0.62 keeps small type above 4.5:1 on the dark cards.
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.45)
    static let surface = Color.white.opacity(0.06)
    static let surfaceHover = Color.white.opacity(0.10)
    /// A hairline round each card, so cards read as cards on pure black.
    static let stroke = Color.white.opacity(0.08)
    static let inset = Color.white.opacity(0.05)
    static let amber = Color(red: 1, green: 0.75, blue: 0.3)
    static let radius: CGFloat = 12

    static let title = Font.system(size: 12, weight: .semibold)
    static let detail = Font.system(size: 11)
    static let meta = Font.system(size: 10.5, weight: .medium).monospacedDigit()
    static let label = Font.system(size: 10, weight: .semibold)
}

/// A card's background: a soft fill, a hairline, and an optional wash of colour from the leading edge.
private struct CardBackground: View {
    var hovering = false
    var tint: Color?
    var selected = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Panel.radius, style: .continuous)
        ZStack {
            shape.fill(hovering ? Panel.surfaceHover : Panel.surface)
            if let tint {
                shape.fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0)], startPoint: .leading,
                                          endPoint: UnitPoint(x: 0.6, y: 0.5)))
            }
            shape.strokeBorder(selected ? Color.white.opacity(0.6) : Panel.stroke, lineWidth: selected ? 1.5 : 1)
        }
    }
}

/// The hover panel: a header in the wings, a short stage, sessions waiting on you, then everyone else.
struct OpenNotchView: View {
    let metrics: NotchMetrics
    var store: AgentStore
    var state: NotchState
    var hooks = HookStatus.shared

    var body: some View {
        let shown = state.shown(store)
        let sections = PanelLayout.sections(shown)
        let layout = state.layout(store)
        let waitingCount = shown.filter(\.needsAttention).count
        VStack(spacing: NotchMetrics.openGap) {
            PanelHeader(metrics: metrics, store: store, state: state)
            if layout.banner { banner }
            ZStack(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.bottom, 3)
                StageView(store: store, pixel: metrics.openPixel, inset: 4, scatter: true, draggable: true)
            }
            .frame(height: metrics.openStageHeight)

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(spacing: NotchMetrics.openGap) {
                    if layout.isEmpty { empty }
                    if !sections.waiting.isEmpty {
                        SectionLabel(title: "Needs you", count: waitingCount, hint: keyHint)
                        ForEach(sections.waiting) { agent in
                            WaitingRow(agent: agent, now: timeline.date, selected: isSelected(agent),
                                       canReply: store.canControl(agent.id),
                                       open: { jump(to: agent) }, answer: { store.answer(agent.id, $0) },
                                       tuck: { store.tuckAway(agent.id) },
                                       snooze: { store.snooze(agent.id, for: $0) },
                                       reply: { store.reply(agent.id, $0) })
                        }
                    }
                    if !sections.others.isEmpty {
                        SectionLabel(title: "Working", count: shown.count - waitingCount,
                                     more: layout.hidden, hint: sections.waiting.isEmpty ? keyHint : nil)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NotchMetrics.openGap),
                                                 count: PanelLayout.tileColumns),
                                  spacing: NotchMetrics.openGap) {
                            ForEach(sections.others) { agent in
                                SessionTile(agent: agent, now: timeline.date, selected: isSelected(agent),
                                            open: { jump(to: agent) },
                                            tuck: { store.tuckAway(agent.id) },
                                            stop: store.canControl(agent.id) && !agent.idle ? { store.interrupt(agent.id) } : nil)
                            }
                        }
                    }
                    if !store.away.isEmpty {
                        SectionLabel(title: "Away", count: store.away.count)
                        AwayRow(agents: store.away, now: timeline.date) { store.bringBack($0.id) }
                    }
                }
            }
        }
        .padding(.horizontal, metrics.topRadius + NotchMetrics.openPadding)
        .padding(.bottom, NotchMetrics.openPadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 3) {
            if let query = state.query, !query.isEmpty {
                Text("Nothing matches “\(query)”").font(Panel.title).foregroundStyle(Panel.secondary)
                Text("Search looks at names, folders and what each session is doing.").font(Panel.detail).foregroundStyle(Panel.tertiary)
            } else if store.away.isEmpty {
                Text("No sessions running").font(Panel.title).foregroundStyle(Panel.secondary)
                Text("Start claude in a terminal and it walks out here.").font(Panel.detail).foregroundStyle(Panel.tertiary)
            } else {
                Text("Everyone's tucked away").font(Panel.title).foregroundStyle(Panel.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: NotchMetrics.emptyHeight)
    }

    /// A notice, or the hooks having gone missing.
    @ViewBuilder private var banner: some View {
        HStack(spacing: 8) {
            if hooks.missing {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Panel.amber)
                Text("Claude Code's hooks are gone from settings.json, so prompts won't reach the notch.")
                    .foregroundStyle(Panel.primary)
                Spacer(minLength: 4)
                SmallButton(title: "Reinstall") { hooks.set(installed: true) }
            } else if let notice = store.notice {
                Image(systemName: "info.circle.fill").foregroundStyle(Panel.secondary)
                Text(notice).foregroundStyle(Panel.primary)
                Spacer(minLength: 0)
            }
        }
        .font(Panel.detail)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: NotchMetrics.bannerHeight)
        .background(CardBackground(tint: hooks.missing ? Panel.amber : nil))
    }

    private var keyHint: String { state.keyboardActive ? PanelKey.hint : "Click for keyboard shortcuts" }

    private func isSelected(_ agent: Agent) -> Bool { state.keyboardActive && state.selectedID == agent.id }

    private func jump(to agent: Agent) {
        store.acknowledge(agent.id)
        WindowFocuser.focus(agent)
    }
}

/// Sits beside the notch, in the strip the menu bar would use: counts and plan usage on the left; what needs you,
/// search and Settings on the right.
private struct PanelHeader: View {
    let metrics: NotchMetrics
    var store: AgentStore
    var state: NotchState
    @FocusState private var searchFocused: Bool

    var body: some View {
        let waiting = store.present.filter(\.needsAttention)
        let blocked = waiting.filter { $0.need == .permission }.count
        let done = waiting.count - blocked
        HStack(spacing: 8) {
            if let query = state.query {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Panel.secondary)
                    TextField("Search sessions", text: Binding(get: { query }, set: { state.query = $0 }))
                        .textFieldStyle(.plain)
                        .foregroundStyle(Panel.primary)
                        .focused($searchFocused)
                        .onSubmit {
                            if let first = PanelKeyboard.order(store, state: state).first,
                               let agent = store.agents.first(where: { $0.id == first }) {
                                store.acknowledge(agent.id)
                                WindowFocuser.focus(agent)
                            }
                        }
                    Button { state.query = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Panel.tertiary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Panel.inset, in: .capsule)
                .overlay(Capsule().strokeBorder(Panel.stroke))
                .onAppear { searchFocused = true }
            } else {
                Text(store.present.count == 1 ? "1 session" : "\(store.present.count) sessions")
                    .foregroundStyle(Panel.secondary)
                if let usage = store.planUsage { PlanPill(usage: usage) }
            }
            Spacer(minLength: metrics.notchWidth + 16)
            if blocked > 0 {
                Chip(symbol: "exclamationmark.octagon.fill", text: "\(blocked)", tint: Sprite.flag)
                    .help("\(blocked) blocked on a prompt")
            }
            if done > 0 {
                Chip(symbol: "checkmark.circle.fill", text: "\(done)", tint: Sprite.turnFlag)
                    .help("\(done) finished: your turn")
            }
            if Preferences.shared.budgets.isTotalOver(store.present) {
                Chip(symbol: "dollarsign.circle.fill", text: Format.dollars(Budget.spent(store.present)), tint: Panel.amber)
                    .help("Running sessions are over your total budget")
            }
            if Preferences.shared.isQuiet {
                Image(systemName: "moon.fill").foregroundStyle(Panel.tertiary).help("Quiet: no sounds or phone alerts")
            }
            HeaderButton(symbol: "magnifyingglass", help: "Search (/)") {
                state.query = state.query == nil ? "" : nil
            }
            HeaderButton(symbol: "gearshape.fill", help: "Settings (⌘,)") { SettingsWindow.shared.show() }
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(height: metrics.notchHeight)
        .padding(.horizontal, 6)
        .onChange(of: searchFocused) { _, focused in state.editingSearch = focused }
    }
}

private struct Chip: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 11, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(tint.opacity(0.16), in: .capsule)
    }
}

/// The plan's 5-hour and weekly use, from the Claude app's own cache.
private struct PlanPill: View {
    let usage: PlanUsage

    var body: some View {
        let tint = usage.isHigh ? Panel.amber : Panel.secondary
        HStack(spacing: 6) {
            Text("5h \(usage.fiveHour)%")
            Text("wk \(usage.weekly)%")
        }
        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(tint.opacity(0.12), in: .capsule)
        .help("Plan usage: \(usage.fiveHour)% of the 5-hour window, \(usage.weekly)% of the week. As of \(Format.elapsed(from: usage.at, to: Date())) ago, from the Claude app.")
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Panel.primary : Panel.secondary)
                .frame(width: 24, height: 22)
                .background(Color.white.opacity(hovering ? 0.14 : 0.06), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct SectionLabel: View {
    let title: String
    let count: Int
    var more = 0
    var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).tracking(0.6)
            Text("\(count)")
                .padding(.horizontal, 5)
                .background(Color.white.opacity(0.1), in: .capsule)
            Spacer()
            if let hint { Text(hint).textCase(nil) }
            if more > 0 { Text("+\(more) more · / to search") }
        }
        .font(Panel.label)
        .foregroundStyle(Panel.tertiary)
        .frame(height: NotchMetrics.sectionLabelHeight)
    }
}

/// A session waiting on you: full width, coloured by why. With a prompt, the whole command and the answer.
struct WaitingRow: View {
    let agent: Agent
    let now: Date
    var selected = false
    /// Its terminal can take a typed reply.
    var canReply = false
    let open: () -> Void
    let answer: (PermissionDecision) -> Void
    let tuck: () -> Void
    var snooze: (TimeInterval) -> Void = { _ in }
    var reply: (String) -> Void = { _ in }
    @State private var hovering = false
    /// Non-nil while writing a reason to deny with.
    @State private var denyReason: String?
    @State private var replyText = ""

    private var tint: Color { Sprite.flagColor(for: agent.need ?? .permission) }

    var body: some View {
        HStack(spacing: 0) {
            Capsule().fill(tint).frame(width: 3).padding(.vertical, 10).padding(.leading, 6)
            VStack(alignment: .leading, spacing: 6) {
                Button(action: open) { summary }.buttonStyle(.plain)
                if agent.need == .yourTurn, agent.hasReview {
                    ReviewBlock(agent: agent)
                }
                if agent.need == .yourTurn, canReply { replyField }
                if let request = agent.ask?.request {
                    if request.isQuestion {
                        if request.questions.count <= PanelLayout.maxInlineQuestions {
                            QuestionsView(questions: request.questions) { answer(.answer($0)) }
                        }
                    } else if let reason = denyReason {
                        // Telling Claude why: the reason replaces the command until it's sent or cancelled.
                        HStack(spacing: 8) {
                            TextField("Tell Claude why, then press Return", text: Binding(
                                get: { reason }, set: { denyReason = $0 }))
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(Panel.primary)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .padding(.horizontal, 8)
                                .background(Panel.inset, in: .rect(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Panel.stroke))
                                .onSubmit { answer(.denyBecause(reason)); denyReason = nil }
                            AnswerButton(title: "Cancel", style: .secondary) { denyReason = nil }
                            AnswerButton(title: "Deny", symbol: "xmark", style: .primary) { answer(.denyBecause(reason)); denyReason = nil }
                        }
                    } else {
                        HStack(alignment: .center, spacing: 8) {
                            Text(request.summary)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Panel.primary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .padding(.horizontal, 8)
                                .background(Panel.inset, in: .rect(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Panel.stroke))
                            Button { denyReason = "" } label: {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Panel.secondary)
                                    .frame(width: 26, height: 30)
                            }
                            .buttonStyle(.plain)
                            .help("Deny, and tell Claude why")
                            AnswerButton(title: "Deny", style: .secondary) { answer(.deny) }
                            if request.canAlways {
                                AnswerButton(title: "Always", style: .secondary) { answer(.always) }
                                    .help("Allow, and don't ask again for this")
                            }
                            AnswerButton(title: "Allow", symbol: "checkmark", style: .primary) { answer(.allow) }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(height: PanelLayout.rowHeight(for: agent, canReply: canReply))
        .background(CardBackground(hovering: hovering, tint: tint, selected: selected))
        .clipShape(.rect(cornerRadius: Panel.radius, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agent.displayName), \(statusText)")
    }

    /// The next prompt, typed into the session's terminal.
    private var replyField: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 10)).foregroundStyle(Panel.tertiary)
            TextField("Reply to Claude…", text: $replyText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Panel.primary)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(replyText.isEmpty ? Panel.tertiary : Panel.primary)
            }
            .buttonStyle(.plain)
            .disabled(replyText.isEmpty)
            .help("Send as the next prompt")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(Panel.inset, in: .capsule)
        .overlay(Capsule().strokeBorder(Panel.stroke))
    }

    private func send() {
        guard !replyText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        reply(replyText)
        replyText = ""
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(agent.displayName).font(Panel.title).foregroundStyle(Panel.primary)
                Spacer(minLength: 6)
                if let since = agent.waitingSince {
                    Text(Format.elapsed(from: since, to: now))
                        .font(Panel.meta)
                        .foregroundStyle(tint)
                }
                if hovering {
                    SnoozeMenu(snooze: snooze)
                    TuckButton(action: tuck)
                }
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? Panel.primary : Panel.tertiary)
                    .help("Jump to the session")
            }
            HStack(spacing: 5) {
                Image(systemName: agent.need == .permission ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(tint)
                Text(statusText).foregroundStyle(Panel.secondary)
                let meta = Format.meta(project: agent.title == nil ? nil : agent.project, usage: agent.usage, kind: agent.kind)
                if !meta.isEmpty {
                    Text("· " + meta).foregroundStyle(Panel.tertiary)
                }
            }
            .font(Panel.detail)
            .lineLimit(1)
        }
        .contentShape(.rect)
    }

    private var statusText: String {
        switch agent.need {
        case .permission:
            if let request = agent.ask?.request {
                request.isQuestion
                    ? (request.questions.count > PanelLayout.maxInlineQuestions
                        ? "Asking \(request.questions.count) questions: answer in its window" : "Has a question for you")
                    : "Asking permission"
            } else {
                "Needs permission: answer in its window"
            }
        case .yourTurn: agent.turnChanges.isEmpty ? "Finished, your turn" : "Ready for review"
        case nil: agent.lastTool
        }
    }
}

/// "Remind me later": out of sight, then back with a nudge.
private struct SnoozeMenu: View {
    let snooze: (TimeInterval) -> Void

    var body: some View {
        Menu {
            Button("10 minutes") { snooze(10 * 60) }
            Button("30 minutes") { snooze(30 * 60) }
            Button("1 hour") { snooze(60 * 60) }
        } label: {
            Image(systemName: "clock.fill").font(.system(size: 11)).foregroundStyle(Panel.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Remind me later (Z)")
    }
}

/// Everyone not waiting on you: what it's doing, where, and how full its context is.
struct SessionTile: View {
    let agent: Agent
    let now: Date
    var selected = false
    let open: () -> Void
    let tuck: () -> Void
    /// Present when its terminal can take an Esc to stop the turn.
    var stop: (() -> Void)?
    @State private var hovering = false
    @State private var showingSteps = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    Text(agent.displayName).font(Panel.title).foregroundStyle(Panel.primary)
                    if !agent.subagents.isEmpty {
                        Text("+\(agent.subagents.count)")
                            .font(Panel.label)
                            .foregroundStyle(Panel.secondary)
                            .padding(.horizontal, 4)
                            .background(Color.white.opacity(0.1), in: .capsule)
                            .help("\(agent.subagents.count) sub-agents running")
                    }
                }
                HStack(spacing: 4) {
                    Text(Format.meta(project: agent.title == nil ? nil : agent.project,
                                     elapsed: Format.elapsed(from: agent.usage?.startedAt ?? agent.startedAt, to: now),
                                     usage: agent.usage, kind: agent.kind))
                        .foregroundStyle(Panel.tertiary)
                    if Preferences.shared.budgets.isOver(agent) {
                        Image(systemName: "dollarsign.circle.fill")
                            .foregroundStyle(Panel.amber)
                            .help("Over your per-session budget")
                    }
                }
                .font(Panel.meta)
                HStack(spacing: 5) {
                    Image(systemName: icon).foregroundStyle(Panel.secondary).frame(width: 12)
                    Text(agent.lastTool).foregroundStyle(Panel.secondary)
                    Spacer(minLength: 4)
                    if let usage = agent.usage { ContextGauge(fraction: usage.contextFraction) }
                }
                .font(Panel.detail)
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: NotchMetrics.tileHeight, maxHeight: NotchMetrics.tileHeight,
                   alignment: .leading)
            .background(CardBackground(hovering: hovering, selected: selected))
            .contentShape(.rect(cornerRadius: Panel.radius))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering || showingSteps {
                HStack(spacing: 7) {
                    if let stop {
                        Button(action: stop) {
                            Image(systemName: "stop.circle.fill").font(.system(size: 12)).foregroundStyle(Sprite.flag)
                        }
                        .buttonStyle(.plain)
                        .help("Stop this turn (Esc in its terminal)")
                    }
                    if !agent.timeline.isEmpty {
                        Button { showingSteps.toggle() } label: {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 12))
                                .foregroundStyle(Panel.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("What it's been doing")
                        .popover(isPresented: $showingSteps, arrowEdge: .bottom) { StepList(agent: agent) }
                    }
                    TuckButton(action: tuck)
                }
                .padding(8)
            }
        }
        .onHover { hovering = $0 }
        .help(Format.usageHelp(agent))
        .accessibilityLabel("\(agent.displayName), \(agent.lastTool)")
    }

    /// Green while working, dim while dozing.
    private var dotColor: Color {
        agent.isQuiet(at: now) ? Color.white.opacity(0.25) : Sprite.turnFlag
    }

    /// What it's doing, as a symbol: matches the prop its Claude carries.
    private var icon: String {
        if agent.isQuiet(at: now) { return "moon.zzz" }
        return switch agent.activity {
        case .writing: "pencil"
        case .reading: "book"
        case .running: "hammer"
        case .searching: "magnifyingglass"
        case .delegating: "person.2"
        case .thinking: "ellipsis"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// How full the context window is: a short bar plus the number, amber past 40%, red past 70%.
private struct ContextGauge: View {
    let fraction: Double

    private var color: Color {
        switch Load(fraction: fraction) {
        case .light: Panel.secondary
        case .heavy: Color(red: 1, green: 0.75, blue: 0.3)
        case .full: Sprite.flag
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(color).frame(width: max(2, 22 * fraction))
            }
            .frame(width: 22, height: 3)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(Panel.meta)
                .foregroundStyle(color)
        }
        .help("Context window used")
        .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent full")
    }
}

/// A finished turn, ready to review: Claude's last words, the files it changed, how the tests went.
struct ReviewBlock: View {
    let agent: Agent
    @State private var showingChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = agent.lastMessage {
                Text(message)
                    .font(Panel.detail)
                    .foregroundStyle(Panel.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                ForEach(agent.turnChanges.prefix(3), id: \.path) { change in
                    FileChip(change: change)
                }
                if agent.turnChanges.count > 3 {
                    Text("+\(agent.turnChanges.count - 3) files").font(Panel.meta).foregroundStyle(Panel.tertiary)
                }
                if let passed = agent.testsPassed {
                    Label(passed ? "Tests passed" : "Tests failed",
                          systemImage: passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(Panel.meta)
                        .foregroundStyle(passed ? Sprite.turnFlag : Sprite.flag)
                }
                Spacer(minLength: 4)
                if !agent.turnChanges.isEmpty {
                    SmallButton(title: "Changes") { showingChanges.toggle() }
                        .popover(isPresented: $showingChanges, arrowEdge: .bottom) { DiffList(changes: agent.turnChanges) }
                    if let folder = agent.cwd {
                        SmallButton(title: "Open PR") { GitInfo.openPullRequest(in: folder) }
                            .help("Open a pull request for this branch on GitHub")
                    }
                }
            }
        }
    }
}

private struct FileChip: View {
    let change: FileChange

    var body: some View {
        HStack(spacing: 4) {
            Text(change.name).foregroundStyle(Panel.primary)
            Text("+\(change.added)").foregroundStyle(Sprite.turnFlag)
            Text("−\(change.removed)").foregroundStyle(Sprite.flag.opacity(0.9))
        }
        .font(.system(size: 10.5, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Panel.inset, in: .rect(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Panel.stroke))
        .help(change.path)
    }
}

private struct SmallButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Panel.primary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Color.white.opacity(hovering ? 0.2 : 0.12), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The edits a turn made, as a small diff: removed lines in red, added in green.
struct DiffList: View {
    let changes: [FileChange]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(changes, id: \.path) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(change.name).font(.system(size: 12, weight: .semibold))
                            Text("+\(change.added) −\(change.removed)").font(Panel.meta).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .help(change.path)
                        ForEach(Array(change.hunks.enumerated()), id: \.offset) { _, hunk in
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(hunk.removed.enumerated()), id: \.offset) { _, line in
                                    DiffLine(text: line, added: false)
                                }
                                ForEach(Array(hunk.added.enumerated()), id: \.offset) { _, line in
                                    DiffLine(text: line, added: true)
                                }
                            }
                            .clipShape(.rect(cornerRadius: 4))
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 520, height: 380)
    }
}

private struct DiffLine: View {
    let text: String
    let added: Bool

    var body: some View {
        Text((added ? "+ " : "- ") + text)
            .font(.system(size: 10.5, design: .monospaced))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .background((added ? Color.green : Color.red).opacity(0.14))
    }
}

/// A session's recent steps, newest first: what it ran, edited and read, how long each took, and what failed.
struct StepList: View {
    let agent: Agent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(agent.displayName).font(.system(size: 12, weight: .semibold)).padding(.bottom, 2)
                ForEach(agent.timeline.suffix(40).reversed()) { step in
                    HStack(spacing: 6) {
                        Image(systemName: step.failed ? "xmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(step.failed ? Sprite.flag : .secondary)
                        Text(step.summary).lineLimit(1)
                        Spacer(minLength: 8)
                        if let change = step.change {
                            Text("+\(change.added) −\(change.removed)").foregroundStyle(.secondary)
                        }
                        if let duration = step.duration, duration >= 1 {
                            Text(Format.elapsed(from: .distantPast, to: Date.distantPast.addingTimeInterval(duration)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(12)
        }
        .frame(width: 420, height: 320)
    }
}

/// Claude's multiple-choice questions, answered right on the card. One plain question answers on a tap.
struct QuestionsView: View {
    let questions: [Question]
    let send: ([String: [String]]) -> Void
    @State private var picked: [String: [String]] = [:]

    private var needsSend: Bool { PanelLayout.needsSend(questions) }
    private var complete: Bool { questions.allSatisfy { !(picked[$0.text] ?? []).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 5) {
                    Text(question.text + (question.multiSelect ? "  (pick any)" : ""))
                        .font(Panel.detail)
                        .foregroundStyle(Panel.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        ForEach(question.options) { option in
                            OptionChip(label: option.label,
                                       selected: picked[question.text]?.contains(option.label) == true) {
                                pick(option.label, in: question)
                            }
                            .help(option.detail ?? option.label)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if needsSend {
                HStack {
                    Spacer()
                    AnswerButton(title: "Send", style: .primary) { send(picked) }
                        .disabled(!complete)
                        .opacity(complete ? 1 : 0.4)
                }
            }
        }
    }

    private func pick(_ label: String, in question: Question) {
        var chosen = picked[question.text] ?? []
        if question.multiSelect {
            if let index = chosen.firstIndex(of: label) { chosen.remove(at: index) } else { chosen.append(label) }
        } else {
            chosen = [label]
        }
        picked[question.text] = chosen
        if !needsSend { send(picked) }
    }
}

private struct OptionChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Color.black : Panel.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(selected ? Color.white.opacity(0.92) : Color.white.opacity(hovering ? 0.2 : 0.12),
                            in: .capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Tucks a session away until it does something new.
private struct TuckButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Panel.secondary)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Tuck away until it's active again")
        .accessibilityLabel("Tuck away")
    }
}

/// Sessions tucked away (or snoozed): one chip each. Click one to bring it back.
private struct AwayRow: View {
    static let shown = 5
    let agents: [Agent]
    let now: Date
    let bringBack: (Agent) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(agents.prefix(Self.shown)) { agent in
                Button { bringBack(agent) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: agent.snoozedUntil == nil ? "moon.zzz" : "clock")
                        Text(agent.shortName)
                        if let until = agent.snoozedUntil {
                            Text(Format.elapsed(from: now, to: until)).foregroundStyle(Panel.tertiary).monospacedDigit()
                        }
                    }
                    .font(Panel.detail)
                    .foregroundStyle(Panel.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: NotchMetrics.awayRowHeight)
                    .background(Panel.surface, in: .capsule)
                    .overlay(Capsule().strokeBorder(Panel.stroke))
                }
                .buttonStyle(.plain)
                .help(agent.snoozedUntil == nil ? "Bring back \(agent.displayName)" : "Snoozed: bring back \(agent.displayName) now")
            }
            if agents.count > Self.shown {
                Text("+\(agents.count - Self.shown)").font(Panel.detail).foregroundStyle(Panel.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: NotchMetrics.awayRowHeight)
    }
}

private struct AnswerButton: View {
    enum Style { case primary, secondary }
    let title: String
    var symbol: String?
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(style == .primary ? Color.black : Panel.primary)
            .frame(minWidth: 62)
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(style == .primary ? Color.white.opacity(hovering ? 1 : 0.9) : Color.white.opacity(hovering ? 0.18 : 0.1),
                        in: .rect(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum Format {
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    static func dollars(_ amount: Double) -> String {
        amount < 10 ? String(format: "$%.2f", amount) : String(format: "$%.0f", amount)
    }

    /// "react · 12m · $1.24", leaving out whatever isn't known (Codex has no price we know).
    static func meta(project: String?, elapsed: String? = nil, usage: SessionUsage?, kind: AgentKind = .claude) -> String {
        [kind == .codex ? "Codex" : nil, project, elapsed, usage.flatMap { $0.priced ? dollars($0.costUSD) : nil }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func usageHelp(_ agent: Agent) -> String {
        let title = agent.title.map { "\($0) (\(agent.project))\n" } ?? ""
        guard let usage = agent.usage else { return title }
        let window = usage.contextWindow >= 1_000_000 ? "\(usage.contextWindow / 1_000_000)M" : "\(usage.contextWindow / 1000)K"
        let context = title + "Context \(Int((usage.contextFraction * 100).rounded()))% of \(window) tokens"
        return usage.priced ? context + " · \(dollars(usage.costUSD)) at API prices (not counting sub-agents)" : context
    }
}
