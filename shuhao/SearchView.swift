import SwiftUI
import UIKit  // UIPasteboard for the contextMenu "copy" action

enum SearchScope: Hashable, Identifiable {
    case all
    case source(SourceID)
    var id: String {
        switch self {
        case .all: return "all"
        case .source(let s): return s.rawValue
        }
    }
    var displayName: String {
        switch self {
        case .all: return "全部"
        case .source(let s): return s.displayName
        }
    }
    var tint: Color {
        switch self {
        case .all: return Color.accentColor
        case .source(let s): return s.tint
        }
    }
}

struct SearchView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var playlists: PlaylistStore
    @AppStorage("search.history") private var historyJSON: String = "[]"
    @State private var keyword: String = ""
    @State private var selectedScope: SearchScope = .all
    @State private var resultsByScope: [SearchScope: [Track]] = [:]
    @State private var loadingScopes: Set<SearchScope> = []
    @State private var error: String?
    @State private var showRecognize = false
    @FocusState private var searchFocused: Bool

    private let tabs: [SearchScope] = [
        .all,
        .source(.kw), .source(.wy), .source(.kg), .source(.tx),
    ]

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, DS.Spacing.l)
                .padding(.top, DS.Spacing.s)

            if !keyword.isEmpty {
                scopeTabs
                    .padding(.top, 8)
            }

            Group {
                if keyword.isEmpty {
                    emptyState
                } else if loadingScopes.contains(selectedScope) && (resultsByScope[selectedScope]?.isEmpty ?? true) {
                    LoadingPlaceholder()
                } else if let error, (resultsByScope[selectedScope] ?? []).isEmpty {
                    Text(error).foregroundColor(.red).padding()
                } else {
                    let results = resultsByScope[selectedScope] ?? []
                    if results.isEmpty {
                        BrandedEmpty(icon: "music.note.list",
                                     title: "没有找到歌曲",
                                     subtitle: "换个关键字或切换音源试试")
                    } else {
                        resultsList(results)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .brandedSurface()
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showRecognize) {
            RecognizeView { term in
                keyword = term
                searchAll()
            }
        }
    }

    // MARK: - Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("歌曲、歌手、专辑", text: $keyword)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { searchAll() }
                Spacer(minLength: 0)
                if !keyword.isEmpty {
                    Button {
                        keyword = ""; resultsByScope = [:]; error = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                showRecognize = true
            } label: {
                Image(systemName: "shazam.logo.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(DS.Palette.brandGradient)
            }
            .accessibilityLabel("听歌识曲")

            if searchFocused || !keyword.isEmpty {
                Button("取消") {
                    keyword = ""; resultsByScope = [:]; error = nil; searchFocused = false
                }
                .foregroundColor(.accentColor)
            }
        }
    }

    private var scopeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs) { scope in
                    let isActive = selectedScope == scope
                    let isLoading = loadingScopes.contains(scope)
                    Button {
                        selectedScope = scope
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(scope.tint).frame(width: 6, height: 6)
                            Text(scope.displayName)
                                .font(.system(size: 13, weight: .semibold))
                            if isLoading {
                                UIKitSpinner(style: .medium).scaleEffect(0.6).frame(width: 12, height: 12)
                            } else if let count = resultsByScope[scope]?.count, count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(isActive ? .white.opacity(0.85) : .secondary)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundColor(isActive ? .white : .primary)
                        .background(
                            Capsule().fill(isActive ? scope.tint : Color(.secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Spacing.l)
        }
        // 同 ChipBar:抵消 RootTabView 广播下来的底部留白,否则这条横向 scope 条
        // 下面会多出一大片空白(那份留白是给迷你播放器让位用的,只该作用于纵向列表)。
        .bottomContentMargin(0)
    }

    private func resultsList(_ results: [Track]) -> some View {
        List(results) { track in
            TrackRow(track: track)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: DS.Spacing.l, bottom: 6, trailing: DS.Spacing.l))
                .contentShape(Rectangle())
                .onTapGesture {
                    playback.play(track: track, in: results, startIndex: results.firstIndex { $0.id == track.id })
                    pushHistory(keyword)
                }
                .trackRowSwipe(track)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Empty / history

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                if !history.isEmpty {
                    HStack {
                        Text("最近搜索").font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
                        Spacer()
                        Button("清除") { historyJSON = "[]" }
                            .font(.caption)
                    }
                    FlowChips(items: history) { tag in
                        keyword = tag; searchAll(); searchFocused = false
                    }
                }
                BrandedEmpty(icon: "music.mic",
                             title: "发现你喜欢的音乐",
                             subtitle: "可在多个音源中搜索,自定义脚本提供高品质播放地址",
                             topPadding: history.isEmpty ? 80 : 24)
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.top, DS.Spacing.l)
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

    // MARK: - Search

    /// Fan out one query to every source in parallel and refresh the "全部" tab as soon as we have
    /// any per-source results.
    private func searchAll() {
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        pushHistory(term)
        error = nil
        // Mark every tab as loading; we'll clear each as its source finishes.
        for scope in tabs { loadingScopes.insert(scope) }
        // Per-source storage that we'll re-aggregate into the "全部" tab on each completion.
        var perSource: [SourceID: [Track]] = [:]

        // Only loop over sources we actually expose in Catalogs.all (skips local + mg).
        for svc in Catalogs.all {
            let src = svc.source
            Task { [svc] in
                do {
                    let result = try await svc.search(keyword: term, page: 1)
                    await MainActor.run {
                        self.resultsByScope[.source(src)] = result
                        self.loadingScopes.remove(.source(src))
                        perSource[src] = result
                        self.resultsByScope[.all] = SearchView.interleave(perSource)
                        if self.loadingScopes.allSatisfy({ if case .source = $0 { return false } else { return true } }) {
                            self.loadingScopes.remove(.all)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.resultsByScope[.source(src)] = []
                        self.loadingScopes.remove(.source(src))
                        if self.selectedScope == .source(src) {
                            self.error = "搜索 \(src.displayName) 失败: \(error.localizedDescription)"
                        }
                        if self.loadingScopes.allSatisfy({ if case .source = $0 { return false } else { return true } }) {
                            self.loadingScopes.remove(.all)
                        }
                    }
                }
            }
        }
    }

    /// Round-robin interleave across sources so the aggregated view shows a mix from
    /// every platform that returned something (same approach lx-music's "all" tab uses).
    private static func interleave(_ groups: [SourceID: [Track]]) -> [Track] {
        let order: [SourceID] = [.kw, .wy, .kg, .tx]
        var iterators: [SourceID: IndexingIterator<[Track]>] = [:]
        for s in order { iterators[s] = groups[s]?.makeIterator() }
        var out: [Track] = []
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            for s in order {
                if var it = iterators[s], let next = it.next() {
                    out.append(next)
                    iterators[s] = it
                    keepGoing = true
                }
            }
        }
        return out
    }
}

