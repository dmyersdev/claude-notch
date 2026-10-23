import SwiftUI

/// The black notch shape: concave flares at the top, rounded bottom corners. Under the menu bar style, a narrower
/// stem (the notch) drops into a wider strip: `stemLeft`/`stemRight` are how far the strip reaches past the stem.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var stemLeft: CGFloat = 0
    var stemRight: CGFloat = 0
    var stemHeight: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(bottomRadius, AnimatablePair(stemLeft, AnimatablePair(stemRight, stemHeight))) }
        set {
            bottomRadius = newValue.first
            stemLeft = newValue.second.first
            stemRight = newValue.second.second.first
            stemHeight = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, rect.height / 2), w = rect.width, h = rect.height
        var path = Path()
        guard stemHeight > 0, stemLeft + stemRight > 0.5 else {
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
        // The stem's straight sides, the strip's top, and the small curves joining them.
        let left = stemLeft + t, right = w - stemRight - t, sh = min(stemHeight, h - b)
        let join = min(6, sh / 2, stemLeft, stemRight), corner = min(8, (h - sh) / 2)
        path.move(to: CGPoint(x: stemLeft, y: 0))
        path.addQuadCurve(to: CGPoint(x: left, y: t), control: CGPoint(x: left, y: 0))
        path.addLine(to: CGPoint(x: left, y: sh - join))
        path.addQuadCurve(to: CGPoint(x: left - join, y: sh), control: CGPoint(x: left, y: sh))
        path.addLine(to: CGPoint(x: corner, y: sh))
        path.addQuadCurve(to: CGPoint(x: 0, y: sh + corner), control: CGPoint(x: 0, y: sh))
        path.addLine(to: CGPoint(x: 0, y: h - b))
        path.addQuadCurve(to: CGPoint(x: b, y: h), control: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: w - b, y: h))
        path.addQuadCurve(to: CGPoint(x: w, y: h - b), control: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: w, y: sh + corner))
        path.addQuadCurve(to: CGPoint(x: w - corner, y: sh), control: CGPoint(x: w, y: sh))
        path.addLine(to: CGPoint(x: right + join, y: sh))
        path.addQuadCurve(to: CGPoint(x: right, y: sh - join), control: CGPoint(x: right, y: sh))
        path.addLine(to: CGPoint(x: right, y: t))
        path.addQuadCurve(to: CGPoint(x: w - stemRight, y: 0), control: CGPoint(x: right, y: 0))
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
    /// The pointer is close to the notch: walkers look at it, so the stage draws smoothly.
    var pointerNear = false
    /// The panel has been clicked and takes keys; the selection is what they act on.
    var keyboardActive = false
    var selectedID: String?
    /// How wide each wing of the closed notch is right now: fitted to the free menu bar beside the notch.
    var leftWing: CGFloat = NotchMetrics.defaultWingWidth
    var rightWing: CGFloat = NotchMetrics.defaultWingWidth
    /// The pointer is over a wing (or a menu is open): it turns see-through so what's under it shows.
    var wingsFaded = false
    /// Filtering the panel's sessions by name or folder; nil when not searching.
    var query: String?
    /// The search field has the keyboard.
    var editingSearch = false

    /// When only one side has room, everyone walks there.
    var onlySide: Wing? {
        if leftWing == 0 && rightWing > 0 { return .right }
        if rightWing == 0 && leftWing > 0 { return .left }
        return nil
    }

    /// The open panel's layout, as both the view and the window's hit area see it.
    func layout(_ store: AgentStore) -> PanelLayout {
        PanelLayout(agents: shown(store), away: store.away.count, replyable: Set(store.channels.keys),
                    banner: store.notice != nil || HookStatus.shared.missing)
    }

    /// The sessions the panel shows: everyone present, or those matching the search.
    func shown(_ store: AgentStore) -> [Agent] {
        guard let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else { return store.present }
        return PanelSearch.filter(store.present, query: query)
    }
}

/// Shared by every notch: hidden for a while on request, and whether some app has a menu open.
@MainActor @Observable final class NotchVisibility {
    static let shared = NotchVisibility()
    private(set) var hiddenUntil: Date?
    /// A menu is open somewhere (an app's menu bar menu, or a status item's): the wings get out of the way.
    var menuOpen = false
    @ObservationIgnored private var timer: Timer?

