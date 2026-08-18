import SwiftUI
import Combine

// MARK: - Search (iPad)
//
// QQ 音乐 iPad 的搜索是占据整个 detail-pane 中央的大输入框 + 多 tab 结果。
// 顶部一个 hero 区域(带热词),提交后切换为多 tab 结果列表(单曲/歌单/MV/专辑/歌手)。
// 我们当前后端只支持单曲搜索 + 歌单搜索,先做单曲;tab 框架预留。

/// 搜索页状态 —— 由 IPadRootView 持有并通过 environmentObject 注入。
/// IPadRootView 的 switch 每次切页都会重建 IPadSearchView,挂在 view 上的 @State 全丢;
/// 关键词 / 结果 / 滚动栈提到这里,切走再切回来原样恢复(Mac / iPad 同收益)。
@MainActor
final class IPadSearchSession: ObservableObject {
    @Published var keyword: String = ""
    @Published var submitted: String = ""
    @Published var selectedScope: SearchScope = .all
    @Published var resultsByScope: [SearchScope: [Track]] = [:]
    @Published var loadingScopes: Set<SearchScope> = []
    @Published var playlistResults: [SonglistInfo] = []
    @Published var loadingPlaylists = false
    @Published var navPath = NavigationPath()
}

struct IPadSearchView: View {
    @EnvironmentObject var playback: PlaybackEngine
    /// 显式引用 playlists / downloads,这样在挂 .sheet 时可以手动 .environmentObject(...)
    /// 透传给 sheet 内容。SwiftUI 的 sheet 默认会继承 env,但 Mac Catalyst 上挂在
    /// LazyVStack 的 NavigationStack 外层的 .sheet 不可靠 —— 实测会冒 "No ObservableObject
    /// of type DownloadStore found",显式透传可消除歧义。
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var downloads: DownloadStore
    @AppStorage("search.history") private var historyJSON: String = "[]"
    /// 跟 iPhone 不同 — iPad 搜索结果上方还有一个"歌单"区,聚合所有源的同名歌单
    /// (跟 shuhao-tv 搜索页一致)。状态全在 session 里,切页不丢。
    @EnvironmentObject private var session: IPadSearchSession
    @FocusState private var focused: Bool

    /// 收藏 / 下载弹窗的 state 提到这一层(不挂在 row 上),原因见 IPadTrackRow 的注释 —
    /// LazyVStack 的子 view 会被回收,挂在 row 上的 .sheet 在 Mac Catalyst 上会丢失
    /// dismiss 的目标 view,导致取消按钮无效。这里跟 PlayerView/IPadPlayerView 的模式
    /// 完全对齐:`.sheet(item:)` 配合一个稳定的 parent。
    @State private var trackToFavorite: Track?
    @State private var trackToDownload: Track?
    @State private var showRecognize = false

    private let tabs: [SearchScope] = [
        .all, .source(.kw), .source(.wy), .source(.kg), .source(.tx),
    ]

    var body: some View {
        VStack(spacing: 0) {
            heroOrField
                .padding(.horizontal, 32)
                .padding(.top, session.submitted.isEmpty ? 60 : 16)
                .padding(.bottom, 8)
                .ipadContentWidth()

            if !session.submitted.isEmpty {
                scopeTabs
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .ipadContentWidth()
                resultsList
            } else {
                emptyHero
            }
        }
        .background(IPad.Color.contentBackground)
        // Sheets owned by the search view (NOT by the row) — see IPadTrackRow's note.
        // `.sheet(item:)` + `.inheritedAppearance()` is the same pattern used in
        // PlayerView/IPadPlayerView, which works on Mac Catalyst.
        // Mac Catalyst → .popover, iPad → .sheet ——
        // 直接抄 IPadRootView 设置弹窗(`showSettings`)那套已经在用的模式。
        // popover 在 Mac 上是浮动面板,自带"点外面关闭 / Esc 关闭",
        // toolbar 取消按钮也能正常响应,不会被 sheet 的 UIKit hosting 桥吞点击。
        // env objects 显式透传,免得受 Mac 隐式继承不稳定的影响。
        #if targetEnvironment(macCatalyst)
        .popover(item: $trackToFavorite) { t in
            AddToPlaylistSheet(track: t)
                .environmentObject(playlists)
                .frame(width: 480, height: 560)
        }
        .popover(item: $trackToDownload) { t in
            DownloadSheet(track: t)
                .environmentObject(downloads)
                .frame(width: 480, height: 600)
        }
        #else
        .sheet(item: $trackToFavorite) { t in
            AddToPlaylistSheet(track: t)
                .environmentObject(playlists)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $trackToDownload) { t in
            DownloadSheet(track: t)
                .environmentObject(downloads)
                .presentationDragIndicator(.visible)
        }
        #endif
        // 听歌识曲 —— Mac 用 popover、iPad 用 sheet,同上面收藏/下载弹窗的模式。
        #if targetEnvironment(macCatalyst)
        .popover(isPresented: $showRecognize) {
            RecognizeView { term in
                session.keyword = term
                submit()
            }
            .environmentObject(playback)
            .frame(width: 440, height: 560)
        }
        #else
        .sheet(isPresented: $showRecognize) {
            RecognizeView { term in
                session.keyword = term
                submit()
            }
            .environmentObject(playback)
        }
        #endif
    }

