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
        phoneAlerts = defaults.bool(forKey: Keys.phoneAlerts)
        ntfyServer = defaults.string(forKey: Keys.ntfyServer) ?? "https://ntfy.sh"
        ntfyTopic = defaults.string(forKey: Keys.ntfyTopic) ?? ""
        phoneAlertMinutes = defaults.object(forKey: Keys.phoneAlertMinutes) as? Int ?? 5
        phoneAlertsFinished = defaults.bool(forKey: Keys.phoneAlertsFinished)
        sessionBudget = defaults.object(forKey: Keys.sessionBudget) as? Int ?? 0
        totalBudget = defaults.object(forKey: Keys.totalBudget) as? Int ?? 0
        openTrigger = defaults.string(forKey: Keys.openTrigger).flatMap(OpenTrigger.init) ?? .hover
        notchStyle = defaults.string(forKey: Keys.notchStyle).flatMap(NotchStyle.init) ?? .wings
        wingSides = defaults.string(forKey: Keys.wingSides).flatMap(WingSides.init) ?? .both
        fitToMenuBar = defaults.object(forKey: Keys.fitToMenuBar) as? Bool ?? true
        fitAroundAppMenus = defaults.bool(forKey: Keys.fitAroundAppMenus)
        fadeWings = defaults.object(forKey: Keys.fadeWings) as? Bool ?? true
        showMenuBarIcon = defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true
        screenChoice = defaults.string(forKey: Keys.screenChoice).flatMap(ScreenChoice.init) ?? .notched
        quietMode = defaults.bool(forKey: Keys.quietMode)
        followFocus = defaults.bool(forKey: Keys.followFocus)
        checkForUpdates = defaults.object(forKey: Keys.checkForUpdates) as? Bool ?? true
        hooksWereInstalled = defaults.bool(forKey: Keys.hooksWereInstalled)
    }

    // MARK: The notch and the menu bar

    /// What opens the panel.
    var openTrigger: OpenTrigger { didSet { defaults.set(openTrigger.rawValue, forKey: Keys.openTrigger) } }
    /// Where the Claudes live while it's closed.
    var notchStyle: NotchStyle {
        didSet { defaults.set(notchStyle.rawValue, forKey: Keys.notchStyle); onLayoutChange?() }
    }
    var wingSides: WingSides {
        didSet { defaults.set(wingSides.rawValue, forKey: Keys.wingSides); onLayoutChange?() }
    }
    /// Shrink each wing to the free menu bar beside the notch, so it never covers an icon.
    var fitToMenuBar: Bool {
        didSet { defaults.set(fitToMenuBar, forKey: Keys.fitToMenuBar); onLayoutChange?() }
    }
    /// Also keep clear of the frontmost app's menus (File, Edit…), which takes Accessibility permission.
    var fitAroundAppMenus: Bool {
        didSet { defaults.set(fitAroundAppMenus, forKey: Keys.fitAroundAppMenus); onLayoutChange?() }
    }
    /// The wings turn see-through while the pointer is over them, or while a menu is open.
    var fadeWings: Bool { didSet { defaults.set(fadeWings, forKey: Keys.fadeWings) } }
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) } }
    var screenChoice: ScreenChoice {
        didSet { defaults.set(screenChoice.rawValue, forKey: Keys.screenChoice); onLayoutChange?() }
    }

    // MARK: Quiet

    /// No sounds and no phone alerts. Flags still go up.
    var quietMode: Bool { didSet { defaults.set(quietMode, forKey: Keys.quietMode) } }
    /// Quiet whenever a macOS Focus is on (only when the app can see it: that takes Full Disk Access).
    var followFocus: Bool { didSet { defaults.set(followFocus, forKey: Keys.followFocus) } }
    /// Updated by the app's timer from `FocusStatus`.
    var focusOn = false
    var isQuiet: Bool { quietMode || (followFocus && focusOn) }

    // MARK: Housekeeping

    /// Ask GitHub once a day whether there's a newer release.
    var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: Keys.checkForUpdates) } }
    /// The hooks have been installed at some point, so their going missing is worth a word.
    var hooksWereInstalled: Bool { didSet { defaults.set(hooksWereInstalled, forKey: Keys.hooksWereInstalled) } }

    /// Warn when one session, or all running sessions together, cost more than this many dollars at API prices.
    /// 0 is off.
    var sessionBudget: Int { didSet { defaults.set(sessionBudget, forKey: Keys.sessionBudget) } }
    var totalBudget: Int { didSet { defaults.set(totalBudget, forKey: Keys.totalBudget) } }
    var budgets: Budget { Budget(session: Double(sessionBudget), total: Double(totalBudget)) }

    // Phone alerts through ntfy: off until you choose a topic.
    var phoneAlerts: Bool { didSet { defaults.set(phoneAlerts, forKey: Keys.phoneAlerts) } }
    var ntfyServer: String { didSet { defaults.set(ntfyServer, forKey: Keys.ntfyServer) } }
    var ntfyTopic: String { didSet { defaults.set(ntfyTopic, forKey: Keys.ntfyTopic) } }
    var phoneAlertMinutes: Int { didSet { defaults.set(phoneAlertMinutes, forKey: Keys.phoneAlertMinutes) } }
    var phoneAlertsFinished: Bool { didSet { defaults.set(phoneAlertsFinished, forKey: Keys.phoneAlertsFinished) } }

    var phoneAlertSettings: PhoneAlerts.Settings {
        PhoneAlerts.Settings(enabled: phoneAlerts && !isQuiet, server: ntfyServer, topic: ntfyTopic,
                             delay: TimeInterval(phoneAlertMinutes * 60), includeFinished: phoneAlertsFinished)
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
        guard playSound, !isQuiet else { return }
        NSSound(named: need == .permission ? "Funk" : "Glass")?.play()
    }

    private enum Keys {
        static let playSound = "playSound"
        static let answerPermissions = "answerPermissions"
        static let wingWidth = "wingWidth"
        static let allDisplays = "allDisplays"
        static let tuckAwayMinutes = "tuckAwayMinutes"
        static let phoneAlerts = "phoneAlerts"
        static let ntfyServer = "ntfyServer"
        static let ntfyTopic = "ntfyTopic"
        static let phoneAlertMinutes = "phoneAlertMinutes"
        static let phoneAlertsFinished = "phoneAlertsFinished"
        static let sessionBudget = "sessionBudget"
        static let totalBudget = "totalBudget"
        static let openTrigger = "openTrigger"
        static let notchStyle = "notchStyle"
        static let wingSides = "wingSides"
        static let fitToMenuBar = "fitToMenuBar"
        static let fitAroundAppMenus = "fitAroundAppMenus"
        static let fadeWings = "fadeWings"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let screenChoice = "screenChoice"
        static let quietMode = "quietMode"
        static let followFocus = "followFocus"
        static let checkForUpdates = "checkForUpdates"
        static let hooksWereInstalled = "hooksWereInstalled"
    }
}

