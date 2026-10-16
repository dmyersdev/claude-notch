import Foundation
import Testing
@testable import ClaudeNotch

struct StageTests {
    let track: ClosedRange<CGFloat> = 20...300

    func run(_ stage: inout Stage, seconds: Double, spacing: CGFloat = 0) {
        for _ in 0..<Int(seconds * 30) { stage.advance(by: 1.0 / 30, track: track, spacing: spacing) }
    }

    @Test func newAgentsEmergeFromTheNotch() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        #expect(stage.walkers.map(\.x) == [160])
    }

    @Test func walkersStayOnTheTrack() {
        var stage = Stage()
        stage.sync((0..<4).map { AgentInput(id: "\($0)", need: nil) }, center: 160)
        run(&stage, seconds: 120)
        #expect(stage.walkers.allSatisfy { track.contains($0.x) })
    }

    @Test func attentionStopsTheWalker() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        run(&stage, seconds: 3)
        stage.sync([AgentInput(id: "a", need: .permission)], center: 160)
        let x = stage.walkers[0].x
        run(&stage, seconds: 5)
        #expect(stage.walkers[0].mood == .attention)
        #expect(stage.walkers[0].x == x)
    }

    @Test func clearingAttentionResumesWalking() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: .permission)], center: 160)
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        #expect(stage.walkers[0].mood == .walking)
    }

    @Test func endedAgentsWalkBackIntoTheNotchAndVanish() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        run(&stage, seconds: 4)
        stage.sync([], center: 160)
        #expect(stage.walkers.first?.mood == .leaving)
        run(&stage, seconds: 10)
        #expect(stage.walkers.isEmpty)
    }

    @Test func walkersDoNotWalkThroughEachOther() {
        var stage = Stage()
        stage.sync((0..<3).map { AgentInput(id: "\($0)", need: nil) }, center: 0, scatter: track)
        let order = stage.walkers.sorted { $0.x < $1.x }.map(\.id)
        run(&stage, seconds: 60, spacing: 24)
        #expect(stage.walkers.sorted { $0.x < $1.x }.map(\.id) == order)
    }

    @Test func walkersFreshOutOfTheNotchSpreadApart() {
        var stage = Stage()
        stage.sync((0..<3).map { AgentInput(id: "\($0)", need: nil) }, center: 160)
        run(&stage, seconds: 5, spacing: 24)
        let xs = stage.walkers.map(\.x).sorted()
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $1 - $0 >= 23 })
    }

    @Test func bumpingTurnsAWalkerAround() {
        var stage = Stage(seed: 1)
        stage.sync([AgentInput(id: "a", need: .permission), AgentInput(id: "b", need: nil)],
                   center: 160)
        run(&stage, seconds: 2, spacing: 24)
        let flag = stage.walkers.first { $0.id == "a" }!
        let other = stage.walkers.first { $0.id == "b" }!
        #expect(flag.x == 160)
        #expect(abs(other.x - flag.x) >= 23)
    }

    @Test func leavingWalkersPassThrough() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: .permission), AgentInput(id: "b", need: nil)],
                   center: 160)
        run(&stage, seconds: 4, spacing: 24)
        stage.sync([AgentInput(id: "a", need: .permission)], center: 160)
        run(&stage, seconds: 10, spacing: 24)
        #expect(stage.walkers.map(\.id) == ["a"])
    }

    @Test func newcomersPopInAtTheEdgeAndNeverGoInside() {
        var stage = Stage()
        let notch: ClosedRange<CGFloat> = 110...210
        stage.notch = notch
        stage.sync((0..<4).map { AgentInput(id: "\($0)", need: $0 == 0 ? .permission : nil) }, center: 160)
        #expect(stage.walkers.allSatisfy { $0.x == notch.lowerBound || $0.x == notch.upperBound })
        #expect(stage.walkers.allSatisfy { $0.arrivedAt != nil })
        var strays = 0
        for _ in 0..<(120 * 30) {
            stage.advance(by: 1.0 / 30, track: track, spacing: 24)
            strays += stage.walkers.filter { notch.lowerBound < $0.x && $0.x < notch.upperBound }.count
        }
        #expect(strays == 0)
    }

    /// Everything at once: arrivals, departures, deaths, drags to the other wing, and the notch sliding
    /// under the walkers as the shape resizes. Nobody is ever inside it.
    @Test func nobodyEverGoesBehindTheNotch() {
        var stage = Stage(seed: 42)
        var rng = SplitMix64(seed: 7)
        var inputs: [String: AgentInput] = [:]
        var violations = 0
        var notch: ClosedRange<CGFloat> = 110...210
        for frame in 0..<(300 * 30) {
            if frame % 15 == 0 {
                switch Int.random(in: 0..<10, using: &rng) {
                case 0...2 where inputs.count < 6:
                    let id = "a\(frame)"
                    inputs[id] = AgentInput(id: id, need: nil)
                case 3 where !inputs.isEmpty:
                    inputs.removeValue(forKey: inputs.keys.sorted().randomElement(using: &rng)!)
                case 4 where !inputs.isEmpty:
                    let id = inputs.keys.sorted().randomElement(using: &rng)!
                    inputs[id]?.wing = Bool.random(using: &rng) ? .left : .right
                case 5 where !inputs.isEmpty:
                    let id = inputs.keys.sorted().randomElement(using: &rng)!
                    inputs[id]?.need = [nil, .permission, .yourTurn].randomElement(using: &rng)!
                case 6:
                    // The shape resizes, so the notch moves relative to where everyone stands.
                    let shift = CGFloat.random(in: -30...30, using: &rng)
                    notch = (110 + shift)...(210 + shift)
                default: break
                }
            }
            var died: Set<String> = []
            if frame % 450 == 0, let victim = inputs.keys.sorted().first {
                inputs.removeValue(forKey: victim)
                died.insert(victim)
            }
            stage.notch = notch
            stage.sync(inputs.values.sorted { $0.id < $1.id }, center: 160, died: died)
            stage.advance(by: 1.0 / 30, track: track, spacing: 24)
            violations += stage.walkers.filter { notch.lowerBound < $0.x && $0.x < notch.upperBound }.count
        }
        #expect(violations == 0)
    }

    @Test func subAgentsNeverTrailBehindTheNotch() {
        let core: ClosedRange<CGFloat> = 122...198
        // Facing away from the notch at its right edge: trailing would go behind it, so they lead instead.
        let atEdge = Stage.followerPositions(parentX: 210, direction: 1, count: 3, parentHalfWidth: 12,
                                             miniWidth: 12, notchCore: core)
        #expect(atEdge.allSatisfy { $0 > 210 })
        // Far from the notch they trail as usual.
        let far = Stage.followerPositions(parentX: 280, direction: 1, count: 2, parentHalfWidth: 12,
                                          miniWidth: 12, notchCore: core)
        #expect(far.allSatisfy { $0 < 280 })
        #expect((atEdge + far).allSatisfy { $0 + 6 <= core.lowerBound || $0 - 6 >= core.upperBound })
    }

    @Test func leaversPuffAwayAtTheEdgeInsteadOfWalkingIn() {
        var stage = Stage()
        let notch: ClosedRange<CGFloat> = 110...210
        stage.notch = notch
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        run(&stage, seconds: 6)
        stage.sync([], center: 160)
        var sawPoof = false
        for _ in 0..<(20 * 30) {
            stage.advance(by: 1.0 / 30, track: track)
            if stage.walkers.contains(where: \.isPoofing) { sawPoof = true }
            #expect(stage.walkers.allSatisfy { !(notch.lowerBound < $0.x && $0.x < notch.upperBound) })
        }
        #expect(sawPoof)
        #expect(stage.walkers.isEmpty)
    }

    @Test func reduceMotionPutsNewcomersBesideTheNotch() {
        var stage = Stage()
        stage.reduceMotion = true
        stage.notch = 110...210
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        stage.advance(by: 1.0 / 30, track: track)
        #expect([110, 210].contains(stage.walkers[0].x))
    }

    @Test func finishingATurnSetsOffACelebration() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        run(&stage, seconds: 1)
        stage.sync([AgentInput(id: "a", need: .yourTurn)], center: 160)
        #expect(stage.walkers[0].isCelebrating(at: stage.time))
        run(&stage, seconds: 2)
        #expect(!stage.walkers[0].isCelebrating(at: stage.time))
        #expect(stage.walkers[0].mood == .attention)
    }

    @Test func permissionPromptsDoNotCelebrate() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        stage.sync([AgentInput(id: "a", need: .permission)], center: 160)
        #expect(!stage.walkers[0].isCelebrating(at: stage.time))
    }

    @Test func walkersStopToLookAtThePointer() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        stage.pointer = 170
        let x = stage.walkers[0].x
        run(&stage, seconds: 2)
        #expect(stage.walkers[0].watching)
        #expect(stage.walkers[0].x == x)
        stage.pointer = nil
        run(&stage, seconds: 2)
        #expect(!stage.walkers[0].watching)
    }

    @Test func quietWalkersDawdle() {
        var busy = Stage(seed: 3), quiet = Stage(seed: 3)
        busy.sync([AgentInput(id: "a", need: nil)], center: 160)
        quiet.sync([AgentInput(id: "a", need: nil, quiet: true)], center: 160)
        busy.advance(by: 0.05, track: track)
        quiet.advance(by: 0.05, track: track)
        #expect(abs(quiet.walkers[0].x - 160) < abs(busy.walkers[0].x - 160))
    }

    @Test func deadSessionsPoofOnTheSpot() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: nil)], center: 160, scatter: track)
        run(&stage, seconds: 1)
        let x = stage.walkers[0].x
        stage.sync([], center: 160, died: ["a"])
        #expect(stage.walkers[0].isPoofing)
        run(&stage, seconds: 0.5)
        #expect(stage.walkers.first?.x == x)
        run(&stage, seconds: 0.5)
        #expect(stage.walkers.isEmpty)
    }

    @Test func endedSessionsStillWalkHome() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        stage.sync([], center: 160, died: ["someone-else"])
        #expect(stage.walkers[0].mood == .leaving)
    }

    @Test func friendsSometimesHighFive() {
        var stage = Stage(seed: 7)
        stage.sync([AgentInput(id: "a", need: nil), AgentInput(id: "b", need: nil)], center: 160, scatter: 100...140)
        var greeted = false
        for _ in 0..<(120 * 30) {
            stage.advance(by: 1.0 / 30, track: track, spacing: 24)
            if stage.walkers.contains(where: \.isGreeting) { greeted = true; break }
        }
        #expect(greeted)
        let pair = stage.walkers.sorted { $0.x < $1.x }
        // Facing each other.
        #expect(pair[0].direction == 1 && pair[1].direction == -1)
    }

    @Test func draggedToTheOtherWingTheyHopOverInsteadOfWalkingThrough() {
        var stage = Stage()
        let notch: ClosedRange<CGFloat> = 110...210
        stage.notch = notch
        stage.sync([AgentInput(id: "a", need: nil, wing: .left)], center: 160)
        run(&stage, seconds: 6)
        #expect(stage.walkers[0].x <= notch.lowerBound)
        stage.sync([AgentInput(id: "a", need: nil, wing: .right)], center: 160)
        var hopped = false
        for _ in 0..<(15 * 30) {
            stage.advance(by: 1.0 / 30, track: track)
            if stage.walkers[0].isHopping { hopped = true }
            #expect(!(notch.lowerBound < stage.walkers[0].x && stage.walkers[0].x < notch.upperBound))
        }
        #expect(hopped)
        #expect(stage.walkers[0].x >= notch.upperBound)
    }

    @Test func heldWalkersGoWhereTheyAreDragged() {
        var stage = Stage()
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        let id = stage.grab(near: 165, within: 20)
        #expect(id == "a")
        stage.move("a", to: 250, track: track)
        run(&stage, seconds: 1)
        #expect(stage.walkers[0].x == 250)
        stage.drop("a")
        #expect(!stage.walkers[0].held)
        #expect(stage.grab(near: 30, within: 20) == nil)
    }

    @Test func heavyContextSlowsThemDown() {
        var light = Stage(seed: 3), full = Stage(seed: 3)
        light.sync([AgentInput(id: "a", need: nil)], center: 160)
        full.sync([AgentInput(id: "a", need: nil, load: .full)], center: 160)
        light.advance(by: 0.05, track: track)
        full.advance(by: 0.05, track: track)
        #expect(abs(full.walkers[0].x - 160) < abs(light.walkers[0].x - 160))
    }

    @Test func reduceMotionKeepsWalkersStill() {
        var stage = Stage()
        stage.reduceMotion = true
        stage.sync([AgentInput(id: "a", need: nil)], center: 160)
        run(&stage, seconds: 5)
        #expect(stage.walkers[0].x == 160)
    }
}

