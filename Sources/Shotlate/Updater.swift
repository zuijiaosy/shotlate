import AppKit
import Sparkle

/// Sparkle, with gentle reminders: a menu bar app has no Dock icon to come back to, so a scheduled check
/// that finds an update adds a menu item instead of popping an alert in the middle of a capture.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()
    static let didChange = Notification.Name("Updater.didChange")
    /// Sparkle's own defaults key; it overrides SUEnableAutomaticChecks in Info.plist.
    private static let automaticChecksKey = "SUEnableAutomaticChecks"

    private var controller: SPUStandardUpdaterController?

    /// The version a scheduled check found and left for the user to open from the menu.
    private(set) var pendingVersion: String? {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    /// `.build/debug/Shotlate` and the self-checks aren't an app bundle, so there is nothing to replace.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String else {
            return "开发版"
        }
        return "\(short)（\(build)）"
    }

    func start() {
        guard Self.isAvailable, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Also brings back an update that a scheduled check is holding for the menu.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get {
            if let updater = controller?.updater { return updater.automaticallyChecksForUpdates }
            return UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true
        }
        set {
            if let updater = controller?.updater {
                updater.automaticallyChecksForUpdates = newValue
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.automaticChecksKey)
            }
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { pendingVersion = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
