import SwiftUI

/// The black notch shape: concave flares at the top, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, rect.height / 2), w = rect.width, h = rect.height
        var path = Path()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: t, y: t), control: CGPoint(x: t, y: 0))
        path.addLine(to: CGPoint(x: t, y: h - b))
        path.addQuadCurve(to: CGPoint(x: t + b, y: h), control: CGPoint(x: t, y: h))
        path.addLine(to: CGPoint(x: w - t - b, y: h))
        path.addQuadCurve(to: CGPoint(x: w - t, y: h - b), control: CGPoint(x: w - t, y: h))
        path.addLine(to: CGPoint(x: w - t, y: t))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - t, y: 0))
        path.closeSubpath()
        return path
    }
}

/// Whether the notch is open (the pointer is over it), and where the pointer is.
@MainActor @Observable final class NotchState {
    var isOpen = false
    /// The pointer relative to the closed shape's top-left (y grows downward), while it's nearby.
    /// Read every frame by the stage, so deliberately not observed.
    @ObservationIgnored var pointer: CGPoint?
}

struct NotchView: View {
    let metrics: NotchMetrics
    var store: AgentStore
    var state: NotchState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasAgents: Bool { !store.agents.isEmpty }

    var body: some View {
        let size = state.isOpen
            ? metrics.openSize(agentCount: store.agents.count)
            : metrics.shapeSize(expanded: hasAgents)
        let shape = NotchShape(topRadius: metrics.topRadius,
                               bottomRadius: state.isOpen ? 22 : 10)
        ZStack(alignment: .top) {
            shape.fill(.black)
            if state.isOpen {
                OpenNotchView(metrics: metrics, store: store)
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.1)))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(alignment: .top) {
            // Kept alive while open so the walkers carry on where they were when it closes. It reaches below
            // the shape so name tags can hang under the notch; the walkers themselves are clipped to the shape.
            StageView(store: store, pixel: metrics.pixel, notchWidth: metrics.notchWidth,
                      notchHeight: metrics.notchHeight, inset: metrics.topRadius + 10, scatter: false,
                      compact: true, floorInset: metrics.floorInset,
                      clip: NotchShape(topRadius: metrics.topRadius, bottomRadius: 10),
                      labelRoom: StageView.labelRoom, state: state)
                .frame(width: size.width, height: size.height + StageView.labelRoom)
                .frame(height: size.height, alignment: .top)
                .opacity(state.isOpen ? 0 : 1)
                .allowsHitTesting(false)
        }
        .opacity(hasAgents || state.isOpen ? 1 : 0)
        .animation(spring(duration: 0.5, bounce: 0.3), value: hasAgents)
        .animation(spring(duration: 0.42, bounce: 0.25), value: state.isOpen)
        .animation(spring(duration: 0.4, bounce: 0.2), value: store.agents.count)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func spring(duration: Double, bounce: Double) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: duration, bounce: bounce)
    }
}

/// Holds the simulation between frames. Deliberately not observed: the Canvas mutates it while drawing.
@MainActor final class StageBox {
    var stage = Stage()
    var lastTime: Double?
}

/// The walkers, drawn on a Canvas that ticks at 30 fps while anyone is around.
struct StageView: View {
    static let labelRoom: CGFloat = 22

