import SwiftUI

/// Browse recommended playlists per platform (with per-platform tag filters), or search
/// playlists by keyword within the selected source; tap → detail with songs.
struct SonglistView: View {
    @AppStorage("ui.songlistSource") private var selectedSourceRaw: String = SourceID.kw.rawValue
    @State private var orderID: String = ""
    @State private var playlists: [SonglistInfo] = []
    @State private var isLoading = false
    @State private var error: String?

    // Search-within-songlist
    @State private var keyword: String = ""
    @State private var submittedQuery: String = ""
    @FocusState private var searchFocused: Bool

    // Per-platform tag filter
    @State private var selectedTag: SonglistTag = .all
    @State private var tagGroups: [SonglistTagGroup] = []
    @State private var tagsLoadedSource: SourceID?
    @State private var tagsLoading = false
    @State private var showTagSheet = false

    private var selectedSource: SourceID {
        SourceID(rawValue: selectedSourceRaw) ?? .kw
    }
    private var selectedSourceBinding: Binding<SourceID> {
        Binding(get: { selectedSource }, set: { selectedSourceRaw = $0.rawValue })
    }

    private var supportedSources: [SourceID] { Songlists.all.map { $0.source } }
    private var currentOrders: [SonglistOrder] { Songlists.service(for: selectedSource)?.orders ?? [] }
    private var currentOrder: SonglistOrder {
        currentOrders.first { $0.id == orderID } ?? currentOrders.first ?? SonglistOrder(id: "hot", name: "最热")
    }
    private var orderBinding: Binding<SonglistOrder> {
        Binding(get: { currentOrder }, set: { orderID = $0.id })
    }
    private var isSearching: Bool { !submittedQuery.isEmpty }
    // Adaptive columns — see LibraryView for the rationale.
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 14)]

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            if supportedSources.count > 1 {
                ChipBar(items: supportedSources, title: { $0.displayName }, selection: selectedSourceBinding)
                    .padding(.top, DS.Spacing.s)
            }

            searchBar
                .padding(.horizontal, DS.Spacing.l)

            if !isSearching {
                HStack(spacing: 8) {
                    if currentOrders.count > 1 {
                        ChipBar(items: currentOrders, title: { $0.name }, selection: orderBinding)
                    } else {
                        Spacer(minLength: 0)
                    }
                    filterButton
                        .padding(.trailing, DS.Spacing.l)
                }
            }

            ScrollView {
                if isLoading && playlists.isEmpty {
                    LoadingPlaceholder()
                } else if let error, playlists.isEmpty {
                    ShUnavailableView(title: "加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if playlists.isEmpty && isSearching && !isLoading {
                    BrandedEmpty(icon: "magnifyingglass",
                                 title: "没有找到歌单",
                                 subtitle: "换个关键字或切换音源试试")
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(playlists) { list in
                            NavigationLink(value: list) {
                                SonglistCard(info: list)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.vertical, DS.Spacing.l)
                }
            }
        }
        .brandedSurface()
        .navigationTitle("歌单")
        // 大标题把内容压得很低,改 inline 让内容贴近状态栏。
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: SonglistInfo.self) { info in
            SonglistDetailView(info: info)
        }
        // Switching source invalidates the tag filter, cached tags and any active search.
        .shOnChange(of: selectedSourceRaw) {
            selectedTag = .all
            tagGroups = []
            tagsLoadedSource = nil
            orderID = ""
            keyword = ""
            submittedQuery = ""
        }
        .task(id: LoadKey(source: selectedSource, order: currentOrder.id, tag: selectedTag.id, query: submittedQuery)) {
            await load()
        }
        .sheet(isPresented: $showTagSheet) {
            TagFilterSheet(groups: $tagGroups, isLoading: $tagsLoading, selected: selectedTag) { tag in
                selectedTag = tag
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索歌单", text: $keyword)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { submittedQuery = keyword.trimmingCharacters(in: .whitespacesAndNewlines) }
                Spacer(minLength: 0)
                if !keyword.isEmpty {
                    Button {
                        keyword = ""; submittedQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if searchFocused || isSearching {
                Button("取消") {
                    keyword = ""; submittedQuery = ""; searchFocused = false
                }
                .foregroundColor(.accentColor)
            }
        }
    }

    private var filterButton: some View {
        let active = !selectedTag.id.isEmpty
        return Button {
            showTagSheet = true
            Task { await ensureTagsLoaded() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(active ? selectedTag.name : "筛选").lineLimit(1)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(active ? .white : .primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(active ? Color.accentColor : Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }

    private struct LoadKey: Hashable {
        let source: SourceID
        let order: String
        let tag: String
        let query: String
    }

    private func load() async {
        playlists = []
        error = nil
        guard let svc = Songlists.service(for: selectedSource) else { return }
        let order = currentOrder
        let tag = selectedTag
        let query = submittedQuery
        isLoading = true
        defer { isLoading = false }
        do {
            if query.isEmpty {
                playlists = try await svc.fetchRecommended(order: order, tag: tag, page: 1)
            } else {
                playlists = try await svc.search(keyword: query, page: 1)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Lazily fetch (and cache) the current source's tag groups for the filter sheet.
    private func ensureTagsLoaded() async {
        guard tagsLoadedSource != selectedSource else { return }
        guard let svc = Songlists.service(for: selectedSource) else { return }
        tagsLoading = true
        defer { tagsLoading = false }
        let groups = (try? await svc.fetchTags()) ?? []
        // Guard against the user having switched source while we were loading.
        guard selectedSource == svc.source else { return }
        tagGroups = groups
        tagsLoadedSource = selectedSource
    }
}

/// Filter sheet: 全部 + per-platform tag groups as wrapping chips.
/// groups/isLoading 用 Binding —— Mac Catalyst 的 popover 内容闭包弹出后
/// 不会因外部 @State 变化重新求值,普通值传进来会永远卡在"加载中"。
struct TagFilterSheet: View {
    @Binding var groups: [SonglistTagGroup]
    @Binding var isLoading: Bool
    let selected: SonglistTag
    let onSelect: (SonglistTag) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    chipRow(tags: [.all])
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            chipRow(tags: group.tags)
                        }
                    }
                    if isLoading && groups.isEmpty {
                        LoadingPlaceholder(topPadding: 40)
                    } else if !isLoading && groups.isEmpty {
                        Text("暂无筛选项")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(DS.Spacing.l)
            }
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .sheetNavBarSurface()
            // Mac 上是 popover,点外部即可关闭,不需要取消按钮。
            #if !targetEnvironment(macCatalyst)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            #endif
        }
    }

    private func chipRow(tags: [SonglistTag]) -> some View {
        FlexLayout(spacing: 8, runSpacing: 8) {
            ForEach(tags) { tag in
                let on = tag.id == selected.id
                Button {
                    onSelect(tag)
                    dismiss()
                } label: {
                    Text(tag.name)
                        .font(.system(size: 13))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundColor(on ? .white : .primary)
                        .background(Capsule().fill(on ? Color.accentColor : Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SonglistCard: View {
    let info: SonglistInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                CoverImage(url: info.picURL, maxPixel: 180) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    LinearGradient(colors: [info.source.tint, info.source.tint.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "music.note.list").font(.system(size: 30)).foregroundColor(.white))
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                .elevation(DS.Elevation.e2(info.source.tint))   // tint the lift with the source's brand color so kw/wy/kg/tx feel subtly different at scale

                if let plays = info.playCount {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                        Text(plays).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    // Solid translucent black — overlays on photos always read against any
                    // cover (Apple Photos / TikTok / 抖音 use this exact treatment).
                    // .thickMaterial in light mode rendered white-on-white and was unreadable.
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(info.author.isEmpty ? info.source.displayName : info.author)
                    .font(DS.Typo.caption2)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

struct SonglistDetailView: View {
    let info: SonglistInfo
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var downloads: DownloadStore
    @StateObject private var artwork = ArtworkColors()
    @State private var detail: SonglistDetail?
    @State private var isLoading = false
    @State private var error: String?
    // 收藏/下载弹窗状态提到根 view —— 行级 sheet 在 Mac Catalyst 上行被回收后
    // dismiss 会失灵(点外面也关不掉),跟 IPadSearchView 同一个修法。
    @State private var trackToFavorite: Track?
    @State private var trackToDownload: Track?

    var body: some View {
        Group {
            if let detail {
                List {
                    Section {
                        header(detail: detail)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())  // header bleeds to edges so the cover-color backdrop fills the width
                    }
                    Section {
                        ForEach(Array(detail.tracks.enumerated()), id: \.element.id) { idx, t in
                            HStack(alignment: .center, spacing: 4) {
                                Text("\(idx + 1)")
                                    .font(DS.Typo.numeric)
                                    .foregroundStyle(DS.Palette.textTertiary)
                                    .frame(width: 28)
                                TrackRow(track: t)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playback.play(track: t, in: detail.tracks, startIndex: idx)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .trackRowSwipe(t,
                                           onAddToPlaylist: { trackToFavorite = $0 },
                                           onDownload: { trackToDownload = $0 })
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else if isLoading {
                LoadingPlaceholder()
            } else if let error {
                ShUnavailableView(title: "加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
            }
        }
        // Stretch to the full safe area so .background paints the whole screen during
        // loading/error states. Without this, Group sizes to LoadingPlaceholder's own
        // ~70pt height and the backdrop renders as a narrow band in the middle.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Background: cover color glow over base surface — gives the detail page a
        // sense of place. Only kicks in once detail loads so the loading state doesn't
        // flash a bare color band over the spinner.
        .background(
            ZStack {
                DS.Palette.bgBase
                if detail != nil {
                    LinearGradient(
                        colors: [artwork.primary.opacity(0.55), artwork.secondary.opacity(0.15), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity)
                }
            }
            .animation(DS.Motion.standard, value: detail == nil)
        )
        .navigationTitle(detail?.info.name ?? info.name)
        .navigationBarTitleDisplayMode(.inline)
        // 收藏/下载弹窗 —— Mac → .popover(点外面/Esc 关),iPad/iPhone → .sheet。
        // 跟 IPadRootView 设置弹窗同一套模式,env objects 显式透传。
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
        .task {
            guard detail == nil, !isLoading else { return }
            isLoading = true
            defer { isLoading = false }
            artwork.extract(from: info.picURL)
            guard let svc = Songlists.service(for: info.source) else { return }
            do {
                detail = try await svc.fetchDetail(info)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func header(detail: SonglistDetail) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(url: detail.info.picURL, maxPixel: 110) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(colors: [info.source.tint, info.source.tint.opacity(0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note.list").font(.system(size: 36)).foregroundColor(.white))
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
            .elevation(DS.Elevation.e2(artwork.primary))

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.info.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(3)
                if !detail.info.author.isEmpty {
                    Text(detail.info.author).font(.subheadline).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                }
                Text("\(detail.tracks.count) 首")
                    .font(DS.Typo.numeric)
                    .foregroundStyle(DS.Palette.textTertiary)
                if !detail.tracks.isEmpty {
                    Button {
                        playback.play(track: detail.tracks[0], in: detail.tracks, startIndex: 0)
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
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.m)
    }
}
