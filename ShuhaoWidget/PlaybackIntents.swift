import AppIntents
import CoreFoundation
import Foundation

/// AppIntents fired by the home-screen widget's transport buttons. Each one
/// posts a Darwin notification — the main app's `CommandBridge` subscribes
/// and translates it into a PlaybackEngine call. Using `AudioPlaybackIntent`
/// (vs plain AppIntent) tells iOS this is a media transport action, so the
/// system grants the audio session and lets the app keep playing without
/// foregrounding the UI.

private func postDarwin(_ name: String) {
    let cf = CFNotificationName(name as CFString)
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        cf, nil, nil, true)
}

struct PlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放/暂停"
    init() {}
    func perform() async throws -> some IntentResult {
        postDarwin("com.heartbeat.shuhao.command.playpause")
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "下一首"
    init() {}
    func perform() async throws -> some IntentResult {
        postDarwin("com.heartbeat.shuhao.command.next")
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "上一首"
    init() {}
    func perform() async throws -> some IntentResult {
        postDarwin("com.heartbeat.shuhao.command.previous")
        return .result()
    }
}

/// Used by the "继续播放" CTA when the widget has recent history but the player
/// isn't currently active. CommandBridge handles the resume logic.
struct PlayRecentIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "继续播放"
    init() {}
    func perform() async throws -> some IntentResult {
        postDarwin("com.heartbeat.shuhao.command.playRecent")
        return .result()
    }
}
