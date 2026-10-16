import AppKit
import Observation
import ServiceManagement

/// The user's settings, kept in UserDefaults.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults
    /// Runs when something that changes the notch's size or placement is edited.
    @ObservationIgnored var onLayoutChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playSound = defaults.bool(forKey: Keys.playSound)
        answerPermissions = defaults.object(forKey: Keys.answerPermissions) as? Bool ?? true
        let wings = defaults.double(forKey: Keys.wingWidth)
        wingWidth = wings > 0 ? wings : Double(NotchMetrics.defaultWingWidth)
        allDisplays = defaults.bool(forKey: Keys.allDisplays)
        tuckAwayMinutes = defaults.object(forKey: Keys.tuckAwayMinutes) as? Int ?? 15
    }

    /// Idle or finished sessions are tucked away after this many minutes; 0 never tucks them.
    var tuckAwayMinutes: Int {
        didSet { defaults.set(tuckAwayMinutes, forKey: Keys.tuckAwayMinutes); onTuckChange?() }
    }
    var tuckAwayAfter: TimeInterval? { tuckAwayMinutes > 0 ? TimeInterval(tuckAwayMinutes * 60) : nil }
    @ObservationIgnored var onTuckChange: (() -> Void)?

    /// A soft sound when a session starts waiting on you.
    var playSound: Bool { didSet { defaults.set(playSound, forKey: Keys.playSound) } }
    /// Hold permission prompts briefly so they can be answered from the notch.
    var answerPermissions: Bool { didSet { defaults.set(answerPermissions, forKey: Keys.answerPermissions) } }
    var wingWidth: Double {
        didSet { defaults.set(wingWidth, forKey: Keys.wingWidth); onLayoutChange?() }
    }
    /// Show a notch on every display, not just the main one.
    var allDisplays: Bool {
        didSet { defaults.set(allDisplays, forKey: Keys.allDisplays); onLayoutChange?() }
    }

    var launchAtLogin: Bool {
        get { access(keyPath: \.launchAtLogin); return SMAppService.mainApp.status == .enabled }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            }
        }
    }

    func playNeedSound(_ need: Need) {
        guard playSound else { return }
        NSSound(named: need == .permission ? "Funk" : "Glass")?.play()
    }

    private enum Keys {
        static let playSound = "playSound"
        static let answerPermissions = "answerPermissions"
        static let wingWidth = "wingWidth"
        static let allDisplays = "allDisplays"
        static let tuckAwayMinutes = "tuckAwayMinutes"
    }
}
