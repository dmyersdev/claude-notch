import AppKit
import SwiftUI

/// How often a stage redraws, set by the stage itself after each frame. Read by SwiftUI's timeline, which may ask
/// from any thread, hence the lock.
final class FramePacer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Stage.smoothInterval

    var interval: Double {
        get { lock.withLock { PowerState.isPaused ? PowerState.pausedInterval : value } }
        set { lock.withLock { value = newValue } }
    }
}

/// A timeline that asks the pacer for each next gap, so the frame rate follows what's on screen.
struct PacedSchedule: TimelineSchedule {
    let pacer: FramePacer

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, pacer: pacer)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date
        let pacer: FramePacer

        mutating func next() -> Date? {
            let date = upcoming
            upcoming = date.addingTimeInterval(pacer.interval)
            return date
        }
    }
}

/// Stops animation entirely while the display sleeps or the screen is locked: nobody can see it.
enum PowerState {
    static let pausedInterval = 60.0
    private static let lock = NSLock()
    nonisolated(unsafe) private static var displayAsleep = false
    nonisolated(unsafe) private static var screenLocked = false
    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []

    static var isPaused: Bool { lock.withLock { displayAsleep || screenLocked } }
    static var isLocked: Bool { lock.withLock { screenLocked } }

    @MainActor static func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observers = [
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
                lock.withLock { displayAsleep = true }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
                lock.withLock { displayAsleep = false }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
                lock.withLock { screenLocked = true }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
                lock.withLock { screenLocked = false }
            },
        ]
    }
}
