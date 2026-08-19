import Foundation
import Combine
import CoreFoundation

/// Cross-process command channel for the home-screen widget's transport buttons.
///
/// The widget runs in a separate extension and can't talk to PlaybackEngine
/// directly. Each widget AppIntent posts a Darwin notification; this bridge
/// subscribes in the app process and forwards to PlaybackEngine.
///
/// Darwin notifications are perfect here: cheap, system-wide, no shared
/// UserDefaults round-trips. One notification per command keeps the widget
/// side stateless.
enum WidgetCommand: String, CaseIterable {
    case playPause = "playpause"
    case next
    case previous
    /// "Play the most recent track" — used by the widget's "继续播放" button when
    /// nothing is currently in the queue.
    case playRecent

    var darwinName: String { "shuhao.com.command.\(rawValue)" }
}

@MainActor
final class CommandBridge {
    private weak var playback: PlaybackEngine?
    private weak var sources: SourceManager?
    private var selfPtr: UnsafeRawPointer?

    func start(playback: PlaybackEngine, sources: SourceManager) {
        self.playback = playback
        self.sources = sources
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        selfPtr = UnsafeRawPointer(opaque)
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        for cmd in WidgetCommand.allCases {
            CFNotificationCenterAddObserver(
                center, opaque,
                { _, observerPtr, name, _, _ in
                    guard let observerPtr, let raw = name?.rawValue as String? else { return }
                    let bridge = Unmanaged<CommandBridge>.fromOpaque(observerPtr).takeUnretainedValue()
                    Task { @MainActor in bridge.handle(rawName: raw) }
                },
                cmd.darwinName as CFString, nil, .deliverImmediately)
        }
    }

    private func handle(rawName: String) {
        guard let playback else { return }
        guard let cmd = WidgetCommand.allCases.first(where: { $0.darwinName == rawName }) else { return }
        switch cmd {
        case .playPause: playback.togglePlayPause()
        case .next:      playback.next()
        case .previous:  playback.previous()
        case .playRecent:
            // "Resume" — re-play the most-recent track from SharedRecentStore.
            // We don't restore a full queue (would require duplicating Track
            // model across targets); single-track playback is plenty for a
            // widget tap that means "give me music".
            if playback.currentTrack != nil {
                playback.togglePlayPause()
            } else if let recent = SharedRecentStore.read().first {
                // Construct a minimal Track from the recent snapshot — picURL
                // is unknown to the widget, but PlaybackEngine fills it back in
                // once loadAndPlay resolves the source URL.
                if let source = SourceID(rawValue: idSourcePrefix(recent.id)) {
                    let track = Track(
                        id: recent.id, name: recent.title, singer: recent.artist,
                        source: source, songmid: idSongMid(recent.id),
                        picURL: recent.coverLocalPath.flatMap { "file://" + $0 }
                    )
                    playback.play(track: track)
                }
            }
        }
    }

    /// `SharedRecentTrack.id` follows Track's id convention `<sourceRaw>_<songmid>`.
    /// Pull the two halves back out so we can reconstruct enough of a Track to
    /// hand to PlaybackEngine.
    private func idSourcePrefix(_ id: String) -> String {
        id.split(separator: "_", maxSplits: 1).first.map(String.init) ?? ""
    }
    private func idSongMid(_ id: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }
}
