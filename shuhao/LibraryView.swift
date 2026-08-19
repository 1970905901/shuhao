import SwiftUI

enum LibraryRoute: Hashable {
    case playlist(UUID)
}

struct LibraryView: View {
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var history: PlayHistoryStore
    @State private var showCreate = false
    @State private var showImport = false
    @State private var showSonglistImport = false
    @State private var newName = ""

    // `adaptive(minimum: 170)` → iPhone shows 2 columns (390 px wide), iPad 3
    // (and 4 on the largest iPads). No conditional sizeClass branch needed.
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                HStack(spacing: 14) {
                    NavigationLink {
                        DownloadedView()
                    } label: {
                        LibraryShortcutCard(
                            icon: "arrow.down.circle.fill",
                            title: "已下载",
                            subtitle: "\(downloads.completedCount) 首 · \(downloads.folders.count) 个歌单",
                            gradient: [.accentColor, .accentColor.opacity(0.6)]
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        PlayHistoryView()
                    } label: {
                        LibraryShortcutCard(
                            icon: "clock.arrow.circlepath",
                            title: "播放历史",
                            subtitle: "\(history.tracks.count) 首",
                            gradient: [.orange, .pink]
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DS.Spacing.l)

                // Full-width "听歌报告" entry — drawn from the same event stream
                // as PlayHistory but visualizes it.
                NavigationLink {
                    StatsView()
                } label: {
                    StatsShortcutCard(playCount: history.events.count)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DS.Spacing.l)

                Section {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(playlists.playlists) { p in
                            NavigationLink(value: p.id) {
                                PlaylistCard(playlist: p, tracks: playlists.tracks(in: p))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    playlists.deletePlaylist(p.id)
                                } label: {
                                    Label("删除歌单", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Spacing.l)
                } header: {
                    HStack(alignment: .center, spacing: 8) {
                        Text("歌单").font(DS.Typography.sectionTitle)
                        Text("\(playlists.playlists.count) 个")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        // 原来顶栏的 + 菜单: 创建 / 导入歌单 / 本地导入 —— 全部歌单
                        // 相关的入口,搬到"歌单"行最右边最合理,跟 section 语义对齐。
                        Menu {
                            Button { showCreate = true } label: {
                                Label("创建歌单", systemImage: "plus.square.on.square")
                            }
                            Button { showSonglistImport = true } label: {
                                Label("导入歌单", systemImage: "link.badge.plus")
                            }
                            Button { showImport = true } label: {
                                Label("本地导入", systemImage: "folder.badge.plus")
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(DS.Palette.brandGradient)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.l)
                }
            }
            .padding(.vertical, DS.Spacing.m)
        }
        .brandedSurface()
        .navigationTitle("我的")
        // 跟搜索/排行榜/歌单一致:标题改 inline,内容贴近状态栏。
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: UUID.self) { id in
            if let p = playlists.playlists.first(where: { $0.id == id }) {
                PlaylistDetailView(playlistID: p.id)
            }
        }
        .navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .playlist(let id):
                if let p = playlists.playlists.first(where: { $0.id == id }) {
                    PlaylistDetailView(playlistID: p.id)
                }
            }
        }
        // 原来顶栏的 + 菜单(创建/导入歌单/本地导入)搬到下方"歌单" section 头的最右
        // 边;齿轮设置按钮挪到独立底部 tab(见 RootTabView 的 .settings tab)。
        .alert("新建歌单", isPresented: $showCreate) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) { newName = "" }
            Button("创建") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { _ = playlists.createPlaylist(name: n) }
                newName = ""
            }
        }
        .sheet(isPresented: $showImport) {
            LocalImportSheet()
        }
        .sheet(isPresented: $showSonglistImport) {
            SonglistImportSheet()
                .environmentObject(playlists)
        }
    }

    private func sectionHeader(_ title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title).font(DS.Typography.sectionTitle)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

/// Half-width entry card used for the 已下载 / 播放历史 shortcuts at the top of 我的.
/// Wide hero card linking to StatsView. Brand-gradient background + "view
/// report" affordance so it reads as a separate destination from the two
/// neighbor cards above.
private struct StatsShortcutCard: View {
    let playCount: Int
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("听歌报告")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(playCount > 0 ? "已记录 \(playCount) 次播放" : "听几首歌看看你的口味")
                    .font(DS.Typo.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity)
        .background(DS.Palette.brandGradient,
                    in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        .elevation(DS.Elevation.e1(DS.Palette.brandStart))
    }
}

private struct LibraryShortcutCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let gradient: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }
}

private struct PlaylistCard: View {
    let playlist: PlaylistMeta
    let tracks: [Track]
    @ObservedObject private var downloads = DownloadStore.shared

