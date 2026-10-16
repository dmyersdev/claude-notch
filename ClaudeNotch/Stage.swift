import CoreGraphics
import Foundation

/// What one agent is doing, as far as its character cares.
struct AgentInput: Equatable {
    var id: String
    var need: Need?
    var activity: Activity = .thinking
    /// Working but silent for a while; it slows down and dozes.
    var quiet = false
    var subagents = 0
    /// How full its context is; a heavier load means a backpack and a slower walk.
    var load: Load = .light
    /// The side of the notch the user dragged it to.
    var wing: Wing?
    /// Tools marked "Always", worn as stickers.
    var stickers: [String] = []
    /// Waiting on the user to answer one of its questions: holds up a "?" bubble.
    var asking = false
    /// When the user last answered it; a new value sets off a cheer.
    var answeredAt: Date?
}

enum Wing: Equatable, Sendable { case left, right }

enum Mood: Equatable {
    case walking
    case resting(until: Double)
    /// Stopped, facing the user, waving a flag.
    case attention
    /// Heading back into the notch; removed when it gets there.
    case leaving
    /// Its session died: gone in a puff of smoke, removed when the puff clears.
    case poof(since: Double)
    /// Bumped into a friend: they stop, face each other and high-five.
    case greeting(until: Double)
    /// Dragged to the other wing: vanishes in a puff here and pops out at `to`, never passing behind the notch.
    case hopping(since: Double, to: CGFloat)
}

struct Walker: Identifiable, Equatable {
    let id: String
    var x: CGFloat
    var direction: CGFloat
    var speed: CGFloat
    var mood: Mood
    /// Seconds spent walking; drives the leg frames.
    var stride: Double = 0
    /// Has walked out of the notch; from then on the notch is a wall.
    var outside = false
    var need: Need?
    var activity: Activity = .thinking
    var quiet = false
    var subagents = 0
    var load: Load = .light
    var wing: Wing?
    var stickers: [String] = []
    var asking = false
    var answeredAt: Date?
    /// No more greetings until then, so friends don't high-five on every bump.
    var greetAgainAt: Double = 0
    /// Being dragged by the user.
    var held = false
    /// When it popped into view at the notch's edge.
    var arrivedAt: Double?
    /// Hopping for joy until this time, having just finished its turn.
    var celebrateUntil: Double?
    /// Stopped to look at the pointer.
    var watching = false

    func isCelebrating(at time: Double) -> Bool { celebrateUntil.map { time < $0 } ?? false }
    var isPoofing: Bool { if case .poof = mood { true } else { false } }
    var isGreeting: Bool { if case .greeting = mood { true } else { false } }
    var isHopping: Bool { if case .hopping = mood { true } else { false } }
    /// Passing through: leaving, vanishing or hopping sides, so nobody bumps into it.
    var isGhost: Bool { mood == .leaving || isHopping || isPoofing }
    /// Just popped into view; stands still until the pop finishes.
    func isArriving(at time: Double) -> Bool { arrivedAt.map { time - $0 < Stage.popDuration } ?? false }
    var speedFactor: CGFloat { (quiet ? 0.35 : 1) * (load == .full ? 0.65 : load == .heavy ? 0.85 : 1) }
}

/// The characters' little world: pure simulation, no drawing, so it can be tested.
struct Stage {
    private(set) var walkers: [Walker] = []
    private(set) var time: Double = 0
    var reduceMotion = false
    /// Where the notch hides characters. Nobody ever goes inside it: newcomers pop in at its edges, leavers
    /// puff away there, and switching sides is a hop, not a walk through.
    var notch: ClosedRange<CGFloat>?
    /// Where the pointer is along the track while it's near; walkers close to it stop and look.
    var pointer: CGFloat?
    static let watchDistance: CGFloat = 40
    static let poofDuration = 0.7
    static let popDuration = 0.45
    static let hopDuration = 0.8
    private var rng: SplitMix64

