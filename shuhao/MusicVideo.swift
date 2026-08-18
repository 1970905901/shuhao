import Foundation

/// MV (music video) result — mirrors shuhao-tv `MusicVideoInfo` so the JSON-shape
/// reasoning carries over. Per-platform `MvResolver` populates this struct after
/// hitting each source's MV endpoint.
struct MusicVideoInfo: Sendable, Equatable, Identifiable {
    var id: String?
    var name: String?
    /// Direct playable video url. Empty when only `qualities` was returned.
    var url: String?
    /// Web page url, used as a manual-open fallback when no playable url exists.
    var pageUrl: String?
    /// Highest-quality entry first.
    var qualities: [MvQuality] = []

    /// Best playable url: explicit `url`, else the first quality with a non-empty url.
    func bestUrl() -> String? {
        if let u = url, !u.isEmpty { return u }
        return qualities.first(where: { !($0.url?.isEmpty ?? true) })?.url
    }
}

struct MvQuality: Sendable, Equatable, Identifiable {
    var id: String { type }
    var type: String
    var url: String?
    var size: String?
}
