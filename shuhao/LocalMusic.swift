import SwiftUI
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

// MARK: - 本地音乐文件夹导入

/// 本地音乐文件夹 → 歌单。
/// - 文件夹用 security-scoped bookmark 持久化(iOS 沙盒容器路径每次启动都会变,
///   所以歌曲不存绝对路径:songmid 存 "lf://<folderID>/<relativePath>",播放时实时解析)。
/// - 歌曲信息(标题/歌手/专辑/时长)导入时从文件读取写进 Track;内嵌封面写入
///   DownloadStore 的统一封面缓存,全 App 的 displayCoverURL/锁屏直接生效;
///   歌词播放时读文件内嵌标签(AppServices.localLyricsProvider)。
@MainActor
final class LocalMusicStore {
    static let shared = LocalMusicStore()

    nonisolated static let scheme = "lf://"
    nonisolated static let audioExtensions: Set<String> =
        ["mp3", "flac", "m4a", "aac", "wav", "aif", "aiff", "caf"]

    private struct FolderRecord: Codable {
        let id: UUID
        var bookmark: Data
        var name: String
    }

    private var folders: [FolderRecord] = []
    private var rootCache: [UUID: URL] = [:]
    private let storeURL: URL = {
        let dir = AppPaths.documents
        return dir.appendingPathComponent("localFolders.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([FolderRecord].self, from: data) {
            folders = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    // MARK: - Import

    enum ImportError: LocalizedError {
        case noAudioFiles
        var errorDescription: String? {
            switch self {
            case .noAudioFiles: return "该文件夹(含子目录)里没有找到音乐文件"
            }
        }
    }

    /// 全流程:bookmark → 递归扫描 → 逐文件读 metadata/封面 → 建歌单。
    /// `progress` 0…1 主线程回调。返回导入的歌曲数。
    func importFolder(_ folderURL: URL, playlistName: String,
                      playlists: PlaylistStore, downloads: DownloadStore,
                      progress: @escaping @MainActor (Double) -> Void) async throws -> Int {
        let scoped = folderURL.startAccessingSecurityScopedResource()
        defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }

        let bookmark = try Self.makeBookmark(folderURL)
        let folderID = UUID()

        let files = await Task.detached(priority: .userInitiated) {
            Self.scanAudioFiles(root: folderURL)
        }.value
        guard !files.isEmpty else { throw ImportError.noAudioFiles }

        var tracks: [Track] = []
        for (idx, rel) in files.enumerated() {
            let fileURL = folderURL.appendingPathComponent(rel)
            let (track, cover) = await Self.readTrack(file: fileURL, rel: rel, folderID: folderID)
            tracks.append(track)
            if let cover, !cover.isEmpty {
                await downloads.cacheEmbeddedCover(cover, for: track.id)
            }
            progress(Double(idx + 1) / Double(files.count))
        }

        folders.append(FolderRecord(id: folderID, bookmark: bookmark, name: playlistName))
        save()

        let playlist = playlists.createPlaylist(name: playlistName)
        playlists.addTracks(tracks, to: playlist.id)
        return tracks.count
    }

    /// 递归列出 root 及所有子目录下的音频文件,返回相对路径(自然排序)。
    nonisolated private static func scanAudioFiles(root: URL) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var rels: [String] = []
        for case let url as URL in en {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(rootPath + "/") else { continue }
            rels.append(String(p.dropFirst(rootPath.count + 1)))
        }
        return rels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 读单个文件的标签(AVFoundation 优先,FLAC 等读不到时退回 EmbeddedTagReader),
    /// 都没有时用文件名,支持 "歌手 - 歌名" 约定。
    nonisolated private static func readTrack(file: URL, rel: String, folderID: UUID) async -> (Track, Data?) {
        var title = file.deletingPathExtension().lastPathComponent
        var artist = ""
        var album: String?
        var duration: Int?
        var cover: Data?

        let asset = AVURLAsset(url: file)
        if let dur = try? await asset.load(.duration) {
            let s = Int(dur.seconds.rounded())
            if s > 0 { duration = s }
        }
        if let meta = try? await asset.load(.commonMetadata) {
            func str(_ id: AVMetadataIdentifier) async -> String? {
                guard let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first
                else { return nil }
                return try? await item.load(.stringValue)
            }
            if let t = await str(.commonIdentifierTitle), !t.isEmpty { title = t }
            if let a = await str(.commonIdentifierArtist), !a.isEmpty { artist = a }
            if let al = await str(.commonIdentifierAlbumName), !al.isEmpty { album = al }
            if let art = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork).first {
                cover = try? await art.load(.dataValue)
            }
        }
        // AVFoundation 对 FLAC 的 Vorbis Comment 经常读不到 ARTIST/TITLE/ALBUM —
        // 自己解析一遍兜底。MP3 的 ID3 文本帧也顺手覆盖,有些文件 ID3 头格式让
        // AVF 解码失败但我们直接按 spec 读没问题。封面缺失时也复用这一次调用。
        let needFields = artist.isEmpty || (album?.isEmpty ?? true)
            || title == file.deletingPathExtension().lastPathComponent
        if cover == nil || needFields {
            let tags = EmbeddedTagReader.read(at: file,
                                              wantCover: cover == nil,
                                              wantLyrics: false,
                                              wantFields: needFields)
            if cover == nil { cover = tags.cover }
            if artist.isEmpty, let a = tags.artist, !a.isEmpty { artist = a }
            if (album?.isEmpty ?? true), let al = tags.album, !al.isEmpty { album = al }
            if let t = tags.title, !t.isEmpty,
               title == file.deletingPathExtension().lastPathComponent {
                title = t
            }
        }
        if artist.isEmpty {
            // 文件名约定 "歌手 - 歌名",但常见的 "01 - 歌名" / "08 - 歌名" 前半是
            // track number 不是歌手 — 全数字(含 "01"/"03A" 之类纯数字段)拒绝拆分。
            let parts = title.components(separatedBy: " - ")
            if parts.count == 2 {
                let head = parts[0].trimmingCharacters(in: .whitespaces)
                let isAllDigits = !head.isEmpty
                    && head.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
                if !isAllDigits {
                    artist = head
                    title = parts[1].trimmingCharacters(in: .whitespaces)
                } else {
                    // 把 track number 前缀从标题里剥掉,让 UI 干净 — 不会写回 Track number 字段。
                    title = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if artist.isEmpty { artist = "未知歌手" }

        let hash = SHA256.hash(data: Data("\(folderID.uuidString)|\(rel)".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let ext = file.pathExtension.lowercased()
        let lossless = ["flac", "wav", "aif", "aiff", "caf"].contains(ext)
        let track = Track(
            id: "local_\(hash)",
            name: title,
            singer: artist,
            albumName: album,
            source: .local,
            songmid: scheme + folderID.uuidString + "/" + rel,
            duration: duration,
            qualities: [lossless ? .flac : .k320]
        )
        return (track, cover)
    }

    // MARK: - Resolution (playback / lyrics)

    /// "lf://<folderID>/<rel>" → 真实文件 URL。文件夹被移动/删除时返回 nil。
    func fileURL(for track: Track) -> URL? {
        guard track.songmid.hasPrefix(Self.scheme) else { return nil }
        let body = track.songmid.dropFirst(Self.scheme.count)
        guard let slash = body.firstIndex(of: "/"),
              let id = UUID(uuidString: String(body[..<slash])) else { return nil }
        let rel = String(body[body.index(after: slash)...])
        guard let root = resolveRoot(id) else { return nil }
        let url = root.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func resolveRoot(_ id: UUID) -> URL? {
        if let cached = rootCache[id] { return cached }
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folders[idx].bookmark,
                                 options: Self.resolveOptions,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        // 一直持有访问权直到 App 退出 — 中途 stopAccessing 会让正在播的歌断流。
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? Self.makeBookmark(url) {
            folders[idx].bookmark = fresh
            save()
        }
        rootCache[id] = url
        return url
    }

    nonisolated private static func makeBookmark(_ url: URL) throws -> Data {
        #if targetEnvironment(macCatalyst)
        return try url.bookmarkData(options: .withSecurityScope,
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    nonisolated private static var resolveOptions: URL.BookmarkResolutionOptions {
        #if targetEnvironment(macCatalyst)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }
}

// MARK: - 导入弹窗(歌单名 + 文件夹选择 + 进度条)

struct LocalImportSheet: View {
    @EnvironmentObject var playlists: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloads = DownloadStore.shared

    @State private var name = ""
    @State private var folderURL: URL?
    @State private var showPicker = false
    @State private var importing = false
    @State private var progress: Double = 0
    @State private var doneCount: Int?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("歌单名称") {
                    TextField("例如:我的本地收藏", text: $name)
                        .disabled(importing)
                }
                Section("本地文件夹") {
                    Button { showPicker = true } label: {
                        Label(folderURL?.lastPathComponent ?? "选择文件夹",
                              systemImage: "folder.badge.plus")
                    }
                    .disabled(importing)
                    Text("将扫描该文件夹及全部子目录里的音乐文件")
                        .font(.caption).foregroundColor(.secondary)
                }
                if importing {
                    Section {
                        ProgressView(value: progress) {
                            Text(progress == 0 ? "正在扫描文件…" : "读取歌曲信息 \(Int(progress * 100))%")
                                .font(.caption)
                        }
                    }
                }
                if let doneCount {
                    Section {
                        Label("导入完成,共 \(doneCount) 首", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let error {
                    Text(error).foregroundColor(.red).font(.caption)
                }
                Section {
                    Button(importing ? "导入中…" : "确定导入") {
                        Task { await doImport() }
                    }
                    .disabled(importing || doneCount != nil || folderURL == nil
                              || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("本地导入")
            .navigationBarTitleDisplayMode(.inline)
            .sheetNavBarSurface()
            // Mac 上是 popover,点外部即可关闭,不需要取消按钮。
            #if !targetEnvironment(macCatalyst)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(importing)
                }
            }
            #endif
            .interactiveDismissDisabled(importing)
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    folderURL = url
                    if name.trimmingCharacters(in: .whitespaces).isEmpty {
                        name = url.lastPathComponent
                    }
                }
            }
        }
    }

    private func doImport() async {
        guard let folderURL else { return }
        importing = true; error = nil; progress = 0
        do {
            let count = try await LocalMusicStore.shared.importFolder(
                folderURL,
                playlistName: name.trimmingCharacters(in: .whitespaces),
                playlists: playlists,
                downloads: downloads
            ) { p in progress = p }
            importing = false
            doneCount = count
            // 让用户看一眼 "导入完成" 再收起
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        } catch {
            importing = false
            self.error = error.localizedDescription
        }
    }
}