    init(seed: UInt64 = 0x5EED) { rng = SplitMix64(seed: seed) }

    /// Matches the walkers to the current agents. New agents emerge from the notch at `center`,
    /// or land somewhere in `scatter` when given (the open panel shows everyone at once).
    /// `died` lists agents that are gone because their process died; they vanish on the spot.
    mutating func sync(_ agents: [AgentInput], center: CGFloat, scatter: ClosedRange<CGFloat>? = nil,
                       died: Set<String> = []) {
        let ids = Set(agents.map(\.id))
        for index in walkers.indices where !ids.contains(walkers[index].id) {
            if case .poof = walkers[index].mood { continue }
            walkers[index].mood = died.contains(walkers[index].id) && !reduceMotion ? .poof(since: time) : .leaving
        }
        for agent in agents {
            if let index = walkers.firstIndex(where: { $0.id == agent.id }) {
                if agent.need == .yourTurn, walkers[index].need == nil, !reduceMotion {
                    walkers[index].celebrateUntil = time + 1.2
                }
                if agent.need != nil {
                    walkers[index].mood = .attention
                } else if walkers[index].mood == .attention || walkers[index].mood == .leaving || walkers[index].isPoofing {
                    walkers[index].mood = .walking
                }
                walkers[index].need = agent.need
                walkers[index].activity = agent.activity
                walkers[index].quiet = agent.quiet
                walkers[index].subagents = agent.subagents
                walkers[index].load = agent.load
                walkers[index].wing = agent.wing
                walkers[index].stickers = agent.stickers
                walkers[index].asking = agent.asking
                if agent.answeredAt != walkers[index].answeredAt {
                    walkers[index].answeredAt = agent.answeredAt
                    if agent.answeredAt != nil, !reduceMotion { walkers[index].celebrateUntil = time + 1.0 }
                }
            } else {
                let side: CGFloat = agent.wing.map { $0 == .right ? 1 : -1 } ?? (Bool.random(using: &rng) ? 1 : -1)
                // With a notch, pop in right at its edge on the chosen side, never behind it.
                let edge = notch.map { side > 0 ? $0.upperBound : $0.lowerBound }
                let x = scatter.map { CGFloat.random(in: $0, using: &rng) } ?? edge ?? center
                walkers.append(Walker(id: agent.id, x: x,
                                      direction: side,
                                      speed: .random(in: 14...24, using: &rng),
                                      mood: agent.need != nil ? .attention : .walking,
                                      need: agent.need, activity: agent.activity, quiet: agent.quiet,
                                      subagents: agent.subagents, load: agent.load, wing: agent.wing,
                                      stickers: agent.stickers, asking: agent.asking, answeredAt: agent.answeredAt,
                                      arrivedAt: edge != nil && scatter == nil && !reduceMotion ? time : nil))
            }
        }
    }

