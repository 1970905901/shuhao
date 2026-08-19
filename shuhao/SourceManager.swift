import Foundation
import Combine

enum ResolveOrigin: Equatable, Sendable {
    case script(name: String)
    case otherSource(SourceID)
    case localFile

    var displayLabel: String {
        switch self {
        case .script(let name): return "脚本: \(name)"
        case .otherSource(let s): return "换源: \(s.displayName)"
        case .localFile: return "本地"
        }
    }
    var iconName: String {
        switch self {
        case .script: return "doc.text.fill"
        case .otherSource: return "arrow.triangle.2.circlepath"
        case .localFile: return "internaldrive.fill"
        }
    }
}

struct ResolvedTrack: Sendable {
    let url: URL
    let origin: ResolveOrigin
    let quality: Quality
    let warning: String?  // soft notice surfaced to UI; nil if everything looks fine
}

@MainActor
final class SourceManager: ObservableObject {
    @Published private(set) var loadedScripts: [LoadedScript] = []
    @Published private(set) var isLoading: Bool = false
    @Published var lastError: String?

    struct LoadedScript: Identifiable {
        let id: UUID
        let script: UserScript
        let runtime: JSScriptRuntime
        let capabilities: ScriptCapabilities
    }

    enum SourceError: LocalizedError {
        case noScriptForSource(SourceID)
        case actionUnsupported(SourceID, String)
        case invalidResult
        case songNotInAPIServer(SourceID)

        var errorDescription: String? {
            switch self {
            case .noScriptForSource(let s):
                return "没有脚本提供 \(s.displayName) 源,请到设置 → 自定义音源 导入脚本"
            case .actionUnsupported(let s, let a):
                return "\(s.displayName) 不支持动作 \(a)"
            case .invalidResult:
                return "脚本返回了无效结果"
            case .songNotInAPIServer(let s):
                return "这首 \(s.displayName) 歌曲不在 v4 脚本的 API 服务器数据库里,换一首或换个能用的脚本"
            }
        }
    }