    private var coverURLs: [String?] {
        tracks.prefix(4).map { downloads.displayCoverURL(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverMosaic(urls: coverURLs)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(playlist.trackIDs.count) 首")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct CoverMosaic: View {
    let urls: [String?]

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 2
            if urls.isEmpty {
                placeholder
            } else if urls.count == 1 {
                cover(urls[0], size: geo.size.width)
            } else {
                ZStack {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            cover(urls[safe: 0] ?? nil, size: s)
                            cover(urls[safe: 2] ?? nil, size: s)
                        }
                        VStack(spacing: 0) {
                            cover(urls[safe: 1] ?? nil, size: s)
                            cover(urls[safe: 3] ?? nil, size: s)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cover(_ url: String?, size: CGFloat) -> some View {
        CoverImage(url: url, maxPixel: size) { img in
            img.resizable().scaledToFill().frame(width: size, height: size).clipped()
        } placeholder: {
            placeholder.frame(width: size, height: size)
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color(.tertiarySystemFill), Color(.quaternarySystemFill)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(Image(systemName: "music.note.list").font(.system(size: 32)).foregroundColor(.secondary.opacity(0.6)))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Playlist Detail

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var artwork = ArtworkColors()
    // 弹窗状态在根 view —— 见 SonglistDetailView 同位置注释(Mac 行级 sheet 问题)。
    @State private var trackToFavorite: Track?
    @State private var trackToDownload: Track?
    @State private var showBatchDownload = false

    private var playlist: PlaylistMeta? {
        playlists.playlists.first(where: { $0.id == playlistID })
    }
    private var tracks: [Track] {
        guard let p = playlist else { return [] }
        return playlists.tracks(in: p)
    }

    var body: some View {
        if let p = playlist {
            List {
                Section {
                    header(name: p.name)
                        .padding(.horizontal, DS.Spacing.l)
                        .padding(.vertical, DS.Spacing.m)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, t in
                        HStack(alignment: .center, spacing: 4) {
                            Text("\(idx + 1)")
                                .font(DS.Typo.numeric)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .frame(width: 28)
                            TrackRow(track: t)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            AppServices.shared.playback?.play(track: t, in: tracks, startIndex: idx)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .trackRowSwipe(t,
                                       onRemove: { playlists.remove(trackIDs: [t.id], from: p.id) },
                                       onAddToPlaylist: { trackToFavorite = $0 },
                                       onDownload: { trackToDownload = $0 })
                    }
                } header: {
                    Text("曲目")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Background: dynamic gradient driven by the playlist's first cover.
            // Same visual language as SonglistDetailView / BoardDetailView so
            // "进了一个歌单详情" 看起来跨页面统一。
            .background(
                ZStack {
                    DS.Palette.bgBase
                    if !tracks.isEmpty {
                        LinearGradient(
                            colors: [artwork.primary.opacity(0.55), artwork.secondary.opacity(0.15), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                        .ignoresSafeArea(edges: .top)
                        .transition(.opacity)
                    }
                }
                .animation(DS.Motion.standard, value: tracks.isEmpty)
            )
            .navigationTitle(p.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                artwork.extract(from: tracks.first.flatMap { downloads.displayCoverURL(for: $0) })
            }
            .shOnChange(of: tracks.first?.id) {
                artwork.extract(from: tracks.first.flatMap { downloads.displayCoverURL(for: $0) })
            }
            // 收藏/下载弹窗 —— Mac → .popover,iPad/iPhone → .sheet(同 SonglistDetailView)。
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
            .popover(isPresented: $showBatchDownload) {
                BatchDownloadSheet(tracks: tracks)
                    .environmentObject(downloads)
                    .environmentObject(settings)
                    .frame(width: 480, height: 620)
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
            .sheet(isPresented: $showBatchDownload) {
                BatchDownloadSheet(tracks: tracks)
                    .environmentObject(downloads)
                    .environmentObject(settings)
                    .presentationDragIndicator(.visible)
            }
            #endif
        } else {
            ShUnavailableView(title: "歌单不存在", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func header(name: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CoverMosaicCompact(urls: tracks.prefix(4).map { downloads.displayCoverURL(for: $0) })
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                .elevation(DS.Elevation.e2(artwork.primary))
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(3)
                Text("\(tracks.count) 首")
                    .font(DS.Typo.numeric)
                    .foregroundStyle(DS.Palette.textTertiary)
                if !tracks.isEmpty {
                    HStack(spacing: 8) {
                        Button {
                            AppServices.shared.playback?.play(track: tracks[0], in: tracks, startIndex: 0)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "play.fill")
                                Text("播放全部")
                            }
                            .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            showBatchDownload = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down.circle")
                                Text("全部下载")
                            }
                            .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CoverMosaicCompact: View {
    let urls: [String?]
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 2
            if urls.compactMap({ $0 }).isEmpty {
                LinearGradient(colors: [.accentColor.opacity(0.5), .accentColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: 28)).foregroundColor(.white))
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        cover(urls[safe: 0] ?? nil, size: s)
                        cover(urls[safe: 2] ?? nil, size: s)
                    }
                    VStack(spacing: 0) {
                        cover(urls[safe: 1] ?? nil, size: s)
                        cover(urls[safe: 3] ?? nil, size: s)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }

    @ViewBuilder
    private func cover(_ url: String?, size: CGFloat) -> some View {
        CoverImage(url: url, maxPixel: size) { img in
            img.resizable().scaledToFill().frame(width: size, height: size).clipped()
        } placeholder: {
            Color(.tertiarySystemFill).frame(width: size, height: size)
        }
    }
}

private extension ArraySlice where Element == String? {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