    /// `spacing` is how close two characters' centres may get (their body width); zero walks through.
    mutating func advance(by dt: Double, track: ClosedRange<CGFloat>, spacing: CGFloat = 0) {
        let dt = min(max(dt, 0), 0.1)
        time += dt
        let center = (track.lowerBound + track.upperBound) / 2

        for index in walkers.indices where !walkers[index].held {
            var walker = walkers[index]
            walker.outside = true
            if walker.isArriving(at: time) { continue }
            walker.arrivedAt = nil
            if let notch, let wing = walker.wing, walker.mood == .walking || isResting(walker),
               (walker.x < (notch.lowerBound + notch.upperBound) / 2) != (wing == .left) {
                // Dragged to the other wing: puff out here, pop out on the other side.
                let to = wing == .right ? notch.upperBound : notch.lowerBound
                if reduceMotion {
                    walker.x = to
                    walker.direction = wing == .right ? 1 : -1
                } else {
                    walker.mood = .hopping(since: time, to: to)
                }
            }
            walker.watching = !walker.isGhost && walker.mood != .attention && !walker.isGreeting
                && pointer.map { abs($0 - walker.x) < Self.watchDistance } ?? false
            switch walker.mood {
            case .walking where walker.watching:
                break
            case .walking:
                if !reduceMotion {
                    walker.x += walker.direction * walker.speed * walker.speedFactor * CGFloat(dt)
                    walker.stride += dt * Double(walker.speedFactor)
                }
                if walker.x >= track.upperBound { walker.direction = -1 }
                if walker.x <= track.lowerBound { walker.direction = 1 }
                if Double.random(in: 0..<1, using: &rng) < dt * (walker.quiet ? 0.5 : 0.12) {
                    let nap = walker.quiet ? Double.random(in: 4...8, using: &rng) : .random(in: 1...3, using: &rng)
                    walker.mood = .resting(until: time + nap)
                }
            case .resting(let until):
                if time >= until {
                    walker.mood = .walking
                    if Bool.random(using: &rng) { walker.direction *= -1 }
                }
            case .attention, .poof:
                break
            case .greeting(let until):
                if time >= until {
                    walker.mood = .walking
                    walker.direction *= -1
                }
            case .hopping(let since, let to):
                if time - since >= Self.hopDuration {
                    walker.x = to
                    walker.direction = notch.map { to >= ($0.lowerBound + $0.upperBound) / 2 ? 1 : -1 } ?? walker.direction
                    walker.mood = .walking
                }
            case .leaving:
                // Home is the notch's nearest edge (or the middle when there's no notch); it puffs away there.
                let home = notch.map { walker.x < ($0.lowerBound + $0.upperBound) / 2 ? $0.lowerBound : $0.upperBound } ?? center
                walker.direction = home >= walker.x ? 1 : -1
                walker.x += walker.direction * max(walker.speed, 30) * CGFloat(dt)
                walker.stride += dt
                if notch != nil, abs(walker.x - home) < 3 {
                    walker.x = home
                    walker.mood = reduceMotion ? .leaving : .poof(since: time)
                }
            }
            if !walker.isGhost {
                walker.x = min(max(walker.x, track.lowerBound), track.upperBound)
            }
            walkers[index] = walker
        }
        if spacing > 0 && !reduceMotion { collide(spacing: spacing, dt: dt, track: track) }
        if let notch { keepOut(of: notch) }
        walkers.removeAll { walker in
            if case .poof(let since) = walker.mood { return time - since > Self.poofDuration }
            guard walker.mood == .leaving else { return false }
            let home = notch.map { walker.x <= ($0.lowerBound + $0.upperBound) / 2 ? $0.lowerBound : $0.upperBound } ?? center
            return abs(walker.x - home) < 3
        }
    }

    private func isResting(_ walker: Walker) -> Bool { if case .resting = walker.mood { true } else { false } }

    // MARK: Dragging

    /// Picks up the walker nearest `x`, if one is within reach. Returns its ID.
    mutating func grab(near x: CGFloat, within reach: CGFloat) -> String? {
        let candidates = walkers.indices.filter { !walkers[$0].isGhost && abs(walkers[$0].x - x) <= reach }
        guard let index = candidates.min(by: { abs(walkers[$0].x - x) < abs(walkers[$1].x - x) }) else { return nil }
        walkers[index].held = true
        return walkers[index].id
    }

    mutating func move(_ id: String, to x: CGFloat, track: ClosedRange<CGFloat>) {
        guard let index = walkers.firstIndex(where: { $0.id == id }) else { return }
        walkers[index].x = min(max(x, track.lowerBound), track.upperBound)
    }

    /// Puts it down where it is; it takes a moment to get its bearings.
    mutating func drop(_ id: String) {
        guard let index = walkers.firstIndex(where: { $0.id == id }) else { return }
        walkers[index].held = false
        if walkers[index].mood == .walking || isResting(walkers[index]) {
            walkers[index].mood = .resting(until: time + 1.5)
        }
    }