// MARK: - Track Row (cleaner)

struct TrackRow: View {
    let track: Track
    @ObservedObject private var downloads = DownloadStore.shared
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: downloads.displayCoverURL(for: track), size: 48, radius: DS.Radius.small)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(track.name).font(DS.Typography.trackTitle).lineLimit(1)
                    // Quality tag mirrors lx-music: only show for >= 320k tracks.
                    if let style = QualityBadgeStyle(highestIn: track.qualities) {
                        QualityBadge(style: style)
                    }
                    // MV indicator — set by SearchCatalog/Boards/Songlist build()
                    // when the per-source MV id is present. Visual: brand-tinted
                    // outlined pill, parallels QualityBadge so the eye reads
                    // them as the same kind of metadata chip.
                    if track.extras["mvId"]?.isEmpty == false {
                        Text("MV")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(DS.Palette.brandStart)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(DS.Palette.brandStart, lineWidth: 1)
                            )
                    }
                    if downloads.isDownloaded(track.id) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }
                }
                HStack(spacing: 6) {
                    SourceChip(source: track.source)
                    Text(track.subtitle)
                        .font(DS.Typography.trackSubtitle)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let d = track.duration {
                Text(formatDuration(d))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Flow chips

struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        FlexLayout(spacing: 8, runSpacing: 8) {
            ForEach(items, id: \.self) { it in
                Button {
                    onTap(it)
                } label: {
                    Text(it)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color(.secondarySystemBackground)))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// Lightweight wrapping flow layout
struct FlexLayout: Layout {
    var spacing: CGFloat
    var runSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, usedWidth: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                x = 0; y += lineH + runSpacing; lineH = 0
            }
            x += s.width + spacing
            usedWidth = max(usedWidth, x - spacing)
            lineH = max(lineH, s.height)
        }
        // 理想尺寸测量(proposal.width == nil/∞)时不能把 ∞ 报回去 —
        // SwiftUI 会直接 fatal "malformed dimension",返回实际内容宽度。
        return CGSize(width: maxWidth.isFinite ? maxWidth : usedWidth,
                      height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineH: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineH + runSpacing; lineH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

// MARK: - Add-to-playlist sheet (kept clean)

struct AddToPlaylistSheet: View {
    let track: Track
    /// 可选 close 回调,留给 .sheet(isPresented:) / .sheet(item:) 调用方在需要的时候
    /// 显式把 binding 置 nil(主要场景:Mac Catalyst 上 dismiss 偶发失灵时的兜底)。
    /// 默认 nil,所有原有调用点(toolbar 取消按钮直接 dismiss())继续走 SwiftUI 原生路径。
    var onClose: (() -> Void)? = nil
    @EnvironmentObject var playlists: PlaylistStore
    @Environment(\.dismiss) var dismiss

    @State private var newName: String = ""

    private func closeNow() {
        onClose?()
        dismiss()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("新建歌单", text: $newName)
                        Button("创建") {
                            let trimmed = newName.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            let p = playlists.createPlaylist(name: trimmed)
                            playlists.addTracks([track], to: p.id)
                            closeNow()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("我的歌单") {
                    ForEach(playlists.playlists) { p in
                        Button {
                            playlists.addTracks([track], to: p.id)
                            closeNow()
                        } label: {
                            HStack {
                                Image(systemName: "music.note.list").foregroundColor(.accentColor)
                                Text(p.name).foregroundColor(.primary)
                                Spacer()
                                Text("\(p.trackIDs.count)").foregroundColor(.secondary).font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("收藏到歌单")
            .navigationBarTitleDisplayMode(.inline)
            .sheetNavBarSurface()
            .toolbar {
                // Mac Catalyst 上这个 sheet 走 .popover —— 点外面 / Esc 都能关,
                // 顶栏的"取消"按钮反而是多余的(还可能误导用户)。只在 iOS 显示。
                #if !targetEnvironment(macCatalyst)
                ToolbarItem(placement: .cancellationAction) { Button("取消") { closeNow() } }
                #endif
            }
            .toolbarBackground(.thinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

// MARK: - Track row swipe actions (shared)

/// Trailing swipe with 收藏 + 下载 (and an optional 移除). Bundles the two sheets so every
/// track list — search, 排行榜, 歌单, 我的歌单 — gets identical behavior with one modifier.
struct TrackRowSwipe: ViewModifier {
    let track: Track
    var onRemove: (() -> Void)? = nil
    /// 弹窗提升出口:传了这两个回调,行内不再自己弹 sheet,改由调用方在稳定的
    /// 根 view 上呈现(Mac Catalyst 行级 sheet 在 List 行回收后 dismiss 会失灵,
    /// 跟 IPadSearchView 修过的问题同源)。不传则保持原有行内 sheet(iPhone 搜索页)。
    var onAddToPlaylist: ((Track) -> Void)? = nil
    var onDownload: ((Track) -> Void)? = nil
    @State private var showAdd = false
    @State private var showDownload = false

    private func requestAdd() {
        if let onAddToPlaylist { onAddToPlaylist(track) } else { showAdd = true }
    }
    private func requestDownload() {
        if let onDownload { onDownload(track) } else { showDownload = true }
    }

    /// Plain "歌名 - 歌手" string used for both copy + share. Kept short so it works as a
    /// chat snippet without overflowing one line.
    private var shareText: String {
        var s = track.name
        if !track.singer.isEmpty { s += " - \(track.singer)" }
        return s
    }

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { requestAdd() } label: { Label("收藏", systemImage: "plus.circle") }
                    .tint(.accentColor)
                Button { requestDownload() } label: { Label("下载", systemImage: "arrow.down.circle") }
                    .tint(.indigo)
                if let onRemove {
                    Button(role: .destructive, action: onRemove) { Label("移除", systemImage: "trash") }
                }
            }
            // contextMenu mirrors the swipe (so users who discover long-press get the
            // same actions) and adds copy/share + the platform link. Heavier than swipe
            // but doesn't conflict — both gestures coexist on List rows in SwiftUI.
            .contextMenu {
                Button { requestAdd() } label: { Label("收藏", systemImage: "heart") }
                Button { requestDownload() } label: { Label("下载", systemImage: "arrow.down.circle") }
                Divider()
                Button {
                    UIPasteboard.general.string = shareText
                } label: { Label("复制歌曲信息", systemImage: "doc.on.doc") }
                ShareLink(item: shareText) { Label("分享", systemImage: "square.and.arrow.up") }
                if let onRemove {
                    Divider()
                    Button(role: .destructive, action: onRemove) { Label("从歌单移除", systemImage: "trash") }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddToPlaylistSheet(track: track)
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showDownload) {
                DownloadSheet(track: track)
                    .presentationDragIndicator(.visible)
            }
    }
}

extension View {
    func trackRowSwipe(
        _ track: Track,
        onRemove: (() -> Void)? = nil,
        onAddToPlaylist: ((Track) -> Void)? = nil,
        onDownload: ((Track) -> Void)? = nil
    ) -> some View {
        modifier(TrackRowSwipe(track: track, onRemove: onRemove,
                               onAddToPlaylist: onAddToPlaylist, onDownload: onDownload))
    }
}