    var store: AgentStore
    let pixel: CGFloat
    /// Characters are hidden behind the notch region at the top centre; zero for none.
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = 0
    var inset: CGFloat
    /// Place newcomers anywhere on the track instead of emerging from the centre.
    var scatter: Bool
    /// Short flags, so a waving Claude fits in the menu bar strip.
    var compact = false
    var floorInset: CGFloat = 4
    /// The shape the walkers live in, when they shouldn't draw outside it.
    var clip: NotchShape?
    /// Extra height under the stage for name tags.
    var labelRoom: CGFloat = 0
    /// Supplies the pointer, for walkers that turn to look and for name tags.
    var state: NotchState?
    /// Claudes can be picked up and dropped on either half, which sets their side of the closed notch.
    var draggable = false
    @State private var box = StageBox()
    @State private var held: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: store.agents.isEmpty)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, date: timeline.date)
            }
        }
        .overlay { if draggable { dragSurface } }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var dragSurface: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        let track = self.track(width: geometry.size.width)
                        if held == nil {
                            held = box.stage.grab(near: drag.startLocation.x, within: CGFloat(Sprite.columns) * pixel)
                        }
                        if let held { box.stage.move(held, to: drag.location.x, track: track) }
                    }
                    .onEnded { drag in
                        guard let id = held else { return }
                        box.stage.drop(id)
                        store.setWing(drag.location.x < geometry.size.width / 2 ? .left : .right, for: id)
                        held = nil
                    })
        }
    }

    private func track(width: CGFloat) -> ClosedRange<CGFloat> {
        let half = inset + CGFloat(Sprite.columns) * pixel / 2
        return half...max(half, width - half)
    }

    private func draw(_ context: inout GraphicsContext, size canvas: CGSize, date: Date) {
        let now = date.timeIntervalSinceReferenceDate
        let dt = box.lastTime.map { now - $0 } ?? 0
        box.lastTime = now
        let size = CGSize(width: canvas.width, height: canvas.height - labelRoom)

        let body = CGFloat(Sprite.columns) * pixel
        let track = track(width: size.width)
        box.stage.reduceMotion = reduceMotion
        // A character touching the notch's edge is the closest it gets.
        let reach = notchWidth / 2 + body / 2
        box.stage.notch = notchWidth > 0 ? (size.width / 2 - reach)...(size.width / 2 + reach) : nil
        // Near means over the shape or just under it.
        let pointer = state?.pointer.flatMap { p in
            (0...size.width).contains(p.x) && (-4...(size.height + 36)).contains(p.y) ? p : nil
        }
        box.stage.pointer = pointer?.x
        box.stage.sync(store.agents.map {
            AgentInput(id: $0.id, need: $0.need, activity: $0.activity, quiet: $0.isQuiet(at: date),
                       subagents: $0.subagents.count, load: $0.load, wing: store.wings[$0.id])
        }, center: size.width / 2, scatter: scatter ? track : nil, died: store.died)
        box.stage.advance(by: dt, track: track, spacing: body)

        let time = box.stage.time
        let frame = reduceMotion ? 0 : Int(time * 6) % 2
        let floor = size.height - floorInset

        if held != nil {
            // While carrying one, show where the two sides of the notch split.
            var divider = Path()
            divider.move(to: CGPoint(x: size.width / 2, y: 4))
            divider.addLine(to: CGPoint(x: size.width / 2, y: size.height - 2))
            context.stroke(divider, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        context.drawLayer { layer in
            if let clip { layer.clip(to: clip.path(in: CGRect(origin: .zero, size: size))) }
            if notchWidth > 0 {
                // Characters walk behind the notch, like the real hardware hides them.
                var outsideNotch = Path(CGRect(origin: .zero, size: canvas))
                outsideNotch.addRect(CGRect(x: (size.width - notchWidth) / 2, y: 0,
                                            width: notchWidth, height: notchHeight))
                layer.clip(to: outsideNotch, style: FillStyle(eoFill: true))
            }
            for walker in box.stage.walkers {
                drawFollowers(of: walker, in: layer, floor: floor, track: track, frame: frame)
                drawWalker(walker, in: layer, floor: floor, center: size.width / 2, pointer: pointer?.x,
                           time: time, frame: frame)
            }
        }

        if labelRoom > 0, pointer != nil {
            drawNameTags(in: &context, below: size.height)
        }
    }

    private func drawWalker(_ walker: Walker, in context: GraphicsContext, floor: CGFloat, center: CGFloat,
                            pointer: CGFloat?, time: Double, frame: Int) {
        let facing: Sprite.Facing = walker.direction > 0 ? .right : .left
        let foot = CGPoint(x: walker.x, y: floor)
        let pack = walker.load
        if walker.held {
            // Dangling from the pointer.
            Sprite.draw(.walk(.front, step: frame), in: context, foot: foot, pixel: pixel, lift: 3, pack: pack)
            return
        }
        if walker.isCelebrating(at: time) {
            // A couple of little hops with sparkles before the flag goes up.
            let hop = Int((abs(sin((walker.celebrateUntil! - time) * .pi * 2.5)) * 2.4).rounded(.down))
            Sprite.draw(.stand(.front), in: context, foot: foot, pixel: pixel, prop: .sparkle(frame: frame), lift: hop,
                        pack: pack)
            return
        }
        switch walker.mood {
        case .greeting(let until):
            let slap = reduceMotion ? 1 : Int((until - time) * 4) % 2
            Sprite.draw(.greet(facing, frame: slap), in: context, foot: foot, pixel: pixel, pack: pack)
        case .crossing:
            Sprite.draw(.walk(facing, step: Int(walker.stride * 7) % 2), in: context, foot: foot, pixel: pixel, pack: pack)
        case .poof(let since):
            Sprite.drawPoof(progress: (time - since) / Stage.poofDuration, in: context, foot: foot, pixel: pixel)
        case .attention:
            // The flag points away from the middle, so it's never tucked behind the notch.
            Sprite.draw(.wave(frame: frame, compact: compact, flagLeft: walker.x < center,
                              color: Sprite.flagColor(for: walker.need ?? .permission)),
                        in: context, foot: foot, pixel: pixel, pack: pack)
        case .resting where walker.quiet:
            Sprite.draw(.stand(.front), in: context, foot: foot, pixel: pixel,
                        prop: .snooze(frame: reduceMotion ? 0 : Int(time * 1.5) % 2), pack: pack)
        case .walking where walker.watching, .resting where walker.watching:
            let look: Sprite.Facing = pointer.map { $0 < walker.x ? .left : .right } ?? .front
            Sprite.draw(.stand(look), in: context, foot: foot, pixel: pixel, prop: prop(for: walker, frame: frame), pack: pack)
        case .walking, .leaving:
            Sprite.draw(.walk(facing, step: Int(walker.stride * 7) % 2), in: context, foot: foot, pixel: pixel,
                        prop: walker.mood == .leaving ? nil : prop(for: walker, frame: frame), pack: pack)
        case .resting:
            Sprite.draw(.stand(.front), in: context, foot: foot, pixel: pixel, prop: prop(for: walker, frame: frame), pack: pack)
        }
    }

    private func prop(for walker: Walker, frame: Int) -> Sprite.Prop? {
        switch walker.activity {
        case .writing: .pencil
        case .reading: .book
        case .running: .hammer(frame: frame)
        case .searching: .magnifier
        case .thinking, .delegating, .other: nil
        }
    }

    /// Sub-agents: tiny Claudes trotting along behind their parent.
    private func drawFollowers(of walker: Walker, in context: GraphicsContext, floor: CGFloat,
                               track: ClosedRange<CGFloat>, frame: Int) {
        guard walker.subagents > 0, !walker.isGhost else { return }
        let mini = max(1, (pixel / 2).rounded(.down))
        let miniWidth = CGFloat(Sprite.columns) * mini
        let behind: CGFloat = walker.direction > 0 ? -1 : 1
        let moving = walker.mood == .walking && !walker.watching
        for index in 0..<min(walker.subagents, 3) {
            let offset = CGFloat(Sprite.columns) * pixel / 2 + 2 + miniWidth / 2 + CGFloat(index) * (miniWidth + 2)
            let x = walker.x + behind * offset
            let pose: Sprite.Pose = moving
                ? .walk(walker.direction > 0 ? .right : .left, step: (Int(walker.stride * 9) + index) % 2)
                : .stand(.front)
            Sprite.draw(pose, in: context, foot: CGPoint(x: x, y: floor), pixel: mini)
        }
    }

    private func drawNameTags(in context: inout GraphicsContext, below top: CGFloat) {
        let names = Dictionary(store.agents.map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a })
        for walker in box.stage.walkers where !walker.isGhost && walker.outside {
            guard let name = names[walker.id] else { continue }
            let text = context.resolve(Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
            let size = text.measure(in: CGSize(width: 200, height: 20))
            let tag = CGRect(x: walker.x - size.width / 2 - 6, y: top + 4, width: size.width + 12, height: size.height + 4)
            context.fill(Path(roundedRect: tag, cornerRadius: tag.height / 2), with: .color(.black.opacity(0.85)))
            context.draw(text, at: CGPoint(x: tag.midX, y: tag.midY))
        }
    }

    private var accessibilityText: String {
        let waiting = store.agents.filter(\.needsAttention).map(\.project)
        if waiting.isEmpty { return "\(store.agents.count) Claude agents working" }
        return "Needs your attention: " + waiting.joined(separator: ", ")
    }
}

/// The hover panel: a header in the wings, a wide stage, and a card per agent.
struct OpenNotchView: View {
    let metrics: NotchMetrics
    var store: AgentStore

    private var waiting: [Agent] { store.agents.filter(\.needsAttention) }
    private var sortedAgents: [Agent] {
        // Whoever is waiting on you comes first, permission prompts before finished turns.
        func rank(_ agent: Agent) -> Int { agent.need == .permission ? 0 : agent.need == .yourTurn ? 1 : 2 }
        return store.agents.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
            .prefix(NotchMetrics.cardColumns * NotchMetrics.maxCardRows)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: NotchMetrics.openGap) {
            header
            ZStack(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.bottom, 3)
                StageView(store: store, pixel: metrics.openPixel, inset: 4, scatter: true, draggable: true)
            }
            .frame(height: metrics.openStageHeight)
            if store.agents.isEmpty {
                Text("No Claude agents running")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: NotchMetrics.cardHeight)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NotchMetrics.openGap),
                                             count: NotchMetrics.cardColumns),
                              spacing: NotchMetrics.openGap) {
                        ForEach(sortedAgents) { agent in
                            AgentCard(agent: agent, now: timeline.date,
                                      open: {
                                          store.acknowledge(agent.id)
                                          WindowFocuser.focus(agent)
                                      },
                                      answer: { store.answer(agent.id, $0) })
                        }
                    }
                }
            }
        }
        .padding(.horizontal, metrics.topRadius + NotchMetrics.openPadding)
        .padding(.bottom, NotchMetrics.openPadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Sits beside the notch, in the strip the menu bar would use.
    private var header: some View {
        HStack {
            Text(store.agents.count == 1 ? "1 agent" : "\(store.agents.count) agents")
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: metrics.notchWidth + 16)
            if !waiting.isEmpty {
                Label("\(waiting.count) waiting", systemImage: "flag.fill")
                    .foregroundStyle(waiting.contains { $0.need == .permission } ? Sprite.flag : Sprite.turnFlag)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(height: metrics.notchHeight)
        .padding(.horizontal, 6)
    }
}

struct AgentCard: View {
    let agent: Agent
    let now: Date
    /// Jump to the session.
    let open: () -> Void
    let answer: (PermissionDecision) -> Void

    private var tint: Color? { agent.need.map(Sprite.flagColor) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    // The conversation's name, then where it runs and what it has cost, then what it's doing.
                    HStack(spacing: 6) {
                        Text(agent.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        if !agent.subagents.isEmpty {
                            Text("+\(agent.subagents.count)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Text(([agent.title == nil ? nil : agent.project,
                           Self.elapsed(from: agent.usage?.startedAt ?? agent.startedAt, to: now),
                           agent.usage.map { Self.dollars($0.costUSD) }] as [String?])
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                    status
                }
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: NotchMetrics.cardHeight,
                       maxHeight: NotchMetrics.cardHeight, alignment: .leading)
                .background(.white.opacity(tint == nil ? 0.06 : 0.12), in: .rect(cornerRadius: 12))
                .overlay {
                    if let tint {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.6), lineWidth: 1)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let usage = agent.usage { ContextBar(fraction: usage.contextFraction) }
                }
                .contentShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help(usageHelp)
            .accessibilityLabel("\(agent.displayName), \(agent.project), " + statusText)

            if agent.ask != nil {
                HStack(spacing: 4) {
                    AnswerButton(title: "Deny", tint: .white.opacity(0.18)) { answer(.deny) }
                    AnswerButton(title: "Allow", tint: Sprite.flag) { answer(.allow) }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let ask = agent.ask {
            Text(ask.summary)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.trailing, 92)
        } else if let need = agent.need {
            Label(statusText, systemImage: need == .permission ? "flag.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Sprite.flagColor(for: need))
        } else {
            Text(agent.lastTool)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var statusText: String {
        guard let need = agent.need else { return agent.lastTool }
        let label = need == .permission ? "Needs permission" : "Your turn"
        return agent.waitingSince.map { "\(label) · \(Self.elapsed(from: $0, to: now))" } ?? label
    }

    private var usageHelp: String {
        let title = agent.title.map { "\($0) (\(agent.project))\n" } ?? ""
        guard let usage = agent.usage else { return title }
        let window = usage.contextWindow >= 1_000_000 ? "\(usage.contextWindow / 1_000_000)M" : "\(usage.contextWindow / 1000)K"
        return title + "Context \(Int((usage.contextFraction * 100).rounded()))% of \(window) tokens · "
            + "\(Self.dollars(usage.costUSD)) at API prices (not counting sub-agents)"
    }

    static func dollars(_ amount: Double) -> String {
        amount < 10 ? String(format: "$%.2f", amount) : String(format: "$%.0f", amount)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

/// A hairline along the bottom of a card: how much of the context window the session has filled.
private struct ContextBar: View {
    let fraction: Double

    private var color: Color {
        switch Load(fraction: fraction) {
        case .light: .white.opacity(0.35)
        case .heavy: Color(red: 1, green: 0.75, blue: 0.3)
        case .full: Sprite.flag
        }
    }

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(color)
                .frame(width: max(2, (geometry.size.width - 20) * fraction), height: 2)
                .padding(.leading, 10)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 5)
        }
        .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent full")
    }
}

private struct AnswerButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(tint, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
