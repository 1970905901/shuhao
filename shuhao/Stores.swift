import Foundation
import Combine

@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [PlaylistMeta] = []
    @Published private(set) var trackBank: [String: Track] = [:]

    /// 已删除歌单的墓碑:歌单 id → 删除时间。
    /// 删除必须显式记录并同步 —— 否则其它设备上仍存在的副本会在下一次
    /// pullFromCloud 里被当作"本地缺失的远端歌单"重新加回来,表现为
    /// 删掉的歌单过一阵自己回来。
    ///
    /// 按条数封顶而不是按时间过期:墓碑要压住的是"某台设备离线很久、回来时
    /// 还揣着旧副本"的情况,按时间清理等于赌设备最长闲置多久 —— 抽屉里的
    /// iPad 放半年很常见,过期了这个 bug 就会重现。一条墓碑实测约 56 字节,
    /// 200 条约 11KB,只占 iCloud KV 1MB 配额的 1%,留着比清掉划算得多。
    private var tombstones: [String: Date] = [:]
    private static let maxTombstones = 200

    private let playlistsURL: URL
    private let trackBankURL: URL
    private let tombstonesURL: URL

    private var cloudCancellable: AnyCancellable?

    init() {
        let dir = AppPaths.documents
        self.playlistsURL = dir.appendingPathComponent("playlists.json")
        self.trackBankURL = dir.appendingPathComponent("trackBank.json")
        self.tombstonesURL = dir.appendingPathComponent("deletedPlaylists.json")
        load()
        if playlists.isEmpty {
            if let remote: [PlaylistMeta] = CloudSync.shared.pull([PlaylistMeta].self, forKey: CloudSync.Keys.playlists) {
                // 首次装机也要过一遍墓碑,否则云端残留的已删歌单会在新设备复活
                playlists = applyingTombstones(to: remote)
            }
            if let bank: [String: Track] = CloudSync.shared.pull([String: Track].self, forKey: CloudSync.Keys.trackBank) {
                trackBank = bank
            }
        }
        if playlists.isEmpty {
            playlists.append(PlaylistMeta(name: "我喜欢的"))
            save()
        }
        // 清理已经存在的同名重复 — 上一版 pullFromCloud 有 dedupe bug 时
        // 已经写到磁盘的两个 "我喜欢的" 在 load() 后会都被读进 playlists。
        // 这里调一次 dedupeByName 让本地数据收敛。
        let before = playlists.count
        dedupeByName()
        if playlists.count != before { save() }
        cloudCancellable = CloudSync.shared.didReceiveRemoteChange.sink { [weak self] in
            self?.pullFromCloud()
        }
    }

    /// 按名字归并 playlists — 同名的合并曲目(union)、updatedAt 取最大。
    /// 用于:
    ///   1. App 启动时清理之前 bug 写入的重复数据
    ///   2. pullFromCloud 第二遍 dedupe
    private func dedupeByName() {
        var deduped: [PlaylistMeta] = []
        for p in playlists {
            if let i = deduped.firstIndex(where: { $0.name == p.name }) {
                var combined = deduped[i]
                for tid in p.trackIDs where !combined.trackIDs.contains(tid) {
                    combined.trackIDs.append(tid)
                }
                combined.updatedAt = max(combined.updatedAt, p.updatedAt)
                deduped[i] = combined
            } else {
                deduped.append(p)
            }
        }
        playlists = deduped
    }

    /// 丢掉 list 里已被墓碑标记的歌单。
    /// 墓碑时间早于歌单 updatedAt 时保留 —— 说明删除之后又有设备改过它
    /// (加了歌等),按 last-writer-wins 让修改赢,避免误删有效数据。
    private func applyingTombstones(to list: [PlaylistMeta]) -> [PlaylistMeta] {
        guard !tombstones.isEmpty else { return list }
        return list.filter { p in
            guard let deletedAt = tombstones[p.id.uuidString] else { return true }
            return p.updatedAt > deletedAt
        }
    }

    /// 只保留最近的 maxTombstones 条 —— 删得再多也不会撑爆云端配额,
    /// 而正常使用下(删过的歌单远少于 200 个)墓碑等同于永不过期。
    private func pruneTombstones() {
        guard tombstones.count > Self.maxTombstones else { return }
        let keep = tombstones.sorted { $0.value > $1.value }.prefix(Self.maxTombstones)
        tombstones = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func pullFromCloud() {
        // 先合并墓碑:两端的删除记录取并集、同 id 取较晚的时间。
        // 必须在合并歌单之前做,这样远端的删除也能落到本地。
        if let remoteTombs: [String: Date] = CloudSync.shared.pull([String: Date].self, forKey: CloudSync.Keys.deletedPlaylists) {
            tombstones.merge(remoteTombs) { local, remote in max(local, remote) }
        }
        pruneTombstones()
        // 远端删除的歌单,本地也要删掉(除非本地在删除之后改过它)
        let survivors = applyingTombstones(to: playlists)
        if survivors.count != playlists.count {
            playlists = survivors
        }
        if let remote: [PlaylistMeta] = CloudSync.shared.pull([PlaylistMeta].self, forKey: CloudSync.Keys.playlists).map(applyingTombstones(to:)) {
            // 合并:同名歌单当成同一个,避免各端 init 时本地默认创建的
            // "我喜欢的" 跟从其它设备同步过来的 "我喜欢的" 出现两条。
            //   1. 先按 UUID 直接匹配 — 取 updatedAt 较新的
            //   2. UUID 不匹配但同名 → 合并曲目(union),取最新 updatedAt
            //   3. 既无 UUID 匹配也无同名 → 作为新歌单加入
            // 最后再走一遍同名 dedupe(防止 remote 内部就有同名重复 +
            // local 与 remote 之间的 dedupe 顺序问题)。
            var merged = playlists
            for r in remote {
                if let i = merged.firstIndex(where: { $0.id == r.id }) {
                    if r.updatedAt > merged[i].updatedAt {
                        // 本地导入的歌不上云,远端版本里必然没有 — 合并回来防丢。
                        var newer = r
                        for tid in merged[i].trackIDs
                        where isLocalImport(tid) && !newer.trackIDs.contains(tid) {
                            newer.trackIDs.append(tid)
                        }
                        merged[i] = newer
                    }
                } else if let i = merged.firstIndex(where: { $0.name == r.name }) {
                    var combined = r
                    for tid in merged[i].trackIDs where !combined.trackIDs.contains(tid) {
                        combined.trackIDs.append(tid)
                    }
                    combined.updatedAt = max(combined.updatedAt, merged[i].updatedAt)
                    merged[i] = combined
                } else {
                    merged.append(r)
                }
            }
            playlists = merged
            // 第二遍 dedupe — 防止 remote 内部就有同名重复 + local 与 remote
            // 之间的 dedupe 处理顺序在某些 case 下漏掉的歧义
            dedupeByName()
        }
        if let bank: [String: Track] = CloudSync.shared.pull([String: Track].self, forKey: CloudSync.Keys.trackBank) {
            trackBank.merge(bank) { local, _ in local }
        }
        // 推回 iCloud — 让所有设备最终收敛到同一份 UUID 列表,不会再分叉
        save(skipCloud: false)
    }

    func tracks(in playlist: PlaylistMeta) -> [Track] {
        playlist.trackIDs.compactMap { trackBank[$0] }
    }

    /// persist: false 时只改内存不落盘 —— 大歌单分批导入用,中间批次跳过
    /// save()(整个 trackBank 的 JSON 编码 + 写盘 + 推云都在主线程,是卡顿大头),
    /// 调用方在最后一批之后调 persist() 统一落盘。
    func addTracks(_ tracks: [Track], to playlistID: UUID, persist: Bool = true) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var existing = Set(playlists[idx].trackIDs)
        var newIDs: [String] = []
        var additions: [String: Track] = [:]
        for t in tracks {
            additions[t.id] = t
            if existing.insert(t.id).inserted {
                newIDs.append(t.id)
            }
        }
        // 整批合并/追加,@Published 只各触发一次,避免逐首 append 刷 1000 次 UI
        trackBank.merge(additions) { _, new in new }
        playlists[idx].trackIDs.append(contentsOf: newIDs)
        playlists[idx].updatedAt = Date()
        if persist { save() }
    }

    /// 配合 addTracks(persist: false) 使用,分批写完后统一落盘 + 推云。
    func persist() {
        save()
    }

    func remove(trackIDs: [String], from playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].trackIDs.removeAll { trackIDs.contains($0) }
        playlists[idx].updatedAt = Date()
        save()
        cleanTrackBank()
    }

    func createPlaylist(name: String) -> PlaylistMeta {
        let p = PlaylistMeta(name: name)
        playlists.append(p)
        save()
        return p
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        // 记下墓碑并同步出去,否则别的设备会把它当新歌单推回来
        tombstones[id.uuidString] = Date()
        save()
        cleanTrackBank()
    }

    func renamePlaylist(_ id: UUID, name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = name
        playlists[idx].updatedAt = Date()
        save()
    }

    private func cleanTrackBank() {
        let keep = Set(playlists.flatMap { $0.trackIDs })
        trackBank = trackBank.filter { keep.contains($0.key) }
        save()
    }

    private func load() {
        if let data = try? Data(contentsOf: playlistsURL),
           let decoded = try? JSONDecoder().decode([PlaylistMeta].self, from: data) {
            playlists = decoded
        }
        if let data = try? Data(contentsOf: trackBankURL),
           let decoded = try? JSONDecoder().decode([String: Track].self, from: data) {
            trackBank = decoded
        }
        if let data = try? Data(contentsOf: tombstonesURL),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            tombstones = decoded
        }
    }

    private func save(skipCloud: Bool = false) {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: playlistsURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(trackBank) {
            try? data.write(to: trackBankURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(tombstones) {
            try? data.write(to: tombstonesURL, options: .atomic)
        }
        if !skipCloud {
            // 本地文件夹导入的歌(lf://)的 bookmark 只在本机有效,同步到其它设备
            // 也播不了,所以歌曲和纯本地歌单都不上云。
            var cloudBank = trackBank.filter { !isLocalImport($0.key) }
            // 云端已有的曲目要保住:push 是整体覆盖,如果这台设备的 trackBank
            // 不全(曾经超限没同步到、或刚装机还没拉全),直接推自己的那份会把
            // 别的设备存进去的曲目抹掉 —— 歌单里的 id 还在、歌没了,就成了
            // "有名字有数量、点进去空白"的幽灵歌单。所以先并上云端现有的。
            if let remoteBank: [String: Track] = CloudSync.shared.pull([String: Track].self, forKey: CloudSync.Keys.trackBank) {
                cloudBank.merge(remoteBank) { local, _ in local }
            }
            // 再把没人引用的曲目剪掉,免得云端 1MB 配额被已删歌单的残留吃满。
            // 引用集必须算上云端歌单 —— 别的设备刚建的歌单本地还没拉到,
            // 只按本地引用剪会把它的歌删掉,又变成幽灵歌单。
            let remotePlaylists: [PlaylistMeta] = CloudSync.shared.pull([PlaylistMeta].self, forKey: CloudSync.Keys.playlists) ?? []
            let referenced = Set(playlists.flatMap { $0.trackIDs })
                .union(applyingTombstones(to: remotePlaylists).flatMap { $0.trackIDs })
            cloudBank = cloudBank.filter { referenced.contains($0.key) }
            let cloudPlaylists: [PlaylistMeta] = playlists.compactMap { p in
                var copy = p
                copy.trackIDs = p.trackIDs.filter { !isLocalImport($0) }
                if copy.trackIDs.isEmpty && !p.trackIDs.isEmpty { return nil }
                return copy
            }
            CloudSync.shared.push(cloudPlaylists, forKey: CloudSync.Keys.playlists)
            CloudSync.shared.push(cloudBank, forKey: CloudSync.Keys.trackBank)
            CloudSync.shared.push(tombstones, forKey: CloudSync.Keys.deletedPlaylists)
        }
    }

    /// 本地文件夹导入的歌(songmid 是 lf:// 引用)。
    private func isLocalImport(_ trackID: String) -> Bool {
        trackBank[trackID]?.songmid.hasPrefix(LocalMusicStore.scheme) ?? false
    }
}

@MainActor
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [UserScript] = []

    private let url: URL
    private var cloudCancellable: AnyCancellable?

    init() {
        let dir = AppPaths.documents
        self.url = dir.appendingPathComponent("scripts.json")
        load()
        // Migrate from cloud if local is empty (fresh install on a 2nd device).
        if scripts.isEmpty,
           let remote: [UserScript] = CloudSync.shared.pull([UserScript].self, forKey: CloudSync.Keys.scripts) {
            scripts = remote
            save(skipCloud: true)
        }
        cloudCancellable = CloudSync.shared.didReceiveRemoteChange.sink { [weak self] in
            self?.pullFromCloud()
        }
    }

    private func pullFromCloud() {
        guard let remote: [UserScript] = CloudSync.shared.pull([UserScript].self, forKey: CloudSync.Keys.scripts) else { return }
        // Last-write-wins by `name + version` — script identity is the bundle,
        // not the UUID (UUIDs differ across devices for the same script source).
        var merged = scripts
        for r in remote {
            if !merged.contains(where: { $0.name == r.name && $0.version == r.version }) {
                merged.append(r)
            }
        }
        if merged.count != scripts.count {
            scripts = merged
            save(skipCloud: true)
        }
    }

    func add(_ script: UserScript) {
        scripts.removeAll { $0.id == script.id }
        scripts.append(script)
        save()
    }

    func remove(_ id: UUID) {
        scripts.removeAll { $0.id == id }
        save()
    }

    func toggle(_ id: UUID, enabled: Bool) {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[idx].enabled = enabled
        save()
    }

    /// Parse standard lx-music user-script header comment for metadata.
    static func parseMetadata(from raw: String) -> UserScript {
        var name = "未命名脚本"
        var description = ""
        var version = "1.0.0"
        var author = "未知"
        var homepage = ""
        let header = String(raw.prefix(2000))
        // split(whereSeparator:) instead of split(separator: "\n") — "\r\n" is a
        // single Character in Swift, so splitting on "\n" misses CRLF line endings
        // and glues lines together (real scripts in the wild mix CRLF/LF).
        for line in header.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("*") || trimmed.hasPrefix("//") else { continue }
            let body = trimmed.replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "//", with: "")
                .trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("@name") {
                name = body.replacingOccurrences(of: "@name", with: "").trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("@description") {
                description = body.replacingOccurrences(of: "@description", with: "").trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("@version") {
                version = body.replacingOccurrences(of: "@version", with: "").trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("@author") {
                author = body.replacingOccurrences(of: "@author", with: "").trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("@homepage") || body.hasPrefix("@repository") {
                homepage = body.replacingOccurrences(of: "@homepage", with: "")
                    .replacingOccurrences(of: "@repository", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return UserScript(name: name, description: description, version: version,
                          author: author, homepage: homepage, rawScript: raw)
    }

    private func load() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([UserScript].self, from: data) {
            scripts = decoded
            // Self-heal entries imported before the CRLF parsing fix: re-derive
            // metadata from the stored script body if the name never parsed.
            var healed = false
            for idx in scripts.indices where scripts[idx].name == "未命名脚本" {
                let reparsed = Self.parseMetadata(from: scripts[idx].rawScript)
                guard reparsed.name != "未命名脚本" else { continue }
                scripts[idx].name = reparsed.name
                scripts[idx].description = reparsed.description
                scripts[idx].version = reparsed.version
                scripts[idx].author = reparsed.author
                scripts[idx].homepage = reparsed.homepage
                healed = true
            }
            if healed { save() }
        }
    }

    private func save(skipCloud: Bool = false) {
        if let data = try? JSONEncoder().encode(scripts) {
            try? data.write(to: url, options: .atomic)
        }
        // Push to iCloud KV — 1 MB total limit; CloudSync.push silently
        // refuses oversize payloads so a single very large script just won't
        // sync rather than breaking the rest of the store.
        if !skipCloud {
            CloudSync.shared.push(scripts, forKey: CloudSync.Keys.scripts)
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var preferredQuality: Quality {
        didSet { UserDefaults.standard.set(preferredQuality.rawValue, forKey: "pref.quality") }
    }
    @Published var enableDirectFallback: Bool {
        didSet { UserDefaults.standard.set(enableDirectFallback, forKey: "pref.enableDirectFallback") }
    }
    /// When on, the UI surfaces informational notices like "换源播放" / "已降级音质" / "已用 libFLAC 解码".
    /// Real playback errors are always shown regardless of this flag.
    @Published var showDebugNotices: Bool {
        didSet { UserDefaults.standard.set(showDebugNotices, forKey: "pref.showDebugNotices") }
    }
    /// Show the synced current lyric line in the CarPlay / lock-screen album field instead of the album name.
    @Published var showLyricsOnNowPlaying: Bool {
        didSet { UserDefaults.standard.set(showLyricsOnNowPlaying, forKey: "pref.showLyricsOnNowPlaying") }
    }
    /// Which sources contribute to the iPad/Mac "发现" page's recommendation
    /// + leaderboard feeds. Defaults to all four mainstream sources. Stored
    /// as a comma-joined rawValue list since UserDefaults doesn't carry Set.
    @Published var homeSources: Set<SourceID> {
        didSet {
            let raw = homeSources.map(\.rawValue).sorted().joined(separator: ",")
            UserDefaults.standard.set(raw, forKey: "pref.homeSources")
        }
    }
    /// 批量下载时,如果某首歌已下载但音质低于意图档算出的目标档,是否自动重下升级。
    /// 默认开 —— 用户点「全部下载 + 选 flac」基本就是想把歌单整体提到高音质。
    @Published var batchUpgradeQuality: Bool {
        didSet { UserDefaults.standard.set(batchUpgradeQuality, forKey: "pref.batchUpgradeQuality") }
    }
    /// 同时跑的下载任务上限。批量下载 200 首一瞬间砸 200 个请求容易拖卡播放,
    /// 默认 10,用户嫌慢可以调。1~32 区间内夹紧。
    @Published var downloadConcurrency: Int {
        didSet {
            let clamped = max(1, min(32, downloadConcurrency))
            if clamped != downloadConcurrency { downloadConcurrency = clamped; return }
            UserDefaults.standard.set(downloadConcurrency, forKey: "pref.downloadConcurrency")
            DownloadStore.shared.maxConcurrent = downloadConcurrency
        }
    }

    init() {
        let q = UserDefaults.standard.string(forKey: "pref.quality") ?? Quality.k320.rawValue
        self.preferredQuality = Quality(rawValue: q) ?? .k320
        if UserDefaults.standard.object(forKey: "pref.enableDirectFallback") == nil {
            // Default ON — the bundled v4.0.js script's API server only implements `checkUpdate`
            // and 404s `/lxmusicv4/url/...`, so strict-script mode currently can't play anything.
            // Users who deploy their own lx-music-api-server can disable this.
            self.enableDirectFallback = true
        } else {
            self.enableDirectFallback = UserDefaults.standard.bool(forKey: "pref.enableDirectFallback")
        }
        self.showDebugNotices = UserDefaults.standard.bool(forKey: "pref.showDebugNotices")  // default off
        if UserDefaults.standard.object(forKey: "pref.showLyricsOnNowPlaying") == nil {
            self.showLyricsOnNowPlaying = true  // default on
        } else {
            self.showLyricsOnNowPlaying = UserDefaults.standard.bool(forKey: "pref.showLyricsOnNowPlaying")
        }
        // 发现页源:首次启动 4 个主流源全开,后续按用户勾选持久化
        if let raw = UserDefaults.standard.string(forKey: "pref.homeSources") {
            let ids = raw.split(separator: ",").compactMap { SourceID(rawValue: String($0)) }
            self.homeSources = Set(ids.isEmpty ? [.kw, .wy, .kg, .tx] : ids)
        } else {
            self.homeSources = [.kw, .wy, .kg, .tx]
        }
        // 批量升级:首次启动默认 ON。
        if UserDefaults.standard.object(forKey: "pref.batchUpgradeQuality") == nil {
            self.batchUpgradeQuality = true
        } else {
            self.batchUpgradeQuality = UserDefaults.standard.bool(forKey: "pref.batchUpgradeQuality")
        }
        // 并发上限:首次启动默认 10,之后读用户设置(0 当作未设置走默认)。
        let saved = UserDefaults.standard.integer(forKey: "pref.downloadConcurrency")
        self.downloadConcurrency = saved > 0 ? max(1, min(32, saved)) : 10
        // 启动时把上限推给 DownloadStore —— SettingsStore 后于 DownloadStore.shared
        // 初始化(shuhaoApp 顶层),写一次就同步上了。
        DownloadStore.shared.maxConcurrent = self.downloadConcurrency
    }
}