    /// The last word, every frame: anyone inside the notch (walked, shoved, or the notch moved under them as
    /// the shape resized) goes back to the nearest edge, facing away.
    private mutating func keepOut(of notch: ClosedRange<CGFloat>) {
        for index in walkers.indices {
            let x = walkers[index].x
            guard notch.lowerBound < x && x < notch.upperBound else { continue }
            let left = x < (notch.lowerBound + notch.upperBound) / 2
            walkers[index].x = left ? notch.lowerBound : notch.upperBound
            if walkers[index].mood != .leaving { walkers[index].direction = left ? -1 : 1 }
        }
    }

    /// Neighbours that touch bump and turn around; overlapping ones (fresh out of the notch, say)
    /// are eased apart. Leaving walkers pass through everyone, and flag wavers stand their ground.
    private mutating func collide(spacing: CGFloat, dt: Double, track: ClosedRange<CGFloat>) {
        let solid = walkers.indices.filter { !walkers[$0].isGhost && !walkers[$0].held }
            .sorted { (walkers[$0].x, walkers[$0].id) < (walkers[$1].x, walkers[$1].id) }
        var blockedLeft = Set<Int>(), blockedRight = Set<Int>()
        for (a, b) in zip(solid, solid.dropFirst()) {
            let gap = walkers[b].x - walkers[a].x
            guard gap < spacing else { continue }
            if walkers[a].mood == .walking, walkers[b].mood == .walking, gap > spacing * 0.8,
               time >= walkers[a].greetAgainAt, time >= walkers[b].greetAgainAt,
               Double.random(in: 0..<1, using: &rng) < 0.5 {
                // Face each other for a high-five, then part ways.
                for (index, facing) in [(a, CGFloat(1)), (b, CGFloat(-1))] {
                    walkers[index].mood = .greeting(until: time + 1.4)
                    walkers[index].direction = facing
                    walkers[index].greetAgainAt = time + 25
                }
                continue
            }
            blockedRight.insert(a)
            blockedLeft.insert(b)
            if walkers[a].mood == .walking { walkers[a].direction = -1 }
            if walkers[b].mood == .walking { walkers[b].direction = 1 }

            let movable = [a, b].filter { walkers[$0].mood != .attention }
            guard !movable.isEmpty else { continue }
            let push = min(spacing - gap, 30 * CGFloat(dt)) / CGFloat(movable.count)
            if movable.contains(a) { walkers[a].x = max(walkers[a].x - push, track.lowerBound) }
            if movable.contains(b) { walkers[b].x = min(walkers[b].x + push, track.upperBound) }
        }
        // Boxed in on both sides: stop for a moment rather than jitter back and forth.
        for index in blockedLeft.intersection(blockedRight) where walkers[index].mood == .walking {
            walkers[index].mood = .resting(until: time + .random(in: 1...2, using: &rng))
        }
    }
}

extension Stage {
    /// Where a walker's tiny sub-agent followers stand: trailing behind it, or in front of it when trailing
    /// would put any of them behind the notch (`notchCore` is the notch itself, without any body margin).
    static func followerPositions(parentX: CGFloat, direction: CGFloat, count: Int, parentHalfWidth: CGFloat,
                                  miniWidth: CGFloat, notchCore: ClosedRange<CGFloat>?) -> [CGFloat] {
        func line(_ side: CGFloat) -> [CGFloat] {
            let first: CGFloat = parentHalfWidth + 2 + miniWidth / 2
            let step: CGFloat = miniWidth + 2
            return (0..<count).map { (index: Int) -> CGFloat in
                let offset: CGFloat = first + CGFloat(index) * step
                return parentX + side * offset
            }
        }
        let behind = line(direction > 0 ? -1 : 1)
        guard let core = notchCore else { return behind }
        let clear = { (x: CGFloat) in x + miniWidth / 2 <= core.lowerBound || x - miniWidth / 2 >= core.upperBound }
        return behind.allSatisfy(clear) ? behind : line(direction > 0 ? 1 : -1)
    }
}

/// Small seeded generator so the simulation is reproducible in tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
