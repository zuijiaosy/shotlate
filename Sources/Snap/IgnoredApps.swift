import AppKit

/// Apps in front of which Snap lets go of its hotkeys (games, remote desktops, apps with the same shortcuts).
enum IgnoredApps {
    /// Case-insensitive: a pattern matches the app's name or bundle id exactly, or appears anywhere in its path.
    static func matches(name: String?, bundleID: String?, path: String?, patterns: [String]) -> Bool {
        for raw in patterns {
            let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !p.isEmpty else { continue }
            if name?.lowercased() == p || bundleID?.lowercased() == p { return true }
            if let path = path?.lowercased(), path.contains(p) { return true }
        }
        return false
    }

    static func matches(_ app: NSRunningApplication, patterns: [String]) -> Bool {
        matches(name: app.localizedName, bundleID: app.bundleIdentifier, path: app.bundleURL?.path, patterns: patterns)
    }
}