    // MARK: Bar / Hero

    /// When not yet searched: render a large centered hero header above the
    /// search field (QQ 音乐 PC 端的"打开搜索"体验)。
    /// Once session.submitted: shrink to a compact toolbar-style field at the top.
    @ViewBuilder
    private var heroOrField: some View {
        if session.submitted.isEmpty {
            VStack(spacing: 14) {
                Text("发现你喜欢的音乐")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("在 4 个音源中搜索 · 自定义脚本提供高品质播放地址")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .padding(.bottom, 6)
                searchField
                    .frame(maxWidth: 560)
                if !history.isEmpty {
                    historyRow
                        .frame(maxWidth: 720)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            searchField
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.Palette.textTertiary)
            TextField("歌曲、歌手、专辑", text: $session.keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { submit() }
            if !session.keyword.isEmpty {
                Button {
                    session.keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
            Button {
                showRecognize = true
            } label: {
                Image(systemName: "shazam.logo.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(DS.Palette.brandGradient)
            }
            .buttonStyle(.plain)
            .help("听歌识曲")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(focused ? DS.Palette.brandStart.opacity(0.6) : DS.Palette.strokeSubtle,
                        lineWidth: focused ? 1.5 : 0.5)
        )
    }

    @ViewBuilder
    private var historyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近搜索").font(.system(size: 12)).foregroundStyle(DS.Palette.textTertiary)
                Spacer()
                Button("清除") { historyJSON = "[]" }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            HStack(spacing: 8) {
                ForEach(history.prefix(8), id: \.self) { tag in
                    Button { session.keyword = tag; submit() } label: {
                        Text(tag)
                            .font(.system(size: 13))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(DS.Palette.strokeSubtle.opacity(0.4)))
                            .foregroundStyle(DS.Palette.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 12)
    }

    private var scopeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tabs) { scope in
                    let isActive = session.selectedScope == scope
                    Button { session.selectedScope = scope } label: {
                        HStack(spacing: 6) {
                            Circle().fill(scope.tint).frame(width: 6, height: 6)
                            Text(scope.displayName)
                                .font(.system(size: 13, weight: .semibold))
                            if let n = session.resultsByScope[scope]?.count, n > 0 {
                                Text("\(n)").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(isActive ? .white.opacity(0.85) : DS.Palette.textTertiary)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundStyle(isActive ? .white : DS.Palette.textPrimary)
                        .background(Capsule().fill(isActive ? scope.tint : DS.Palette.strokeSubtle.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var resultsList: some View {
        let results = session.resultsByScope[session.selectedScope] ?? []
        return NavigationStack(path: $session.navPath) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    // 歌单结果 carousel — 在歌曲列表之上,跟 shuhao-tv 搜索
                    // 页的"歌单 (N)" + "歌曲 (N)" 双 section 一致
                    if !session.playlistResults.isEmpty {
                        playlistsSection
                            .padding(.bottom, 18)
                    }
                    // 歌曲列表 section
                    if !results.isEmpty {
                        HStack {
                            Text("歌曲")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DS.Palette.textPrimary)
                            Text("\(results.count)")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Palette.textTertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { idx, t in
                        IPadTrackRow(
                            index: idx + 1,
                            track: t,
                            isPlaying: playback.currentTrack?.id == t.id,
                            onTap: {
                                playback.play(track: t, in: results, startIndex: idx)
                                pushHistory(session.submitted)
                            },
                            onAddToPlaylist: { trackToFavorite = $0 },
                            onDownload: { trackToDownload = $0 }
                        )
                    }
                    if session.loadingScopes.contains(session.selectedScope) && results.isEmpty
                        && session.playlistResults.isEmpty {
                        LoadingPlaceholder(topPadding: 60)
                    } else if results.isEmpty && session.playlistResults.isEmpty {
                        BrandedEmpty(icon: "magnifyingglass",
                                     title: "没有结果",
                                     subtitle: "试试别的关键词,或切换音源")
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 120)
                .ipadContentWidth()
            }
            .navigationDestination(for: SonglistInfo.self) { info in
                SonglistDetailView(info: info)
            }
        }
    }

    /// "歌单 (N)" 横向 carousel — 用现有的 IPadAlbumCard,点击进入 SonglistDetailView。
    /// 跨 source 聚合,展示前 8 个匹配的歌单。
    @ViewBuilder
    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("歌单")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("\(session.playlistResults.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Palette.textTertiary)
                Spacer()
                if session.loadingPlaylists {
                    UIKitSpinner(style: .medium).scaleEffect(0.6).frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(session.playlistResults.prefix(8)) { p in
                        NavigationLink(value: p) {
                            IPadAlbumCard(
                                imageURL: p.picURL,
                                title: p.name,
                                subtitle: p.playCount ?? p.author,
                                fallbackTint: p.source.tint,
                                size: 140
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var emptyHero: some View {
        Spacer()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Logic

    private func submit() {
        let kw = session.keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        session.submitted = kw
        focused = false
        Task { await runSearch(kw) }
    }

    @MainActor
    private func runSearch(_ keyword: String) async {
        session.resultsByScope = [:]
        session.playlistResults = []
        session.loadingPlaylists = true
        // Songs across all sources(并行)
        async let songsTask: Void = withTaskGroup(of: Void.self) { group in
            for scope in tabs where scope != .all {
                guard case let .source(src) = scope else { continue }
                group.addTask {
                    await searchOne(src, keyword: keyword)
                }
            }
        }
        // Playlists across all sources(并行)— Songlists.service 给 .search 实现
        async let playlistsTask: [SonglistInfo] = searchPlaylistsAcrossSources(keyword: keyword)
        _ = await songsTask
        let plists = await playlistsTask
        session.playlistResults = plists
        session.loadingPlaylists = false

        // Build merged "全部" result for songs
        var all: [Track] = []
        for scope in tabs where scope != .all {
            if let r = session.resultsByScope[scope] { all.append(contentsOf: r) }
        }
        session.resultsByScope[.all] = all
    }

    /// 并行扫每个 Songlists.service 的 search 实现,interleave 结果。
    /// 某些源不实现 search(默认 no-op 返回 []),没 result 的就跳过。
    private func searchPlaylistsAcrossSources(keyword: String) async -> [SonglistInfo] {
        let srcs: [SourceID] = [.kw, .wy, .kg, .tx]
        let groups = await withTaskGroup(of: (SourceID, [SonglistInfo]).self) { group -> [SourceID: [SonglistInfo]] in
            for s in srcs {
                group.addTask {
                    guard let svc = Songlists.service(for: s) else { return (s, []) }
                    do {
                        return (s, try await svc.search(keyword: keyword, page: 1))
                    } catch {
                        return (s, [])
                    }
                }
            }
            var dict: [SourceID: [SonglistInfo]] = [:]
            for await (s, lists) in group { dict[s] = lists }
            return dict
        }
        var merged: [SonglistInfo] = []
        let maxPer = srcs.map { (groups[$0]?.count ?? 0) }.max() ?? 0
        for i in 0..<maxPer {
            for s in srcs {
                if let g = groups[s], i < g.count {
                    merged.append(g[i])
                }
            }
        }
        return merged
    }

    @MainActor
    private func searchOne(_ src: SourceID, keyword: String) async {
        let scope = SearchScope.source(src)
        session.loadingScopes.insert(scope)
        defer { session.loadingScopes.remove(scope) }
        guard let catalog = Catalogs.service(for: src) else { return }
        do {
            let tracks = try await catalog.search(keyword: keyword, page: 1)
            session.resultsByScope[scope] = tracks
        } catch {
            session.resultsByScope[scope] = []
        }
    }

    private var history: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(historyJSON.utf8))) ?? []
    }

    private func pushHistory(_ kw: String) {
        var arr = history
        arr.removeAll { $0 == kw }
        arr.insert(kw, at: 0)
        if arr.count > 12 { arr = Array(arr.prefix(12)) }
        if let data = try? JSONEncoder().encode(arr), let s = String(data: data, encoding: .utf8) {
            historyJSON = s
        }
    }
}
