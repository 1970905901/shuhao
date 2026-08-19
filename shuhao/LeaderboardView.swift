import SwiftUI

/// Two-level view: list of boards (排行榜) → board detail (songs of that board).
/// Supports multiple platforms via segmented picker at top.
struct LeaderboardView: View {
    @AppStorage("ui.boardSource") private var selectedSourceRaw: String = SourceID.kw.rawValue
    @State private var boards: [BoardInfo] = []
    @State private var isLoading = false

    private var selectedSource: SourceID {
        get { SourceID(rawValue: selectedSourceRaw) ?? .kw }
    }
    private var selectedSourceBinding: Binding<SourceID> {
        Binding(get: { selectedSource }, set: { selectedSourceRaw = $0.rawValue })
    }

    private var supportedSources: [SourceID] { Boards.all.map { $0.source } }

    var body: some View {
        VStack(spacing: 0) {
            if supportedSources.count > 1 {
                ChipBar(items: supportedSources, title: { $0.displayName }, selection: selectedSourceBinding)
                    .padding(.top, DS.Spacing.s)
                    .padding(.bottom, DS.Spacing.xs)
            }
            if isLoading && boards.isEmpty {
                LoadingPlaceholder()
                Spacer()
            } else {
                // Switched from `List(insetGrouped)` to a ScrollView of cards so the leaderboard
                // matches the songlist grid's visual language (cover-driven cards) instead of
                // sitting in a flat iOS Settings-style list.
                ScrollView {
                    LazyVStack(spacing: DS.Spacing.m) {
                        ForEach(boards) { board in
                            NavigationLink(value: board) {
                                BoardRow(board: board)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.top, DS.Spacing.s)
                    .padding(.bottom, DS.Spacing.xl)
                }
            }
        }
        .brandedSurface()
        .navigationTitle("排行榜")
        // 大标题把内容压得很低,改 inline 让内容贴近状态栏。
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: BoardInfo.self) { board in
            BoardDetailView(board: board)
        }
        .task(id: selectedSource) {
            await load()
        }
    }

    private func load() async {
        guard let svc = Boards.service(for: selectedSource) else { return }
        boards = svc.list  // immediate placeholder
        isLoading = true
        defer { isLoading = false }
        boards = await svc.fetchBoards()
    }
}

private struct BoardThumbnail: View {
    let board: BoardInfo
    var size: CGFloat = 56
    var body: some View {
        CoverImage(url: board.picURL, maxPixel: size) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            LinearGradient(colors: [board.source.tint, board.source.tint.opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                Text(String(board.name.prefix(2)))
                    .font(.system(size: size * 0.25, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1).minimumScaleFactor(0.5)
            )
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }
}

/// Single leaderboard card. Glass surface + cover-tinted shadow so each
/// board has a slight color signature pulled from its source tint.
private struct BoardRow: View {
    let board: BoardInfo
    var body: some View {
        HStack(spacing: 14) {
            BoardThumbnail(board: board, size: 64)
                .elevation(DS.Elevation.e1(board.source.tint))
            VStack(alignment: .leading, spacing: 6) {
                Text(board.name)
                    .font(DS.Typo.bodyStrong)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    SourceChip(source: board.source)
                    Text("Top 100")
                        .font(DS.Typo.caption2)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(DS.Spacing.m)
        .background(DS.Glass.thin, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(DS.Palette.strokeSubtle, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
    }
}

struct BoardDetailView: View {
    let board: BoardInfo
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var downloads: DownloadStore
    @StateObject private var artwork = ArtworkColors()
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var error: String?
    // 弹窗状态在根 view —— 见 SonglistDetailView 同位置注释(Mac 行级 sheet 问题)。
    @State private var trackToFavorite: Track?
    @State private var trackToDownload: Track?

    var body: some View {
        Group {
            if isLoading && tracks.isEmpty {
                LoadingPlaceholder()
            } else if let error, tracks.isEmpty {
                ShUnavailableView(title: "加载失败", systemImage: "exclamationmark.triangle",
                                  description: Text(error))
            } else {
                List {
                    Section {
                        HStack(spacing: 14) {
                            BoardThumbnail(board: board, size: 96)
                                .elevation(DS.Elevation.e2(artwork.primary))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(board.name)
                                    .font(.system(size: 19, weight: .bold))
                                    .foregroundStyle(DS.Palette.textPrimary)
                                    .lineLimit(2)
                                Text("\(tracks.count) 首歌曲")
                                    .font(DS.Typo.numeric)
                                    .foregroundStyle(DS.Palette.textTertiary)
                                if !tracks.isEmpty {
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
                                }
                            }
                            Spacer(minLength: 0)
                        }
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
                                playback.play(track: t, in: tracks, startIndex: idx)
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // see SonglistDetailView — without this the .background only paints LoadingPlaceholder's own ~70pt strip
        .background(
            ZStack {
                DS.Palette.bgBase
                // Only show cover-tint backdrop after tracks have loaded — otherwise a
                // bare color band appears above the loading spinner, looks like a UI glitch.
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
        .navigationTitle(board.name)
        .navigationBarTitleDisplayMode(.inline)
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
            artwork.extract(from: board.picURL)
            guard tracks.isEmpty, !isLoading else { return }
            isLoading = true
            defer { isLoading = false }
            guard let svc = Boards.service(for: board.source) else { return }
            do {
                tracks = try await svc.fetchTracks(bangid: board.bangid, page: 1)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