/// What opens the panel. Only the notch itself counts, never the wings, so the menu bar under them stays usable.
enum OpenTrigger: String, CaseIterable, Identifiable {
    /// Rest the pointer on the notch.
    case hover
    /// Push the pointer against the top edge of the screen, in the notch.
    case push
    /// Click the notch.
    case click
    /// Hover the notch while holding ⌥.
    case option

    var id: Self { self }
    var title: String {
        switch self {
        case .hover: "Hover over the notch"
        case .push: "Push the pointer into the top edge"
        case .click: "Click the notch"
        case .option: "Hover while holding ⌥"
        }
    }
}

/// Where the Claudes walk while the notch is closed.
enum NotchStyle: String, CaseIterable, Identifiable {
    /// In the menu bar, on wings either side of the notch.
    case wings
    /// Nothing outside the notch but a badge when someone is waiting.
    case compact
    /// On a strip hanging just under the menu bar, which keeps the whole menu bar clear.
    case below

    var id: Self { self }
    var title: String {
        switch self {
        case .wings: "In the menu bar"
        case .compact: "Compact: just a badge"
        case .below: "Under the menu bar"
        }
    }
}

enum WingSides: String, CaseIterable, Identifiable {
    case both, left, right
    var id: Self { self }
    var title: String {
        switch self {
        case .both: "Both sides"
        case .left: "Left only"
        case .right: "Right only"
        }
    }
}

enum ScreenChoice: String, CaseIterable, Identifiable {
    /// The built-in display with the notch, or the main display without one.
    case notched
    /// The display with the menu bar (System Settings → Displays → main display).
    case main
    /// Whichever display the pointer is on.
    case pointer

    var id: Self { self }
    var title: String {
        switch self {
        case .notched: "The one with the notch"
        case .main: "The main display"
        case .pointer: "Whichever has the pointer"
        }
    }
}
