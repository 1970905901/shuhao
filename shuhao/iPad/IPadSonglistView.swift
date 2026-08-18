import SwiftUI

// MARK: - Songlist Square (歌单) — iPad
//
// 跟 iPhone SonglistView 完全对齐:
//   - 源 chip(酷我/网易云/酷狗/QQ)
//   - 搜索框 + 取消按钮
//   - 排序 chip (推荐/最热/最新...)
//   - 筛选按钮(打开 TagFilterSheet)
//   - 主区域 4-5 列网格
//
// 跟 iPhone 唯一差别是网格密度大一点 + 卡片大一些。

struct IPadSonglistView: View {
    @Binding var path: NavigationPath
    @AppStorage("ui.songlistSource") private var selectedSourceRaw: String = SourceID.kw.rawValue
    @AppStorage("ui.songlistOrder")  private var orderID: String = ""
    @State private var playlists: [SonglistInfo] = []
    @State private var keyword: String = ""
    @State private var submittedQuery: String = ""
    @State private var isLoading = false
    @State private var selectedTag: SonglistTag = .all
    @State private var tagGroups: [SonglistTagGroup] = []
    @State private var tagsLoadedSource: SourceID? = nil
    @State private var tagsLoading = false
    @State private var showTagSheet = false
    @FocusState private var searchFocused: Bool

    private var selectedSource: SourceID { SourceID(rawValue: selectedSourceRaw) ?? .kw }
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

    var body: some View {
        VStack(spacing: 12) {
            header
            ScrollView {
                if isLoading && playlists.isEmpty {
                    LoadingPlaceholder(topPadding: 80)
                } else if playlists.isEmpty && isSearching && !isLoading {
                    BrandedEmpty(icon: "magnifyingglass",
                                 title: "没有找到歌单",
                                 subtitle: "换个关键字或切换音源试试")
                        .padding(.top, 60)
                } else if playlists.isEmpty {
                    BrandedEmpty(icon: "rectangle.stack",
                                 title: "暂无歌单",
                                 subtitle: "尝试换个音源")
                        .padding(.top, 60)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190), spacing: 18, alignment: .top)],
                        spacing: 22
                    ) {
                        ForEach(playlists) { list in
                            Button { path.pushDetail(list) } label: {
                                IPadAlbumCard(
                                    imageURL: list.picURL,
                                    title: list.name,
                                    subtitle: list.playCount ?? list.author,
                                    fallbackTint: list.source.tint,
                                    size: 180
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 96)
                    .ipadContentWidth()
                }
            }
        }
        .background(IPad.Color.contentBackground)
        // 源切换时清空 tag + keyword,跟 iPhone 行为一致
        .onChange(of: selectedSourceRaw) {
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
        // 筛选弹窗 —— Mac → .popover(点外面/Esc 关,跟设置弹窗一致),iPad → .sheet。
        #if targetEnvironment(macCatalyst)
        .popover(isPresented: $showTagSheet) {
            TagFilterSheet(groups: $tagGroups, isLoading: $tagsLoading, selected: selectedTag) { tag in
                selectedTag = tag
            }
            .frame(width: 520, height: 640)
        }
        #else
        .sheet(isPresented: $showTagSheet) {
            TagFilterSheet(groups: $tagGroups, isLoading: $tagsLoading, selected: selectedTag) { tag in
                selectedTag = tag
            }
            .inheritedAppearance()
            .presentationDragIndicator(.visible)
            .presentationDetents([.large])
        }
        #endif
    }

    // MARK: Header (title + source chip + search bar + order chip + filter btn)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("歌单广场")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
                .padding(.horizontal, 32)
                .padding(.top, 8)

            // 源 chip — 跟 iPhone SonglistView 顶部一致
            if supportedSources.count > 1 {
                ChipBar(items: supportedSources, title: { $0.displayName }, selection: selectedSourceBinding)
            }

            // 搜索框
            searchBar
                .padding(.horizontal, 32)

            // 排序 chip + 筛选按钮(只在不搜索时显示)
            if !isSearching {
                HStack(spacing: 8) {
                    if currentOrders.count > 1 {
                        ChipBar(items: currentOrders, title: { $0.name }, selection: orderBinding)
                    } else if let only = currentOrders.first {
                        // 网易云只支持"最热"一种排序 — 显示只读 chip,告诉用户
                        // 当前是什么排序,而不是留空让人困惑
                        readOnlyOrderChip(only.name)
                    } else {
                        // 极端情况(平台没声明任何 order),fallback 显示默认
                        readOnlyOrderChip("默认")
                    }
                    Spacer(minLength: 0)
                    filterButton
                        .padding(.trailing, 32)
                }
            }
        }
        .ipadContentWidth()
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Palette.textTertiary)
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
                        Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(searchFocused ? DS.Palette.brandStart.opacity(0.5) : DS.Palette.strokeSubtle,
                            lineWidth: searchFocused ? 1.5 : 0.5)
            )

            if searchFocused || isSearching {
                Button("取消") {
                    keyword = ""; submittedQuery = ""; searchFocused = false
                }
                .foregroundStyle(DS.Palette.brandStart)
                .buttonStyle(.plain)
            }
        }
    }

    /// 只读 chip — 当源只支持一种排序时,显示它的名字,跟可点击的 ChipBar
    /// 视觉上区分(无背景填充 + 小一号字 + textSecondary)。
    private func readOnlyOrderChip(_ name: String) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Palette.brandStart)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .padding(.leading, 16)
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
            .foregroundStyle(active ? Color.white : DS.Palette.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(active
                                       ? AnyShapeStyle(DS.Palette.brandGradient)
                                       : AnyShapeStyle(DS.Palette.strokeSubtle.opacity(0.5))))
        }
        .buttonStyle(.plain)
    }

    private struct LoadKey: Hashable {
        let source: SourceID
        let order: String
        let tag: String
        let query: String
    }

    private func ensureTagsLoaded() async {
        if tagsLoadedSource == selectedSource && !tagGroups.isEmpty { return }
        guard let svc = Songlists.service(for: selectedSource) else { return }
        tagsLoading = true
        defer { tagsLoading = false }
        do {
            tagGroups = try await svc.fetchTags()
            tagsLoadedSource = selectedSource
        } catch {
            tagGroups = []
        }
    }

    private func load() async {
        guard let svc = Songlists.service(for: selectedSource) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if submittedQuery.isEmpty {
                playlists = try await svc.fetchRecommended(order: currentOrder, tag: selectedTag, page: 1)
            } else {
                playlists = try await svc.search(keyword: submittedQuery, page: 1)
            }
        } catch {
            playlists = []
        }
    }
}