struct NotchMetricsTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func realNotchUsesTheGapBetweenTheAuxiliaryAreas() {
        let metrics = NotchMetrics.make(screenFrame: screen, safeAreaTop: 32,
                                        leftArea: CGRect(x: 0, y: 950, width: 662, height: 32),
                                        rightArea: CGRect(x: 850, y: 950, width: 662, height: 32),
                                        visibleMaxY: 950)
        #expect(metrics.hasNotch)
        #expect(metrics.notchWidth == 188)
        #expect(metrics.notchHeight == 32)
    }

    @Test func noNotchFallsBackToAFakeOneAsTallAsTheMenuBar() {
        let metrics = NotchMetrics.make(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                        safeAreaTop: 0, leftArea: nil, rightArea: nil, visibleMaxY: 1056)
        #expect(!metrics.hasNotch)
        #expect(metrics.notchWidth == NotchMetrics.fakeNotchWidth)
        #expect(metrics.notchHeight == 24)
    }

    @Test func panelIsPinnedToTheTopCentre() {
        let metrics = NotchMetrics.make(screenFrame: screen, safeAreaTop: 0, leftArea: nil,
                                        rightArea: nil, visibleMaxY: 958)
        #expect(metrics.panelFrame.midX == screen.midX)
        #expect(metrics.panelFrame.maxY == screen.maxY)
    }

    @Test func closedNotchFitsTheShortFlagWithoutGrowingTaller() {
        let fake = NotchMetrics.make(screenFrame: screen, safeAreaTop: 0, leftArea: nil,
                                     rightArea: nil, visibleMaxY: 958)
        let real = NotchMetrics.make(screenFrame: screen, safeAreaTop: 32,
                                     leftArea: CGRect(x: 0, y: 950, width: 662, height: 32),
                                     rightArea: CGRect(x: 850, y: 950, width: 662, height: 32),
                                     visibleMaxY: 950)
        for metrics in [fake, real] {
            #expect(metrics.shapeSize(expanded: true).height == metrics.notchHeight)
            #expect(Sprite.compactWaveRows * metrics.pixel + metrics.floorInset <= metrics.notchHeight)
        }
    }
}

