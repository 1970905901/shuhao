import SwiftUI

// MARK: - Download sheet (pick quality + sub-playlist)

struct DownloadSheet: View {
    let track: Track
    /// 可选 close 回调,见 AddToPlaylistSheet.onClose。默认 nil,toolbar 取消按钮
    /// 走原生 dismiss() 路径。
    var onClose: (() -> Void)? = nil
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var sources: SourceManager
    @Environment(\.dismiss) private var dismiss

    @State private var quality: Quality
    @State private var folderID: UUID
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    init(track: Track, onClose: (() -> Void)? = nil) {
        self.track = track
        self.onClose = onClose
        let qs = track.qualities.isEmpty ? [.k320] : track.qualities
        let best: Quality = Quality.ranked.first { qs.contains($0) } ?? .k128
        _quality = State(initialValue: best)
        _folderID = State(initialValue: DownloadStore.shared.folders.first?.id ?? UUID())
    }

    private func closeNow() {
        onClose?()
        dismiss()
    }

    private var availableQualities: [Quality] {
        let qs = Set(track.qualities.isEmpty ? [.k320] : track.qualities)
        // 扩展档位(hires/atmos/master)搜索元数据基本不报,和播放选档一样
        // 只看脚本声明(pickPlayQuality 的 isExtendedTier 旁路),否则永远选不到。
        let scriptQs = Set(sources.loadedScripts.flatMap {
            $0.capabilities.sources[track.source]?.qualities ?? []
        })
        return Quality.ranked.filter {
            qs.contains($0) || ($0.isExtendedTier && scriptQs.contains($0))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("歌曲") {
                    HStack(spacing: 12) {
                        Artwork(url: downloads.displayCoverURL(for: track), size: 48, radius: DS.Radius.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text(track.singer).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                Section("音质") {
                    Picker("音质", selection: $quality) {
                        ForEach(availableQualities, id: \.self) { q in
                            Text(q.displayName).tag(q)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("下载到子歌单") {
                    Picker("子歌单", selection: $folderID) {
                        ForEach(downloads.folders) { f in
                            Text(f.name).tag(f.id)
                        }
                    }
                    Button {
                        showNewFolder = true
                    } label: {
                        Label("新建子歌单", systemImage: "folder.badge.plus")
                    }
                }
                Section {
                    Button {
                        downloads.download(track: track, quality: quality, folderID: folderID)
                        closeNow()
                    } label: {
                        HStack {
                            Spacer()
                            Label("开始下载", systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(downloads.folders.isEmpty)
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .sheetNavBarSurface()
            // init 里拿不到 EnvironmentObject,脚本声明的扩展档位只能在这里补,
            // 把默认选中项提到包含 atmos/master 后的真实最高档。
            .onAppear {
                if let best = availableQualities.first { quality = best }
            }
            .toolbar {
                // 见 AddToPlaylistSheet —— Mac 走 popover,不显示多余的取消按钮。
                #if !targetEnvironment(macCatalyst)
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { closeNow() }
                }
                #endif
            }
            .toolbarBackground(.thinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .alert("新建子歌单", isPresented: $showNewFolder) {
                TextField("名称", text: $newFolderName)
                Button("取消", role: .cancel) { newFolderName = "" }
                Button("创建") {
                    let n = newFolderName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty {
                        let f = downloads.createFolder(name: n)
                        folderID = f.id
                    }
                    newFolderName = ""
                }
            }
        }
    }
}

// MARK: - 已下载 (sub-playlists)

struct DownloadedView: View {
    @EnvironmentObject var downloads: DownloadStore
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 14)]

    var body: some View {
        ScrollView {
            #if targetEnvironment(macCatalyst)
            MacPageHeader("本地与下载") {
                HStack(spacing: 16) {
                    Button { showNewFolder = true } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("新建子歌单")
                    NavigationLink {
                        DownloadsStatusView()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("下载状态")
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            #endif
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(downloads.folders) { folder in
                    let folderTracks = downloads.tracks(in: folder)
                    NavigationLink {
                        DownloadFolderView(folderID: folder.id)
                    } label: {
                        DownloadFolderCard(folder: folder, coverURLs: folderTracks.prefix(4).map { downloads.displayCoverURL(for: $0) }, count: folderTracks.count)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { downloads.deleteFolder(folder.id) } label: {
                            Label("删除子歌单", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(DS.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if targetEnvironment(macCatalyst)
        // 和资料库等 Mac 详情页保持同一背景 — brandedSurface 的底色和外层容器
        // (IPadRootView 的 contentBackground)不同,顶部安全区会露出一条色带。
        .background(IPad.Color.contentBackground)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .brandedSurface()
        .navigationTitle("已下载")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { DownloadsStatusView() } label: { Image(systemName: "arrow.down.circle") }
            }
        }
        #endif
        .alert("新建子歌单", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                let n = newFolderName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { downloads.createFolder(name: n) }
                newFolderName = ""
            }
        }
    }
}

private struct DownloadFolderCard: View {
    let folder: DownloadFolder
    let coverURLs: [String?]
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverMosaic(urls: coverURLs)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                .elevation(DS.Elevation.e2())
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                Text("\(count) 首")
                    .font(DS.Typo.caption2)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }
}

struct DownloadFolderView: View {
    let folderID: UUID
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var playback: PlaybackEngine

    private var folder: DownloadFolder? { downloads.folders.first { $0.id == folderID } }

    var body: some View {
        let tracks = folder.map { downloads.tracks(in: $0) } ?? []
        List {
            if !tracks.isEmpty, let folder {
                Section {
                    header(folder: folder, tracks: tracks)
                        .padding(.horizontal, DS.Spacing.l)
                        .padding(.vertical, DS.Spacing.m)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, t in
                        let missing = downloads.isMissing(t.id)
                        HStack(alignment: .center, spacing: 4) {
                            Text("\(idx + 1)")
                                .font(DS.Typo.numeric)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .frame(width: 28)
                            TrackRow(track: t)
                            if missing {
                                // 用户在 Finder 把源文件删了 —— 替代原来的「质量」徽章,
                                // 红色 + 文案点明状态,左滑里给一键重下入口。
                                Label("文件缺失", systemImage: "exclamationmark.triangle.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(DS.Typo.caption2)
                                    .foregroundStyle(.red)
                            } else if let q = downloads.quality(for: t.id) {
                                Text(q.displayName)
                                    .font(DS.Typo.caption2)
                                    .foregroundStyle(DS.Palette.textTertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { playback.play(track: t, in: tracks, startIndex: idx) }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing) {
                            if missing {
                                // retry 内部读 record 自带的 folderID,这里不需要再传 folder。
                                Button {
                                    downloads.retry(trackID: t.id)
                                } label: {
                                    Label("重新下载", systemImage: "arrow.clockwise.icloud")
                                }
                                .tint(.indigo)
                            }
                            Button(role: .destructive) { downloads.removeDownload(trackID: t.id) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            if missing {
                                Button {
                                    downloads.retry(trackID: t.id)
                                } label: {
                                    Label("重新下载", systemImage: "arrow.clockwise.icloud")
                                }
                            }
                            Button(role: .destructive) { downloads.removeDownload(trackID: t.id) } label: {
                                Label("删除下载", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("曲目")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandedSurface()
        .navigationTitle(folder?.name ?? "子歌单")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if tracks.isEmpty {
                BrandedEmpty(icon: "arrow.down.circle",
                             title: "还没有下载",
                             subtitle: "在播放器或歌曲菜单里下载到这个子歌单",
                             topPadding: 80)
            }
        }
    }

    @ViewBuilder
    private func header(folder: DownloadFolder, tracks: [Track]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CoverMosaic(urls: tracks.prefix(4).map { downloads.displayCoverURL(for: $0) })
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                .elevation(DS.Elevation.e2())
            VStack(alignment: .leading, spacing: 6) {
                Text(folder.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2)
                Text("\(tracks.count) 首 · 已下载")
                    .font(DS.Typo.numeric)
                    .foregroundStyle(DS.Palette.textTertiary)
                Button {
                    playback.play(track: tracks[0], in: tracks, startIndex: 0)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                        Text("播放全部")
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Download status

struct DownloadsStatusView: View {
    @EnvironmentObject var downloads: DownloadStore

    private var active: [DownloadRecord] { records(.downloading) }
    private var failed: [DownloadRecord] { records(.failed) }
    private var missing: [DownloadRecord] { records(.missing) }
    private var completed: [DownloadRecord] { records(.completed) }

    private func records(_ status: DownloadStatus) -> [DownloadRecord] {
        downloads.records.values.filter { $0.status == status }.sorted { $0.track.name < $1.track.name }
    }

    var body: some View {
        List {
            if !active.isEmpty {
                Section {
                    ForEach(active, id: \.track.id) { rec in
                        statusRow(rec, trailing: AnyView(
                            ProgressView(value: downloads.progress[rec.track.id] ?? 0)
                                .tint(DS.Palette.brandStart)
                                .frame(width: 60)
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                } header: { sectionHeader("下载中", count: active.count) }
            }
            if !failed.isEmpty {
                Section {
                    ForEach(failed, id: \.track.id) { rec in
                        statusRow(rec, trailing: AnyView(
                            Button { downloads.retry(trackID: rec.track.id) } label: {
                                Image(systemName: "arrow.clockwise.circle")
                                    .foregroundStyle(DS.Palette.brandStart)
                            }.buttonStyle(.borderless)
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { downloads.removeDownload(trackID: rec.track.id) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { downloads.removeDownload(trackID: rec.track.id) } label: {
                                Label("删除记录", systemImage: "trash")
                            }
                        }
                    }
                } header: { sectionHeader("失败", count: failed.count) }
            }
            if !missing.isEmpty {
                Section {
                    ForEach(missing, id: \.track.id) { rec in
                        statusRow(rec, trailing: AnyView(
                            Button { downloads.retry(trackID: rec.track.id) } label: {
                                Image(systemName: "arrow.clockwise.icloud")
                                    .foregroundStyle(DS.Palette.brandStart)
                            }.buttonStyle(.borderless)
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing) {
                            Button { downloads.retry(trackID: rec.track.id) } label: {
                                Label("重新下载", systemImage: "arrow.clockwise.icloud")
                            }
                            .tint(.indigo)
                            Button(role: .destructive) { downloads.removeDownload(trackID: rec.track.id) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button { downloads.retry(trackID: rec.track.id) } label: {
                                Label("重新下载", systemImage: "arrow.clockwise.icloud")
                            }
                            Button(role: .destructive) { downloads.removeDownload(trackID: rec.track.id) } label: {
                                Label("删除记录", systemImage: "trash")
                            }
                        }
                    }
                } header: { sectionHeader("文件缺失", count: missing.count) }
            }
            if !completed.isEmpty {
                Section {
                    ForEach(completed, id: \.track.id) { rec in
                        statusRow(rec, trailing: AnyView(
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { downloads.removeDownload(trackID: rec.track.id) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { downloads.removeDownload(trackID: rec.track.id) } label: {
                                Label("删除下载", systemImage: "trash")
                            }
                        }
                    }
                } header: { sectionHeader("已完成", count: completed.count) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandedSurface()
        .navigationTitle("下载状态")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if downloads.records.isEmpty {
                BrandedEmpty(icon: "arrow.down.circle", title: "暂无下载", topPadding: 80)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textTertiary)
            Spacer()
            Text("\(count)")
                .font(DS.Typo.numeric)
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .textCase(nil)
    }

    private func statusRow(_ rec: DownloadRecord, trailing: AnyView) -> some View {
        HStack(spacing: 12) {
            Artwork(url: downloads.displayCoverURL(for: rec.track), size: 40, radius: DS.Radius.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.track.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(rec.track.singer)
                        .font(DS.Typo.caption2)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                    Text(rec.quality.displayName)
                        .font(DS.Typo.caption2)
                        .foregroundStyle(DS.Palette.textTertiary)
                    if let e = rec.errorMessage {
                        Text(e)
                            .font(DS.Typo.caption2)
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

// MARK: - Batch download sheet (整张歌单一次下完)
//
// 用户在 PlaylistDetailView header 点「全部下载」打开。逻辑跟单曲 DownloadSheet
// 同构:选音质、选子歌单。区别是音质是「意图档」——每首歌走自己的 qualities,
// 取 ≤ 意图档的最高(都没就取该歌支持的最高一档),不强求每首都下到同一档。
// 已完成的歌跳过,正在下载的也跳过;.failed / .missing / 无记录都算「待下载」。

struct BatchDownloadSheet: View {
    let tracks: [Track]
    var onClose: (() -> Void)? = nil
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var sources: SourceManager
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var quality: Quality = .flac
    @State private var folderID: UUID
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    init(tracks: [Track], onClose: (() -> Void)? = nil) {
        self.tracks = tracks
        self.onClose = onClose
        _folderID = State(initialValue: DownloadStore.shared.folders.first?.id ?? UUID())
    }

    /// 一次性算好的统计 —— 避免 body 里反复调函数。
    private struct Stats {
        var alreadyDone = 0           // .completed 且已经 ≥ 目标档(跳过)
        var willUpgrade: [Track] = [] // .completed 但档位低于目标档(开启升级时纳入 pending)
        var inFlight = 0              // .downloading(防重入,跳过)
        var pending: [Track] = []     // 无记录 / .failed / .missing → 一定下
    }
    private var stats: Stats {
        var s = Stats()
        for t in tracks {
            switch downloads.records[t.id]?.status {
            case .completed:
                // 已下载档位 vs 这次意图档算出来的目标档:目标更高 → 可升级。
                let currentQ = downloads.records[t.id]?.quality ?? .k128
                let targetQ = pickPerTrackQuality(for: t)
                if rank(targetQ) > rank(currentQ) {
                    s.willUpgrade.append(t)
                } else {
                    s.alreadyDone += 1
                }
            case .downloading:
                s.inFlight += 1
            default:
                s.pending.append(t)
            }
        }
        return s
    }
    /// 实际要发起下载的歌:pending 永远算,willUpgrade 看用户设置。
    private var tracksToEnqueue: [Track] {
        settings.batchUpgradeQuality ? (stats.pending + stats.willUpgrade) : stats.pending
    }

    /// 意图档候选 —— 取这堆歌里有任何一首支持的最高档,加上脚本声明的扩展档位。
    /// 用户选一档,具体每首走 `pickPerTrackQuality` 再 normalize。
    private var availableQualities: [Quality] {
        var union = Set<Quality>()
        for t in tracks { union.formUnion(t.qualities) }
        if union.isEmpty { union = [.k320] }
        let scriptQs = Set(sources.loadedScripts.flatMap {
            $0.capabilities.sources.values.flatMap { $0.qualities }
        })
        return Quality.ranked.filter { union.contains($0) || ($0.isExtendedTier && !scriptQs.isEmpty) }
    }

    /// 对单首歌:取她 qualities 里 ≤ 意图档的最高;都不满足(罕见,意味着这首歌最低
    /// 一档都比意图档高)取她最高的一档兜底,反正用户既然点了批量就想全下完。
    private func pickPerTrackQuality(for track: Track) -> Quality {
        let qs = track.qualities.isEmpty ? [.k320] : track.qualities
        // Quality.ranked 从高到低,第一个「该歌支持 且 不高于意图档」的就是要的。
        if let pick = Quality.ranked.first(where: { qs.contains($0) && rank($0) <= rank(quality) }) {
            return pick
        }
        return Quality.ranked.first { qs.contains($0) } ?? .k320
    }
    private func rank(_ q: Quality) -> Int {
        // 反向 index —— 越靠后(质量越低)分越高,方便 ≤ 意图档的比较。
        Quality.ranked.firstIndex(of: q).map { Quality.ranked.count - $0 } ?? 0
    }

    private func closeNow() {
        onClose?()
        dismiss()
    }

    private var canStart: Bool {
        !tracksToEnqueue.isEmpty && !downloads.folders.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("歌单") {
                    HStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 20))
                            .foregroundStyle(DS.Palette.brandStart)
                            .frame(width: 40, height: 40)
                            .background(Color(.tertiarySystemFill),
                                        in: RoundedRectangle(cornerRadius: DS.Radius.small))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("共 \(tracks.count) 首")
                                .font(.system(size: 15, weight: .semibold))
                            Text(summaryLine)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Section("音质(意图档)") {
                    Picker("音质", selection: $quality) {
                        ForEach(availableQualities, id: \.self) { q in
                            Text(q.displayName).tag(q)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text("每首歌按自己支持的最高档下载,不超过这里选的。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Section("下载到子歌单") {
                    Picker("子歌单", selection: $folderID) {
                        ForEach(downloads.folders) { f in
                            Text(f.name).tag(f.id)
                        }
                    }
                    Button {
                        showNewFolder = true
                    } label: {
                        Label("新建子歌单", systemImage: "folder.badge.plus")
                    }
                }
                Section {
                    Button {
                        startBatch()
                        closeNow()
                    } label: {
                        HStack {
                            Spacer()
                            Label(startButtonTitle, systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(!canStart)
                }
            }
            .navigationTitle("全部下载")
            .navigationBarTitleDisplayMode(.inline)
            .sheetNavBarSurface()
            .onAppear {
                if let best = availableQualities.first { quality = best }
            }
            .toolbar {
                #if !targetEnvironment(macCatalyst)
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { closeNow() }
                }
                #endif
            }
            .toolbarBackground(.thinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .alert("新建子歌单", isPresented: $showNewFolder) {
                TextField("名称", text: $newFolderName)
                Button("取消", role: .cancel) { newFolderName = "" }
                Button("创建") {
                    let n = newFolderName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty {
                        let f = downloads.createFolder(name: n)
                        folderID = f.id
                    }
                    newFolderName = ""
                }
            }
        }
    }

    private var summaryLine: String {
        let s = stats
        var parts: [String] = []
        if s.alreadyDone > 0 { parts.append("已下载 \(s.alreadyDone) 首") }
        if s.inFlight > 0 { parts.append("下载中 \(s.inFlight) 首") }
        if settings.batchUpgradeQuality && !s.willUpgrade.isEmpty {
            parts.append("可升级 \(s.willUpgrade.count) 首")
        }
        parts.append("待下载 \(s.pending.count) 首")
        return parts.joined(separator: " · ")
    }

    private var startButtonTitle: String {
        let n = tracksToEnqueue.count
        if n == 0 { return "无歌曲可下载" }
        return "开始下载 \(n) 首"
    }

    private func startBatch() {
        let queue = tracksToEnqueue
        guard !queue.isEmpty else { return }
        // 串行 enqueue;实际的并发上限由 DownloadStore.maxConcurrent 控,
        // 这里只管把任务全部投进去。
        for t in queue {
            downloads.download(track: t, quality: pickPerTrackQuality(for: t), folderID: folderID)
        }
    }
}