    var isHidden: Bool { hiddenUntil.map { $0 > Date() } ?? false }

    func hide(for duration: TimeInterval) {
        hiddenUntil = Date().addingTimeInterval(duration)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
    }

    func show() {
        timer?.invalidate()
        timer = nil
        hiddenUntil = nil
    }

    func toggle(for duration: TimeInterval = 10 * 60) { isHidden ? show() : hide(for: duration) }

    private var observers: [NSObjectProtocol] = []

    /// HIToolbox announces menu tracking to everyone, which is how menu bar tools know a menu is open.
    func watchMenus() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        observers = [
            center.addObserver(forName: .init("com.apple.HIToolbox.beginMenuTrackingNotification"), object: nil,
                               queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.menuOpen = true } },
            center.addObserver(forName: .init("com.apple.HIToolbox.endMenuTrackingNotification"), object: nil,
                               queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.menuOpen = false } },
        ]
    }
}

/// Matching sessions against what's typed in the panel's search field.
enum PanelSearch {
    static func filter(_ agents: [Agent], query: String) -> [Agent] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return agents }
        return agents.filter { agent in
            let haystack = [agent.displayName, agent.project, agent.cwd ?? "", agent.lastTool].joined(separator: " ").lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }
}

struct NotchView: View {
    let metrics: NotchMetrics
    var store: AgentStore
    var state: NotchState
    var visibility = NotchVisibility.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasAgents: Bool { !store.present.isEmpty }
    private var waitingCount: Int { store.present.filter(\.needsAttention).count }
    /// The wings are out: always while anyone's around, but in the compact style only to show the badge.
    private var expanded: Bool { metrics.style == .compact ? waitingCount > 0 : hasAgents }
    private var left: CGFloat { expanded ? state.leftWing : 0 }
    private var right: CGFloat { expanded ? state.rightWing : 0 }
    private var below: Bool { metrics.style == .below && left + right > 0 }

    var body: some View {
        let size = state.isOpen
            ? metrics.openSize(state.layout(store))
            : metrics.closedSize(left: left, right: right)
        let shape = NotchShape(topRadius: metrics.topRadius, bottomRadius: state.isOpen ? 24 : 10,
                               stemLeft: state.isOpen || !below ? 0 : left,
                               stemRight: state.isOpen || !below ? 0 : right,
                               stemHeight: state.isOpen || !below ? 0 : metrics.notchHeight)
        ZStack(alignment: .top) {
            shape.fill(.black)
            if state.isOpen {
                OpenNotchView(metrics: metrics, store: store, state: state)
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.1)))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(alignment: badgeAlignment) {
            // At a glance: how many sessions are waiting, and whether any are blocked.
            if !state.isOpen && waitingCount > 0 {
                WaitingBadge(count: waitingCount, blocked: store.present.contains { $0.need == .permission })
                    .frame(height: below ? metrics.stripHeight : metrics.notchHeight)
                    .padding(badgeEdge, metrics.topRadius + 8)
                    .padding(.top, below ? metrics.notchHeight : 0)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if metrics.style != .compact { closedStage(size: size) }
        }
        .offset(x: state.isOpen ? 0 : NotchMetrics.closedOffset(left: left, right: right))
        .opacity(visibility.isHidden && !state.isOpen ? 0 : (hasAgents || state.isOpen ? (faded ? 0.12 : 1) : 0))
        .animation(spring(duration: 0.5, bounce: 0.3), value: hasAgents)
        .animation(spring(duration: 0.42, bounce: 0.25), value: state.isOpen)
        .animation(spring(duration: 0.4, bounce: 0.2), value: store.present.count)
        .animation(spring(duration: 0.35, bounce: 0.4), value: waitingCount)
        .animation(spring(duration: 0.4, bounce: 0.15), value: state.leftWing)
        .animation(spring(duration: 0.4, bounce: 0.15), value: state.rightWing)
        .animation(.easeOut(duration: 0.18), value: faded)
        .animation(.easeOut(duration: 0.25), value: visibility.isHidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var faded: Bool {
        !state.isOpen && Preferences.shared.fadeWings && (state.wingsFaded || visibility.menuOpen)
    }

    /// The badge sits at whichever end has a wing, the right by preference.
    private var badgeOnLeft: Bool { right == 0 && left > 0 }
    private var badgeAlignment: Alignment { badgeOnLeft ? .topLeading : .topTrailing }
    private var badgeEdge: Edge.Set { badgeOnLeft ? .leading : .trailing }

    /// Kept alive while open so the walkers carry on where they were when it closes. It reaches below the shape
    /// so name tags can hang under the notch; the walkers themselves are clipped to the shape.
    @ViewBuilder private func closedStage(size: CGSize) -> some View {
        let reserve = waitingCount > 0 ? WaitingBadge.reserve : 0
        if below {
            // Under the menu bar: a plain strip, with nothing to hide behind.
            StageView(store: store, pixel: metrics.pixel, inset: 10, scatter: false, compact: true,
                      floorInset: metrics.floorInset, clip: NotchShape(topRadius: 0, bottomRadius: 10),
                      labelRoom: StageView.labelRoom, state: state,
                      trailingReserve: badgeOnLeft ? 0 : reserve, leadingReserve: badgeOnLeft ? reserve : 0,
                      pointerShift: metrics.notchHeight)
                .frame(width: size.width, height: metrics.stripHeight + StageView.labelRoom)
                .frame(height: metrics.stripHeight, alignment: .top)
                .padding(.top, metrics.notchHeight)
                .opacity(state.isOpen ? 0 : 1)
                .allowsHitTesting(false)
        } else {
            StageView(store: store, pixel: metrics.pixel, notchWidth: metrics.notchWidth,
                      notchHeight: metrics.notchHeight, inset: metrics.topRadius + 10, scatter: false,
                      compact: true, floorInset: metrics.floorInset,
                      clip: NotchShape(topRadius: metrics.topRadius, bottomRadius: 10),
                      labelRoom: StageView.labelRoom, state: state,
                      trailingReserve: badgeOnLeft ? 0 : reserve, leadingReserve: badgeOnLeft ? reserve : 0,
                      notchCenter: metrics.topRadius + left + metrics.notchWidth / 2, onlySide: state.onlySide)
                .frame(width: size.width, height: size.height + StageView.labelRoom)
                .frame(height: size.height, alignment: .top)
                .opacity(state.isOpen ? 0 : 1)
                .allowsHitTesting(false)
        }
    }

    private func spring(duration: Double, bounce: Double) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: duration, bounce: bounce)
    }
}