struct OpenPanelTests {
    let metrics = NotchMetrics.make(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                    safeAreaTop: 0, leftArea: nil, rightArea: nil, visibleMaxY: 1056)

    @Test func waitingSessionsGetRowsAndTheRestTiles() {
        func agent(_ id: String, _ need: Need?, ask: Bool = false, since: Double = 0) -> Agent {
            var agent = Agent(id: id, project: id, need: need, waitingSince: need == nil ? nil : Date(timeIntervalSince1970: since))
            if ask { agent.ask = PermissionAsk(summary: "Run ls") }
            return agent
        }
        let agents = [agent("w1", .yourTurn, since: 1), agent("p1", .permission, ask: true, since: 5),
                      agent("a", nil), agent("b", nil), agent("w2", .yourTurn, since: 0)]
        let layout = PanelLayout(agents: agents)
        #expect(layout == PanelLayout(waiting: 3, asks: 1, tiles: 2, hidden: 0))
        #expect(PanelLayout.sections(agents).waiting.map(\.id) == ["p1", "w2", "w1"])
        let crowd = (0..<12).map { agent("x\($0)", nil) }
        #expect(PanelLayout(agents: crowd) == PanelLayout(tiles: 6, hidden: 6))
    }

    @Test func promptsMakeThePanelTaller() {
        let plain = metrics.openSize(PanelLayout(waiting: 1)).height
        let asking = metrics.openSize(PanelLayout(waiting: 1, asks: 1)).height
        #expect(asking - plain == NotchMetrics.askRowHeight - NotchMetrics.waitingRowHeight)
    }

    @Test func panelFitsTheLargestOpenNotch() {
        let open = metrics.openSize(.largest)
        #expect(metrics.panelFrame.width >= open.width)
        #expect(metrics.panelFrame.height >= open.height)
    }

    @Test func openStageHasRoomForAWavingFlag() {
        #expect(metrics.openStageHeight >= Sprite.waveRows * metrics.openPixel + 4)
    }

    @Test func scatteredWalkersLandOnTheTrack() {
        var stage = Stage()
        stage.sync((0..<5).map { AgentInput(id: "\($0)", need: nil) }, center: 0, scatter: 30...500)
        #expect(stage.walkers.allSatisfy { (30...500).contains($0.x) })
    }

    @MainActor @Test func elapsedTimeIsShort() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(Format.elapsed(from: start, to: start.addingTimeInterval(42)) == "42s")
        #expect(Format.elapsed(from: start, to: start.addingTimeInterval(4 * 60 + 5)) == "4m")
        #expect(Format.elapsed(from: start, to: start.addingTimeInterval(3720)) == "1h 2m")
    }
}
