import Foundation
import Combine

/// A named sub-playlist under "已下载". Downloads are organised into these folders.
nonisolated struct DownloadFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var trackIDs: [String]

    init(id: UUID = UUID(), name: String, trackIDs: [String] = []) {
        self.id = id; self.name = name; self.trackIDs = trackIDs
    }
}

nonisolated enum DownloadStatus: String, Codable, Sendable {
    /// missing:曾经下载完成,但本地文件被用户在 Finder/外部删了。
    /// 入口在播放时的 url resolver(见 AppServices)—— 拿不到本地路径就把状态标过来,
    /// UI 自动从「已下载」角标切到「文件缺失」徽章,左滑可重新下载。
    case downloading, completed, failed, missing
}

/// One downloaded (or in-flight) track: its metadata, the chosen quality, the local file name,
/// and which sub-playlist it belongs to.
nonisolated struct DownloadRecord: Codable, Hashable, Sendable {
    var track: Track
    var quality: Quality
    var fileName: String          // relative name inside the Downloads directory
    var status: DownloadStatus
    var folderID: UUID
    var errorMessage: String?
}

@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var folders: [DownloadFolder] = []
    @Published private(set) var records: [String: DownloadRecord] = [:]   // trackID → record
    @Published private(set) var progress: [String: Double] = [:]          // trackID → 0...1 while active

    /// Injected by the app so downloads reuse the same URL resolution as playback.
    var urlResolver: ((Track, Quality) async throws -> URL)?
    /// 拉歌词 —— 沿用 PlaybackEngine.setLyricsResolver 同款依赖注入,DownloadStore
    /// 不直接知道 SourceManager / LyricsFetcher 是什么。下载完会用这个去拉歌词,
    /// 然后跟封面一起写进文件 metadata。
    var lyricsResolver: ((Track) async -> [LyricLine])?

    /// 同时跑的下载任务上限。SettingsStore 启动时推一次 + didSet 时同步,
    /// 默认 10。超过这个数的 download() 会进 pendingQueue 等位。
    var maxConcurrent: Int = 10 {
        didSet { drainQueue() }
    }
    /// 等位的下载请求 —— 已经在 records 里占好 .downloading 状态(给 UI 即时反馈),
    /// 但物理上 runDownload 还没起。activeCount 腾位置后 drainQueue 启动它们。
    private var pendingQueue: [(track: Track, quality: Quality)] = []
    /// 当前真正在跑的下载数(包含 resolver 解析 URL 那一段也算在内)。
    private var activeCount: Int = 0

    /// 新下载会落到这里。
    /// - iPad / iPhone: 沙盒 `Documents/Downloads/`
    /// - Mac Catalyst: `~/Music/Shuhao/` —— 用户能直接在 Finder / 系统音乐 app 里看到
    private let primaryDir: URL
    /// 旧位置(沙盒 `Documents/Downloads/`)。只在 Mac 上有值,作为 lazy fallback ——
    /// 用户切换到新版本之前已经存在的下载不会消失,localURL 会先查 primary 再查 legacy。
    private let legacyDir: URL?
    private let foldersURL: URL
    private let recordsURL: URL
    private var runners: [String: FileDownloader] = [:]   // trackID → active downloader

    /// 已下载歌曲的封面缓存(从音频文件嵌入的 APIC/PICTURE 提取)。放 Caches ——
    /// 系统清掉也没关系,下次启动 backfill 会从音频文件重新提取。
    private let coverCacheDir: URL
    /// 有缓存封面的 trackID 集合。@Published 让 backfill 完成时列表自动刷新。
    @Published private(set) var cachedCoverIDs: Set<String> = []

    private init() {
        let docs = AppPaths.documents
        // legacy 必须指向**搬迁前**的老路径:早期版本把歌下载在 ~/Documents/Downloads,
        // 那些音频文件没有跟着 json 一起搬(搬用户的音乐文件风险太大),所以升级后
        // 仍要能在原地找到它们,否则已下载的歌会集体变成"文件不存在"。
        let legacy = AppPaths.legacyBase.appendingPathComponent("Downloads", isDirectory: true)
        // JSON 状态文件永远跟 app 走(沙盒 Documents),不动它,免得迁移踩坑。
        self.foldersURL = docs.appendingPathComponent("downloadFolders.json")
        self.recordsURL = docs.appendingPathComponent("downloadRecords.json")

        #if targetEnvironment(macCatalyst)
        // Mac 走 ~/Music/Shuhao。如果建不出来(权限 / sandbox 没批 entitlement),
        // 落回沙盒 Documents/Downloads,功能不至于挂。
        let musicRoot = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        let preferred = musicRoot?.appendingPathComponent("Shuhao", isDirectory: true)
        if let preferred,
           ((try? FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil) {
            self.primaryDir = preferred
            self.legacyDir = legacy
        } else {
            self.primaryDir = legacy
            self.legacyDir = nil
        }
        #else
        self.primaryDir = legacy
        self.legacyDir = nil
        #endif

        let caches = AppPaths.caches
        self.coverCacheDir = caches.appendingPathComponent("EmbeddedCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coverCacheDir, withIntermediateDirectories: true)

        try? FileManager.default.createDirectory(at: primaryDir, withIntermediateDirectories: true)
        load()
        if folders.isEmpty {
            folders = [DownloadFolder(name: "默认")]
            save()
        }
        let cachedFiles = (try? FileManager.default.contentsOfDirectory(atPath: coverCacheDir.path)) ?? []
        cachedCoverIDs = Set(cachedFiles.map { ($0 as NSString).deletingPathExtension })
        backfillCoverCache()
    }

    // MARK: - Embedded cover cache

    /// 缓存文件名直接用 trackID(形如 "kw_665163",已经是文件名安全的)。
    nonisolated private func coverCacheURL(forID trackID: String) -> URL {
        coverCacheDir.appendingPathComponent(Self.sanitizeFileComponent(trackID) + ".img")
    }

    /// 已下载歌曲的本地封面文件,没有(未下载/还没提取)返回 nil。
    func embeddedCoverURL(for trackID: String) -> URL? {
        cachedCoverIDs.contains(trackID) ? coverCacheURL(forID: trackID) : nil
    }

    /// 界面显示封面的统一入口:已下载的歌优先用本地嵌入封面(离线可用、高清),
    /// 否则回落到网络 picURL。
    func displayCoverURL(for track: Track) -> String? {
        embeddedCoverURL(for: track.id)?.absoluteString ?? track.picURL
    }

    /// 本地导入等场景把读到的内嵌封面写入统一缓存(displayCoverURL/锁屏即生效)。
    nonisolated func cacheEmbeddedCover(_ data: Data, for trackID: String) async {
        await cacheCover(data, for: trackID)
    }

    /// 把封面数据落到缓存。文件 IO 在调用方线程,集合更新回主线程。
    nonisolated private func cacheCover(_ data: Data, for trackID: String) async {
        try? data.write(to: coverCacheURL(forID: trackID), options: .atomic)
        await MainActor.run { _ = self.cachedCoverIDs.insert(trackID) }
    }

    /// 存量已完成下载(以及被系统清掉缓存的)在启动时后台补提取封面。
    private func backfillCoverCache() {
        let pending: [(id: String, file: URL)] = records.values
            .filter { $0.status == .completed && !cachedCoverIDs.contains($0.track.id) }
            .compactMap { rec in localURL(for: rec.track.id).map { (rec.track.id, $0) } }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for item in pending {
                guard let self else { return }
                let tags = EmbeddedTagReader.read(at: item.file, wantCover: true, wantLyrics: false)
                guard let cover = tags.cover else { continue }
                await self.cacheCover(cover, for: item.id)
            }
        }
    }

    /// 已下载文件里嵌入的歌词(LRC 文本),读不到返回 nil。只读文件头部标签区,开销小。
    nonisolated static func readEmbeddedLyrics(at fileURL: URL) -> String? {
        EmbeddedTagReader.read(at: fileURL, wantCover: false, wantLyrics: true).lyrics
    }

    /// 解析一个 trackID 对应的本地文件 URL —— primary 先看,没有再去 legacy(只 Mac 有)。
    private func resolveExistingURL(fileName: String) -> URL? {
        guard !fileName.isEmpty else { return nil }
        let primary = primaryDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        if let legacy = legacyDir?.appendingPathComponent(fileName),
           FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return nil
    }

    // MARK: - Queries

    func isDownloaded(_ trackID: String) -> Bool { records[trackID]?.status == .completed }
    func isMissing(_ trackID: String) -> Bool { records[trackID]?.status == .missing }

    /// Local file URL for a completed download, or nil.
    func localURL(for trackID: String) -> URL? {
        guard let rec = records[trackID], rec.status == .completed else { return nil }
        return resolveExistingURL(fileName: rec.fileName)
    }

    /// 播放路径在拿不到本地文件时调一次:status 仍是 `.completed` 但磁盘上文件
    /// 已经没了 → 把 record 翻成 `.missing`,UI 自动切「文件缺失」徽章并提供重下入口。
    /// 文件还在(或 record 本来就不是 completed)→ no-op,返回 false。
    @discardableResult
    func markMissingIfNeeded(_ trackID: String) -> Bool {
        guard let rec = records[trackID], rec.status == .completed else { return false }
        if resolveExistingURL(fileName: rec.fileName) != nil { return false }
        records[trackID]?.status = .missing
        records[trackID]?.errorMessage = "本地文件已被删除"
        save()
        return true
    }

    func quality(for trackID: String) -> Quality? { records[trackID]?.quality }

    func tracks(in folder: DownloadFolder) -> [Track] {
        folder.trackIDs.compactMap { records[$0]?.track }
    }

    var activeDownloads: [DownloadRecord] {
        records.values.filter { $0.status == .downloading }.sorted { $0.track.name < $1.track.name }
    }
    var completedCount: Int { records.values.filter { $0.status == .completed }.count }

    // MARK: - Folders

    @discardableResult
    func createFolder(name: String) -> DownloadFolder {
        let f = DownloadFolder(name: name)
        folders.append(f)
        save()
        return f
    }

    /// Delete a folder and every download inside it (files + records).
    func deleteFolder(_ id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        for tid in folders[i].trackIDs { removeDownload(trackID: tid, persist: false) }
        folders.remove(at: i)
        save()
    }

    // MARK: - Naming

    /// 文件/目录名单组件消毒:`/` `:` 换成全角,其它非法字符换 `_`,去掉首部的点。
    nonisolated static func sanitizeFileComponent(_ s: String) -> String {
        var t = s
            .replacingOccurrences(of: "/", with: "／")
            .replacingOccurrences(of: ":", with: "：")
        for ch in ["?", "*", "\"", "<", ">", "|", "\\"] {
            t = t.replacingOccurrences(of: ch, with: "_")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix(".") { t.removeFirst() }
        return t.isEmpty ? "未知" : t
    }

    /// 新下载的相对路径,三种形态:
    /// - 有专辑 + 曲目号: `歌手/专辑/NN - 歌名.ext`
    /// - 有专辑无曲目号: `歌手/专辑 - 歌名.ext`
    /// - 无专辑:         `歌手 - 歌名.ext`
    nonisolated static func relativePath(track: Track, ext: String, trackNumber: Int?) -> String {
        let artist = sanitizeFileComponent(track.singer)
        let name = sanitizeFileComponent(track.name)
        if let album = track.albumName, !album.isEmpty {
            let alb = sanitizeFileComponent(album)
            if let n = trackNumber, n > 0 {
                return "\(artist)/\(alb)/\(String(format: "%02d", n)) - \(name).\(ext)"
            }
            return "\(artist)/\(alb) - \(name).\(ext)"
        }
        return "\(artist) - \(name).\(ext)"
    }

    /// 重名规避:跟其它记录或磁盘上已有文件撞名时,在扩展名前加 " (2)" / " (3)"…
    private func uniquify(_ fileName: String, excluding trackID: String) -> String {
        func taken(_ name: String) -> Bool {
            if records.contains(where: { $0.key != trackID && $0.value.fileName == name }) { return true }
            return FileManager.default.fileExists(atPath: primaryDir.appendingPathComponent(name).path)
        }
        guard taken(fileName) else { return fileName }
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var n = 2
        while taken("\(base) (\(n)).\(ext)") { n += 1 }
        return "\(base) (\(n)).\(ext)"
    }

    // MARK: - Download

    func download(track: Track, quality: Quality, folderID: UUID) {
        guard records[track.id]?.status != .downloading else { return }
        // Re-downloading a completed track at a new quality: drop the old file first.
        if records[track.id] != nil { removeFile(for: track.id) }

        // 最终文件名要等详情接口给曲目号才能定,先占位,runDownload 里再回填。
        var rec = DownloadRecord(track: track, quality: quality, fileName: "", status: .downloading, folderID: folderID)
        rec.errorMessage = nil
        records[track.id] = rec
        progress[track.id] = 0
        if let fi = folders.firstIndex(where: { $0.id == folderID }), !folders[fi].trackIDs.contains(track.id) {
            folders[fi].trackIDs.append(track.id)
        }
        save()

        // 入队 + 看看能不能立刻起 —— activeCount 没满就直接 drain 出去跑,
        // 满了就等其它任务收尾时释放槽位。状态对 UI 还是 .downloading,
        // 等位期间用户能看到「下载中」角标,体感上一致。
        pendingQueue.append((track, quality))
        drainQueue()
    }

    private func drainQueue() {
        while activeCount < maxConcurrent, !pendingQueue.isEmpty {
            let (track, quality) = pendingQueue.removeFirst()
            // 用户在等位时把这条 record 删了 / 重设了 → 跳过。
            guard records[track.id]?.status == .downloading else { continue }
            activeCount += 1
            Task { await self.runDownload(track: track, quality: quality) }
        }
    }

    /// 单次下载的生命周期结束(成功/失败/早退)时调,腾出并发槽位让 pendingQueue 里的下一个起来。
    private func finishSlot() {
        activeCount = max(0, activeCount - 1)
        drainQueue()
    }

    private func runDownload(track: Track, quality: Quality) async {
        guard let resolver = urlResolver else {
            fail(track.id, "下载未就绪")
            finishSlot()
            return
        }
        // 详情(曲目号/年份/高清封面)和播放地址解析并行跑,详情失败不碍事。
        async let detailsTask = TrackDetailFetcher.fetch(track)
        let url: URL
        do {
            url = try await resolver(track, quality)
        } catch {
            fail(track.id, error.localizedDescription)
            finishSlot()
            return
        }
        let details = await detailsTask

        // 优先信任 URL 自带扩展名(后端可能静默降级,hires 请求实发 mp3);
        // 没有就按档位推断 — flac 及以上(含 hires/atmos/master)都是 FLAC 容器。
        let urlExt = url.pathExtension.lowercased()
        let ext = ["mp3", "flac", "m4a", "wav", "ogg"].contains(urlExt)
            ? urlExt
            : ((quality == .k128 || quality == .k320) ? "mp3" : "flac")
        let fileName = uniquify(
            Self.relativePath(track: track, ext: ext, trackNumber: details?.trackNumber),
            excluding: track.id
        )
        records[track.id]?.fileName = fileName

        let dest = primaryDir.appendingPathComponent(fileName)
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let runner = FileDownloader()
        runners[track.id] = runner
        runner.start(
            url: url,
            to: dest,
            progress: { [weak self] p in
                Task { @MainActor in self?.progress[track.id] = p }
            },
            finish: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.runners[track.id] = nil
                    self.progress[track.id] = nil
                    switch result {
                    case .success:
                        self.records[track.id]?.status = .completed
                        self.records[track.id]?.errorMessage = nil
                        // 元数据写入是 best-effort 的后置步骤:歌曲已经是"下载完成"
                        // 状态了,标签写不上属于次要问题,失败不回滚成功状态。
                        self.embedMetadata(for: track, details: details, at: dest)
                    case .failure(let err):
                        self.fail(track.id, err.localizedDescription)
                    }
                    self.save()
                    // 释放并发槽位,让 pendingQueue 里的下一个起来。无论成功失败都要释放。
                    self.finishSlot()
                }
            }
        )
    }

    // MARK: - Metadata embedding

    /// 下载完成后异步拉封面 + 歌词,把它们 + track 信息一起写进音频文件 (ID3v2 或 FLAC tag)。
    /// 这一步是 fire-and-forget —— 失败不影响下载状态,日志输出而已。
    private func embedMetadata(for track: Track, details: TrackDetails?, at fileURL: URL) {
        let lyricsResolver = self.lyricsResolver
        Task.detached(priority: .utility) {
            // 1) 封面 —— 优先详情接口给的高清地址,回落搜索结果的 picURL;
            //    MIME 类型尽量从 HTTP response 拿,拿不到就按 URL 后缀猜。
            var coverData: Data? = nil
            var coverMIME: String? = nil
            if let urlStr = details?.hiResCoverURL ?? track.picURL, let url = URL(string: urlStr) {
                do {
                    var req = URLRequest(url: url)
                    req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
                                 forHTTPHeaderField: "User-Agent")
                    req.timeoutInterval = 15
                    let (data, response) = try await URLSession.shared.data(for: req)
                    coverData = data
                    if let http = response as? HTTPURLResponse,
                       let ct = http.value(forHTTPHeaderField: "Content-Type"),
                       ct.hasPrefix("image/") {
                        // 形如 "image/jpeg; charset=binary" —— 取分号前。
                        coverMIME = ct.split(separator: ";").first.map(String.init)
                    } else {
                        switch url.pathExtension.lowercased() {
                        case "png":  coverMIME = "image/png"
                        case "webp": coverMIME = "image/webp"
                        default:     coverMIME = "image/jpeg"
                        }
                    }
                } catch {
                    print("[Download] 封面抓取失败: \(error.localizedDescription)")
                }
            }
            // 顺手写进本地封面缓存 —— 之后列表/播放器/锁屏显示封面都不用再走网络。
            if let coverData, !coverData.isEmpty {
                await self.cacheCover(coverData, for: track.id)
            }

            // 2) 歌词 —— resolver 是注入的 LyricsFetcher 入口。
            var lrcText: String? = nil
            if let resolver = lyricsResolver {
                let lines = await resolver(track)
                if !lines.isEmpty {
                    lrcText = LRCSerializer.serialize(lines)
                }
            }

            // 3) 写入,扩展名分发到 MP3 / FLAC writer。
            AudioMetadataWriter.apply(
                to: fileURL,
                track: track,
                details: details,
                coverData: coverData,
                coverMIME: coverMIME,
                lrcText: lrcText
            )
        }
    }

    private func fail(_ trackID: String, _ message: String) {
        records[trackID]?.status = .failed
        records[trackID]?.errorMessage = message
        progress[trackID] = nil
        save()
    }

    /// Remove a single download (file + record + folder membership).
    func removeDownload(trackID: String, persist: Bool = true) {
        runners[trackID]?.cancel()
        runners[trackID] = nil
        progress[trackID] = nil
        removeFile(for: trackID)
        try? FileManager.default.removeItem(at: coverCacheURL(forID: trackID))
        cachedCoverIDs.remove(trackID)
        records[trackID] = nil
        for i in folders.indices { folders[i].trackIDs.removeAll { $0 == trackID } }
        if persist { save() }
    }

    func retry(trackID: String) {
        guard let rec = records[trackID] else { return }
        download(track: rec.track, quality: rec.quality, folderID: rec.folderID)
    }

    private func removeFile(for trackID: String) {
        // fileName 为空说明下载还没定名(详情阶段就被取消/中断了),没有文件可删;
        // 不 guard 的话 appendingPathComponent("") 会指回下载根目录,删了就是灾难。
        guard let rec = records[trackID], !rec.fileName.isEmpty else { return }
        // 两个位置都试着删 —— Mac 上可能存在 legacy 留下的老文件。
        let primary = primaryDir.appendingPathComponent(rec.fileName)
        try? FileManager.default.removeItem(at: primary)
        pruneEmptyDirectories(from: primary.deletingLastPathComponent(), upTo: primaryDir)
        if let legacy = legacyDir?.appendingPathComponent(rec.fileName) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    /// 删除文件后,从所在目录往上把空目录清掉,直到下载根目录为止(根目录本身不动)。
    private func pruneEmptyDirectories(from dir: URL, upTo root: URL) {
        var current = dir.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while current.path != rootPath, current.path.hasPrefix(rootPath) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
            // .DS_Store 不算占用 —— Finder 在 Mac 上随手就会生成一个。
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: foldersURL),
           let decoded = try? JSONDecoder().decode([DownloadFolder].self, from: data) {
            folders = decoded
        }
        if let data = try? Data(contentsOf: recordsURL),
           let decoded = try? JSONDecoder().decode([String: DownloadRecord].self, from: data) {
            // Anything left as `.downloading` from a previous run never finished — mark failed.
            records = decoded.mapValues { rec in
                var r = rec
                if r.status == .downloading { r.status = .failed; r.errorMessage = "已中断" }
                return r
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            try? data.write(to: foldersURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: recordsURL, options: .atomic)
        }
    }
}

// MARK: - File downloader (progress via URLSessionDownloadDelegate)

/// Downloads a URL to a destination file, reporting progress. Kept separate from the @MainActor
/// store because URLSession delegate callbacks arrive on a background queue.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var onProgress: ((Double) -> Void)?
    private var onFinish: ((Result<Void, Error>) -> Void)?
    private var destination: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    func start(url: URL, to dest: URL, progress: @escaping (Double) -> Void, finish: @escaping (Result<Void, Error>) -> Void) {
        onProgress = progress
        onFinish = finish
        destination = dest
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        let cfg = URLSessionConfiguration.default
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: req)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        onProgress = nil
        onFinish = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destination else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            onFinish?(.success(()))
        } catch {
            onFinish?(.failure(error))
        }
        onFinish = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            onFinish?(.failure(error))
            onFinish = nil
        }
        session.finishTasksAndInvalidate()
    }
}
