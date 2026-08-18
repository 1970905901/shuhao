import SwiftUI

// MARK: - 资料库 (iPad / Mac)
struct IPadLibraryView: View {
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var history: PlayHistoryStore
    @ObservedObject private var downloads = DownloadStore.shared
    @Binding var path: NavigationPath
    @State private var showCreate = false
    @State private var showImport = false
    @State private var showSonglistImport = false
    @State private var newName = ""

    private var recentTracks: [Track] { Array(history.tracks.prefix(12)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IPad.Layout.sectionTopSpacing) {
                headerRow

                if !recentTracks.isEmpty {
                    continueListening
                    recentCarousel
                }

                playlistGrid
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 96)
            .ipadContentWidth()
        }
        .background(IPad.Color.contentBackground)
        .alert("新建歌单", isPresented: $showCreate) {
            TextField("歌单名", text: $newName)
            Button("取消", role: .cancel) { newName = "" }
            Button("创建") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { _ = playlists.createPlaylist(name: n) }
                newName = ""
            }
        }
        // Mac Catalyst 上 sheet 的 dismiss 不可靠,统一走 popover(同 IPadRootView 设置弹窗)。
        #if targetEnvironment(macCatalyst)
        .popover(isPresented: $showImport) {
            LocalImportSheet()
                .environmentObject(playlists)
                .frame(width: 480, height: 560)
        }
        .popover(isPresented: $showSonglistImport) {
            SonglistImportSheet()
                .environmentObject(playlists)
                .frame(width: 480, height: 560)
        }
        #else
        .sheet(isPresented: $showImport) {
            LocalImportSheet()
                .environmentObject(playlists)
        }
        .sheet(isPresented: $showSonglistImport) {
            SonglistImportSheet()
                .environmentObject(playlists)
        }
        #endif
    }

    // MARK: - Header
    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("资料库")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("\(playlists.playlists.count) 个歌单 · \(history.tracks.count) 首最近播放")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            Spacer()
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
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("添加歌单")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(Color.white)
                .background(Capsule().fill(DS.Palette.brandGradient))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    // MARK: - Continue listening hero
    @ViewBuilder
    private var continueListening: some View {
        if let last = recentTracks.first {
            HStack(spacing: 20) {
                Artwork(url: downloads.displayCoverURL(for: last), size: 140, radius: 16)
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text("继续听")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                        .textCase(.uppercase)
                    Text(last.name)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(2)
                    Text(last.singer)
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Button {
                            playback.play(track: last, in: recentTracks, startIndex: 0)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("继续播放")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(DS.Palette.brandGradient))
                            .foregroundStyle(Color.white)
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            path.pushDetail(IPadDestination.history)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("最近播放列表")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .overlay(Capsule().stroke(DS.Palette.strokeSubtle, lineWidth: 1))
                            .foregroundStyle(DS.Palette.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.Palette.strokeSubtle, lineWidth: 0.5))
        }
    }

    // MARK: - Recent Carousel
    private var recentCarousel: some View {
        VStack(alignment: .leading, spacing: 14) {
            IPadSectionHeader("最近播放") {
                Button("更多") { path.pushDetail(IPadDestination.history) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(recentTracks.enumerated()), id: \.element.id) { idx, t in
                        Button {
                            playback.play(track: t, in: recentTracks, startIndex: idx)
                        } label: {
                            IPadAlbumCard(
                                imageURL: downloads.displayCoverURL(for: t),
                                title: t.name,
                                subtitle: t.singer,
                                fallbackTint: t.source.tint,
                                size: 150
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 我的歌单 (已完美对齐 iPhone 四宫格矩阵逻辑)
    private var playlistGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            IPadSectionHeader("我的歌单", subtitle: "\(playlists.playlists.count) 个")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 18, alignment: .top)],
                spacing: 24
            ) {
                ForEach(playlists.playlists) { p in
                    Button {
                        // 维持 iPad 的多端路由导航
                        path.pushDetail(IPadDestination.playlist(p.id))
                    } label: {
                        // 采用 iPhone 统一的规范化卡片骨架
                        VStack(alignment: .leading, spacing: 10) {
                            let tracksInPlaylist = playlists.tracks(in: p)
                            let coverURLs = tracksInPlaylist.prefix(4).map { downloads.displayCoverURL(for: $0) }
                            
                            // 四宫格拼图组件：彻底去掉写死的 R 尺寸，改用弹性比
                            CoverMosaicView(urls: coverURLs)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
                            
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(DS.Palette.textPrimary)
                                    .lineLimit(1)
                                Text("\(p.trackIDs.count) 首")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.Palette.textTertiary)
                            }
                            .padding(.leading, 2)
                        }
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
        }
    }
}

// MARK: - 完美的四宫格拼图组件 (从 iPhone 端无缝平移并重命名防止冲突)
struct CoverMosaicView: View {
    let urls: [String?]

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 2
            let validUrls = urls.compactMap { $0 }
            
            if validUrls.isEmpty {
                placeholder
            } else if validUrls.count == 1 {
                cover(validUrls[0], size: geo.size.width)
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
    }

    @ViewBuilder
    private func cover(_ url: String?, size: CGFloat) -> some View {
        CoverImage(url: url, maxPixel: size) { img in
            img.resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
        } placeholder: {
            Color(.tertiarySystemFill)
                .frame(width: size, height: size)
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color(.tertiarySystemFill), Color(.quaternarySystemFill)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note.list")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.6))
        )
    }
}

// MARK: - 越界保护安全扩展
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
