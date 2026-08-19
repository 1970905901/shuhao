import AppIntents
import Foundation

/// Siri / 快捷指令 entry points. These live in the **app target** (unlike the
/// widget's Darwin-notification intents) so `perform()` runs in the app
/// process and can drive PlaybackEngine directly via AppServices — including
/// background cold launches, where App.init registers the stores but no scene
/// ever connects.

// MARK: - Transport

struct SiriPlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放/暂停"
    static var description = IntentDescription("切换播放或暂停当前歌曲")

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppServices.shared.bootstrapIfNeeded()
        AppServices.shared.playback?.togglePlayPause()
        return .result()
    }
}

struct SiriNextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "下一首"
    static var description = IntentDescription("跳到播放队列的下一首歌")

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppServices.shared.bootstrapIfNeeded()
        AppServices.shared.playback?.next()
        return .result()
    }
}

struct SiriResumeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "继续播放"
    static var description = IntentDescription("接着上次的进度继续听")

    @MainActor
    func perform() async throws -> some IntentResult {
        // bootstrap 里包含 restoreLastSession,冷启动时把上次的队列拉回来。
        await AppServices.shared.bootstrapIfNeeded()
        guard let playback = AppServices.shared.playback else { return .result() }
        if playback.currentTrack != nil {
            if !playback.isPlaying { playback.togglePlayPause() }
        }
        return .result()
    }
}

// MARK: - 点歌(搜索并播放)

struct PlaySongIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放歌曲"
    static var description = IntentDescription("按歌名(可带歌手)全源搜索并播放最匹配的一首")

    @Parameter(title: "歌曲", requestValueDialog: "想听哪首歌?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("搜索并播放 \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppServices.shared.bootstrapIfNeeded()
        guard let playback = AppServices.shared.playback else {
            return .result(dialog: "播放器还没准备好")
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .result(dialog: "没听清歌名,再试一次") }

        let results = await Catalogs.searchAll(keyword: term)
        guard let first = results.first else {
            return .result(dialog: "没有找到“\(term)”")
        }
        // 把前几条搜索结果一起入队 —— 第一条放不出来时引擎还能顺到下一条。
        playback.play(track: first, in: Array(results.prefix(20)), startIndex: 0)
        return .result(dialog: "开始播放\(first.name) - \(first.singer)")
    }
}

// MARK: - 播放歌单

struct PlaylistEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "歌单"
    static var defaultQuery = PlaylistEntityQuery()

    var id: UUID
    var name: String
    var trackCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(trackCount) 首")
    }
}

struct PlaylistEntityQuery: EntityQuery {
    @MainActor
    private func allEntities() -> [PlaylistEntity] {
        guard let store = AppServices.shared.playlists else { return [] }
        return store.playlists.map {
            PlaylistEntity(id: $0.id, name: $0.name, trackCount: $0.trackIDs.count)
        }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
        allEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        allEntities()
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放歌单"
    static var description = IntentDescription("播放我收藏的某个歌单")

    @Parameter(title: "歌单")
    var playlist: PlaylistEntity

    @Parameter(title: "随机播放", default: false)
    var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("播放歌单 \(\.$playlist)") {
            \.$shuffled
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppServices.shared.bootstrapIfNeeded()
        guard let playback = AppServices.shared.playback,
              let store = AppServices.shared.playlists,
              let meta = store.playlists.first(where: { $0.id == playlist.id }) else {
            return .result(dialog: "没有找到这个歌单")
        }
        var tracks = store.tracks(in: meta)
        guard !tracks.isEmpty else {
            return .result(dialog: "歌单“\(meta.name)”是空的")
        }
        if shuffled { tracks.shuffle() }
        playback.play(track: tracks[0], in: tracks, startIndex: 0)
        return .result(dialog: "开始播放“\(meta.name)”")
    }
}

// MARK: - Shortcuts provider

struct ShuhaoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SiriResumeIntent(),
            phrases: [
                "在\(.applicationName)继续播放",
                "用\(.applicationName)接着放",
            ],
            shortTitle: "继续播放",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: SiriPlayPauseIntent(),
            phrases: [
                "\(.applicationName)暂停",
                "暂停\(.applicationName)",
            ],
            shortTitle: "播放/暂停",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: SiriNextTrackIntent(),
            phrases: [
                "\(.applicationName)下一首",
                "在\(.applicationName)切歌",
            ],
            shortTitle: "下一首",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PlaySongIntent(),
            phrases: [
                "在\(.applicationName)播放歌曲",
                "用\(.applicationName)点歌",
                "在\(.applicationName)搜歌",
            ],
            shortTitle: "播放歌曲",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "在\(.applicationName)播放歌单",
                "用\(.applicationName)播放歌单\(\.$playlist)",
            ],
            shortTitle: "播放歌单",
            systemImageName: "music.note.list"
        )
    }
}
