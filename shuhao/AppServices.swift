import Foundation

/// App-wide service registry. shuhaoApp creates the stores and registers them
/// here in `init`, so AppIntents (Siri / Shortcuts) can reach the live
/// PlaybackEngine even when the app is launched in the background by the
/// system (no scene → `.task` never runs). `bootstrapIfNeeded()` is the single
/// wiring point shared by the UI path and the intent path.
@MainActor
final class AppServices {
    static let shared = AppServices()

    var playback: PlaybackEngine?
    var sources: SourceManager?
    var playlists: PlaylistStore?
    var scripts: ScriptStore?
    var settings: SettingsStore?
    var downloads: DownloadStore?
    var history: PlayHistoryStore?

    private var bootstrapped = false

    func register(playback: PlaybackEngine, sources: SourceManager,
                  playlists: PlaylistStore, scripts: ScriptStore,
                  settings: SettingsStore, downloads: DownloadStore,
                  history: PlayHistoryStore) {
        self.playback = playback
        self.sources = sources
        self.playlists = playlists
        self.scripts = scripts
        self.settings = settings
        self.downloads = downloads
        self.history = history
    }

    /// Wires resolvers / user scripts / session restore exactly once. Safe to
    /// call from both shuhaoApp's `.task` and a Siri intent's `perform()`.
    func bootstrapIfNeeded() async {
        guard !bootstrapped,
              let playback, let sources, let scripts,
              let settings, let downloads, let history else { return }
        bootstrapped = true

        sources.fallbackEnabled = settings.enableDirectFallback
        // Downloads reuse the same URL resolution as playback (script → other-source → direct).
        downloads.urlResolver = { [sources] track, quality in
            try await sources.resolveMusicURL(track: track, quality: quality).url
        }
        // 下载完成后写 metadata 时用 —— 跟 PlaybackEngine 共用 LyricsFetcher 的缓存。
        downloads.lyricsResolver = { [sources] track in
            await LyricsFetcher.shared.fetch(for: track, sources: sources)
        }
        playback.setURLResolver { [sources, settings, playback, downloads] track in
            // 本地文件夹导入的歌:songmid 是 lf:// 引用,实时解析成真实文件路径。
            if track.source == .local, track.songmid.hasPrefix(LocalMusicStore.scheme) {
                guard let url = await MainActor.run(body: { LocalMusicStore.shared.fileURL(for: track) }) else {
                    throw NSError(domain: "LocalMusic", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "找不到本地文件(原文件夹可能已移动或删除)"
                    ])
                }
                return ResolvedTrack(url: url, origin: .localFile,
                                     quality: track.qualities.first ?? .k320, warning: nil)
            }
            // Prefer a local downloaded file — plays offline and skips the network entirely.
            // 同时 lazy 校验:record 说是 completed 但文件没了(用户手动在 Finder 删了)
            // → 把 record 翻成 .missing,UI 自动切「文件缺失」徽章,本次播放透传到网络。
            let localOrMissing: URL? = await MainActor.run {
                if let url = downloads.localURL(for: track.id) { return url }
                downloads.markMissingIfNeeded(track.id)
                return nil
            }
            if let local = localOrMissing {
                let q = await MainActor.run { downloads.quality(for: track.id) } ?? .k320
                return ResolvedTrack(url: local, origin: .localFile, quality: q, warning: nil)
            }
            sources.fallbackEnabled = settings.enableDirectFallback
            // `qualityCap` is set by PlaybackEngine when AVPlayer rejects a higher format
            // (e.g. 24-bit Hi-Res FLAC). When set, we resolve at the lower quality instead.
            let q = await MainActor.run { playback.qualityCap } ?? settings.preferredQuality
            return try await sources.resolveMusicURL(track: track, quality: q)
        }
        // Synced lyric line shown in the CarPlay/lock-screen album field.
        playback.setLyricsResolver { [sources] track in
            await LyricsFetcher.shared.fetch(for: track, sources: sources)
        }
        // 已下载的歌:锁屏封面 + 歌词直接读本地(嵌入封面缓存 / 文件内嵌 LRC),离线可用。
        playback.localArtworkProvider = { [downloads] track in
            downloads.embeddedCoverURL(for: track.id)
        }
        LyricsFetcher.shared.localLyricsProvider = { [downloads] track in
            let file = await MainActor.run(body: { () -> URL? in
                if track.source == .local, track.songmid.hasPrefix(LocalMusicStore.scheme) {
                    return LocalMusicStore.shared.fileURL(for: track)
                }
                return downloads.localURL(for: track.id)
            })
            guard let file else { return nil }
            return await Task.detached(priority: .userInitiated) {
                DownloadStore.readEmbeddedLyrics(at: file)
            }.value
        }
        // Record every track that starts playing into the play-history list.
        playback.onTrackPlayed = { [history] track in history.record(track) }
        for s in scripts.scripts where s.enabled {
            await sources.load(script: s)
        }
        // Bring back the queue + position from the previous session (paused, no autoplay).
        playback.restoreLastSession()
    }
}
