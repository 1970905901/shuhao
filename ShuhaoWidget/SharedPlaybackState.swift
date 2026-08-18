import Foundation

/// Snapshot of recently-played tracks for the home-screen widget.
///
/// **Target membership note:** must belong to both `shuhao` and `ShuhaoWidget`
/// targets (the app writes, the widget reads). Stored in shared UserDefaults via
/// `SharedAppGroup.defaults` — small enough to fit comfortably (a few KB).
struct SharedRecentTrack: Codable, Hashable, Identifiable {
    /// Stable id for `ForEach` / list diffing.
    var id: String
    var title: String
    var artist: String
    /// Absolute path to the cover file inside the App Group container (written
    /// by `CoverCache`). `nil` while the download is in flight or failed.
    var coverLocalPath: String?
    /// Display name of the music source (酷我 / 网易云 / 酷狗 / QQ 音乐 / ...).
    var sourceName: String
    /// When this entry was inserted — used to sort newest-first in the widget.
    var playedAt: Date

    init(id: String, title: String, artist: String,
         coverLocalPath: String?, sourceName: String, playedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.artist = artist
        self.coverLocalPath = coverLocalPath
        self.sourceName = sourceName
        self.playedAt = playedAt
    }
}

/// Tiny store wrapped around shared UserDefaults. Keeps the latest N tracks so
/// the widget can render either a single-cover small variant or a list medium
/// variant without hitting the network.
enum SharedRecentStore {
    private static let key = "shared.recentTracks"
    private static let maxCount = 8

    static func read() -> [SharedRecentTrack] {
        guard let data = SharedAppGroup.defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SharedRecentTrack].self, from: data)) ?? []
    }

    /// Insert at the top, dedup by id, cap to `maxCount`. Mirrors how 网易云/
    /// Apple Music "最近播放" stacks behave.
    static func push(_ track: SharedRecentTrack) {
        var list = read()
        list.removeAll { $0.id == track.id }
        list.insert(track, at: 0)
        if list.count > maxCount {
            list = Array(list.prefix(maxCount))
        }
        write(list)
    }

    static func clear() {
        SharedAppGroup.defaults?.removeObject(forKey: key)
    }

    private static func write(_ list: [SharedRecentTrack]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        SharedAppGroup.defaults?.set(data, forKey: key)
    }
}

/// Live playback snapshot the widget reads to render the "正在播放" small/medium
/// variants. Written by `RecentTracksRecorder` from the main app; cleared when
/// the queue empties. The fields are minimal on purpose — the widget refreshes
/// every ~15s through `WidgetCenter.reloadAllTimelines()` after each track or
/// play/pause change, so over-stamping `elapsed` here would burn timeline budget
/// for no UI benefit.
struct SharedNowPlaying: Codable, Hashable {
    var trackID: String
    var title: String
    var artist: String
    var coverLocalPath: String?
    var isPlaying: Bool
    /// Recorded `currentTime` at write-moment. The widget extrapolates from
    /// `updatedAt` to estimate elapsed time without needing live updates.
    var elapsed: Double
    var duration: Double
    /// Current lyric line at write-moment. nil = no lyrics for this track, or
    /// the song is between lines. Updated each time the active line changes
    /// (RecentTracksRecorder throttles to ~1 Hz to stay within WidgetKit's
    /// reload budget).
    var currentLyric: String?
    var updatedAt: Date

    /// What the widget should display as "current time", projected from the
    /// last snapshot using wall-clock delta if the player is currently playing.
    func projectedElapsed(at now: Date = Date()) -> Double {
        if isPlaying {
            return min(duration, elapsed + now.timeIntervalSince(updatedAt))
        }
        return elapsed
    }
}

enum SharedNowPlayingStore {
    private static let key = "shared.nowPlaying"

    static func read() -> SharedNowPlaying? {
        guard let data = SharedAppGroup.defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SharedNowPlaying.self, from: data)
    }

    static func write(_ snapshot: SharedNowPlaying) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        SharedAppGroup.defaults?.set(data, forKey: key)
    }

    static func clear() {
        SharedAppGroup.defaults?.removeObject(forKey: key)
    }
}