/// The closed notch's count of sessions waiting on you: red octagon when any is blocked, green check otherwise.
struct WaitingBadge: View {
    static let reserve: CGFloat = 36
    let count: Int
    let blocked: Bool

    var body: some View {
        let tint = blocked ? Sprite.flag : Sprite.turnFlag
        HStack(spacing: 3) {
            Image(systemName: blocked ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
            Text("\(count)").font(.system(size: 10, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .frame(height: 15)
        .background(tint.opacity(0.18), in: .capsule)
        .accessibilityLabel("\(count) waiting" + (blocked ? ", blocked on a permission prompt" : ""))
    }
}

/// Holds the simulation between frames. Deliberately not observed: the Canvas mutates it while drawing.
@MainActor final class StageBox {
    var stage = Stage()
    var lastTime: Double?
    let pacer = FramePacer()
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
    /// Room kept clear at the right end of the track (for the waiting badge).
    var trailingReserve: CGFloat = 0
    /// The same at the left end, when the badge sits there.
    var leadingReserve: CGFloat = 0
    /// How far below the closed shape's top this stage starts, for placing the pointer.
    var pointerShift: CGFloat = 0
    /// Where the notch sits across the stage; the middle unless one wing is wider.
    var notchCenter: CGFloat?
    /// Only one wing has room: everyone walks on that side.
    var onlySide: Wing?
    /// Claudes can be picked up and dropped on either half, which sets their side of the closed notch.
    var draggable = false
    @State private var box = StageBox()
    @State private var held: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A fresh schedule on every update (a new session, a flag, the pointer arriving) means a change is drawn
        // at once, however slowly the stage was ticking.
        let _ = state?.pointerNear
        let _ = store.present
        TimelineView(PacedSchedule(pacer: box.pacer)) { timeline in
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
                        store.setWing(drag.location.x < (notchCenter ?? geometry.size.width / 2) ? .left : .right, for: id)
                        held = nil
                    })
        }
    }

    private func track(width: CGFloat) -> ClosedRange<CGFloat> {
        let half = inset + CGFloat(Sprite.columns) * pixel / 2
        return (half + leadingReserve)...max(half + leadingReserve, width - half - trailingReserve)
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
        let mid = notchCenter ?? size.width / 2
        box.stage.notch = notchWidth > 0 ? (mid - reach)...(mid + reach) : nil
        // Near means over the shape or just under it.
        let pointer = state?.pointer.flatMap { p in
            let p = CGPoint(x: p.x, y: p.y - pointerShift)
            return (0...size.width).contains(p.x) && (-4...(size.height + 36)).contains(p.y) ? p : nil
        }
        box.stage.pointer = pointer?.x
        box.stage.sync(store.present.map {
            AgentInput(id: $0.id, need: $0.need, activity: $0.activity, quiet: $0.isQuiet(at: date),
                       subagents: $0.subagents.count, load: $0.load, wing: onlySide ?? store.wings[$0.id],
                       stickers: $0.trusted.sorted(), asking: $0.isAsking, answeredAt: $0.answeredAt,
                       boxes: $0.turnChanges.count, testsPassed: $0.testsPassed,
                       waited: $0.waitingSince.map { date.timeIntervalSince($0) } ?? 0, kind: $0.kind)
        }, center: mid, scatter: scatter ? track : nil, died: store.died)
        box.stage.advance(by: dt, track: track, spacing: body)

        let time = box.stage.time
        let frame = reduceMotion ? 0 : Int(time * 2) % 2
        let floor = size.height - floorInset

        if held != nil {
            // While carrying one, show where the two sides of the notch split.
            var divider = Path()
            divider.move(to: CGPoint(x: mid, y: 4))
            divider.addLine(to: CGPoint(x: mid, y: size.height - 2))
            context.stroke(divider, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        context.drawLayer { layer in
            if let clip { layer.clip(to: clip.path(in: CGRect(origin: .zero, size: size))) }
            if notchWidth > 0 {
                // Characters walk behind the notch, like the real hardware hides them.
                var outsideNotch = Path(CGRect(origin: .zero, size: canvas))
                outsideNotch.addRect(CGRect(x: mid - notchWidth / 2, y: 0,
                                            width: notchWidth, height: notchHeight))
                layer.clip(to: outsideNotch, style: FillStyle(eoFill: true))
            }
            for walker in box.stage.walkers {
                drawFollowers(of: walker, in: layer, floor: floor, center: mid, frame: frame)
                drawWalker(walker, in: layer, floor: floor, center: mid, pointer: pointer?.x,
                           time: time, frame: frame)
            }
        }

        if labelRoom > 0, pointer != nil {
            drawNameTags(in: &context, below: size.height)
        }
        box.pacer.interval = store.present.isEmpty && box.stage.walkers.isEmpty
            ? Stage.idleInterval * 5 : box.stage.frameInterval(pointerNear: pointer != nil)
    }

    private func drawWalker(_ walker: Walker, in context: GraphicsContext, floor: CGFloat, center: CGFloat,
                            pointer: CGFloat?, time: Double, frame: Int) {
        let facing: Sprite.Facing = walker.direction > 0 ? .right : .left
        let foot = CGPoint(x: walker.x, y: floor)
        let pack = walker.load
        let stickers = walker.stickers.map(Sprite.stickerColor)
        let skin = Sprite.skin(for: walker.kind)
        if walker.held {
            // Dangling from the pointer.
            Sprite.draw(.walk(.front, step: frame), in: context, foot: foot, pixel: pixel, lift: 3, pack: pack, stickers: stickers, skin: skin)
            return
        }
        if let arrived = walker.arrivedAt, walker.isArriving(at: time) {
            Sprite.drawPoof(progress: (time - arrived) / Stage.popDuration, in: context, foot: foot, pixel: pixel,
                            appearing: true, skin: skin)
            return
        }
        if walker.isCelebrating(at: time) {
            // A couple of little hops with sparkles before the flag goes up.
            let hop = Int((abs(sin((walker.celebrateUntil! - time) * .pi * 2.5)) * 2.4).rounded(.down))
            Sprite.draw(.stand(.front), in: context, foot: foot, pixel: pixel, prop: .sparkle(frame: frame), lift: hop,
                        pack: pack, stickers: stickers, skin: skin)
            return
        }
        switch walker.mood {
        case .greeting(let until):
            let slap = reduceMotion ? 1 : Int((until - time) * 4) % 2
            Sprite.draw(.greet(facing, frame: slap), in: context, foot: foot, pixel: pixel, pack: pack, stickers: stickers, skin: skin)
        case .hopping(let since, let to):
            // Puff out where it stands, then pop out on the other side of the notch.
            let t = (time - since) / Stage.hopDuration
            if t < 0.5 {
                Sprite.drawPoof(progress: t * 2, in: context, foot: foot, pixel: pixel, skin: skin)
            } else {
                Sprite.drawPoof(progress: (t - 0.5) * 2, in: context, foot: CGPoint(x: to, y: floor), pixel: pixel,
                                appearing: true, skin: skin)
            }
        case .poof(let since):
            Sprite.drawPoof(progress: (time - since) / Stage.poofDuration, in: context, foot: foot, pixel: pixel, skin: skin)
        case .attention where walker.need == .yourTurn && walker.boxes > 0:
            Sprite.draw(.stand(.front), in: context, foot: foot, pixel: pixel, prop: .parcel(passed: walker.testsPassed),
                        pack: pack, stickers: stickers, skin: skin)
        case .attention where walker.asking:
            Sprite.draw(.stand(.front), in: context, foot: foot, pixel: pixel,
                        prop: .bubble(frame: reduceMotion ? 0 : Int(time * 2) % 2), pack: pack, stickers: stickers, skin: skin)
        case .attention:
            // The flag points away from the middle, so it's never tucked behind the notch.
            Sprite.draw(Sprite.wave(for: walker.need ?? .permission, frame: frame, compact: compact,
                                    flagLeft: walker.x < center, waited: walker.waited),
                        in: context, foot: foot, pixel: pixel, pack: pack, stickers: stickers, skin: skin)
        case .resting where walker.quiet:
            Sprite.draw(.stand(.front), in: context, foot: foot, pixel: pixel,
                        prop: .snooze(frame: reduceMotion ? 0 : Int(time * 1.5) % 2), pack: pack, stickers: stickers, skin: skin)
        case .walking where walker.watching, .resting where walker.watching:
            let look: Sprite.Facing = pointer.map { $0 < walker.x ? .left : .right } ?? .front
            Sprite.draw(.stand(look), in: context, foot: foot, pixel: pixel, prop: prop(for: walker, frame: frame), pack: pack, stickers: stickers, skin: skin)
        case .walking, .leaving:
            Sprite.draw(.walk(facing, step: Int(walker.stride * 7) % 2), in: context, foot: foot, pixel: pixel,
                        prop: walker.mood == .leaving ? nil : prop(for: walker, frame: frame), pack: pack, stickers: stickers,
                        boxes: walker.mood == .leaving ? 0 : walker.boxes, skin: skin)
        case .resting:
            Sprite.draw(.stand(.front), in: context, foot: foot, pixel: pixel, prop: prop(for: walker, frame: frame), pack: pack,
                        stickers: stickers, boxes: walker.boxes, skin: skin)
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
                               center: CGFloat, frame: Int) {
        guard walker.subagents > 0, !walker.isGhost else { return }
        let mini = max(1, (pixel / 2).rounded(.down))
        let miniWidth = CGFloat(Sprite.columns) * mini
        let moving = walker.mood == .walking && !walker.watching
        let core = notchWidth > 0 ? (center - notchWidth / 2)...(center + notchWidth / 2) : nil
        let positions = Stage.followerPositions(parentX: walker.x, direction: walker.direction,
                                                count: min(walker.subagents, 3),
                                                parentHalfWidth: CGFloat(Sprite.columns) * pixel / 2,
                                                miniWidth: miniWidth, notchCore: core)
        for (index, x) in positions.enumerated() {
            let pose: Sprite.Pose = moving
                ? .walk(walker.direction > 0 ? .right : .left, step: (Int(walker.stride * 9) + index) % 2)
                : .stand(.front)
            Sprite.draw(pose, in: context, foot: CGPoint(x: x, y: floor), pixel: mini)
        }
    }

    private func drawNameTags(in context: inout GraphicsContext, below top: CGFloat) {
        let names = Dictionary(store.present.map { ($0.id, $0.shortName) }, uniquingKeysWith: { a, _ in a })
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
        let waiting = store.present.filter(\.needsAttention).map(\.project)
        if waiting.isEmpty { return "\(store.present.count) Claude agents working" }
        return "Needs your attention: " + waiting.joined(separator: ", ")
    }
}
