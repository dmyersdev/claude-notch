import SwiftUI

/// Colours and type for the open panel, kept in one place so rows and tiles agree.
enum Panel {
    static let primary = Color.white
    /// Secondary text at 0.62 keeps small type above 4.5:1 on the dark cards.
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.45)
    static let surface = Color.white.opacity(0.07)
    static let surfaceHover = Color.white.opacity(0.11)
    static let inset = Color.black.opacity(0.35)
    static let radius: CGFloat = 10

    static let title = Font.system(size: 12, weight: .semibold)
    static let detail = Font.system(size: 11)
    static let meta = Font.system(size: 10.5, weight: .medium).monospacedDigit()
    static let label = Font.system(size: 10, weight: .semibold)
}

/// The hover panel: a header in the wings, a short stage, sessions waiting on you, then everyone else.
struct OpenNotchView: View {
    let metrics: NotchMetrics
    var store: AgentStore

    var body: some View {
        let sections = PanelLayout.sections(store.present)
        let layout = PanelLayout(agents: store.present, away: store.away.count)
        VStack(spacing: NotchMetrics.openGap) {
            header(waiting: store.present.filter(\.needsAttention))
            ZStack(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.bottom, 3)
                StageView(store: store, pixel: metrics.openPixel, inset: 4, scatter: true, draggable: true)
            }
            .frame(height: metrics.openStageHeight)

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(spacing: NotchMetrics.openGap) {
                    if layout.isEmpty {
                        Text(store.away.isEmpty ? "No Claude Code sessions running" : "Everyone's tucked away")
                            .font(Panel.detail)
                            .foregroundStyle(Panel.secondary)
                            .frame(maxWidth: .infinity, minHeight: NotchMetrics.emptyHeight)
                    }
                    if !sections.waiting.isEmpty {
                        SectionLabel(title: "Needs you", count: store.present.filter(\.needsAttention).count)
                        ForEach(sections.waiting) { agent in
                            WaitingRow(agent: agent, now: timeline.date,
                                       open: { jump(to: agent) }, answer: { store.answer(agent.id, $0) },
                                       tuck: { store.tuckAway(agent.id) })
                        }
                    }
                    if !sections.others.isEmpty {
                        SectionLabel(title: "Working", count: store.present.count - store.present.filter(\.needsAttention).count,
                                     more: layout.hidden)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NotchMetrics.openGap),
                                                 count: PanelLayout.tileColumns),
                                  spacing: NotchMetrics.openGap) {
                            ForEach(sections.others) { agent in
                                SessionTile(agent: agent, now: timeline.date, open: { jump(to: agent) },
                                            tuck: { store.tuckAway(agent.id) })
                            }
                        }
                    }
                    if !store.away.isEmpty {
                        SectionLabel(title: "Away", count: store.away.count)
                        AwayRow(agents: store.away) { store.bringBack($0.id) }
                    }
                }
            }
        }
        .padding(.horizontal, metrics.topRadius + NotchMetrics.openPadding)
        .padding(.bottom, NotchMetrics.openPadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func jump(to agent: Agent) {
        store.acknowledge(agent.id)
        WindowFocuser.focus(agent)
    }

    /// Sits beside the notch, in the strip the menu bar would use.
    private func header(waiting: [Agent]) -> some View {
        let blocked = waiting.filter { $0.need == .permission }.count
        let done = waiting.count - blocked
        return HStack(spacing: 10) {
            Text(store.present.count == 1 ? "1 session" : "\(store.present.count) sessions")
                .foregroundStyle(Panel.secondary)
            Spacer(minLength: metrics.notchWidth + 16)
            if blocked > 0 {
                Label("\(blocked) blocked", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(Sprite.flag)
            }
            if done > 0 {
                Label("\(done) your turn", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Sprite.turnFlag)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .labelStyle(.titleAndIcon)
        .frame(height: metrics.notchHeight)
        .padding(.horizontal, 6)
    }
}

private struct SectionLabel: View {
    let title: String
    let count: Int
    var more = 0

    var body: some View {
        HStack {
            Text("\(title.uppercased())  \(count)")
            Spacer()
            if more > 0 { Text("+\(more) more") }
        }
        .font(Panel.label)
        .tracking(0.6)
        .foregroundStyle(Panel.tertiary)
        .frame(height: NotchMetrics.sectionLabelHeight)
    }
}

/// A session waiting on you: full width, coloured by why. With a prompt, the whole command and the answer.
struct WaitingRow: View {
    let agent: Agent
    let now: Date
    let open: () -> Void
    let answer: (PermissionDecision) -> Void
    let tuck: () -> Void
    @State private var hovering = false

    private var tint: Color { Sprite.flagColor(for: agent.need ?? .permission) }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Button(action: open) { summary }.buttonStyle(.plain)
                if let ask = agent.ask {
                    HStack(alignment: .center, spacing: 8) {
                        Text(ask.summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Panel.primary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .padding(.horizontal, 8)
                            .background(Panel.inset, in: .rect(cornerRadius: 6))
                        AnswerButton(title: "Deny", style: .secondary) { answer(.deny) }
                        AnswerButton(title: "Allow", style: .primary) { answer(.allow) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(height: agent.ask == nil ? NotchMetrics.waitingRowHeight : NotchMetrics.askRowHeight)
        .background(hovering ? Panel.surfaceHover : Panel.surface, in: .rect(cornerRadius: Panel.radius))
        .clipShape(.rect(cornerRadius: Panel.radius))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agent.displayName), \(statusText)")
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
                if hovering { TuckButton(action: tuck) }
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? Panel.primary : Panel.tertiary)
                    .help("Jump to the session")
            }
            HStack(spacing: 5) {
                Image(systemName: agent.need == .permission ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(tint)
                Text(statusText).foregroundStyle(Panel.secondary)
                let meta = Format.meta(project: agent.title == nil ? nil : agent.project, usage: agent.usage)
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
        case .permission: agent.ask == nil ? "Needs permission: answer in its window" : "Asking permission"
        case .yourTurn: "Finished, your turn"
        case nil: agent.lastTool
        }
    }
}

/// Everyone not waiting on you: what it's doing, where, and how full its context is.
struct SessionTile: View {
    let agent: Agent
    let now: Date
    let open: () -> Void
    let tuck: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(agent.displayName).font(Panel.title).foregroundStyle(Panel.primary)
                    if !agent.subagents.isEmpty {
                        Text("+\(agent.subagents.count)")
                            .font(Panel.label)
                            .foregroundStyle(Panel.secondary)
                            .help("\(agent.subagents.count) sub-agents running")
                    }
                }
                Text(Format.meta(project: agent.title == nil ? nil : agent.project,
                                 elapsed: Format.elapsed(from: agent.usage?.startedAt ?? agent.startedAt, to: now),
                                 usage: agent.usage))
                    .font(Panel.meta)
                    .foregroundStyle(Panel.tertiary)
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
            .background(hovering ? Panel.surfaceHover : Panel.surface, in: .rect(cornerRadius: Panel.radius))
            .contentShape(.rect(cornerRadius: Panel.radius))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovering { TuckButton(action: tuck).padding(7) }
        }
        .onHover { hovering = $0 }
        .help(Format.usageHelp(agent))
        .accessibilityLabel("\(agent.displayName), \(agent.lastTool)")
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

/// Sessions tucked away: one chip each. Click one to bring it back.
private struct AwayRow: View {
    static let shown = 5
    let agents: [Agent]
    let bringBack: (Agent) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(agents.prefix(Self.shown)) { agent in
                Button { bringBack(agent) } label: {
                    Label(agent.shortName, systemImage: "moon.zzz")
                        .font(Panel.detail)
                        .foregroundStyle(Panel.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: NotchMetrics.awayRowHeight)
                        .background(Panel.surface, in: .capsule)
                }
                .buttonStyle(.plain)
                .help("Bring back \(agent.displayName)")
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
    let style: Style
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style == .primary ? Color.black : Panel.primary)
                .frame(width: 62, height: 30)
                .background(style == .primary ? Color.white.opacity(hovering ? 1 : 0.9) : Color.white.opacity(hovering ? 0.2 : 0.12),
                            in: .rect(cornerRadius: 7))
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

    /// "react · 12m · $1.24", leaving out whatever isn't known.
    static func meta(project: String?, elapsed: String? = nil, usage: SessionUsage?) -> String {
        [project, elapsed, usage.map { dollars($0.costUSD) }].compactMap { $0 }.joined(separator: " · ")
    }

    static func usageHelp(_ agent: Agent) -> String {
        let title = agent.title.map { "\($0) (\(agent.project))\n" } ?? ""
        guard let usage = agent.usage else { return title }
        let window = usage.contextWindow >= 1_000_000 ? "\(usage.contextWindow / 1_000_000)M" : "\(usage.contextWindow / 1000)K"
        return title + "Context \(Int((usage.contextFraction * 100).rounded()))% of \(window) tokens · "
            + "\(dollars(usage.costUSD)) at API prices (not counting sub-agents)"
    }
}
