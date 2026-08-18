import Foundation
import Intents

/// SiriKit INPlayMediaIntent —— 支持"用随便听播放晴天"一句直达,歌名直接嵌在
/// 唤醒句里(App Shortcuts 的短语做不到这一点)。iOS 14+ 的 in-app handling:
/// 系统后台拉起 app,由 ShuhaoAppDelegate.application(_:handlerFor:) 返回本类,
/// 不需要单独的 Intents Extension。
@MainActor
final class SiriPlayMediaHandler: NSObject, INPlayMediaIntentHandling {

    /// resolve 阶段搜到的结果缓存下来,handle 阶段直接用,避免搜两次。
    /// 系统对同一次意图会复用同一个 handler 实例。
    private var resolvedTracks: [Track] = []

    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        let search = intent.mediaSearch

        // "播放(我的)歌单 XX" → 匹配本地歌单名
        if search?.mediaType == .playlist, let name = search?.mediaName,
           let meta = AppServices.shared.playlists?.playlists
               .first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            let item = INMediaItem(
                identifier: "playlist:\(meta.id.uuidString)",
                title: meta.name, type: .playlist, artwork: nil)
            return [.success(with: item)]
        }

        let term = [search?.mediaName, search?.artistName]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return [.unsupported()] }

        let results = await Catalogs.searchAll(keyword: term)
        guard let first = results.first else { return [.unsupported()] }
        resolvedTracks = results

        let item = INMediaItem(
            identifier: first.id, title: first.name,
            type: .song, artwork: nil, artist: first.singer)
        return [.success(with: item)]
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        await AppServices.shared.bootstrapIfNeeded()
        guard let playback = AppServices.shared.playback,
              let item = intent.mediaItems?.first else {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }

        // 歌单分支
        if let id = item.identifier, id.hasPrefix("playlist:"),
           let uuid = UUID(uuidString: String(id.dropFirst("playlist:".count))),
           let store = AppServices.shared.playlists,
           let meta = store.playlists.first(where: { $0.id == uuid }) {
            let tracks = store.tracks(in: meta)
            guard !tracks.isEmpty else {
                return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
            }
            playback.play(track: tracks[0], in: tracks, startIndex: 0)
            return INPlayMediaIntentResponse(code: .success, userActivity: nil)
        }

        // 单曲分支:优先用 resolve 缓存;缓存为空(如从快捷指令 donation 重放)就重搜。
        var queue = resolvedTracks
        if queue.isEmpty {
            let term = [item.title, item.artist].compactMap { $0 }.joined(separator: " ")
            guard !term.isEmpty else {
                return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
            }
            queue = await Catalogs.searchAll(keyword: term)
        }
        guard !queue.isEmpty else {
            return INPlayMediaIntentResponse(code: .failure, userActivity: nil)
        }
        // 把命中的那首挪到队首,后面带上其余结果兜底(首条解析失败可顺延)。
        if let idx = queue.firstIndex(where: { $0.id == item.identifier }), idx > 0 {
            queue.swapAt(0, idx)
        }
        playback.play(track: queue[0], in: Array(queue.prefix(20)), startIndex: 0)
        return INPlayMediaIntentResponse(code: .success, userActivity: nil)
    }
}