    /// 加载脚本并返回是否成功。失败原因写入 `lastError`,供 UI 展示。
    /// ⚠️ 之前签名是 `-> Void`,导入表单在 load 失败时**没有任何提示**就关闭了
    /// (脚本被 add 进列表但实际没加载,界面上既没报错也没勾选) —— 这就是
    /// "本地脚本导入老样子"的直接原因之一。现在返回 Bool,调用方必须展示错误。
    @discardableResult
    func load(script: UserScript) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let meta = JSScriptRuntime.ScriptMetadata(
                id: script.id.uuidString,
                name: script.name,
                description: script.description,
                version: script.version,
                author: script.author,
                homepage: script.homepage
            )
            let runtime = try JSScriptRuntime(metadata: meta, rawScript: script.rawScript)
            let caps = try await runtime.waitForInit(timeout: 10)
            loadedScripts.removeAll { $0.script.id == script.id }
            loadedScripts.append(LoadedScript(id: script.id, script: script, runtime: runtime, capabilities: caps))
            return true
        } catch {
            lastError = "加载脚本失败: \(error.localizedDescription)"
            print("[SourceManager] load failed: \(error)")
            return false
        }
    }

    func unload(scriptID: UUID) {
        loadedScripts.removeAll { $0.script.id == scriptID }
    }

    /// Pick a script that supports `source` + `action`.
    private func pickScript(for source: SourceID, action: String) -> LoadedScript? {
        loadedScripts.first { ls in
            guard let cap = ls.capabilities.sources[source] else { return false }
            return cap.actions.contains(action)
        }
    }

    /// All loaded scripts that support `source` + `action`, in load order. Used to retry a song
    /// across every configured music source before giving up / switching platforms.
    private func pickScripts(for source: SourceID, action: String) -> [LoadedScript] {
        loadedScripts.filter { ls in
            guard let cap = ls.capabilities.sources[source] else { return false }
            return cap.actions.contains(action)
        }
    }

    /// Resolve a track URL — mirrors lx-music-mobile `handleGetOnlineMusicUrl`:
    ///   1) Try the user script for this source.
    ///   2) On failure, search other platforms for the same song and try those.
    ///   3) Last resort: platform direct fallback for kw/wy (off in strict mode).
    /// Returns both the URL and which mechanism produced it so the UI can be transparent.
    func resolveMusicURL(track: Track, quality: Quality? = nil) async throws -> ResolvedTrack {
        let preferred = quality ?? .k320
        // 1) Try the script on the original source. If the backend rejects the chosen quality
        //    (lxmusic's API server often only carries a subset), cascade down on the same script
        //    before resorting to other-source.  This is stricter than lx-music-mobile (which
        //    jumps straight to other-source on any failure) but matches the spirit of getPlayQuality
        //    while accounting for backend-level gaps that capability lists don't surface.
        //    Try EVERY loaded script that supports this platform, in load order — so if the user
        //    added several music sources, a song that one source can't deliver is retried on the
        //    next before we resort to switching platforms.
        let scripts = pickScripts(for: track.source, action: "musicUrl")
        for (scriptIdx, ls) in scripts.enumerated() {
            let scriptQs = Set(ls.capabilities.sources[track.source]?.qualities ?? [])
            let first = SourceManager.pickPlayQuality(
                preferred: preferred,
                trackQualities: Set(track.qualities),
                scriptQualities: scriptQs
            )
            print("[SourceManager] script[\(scriptIdx)] '\(ls.script.name)' musicUrl source=\(track.source.rawValue) songmid=\(track.songmid) prefer=\(preferred.rawValue) → effective=\(first.rawValue)")
            // Build the cascade — every quality at or below the chosen one that both
            // track and script claim to support.
            let cascade = SourceManager.qualityCascade(from: first, trackQualities: Set(track.qualities), scriptQualities: scriptQs)
            for (idx, q) in cascade.enumerated() {
                do {
                    let url = try await resolveViaScript(track: track, quality: q, loaded: ls)
                    let warn: String?
                    if scriptIdx > 0 {
                        warn = "已切换到音源「\(ls.script.name)」"
                    } else if idx > 0 {
                        warn = "\(first.displayName) 远程不支持,已降级到 \(q.displayName)"
                    } else {
                        warn = nil
                    }
                    return ResolvedTrack(url: url, origin: .script(name: ls.script.name), quality: q, warning: warn)
                } catch {
                    print("[SourceManager] script '\(ls.script.name)' @\(q.rawValue) failed (\(error.localizedDescription))")
                }
            }
            print("[SourceManager] script '\(ls.script.name)' exhausted\(scriptIdx + 1 < scripts.count ? " — trying next source" : " — trying other platforms")")
        }
        // 2) lx-music's `getOtherSource`: search the same song name+singer on EVERY other
        // platform, then try the script on each in match-quality order. First playable wins.
        if let resolved = await tryOtherSources(for: track, preferred: preferred) {
            return resolved
        }
        // (内置直连兜底已删除:脚本解析失败时直接报错,不再静默落到平台直连)
        if pickScript(for: track.source, action: "musicUrl") == nil {
            throw SourceError.noScriptForSource(track.source)
        }
        throw SourceError.songNotInAPIServer(track.source)
    }

    /// Search for the same song on other platforms and try resolving via each one's script.
    /// Returns the first successful URL, or nil if no alternative worked.
    private func tryOtherSources(for track: Track, preferred: Quality) async -> ResolvedTrack? {
        let alternatives = await OtherSourceFinder.findMatches(for: track)
        guard !alternatives.isEmpty else {
            print("[SourceManager] no other-source matches for \(track.name)")
            return nil
        }
        print("[SourceManager] other-source candidates: \(alternatives.map { "\($0.source.rawValue)/\($0.songmid)" }.joined(separator: ", "))")
        for alt in alternatives.prefix(5) {
            guard let altLS = pickScript(for: alt.source, action: "musicUrl") else { continue }
            let q = SourceManager.pickPlayQuality(
                preferred: preferred,
                trackQualities: Set(alt.qualities),
                scriptQualities: Set(altLS.capabilities.sources[alt.source]?.qualities ?? [])
            )
            do {
                print("[SourceManager] other-source try \(alt.source.rawValue)/\(alt.songmid) (\(alt.name) - \(alt.singer))")
                let url = try await resolveViaScript(track: alt, quality: q, loaded: altLS)
                print("[SourceManager] ✓ other-source hit \(alt.source.rawValue) -> \(url.host ?? "?")")
                let warn = "原 \(track.source.displayName) 源无法获取播放地址,已换到 \(alt.source.displayName)"
                return ResolvedTrack(url: url, origin: .otherSource(alt.source), quality: q, warning: warn)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Mirrors lx-music-mobile/src/core/music/utils.ts#getPlayQuality.
    /// `TRY_QUALITYS_LIST` is ['flac24bit', 'flac', '320k'] — 128k falls through directly.
    nonisolated static func pickPlayQuality(preferred: Quality,
                                             trackQualities: Set<Quality>,
                                             scriptQualities: Set<Quality>) -> Quality {
        let tryList: [Quality] = Array(Quality.ranked.dropLast())  // everything above 128k
        guard let startIdx = tryList.firstIndex(of: preferred) else {
            return .k128
        }
        for q in tryList[startIdx...] {
            // Extended tiers (hires/atmos/master): official metadata rarely lists them,
            // so script support alone is enough — failures fall through the cascade.
            // flac24/flac 同理:QQ 对 VIP 曲目常不下发 size_flac,元数据漏标不等于
            // 没有 —— 脚本声明支持就尝试,拼错的 URL 由 PlaybackEngine 的 404 降级兜底。
            if (trackQualities.contains(q) || q.isExtendedTier || q == .flac24 || q == .flac)
                && scriptQualities.contains(q) {
                return q
            }
        }
        return .k128
    }

    /// Cascade for backend retries: starting at `first` (already the result of pickPlayQuality),
    /// list every lower quality both track and script claim to support, ending at .k128.
    /// Used when the user-script's backend rejects a specific quality even though it advertises
    /// support (e.g. lxmusic API server returning "internal server error" for kw flac24bit).
    nonisolated static func qualityCascade(from first: Quality,
                                            trackQualities: Set<Quality>,
                                            scriptQualities: Set<Quality>) -> [Quality] {
        let full: [Quality] = Quality.ranked
        guard let startIdx = full.firstIndex(of: first) else { return [first] }
        var out: [Quality] = []
        for q in full[startIdx...] {
            // k128 is the universal floor — try it even if not in scriptQualities since
            // the bundled lx backend always carries 128k for the supported sources.
            // `first` is always included (it's the already-picked starting point), and
            // extended + lossless tiers only need script support (see pickPlayQuality).
            if q == first || q == .k128
                || ((trackQualities.contains(q) || q.isExtendedTier || q == .flac24 || q == .flac)
                    && scriptQualities.contains(q)) {
                out.append(q)
            }
        }
        if out.isEmpty { out = [first] }
        return out
    }

    private func resolveViaScript(track: Track, quality: Quality, loaded ls: LoadedScript) async throws -> URL {
        let info: [String: Any] = [
            "type": quality.rawValue,
            "musicInfo": SourceManager.makeOldMusicInfo(track: track),
        ]
        if UserDefaults.standard.bool(forKey: "debug.logScriptInfo") {
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]),
               let s = String(data: data, encoding: .utf8) {
                print("[SourceManager] → script info:\n\(s)")
            }
        }
        // The ScriptHTTPClient already has a 12s request timeout, so a hung backend (e.g. mg)
        // surfaces an error in ~12s instead of hanging forever.
        let result = try await ls.runtime.requestAction(source: track.source, action: "musicUrl", info: info)
        if UserDefaults.standard.bool(forKey: "debug.logScriptInfo") {
            print("[SourceManager] ← script result: \(result)")
        }
        if let dict = result as? [String: Any] {
            if let data = dict["data"] as? [String: Any], let urlStr = data["url"] as? String, let u = URL(string: urlStr) {
                return u
            }
            if let urlStr = dict["url"] as? String, let u = URL(string: urlStr) {
                return u
            }
        }
        throw SourceError.invalidResult
    }


    /// Builds the "old format" music info object that lx-music v4 user scripts expect.
    /// Mirrors `toOldMusicInfo` from lx-music-mobile/src/utils/index.ts.
    nonisolated static func makeOldMusicInfo(track: Track) -> [String: Any] {
        let interval: String = track.duration.map { secs in
            String(format: "%02d:%02d", secs / 60, secs % 60)
        } ?? ""
        var types: [[String: String]] = []
        var _types: [String: [String: String]] = [:]
        // Officially the order is highest → lowest; the script iterates the array.
        let ordered: [Quality] = Quality.ranked.filter { track.qualities.contains($0) }
        for q in ordered {
            types.append(["type": q.rawValue, "size": ""])
            _types[q.rawValue] = ["size": ""]
        }
        var info: [String: Any] = [
            "name": track.name,
            "singer": track.singer,
            "source": track.source.rawValue,
            "songmid": track.songmid,
            "interval": interval,
            "albumName": track.albumName ?? "",
            "img": track.picURL ?? "",
            "typeUrl": [String: String](),
            "albumId": track.albumId ?? "",
            "types": types,
            "_types": _types,
        ]
        // Source-specific fields the official `toOldMusicInfo` merges in.
        // Scripts read these from musicInfo (e.g. kg.hash, tx.strMediaMid).
        for (k, v) in track.extras { info[k] = v }
        return info
    }

    /// Ask a user script for lyric data. Returns the raw `{lyric, tlyric, rlyric, lxlyric}` dict.
    /// Mirrors lx-music-mobile init/userApi/index.ts line ~123: info = { type, musicInfo }.
    func requestLyric(track: Track) async throws -> Any {
        guard let ls = pickScript(for: track.source, action: "lyric") else {
            throw SourceError.noScriptForSource(track.source)
        }
        let info: [String: Any] = [
            "type": "",
            "musicInfo": SourceManager.makeOldMusicInfo(track: track),
        ]
        return try await ls.runtime.requestAction(source: track.source, action: "lyric", info: info)
    }

    func availableQualities(for source: SourceID) -> [Quality] {
        var set = Set<Quality>()
        for ls in loadedScripts {
            if let cap = ls.capabilities.sources[source] {
                cap.qualities.forEach { set.insert($0) }
            }
        }
        return Quality.allCases.filter { set.contains($0) }
    }

    func supportedSources() -> [SourceID] {
        var set = Set<SourceID>()
        for ls in loadedScripts {
            for (src, cap) in ls.capabilities.sources where cap.actions.contains("musicUrl") {
                set.insert(src)
            }
        }
        return SourceID.allCases.filter { set.contains($0) }
    }
}
