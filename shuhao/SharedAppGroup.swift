import Foundation

/// Constants + helpers for the shared App Group container that bridges the
/// main app with system surfaces (Siri / Shortcuts, a future Live Activity,
/// the now-playing / recent-plays snapshot).
///
/// Lives in the `shuhao` target only (the home-screen widget target was
/// removed). The App Group container lets the app share state with those
/// surfaces.
enum SharedAppGroup {
    /// Must match the App Group ID configured under Signing & Capabilities on
    /// both targets in Xcode.
    static let identifier = "group.com.heartbeat.shuhao"

    /// `UserDefaults` instance backed by the shared container. Use this for
    /// small structured data like "recent tracks" — *not* for large blobs.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// Root URL of the shared container on disk. Returns `nil` if entitlements
    /// aren't set up (shouldn't happen in production, but degrade gracefully).
    static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Subdirectory where downloaded album covers live. Created lazily on first
    /// access; safe to call from any process that has the group entitlement.
    static var coversDirectory: URL? {
        guard let base = containerURL?.appendingPathComponent("covers", isDirectory: true) else {
            return nil
        }
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }
}
