import SwiftUI

// MARK: - iPad design tokens
//
// QQ 音乐 iPad 客户端的尺度参考:
//   - sidebar 宽度 220pt(macOS) / 240pt(iPad)
//   - carousel 卡片 180×180,grid 卡片 168×210(含文字)
//   - 列表行 64pt 高,artwork 48pt
//   - 顶部全局工具栏 56pt
//   - 圆角 sidebar/卡片 12pt,小元素 8pt
//
// 这些常量集中在 IPad enum 下,避免散落在各文件里魔数化。

enum IPad {
    enum Layout {
        static let sidebarWidth: CGFloat        = 240
        static let topBarHeight: CGFloat        = 56
        static let miniPlayerHeight: CGFloat    = 72
        static let contentMaxWidth: CGFloat     = 1280  // detail-pane horizontal cap
        static let carouselCardSize: CGFloat    = 180
        static let gridCardWidth: CGFloat       = 168
        static let listRowHeight: CGFloat       = 64
        static let listArtworkSize: CGFloat     = 48
        static let sectionTopSpacing: CGFloat   = 28
        static let cardCorner: CGFloat          = 12
    }

    enum Color {
        /// Sidebar background tint — slightly elevated from the window base.
        /// Light mode: warm cream. Dark mode: near-black with a hint of plum.
        static let sidebarBackground = SwiftUI.Color("SidebarBackground")
        /// Content pane background.
        static let contentBackground = SwiftUI.Color("ContentBackground")
        /// Subtle separator/border between sidebar and content.
        static let separator = SwiftUI.Color("StrokeSubtle")
    }
}

// MARK: - SectionHeader

/// "推荐歌单    最热 · 抒情 · 摇滚 …    更多 >" — used at the top of every
/// home/library section on iPad. Title is large+bold, accessory and action are
/// secondary and right-aligned. Matches QQ 音乐 web/iPad 的 section header 节奏。
struct IPadSectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

// MARK: - HeroBanner

/// QQ 音乐首页顶部用的大型 banner — 一个 cover-driven 卡片,占满 detail-pane 宽度,
/// 高度 ~280pt。左侧是文字 + CTA,右侧是封面。配色从封面提取,做品牌渐变叠加。
struct IPadHeroBanner: View {
    let title: String
    let subtitle: String
    let imageURL: String?
    let accentStart: Color
    let accentEnd: Color
    let action: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            // Background: angled gradient with optional blurred cover behind.
            LinearGradient(colors: [accentStart, accentEnd],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let imageURL {
                // 背景虚化层,28pt 模糊 —— 小图足够,别为它拉原图
                CoverImage(url: imageURL, maxPixel: 120) { img in
                    img.resizable().scaledToFill()
                } placeholder: { Color.clear }
                .opacity(0.32)
                .blur(radius: 28)
            }
            // Content row
            HStack(alignment: .center, spacing: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(3)
                    Button(action: action) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("立即播放")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.95), in: Capsule())
                        .foregroundStyle(accentStart)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 12)
                if let imageURL {
                    CoverImage(url: imageURL, maxPixel: 220) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - Carousel album card (180x180 cover + label)

/// Single tile in a horizontally-scrolling carousel of cover-driven content
/// (推荐歌单/排行榜入口/电台/etc). Hover/press scales subtly (Liquid Glass feel).
struct IPadAlbumCard: View {
    let imageURL: String?
    let title: String
    var subtitle: String?
    var fallbackTint: Color = DS.Palette.brandStart
    /// 没有封面 URL 时显示的 SF Symbol — 歌单卡片用默认的 music.note,排行榜
    /// 卡片应该传 "chart.bar.fill" 之类的图标。
    var fallbackIcon: String = "music.note"
    var size: CGFloat = IPad.Layout.carouselCardSize
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let imageURL {
                    // 加载失败(404/超时/被劫持)与加载中共用同一个 placeholder,
                    // 避免 4xx 之后留一个空白方块
                    CoverImage(url: imageURL, maxPixel: size) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        placeholder
                    }
                } else {
                    placeholder
                }
                // Play indicator on hover — only visible when the cursor is over
                // the card (trackpad on Magic Keyboard / mouse on Mac Catalyst).
                if hovering {
                    Color.black.opacity(0.32)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: IPad.Layout.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: IPad.Layout.cardCorner, style: .continuous)
                    .stroke(.white.opacity(0.04), lineWidth: 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.12),
                    radius: hovering ? 14 : 8, y: hovering ? 8 : 4)
            .scaleEffect(hovering ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Palette.textPrimary)
                // reservesSpace:一行标题也占满两行的高度,网格/carousel 里相邻卡片
                // 的封面和播放量行才能对齐 —— 否则单行标题的卡片整体矮一截,
                // 在默认垂直居中的 LazyVGrid 单元格里会往下沉、看起来没对齐。
                .lineLimit(2, reservesSpace: true)
                .frame(width: size, alignment: .leading)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .frame(width: size, alignment: .leading)
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [fallbackTint.opacity(0.55), fallbackTint.opacity(0.25)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: fallbackIcon)
                .font(.system(size: size * 0.32, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        )
    }
}

// MARK: - List row (track row for iPad — wider than iPhone with album column)

/// 4-column row used in iPad track lists / playlist details / search results:
///   [#][cover][title // singer][album][duration][actions]
/// The album column appears only when there's space (>= 720pt content width).
///
/// Actions (收藏 / 下载 / 复制 / 分享) appear in both the visible "..." Menu
/// (iPad-native) and the `.contextMenu` long-press. Mirrors `TrackRowSwipe` on
/// iPhone so search/leaderboard/songlist rows on iPad get the same toolkit,
/// even though LazyVStack can't host `.swipeActions`.
///
/// **Sheet state lives in the parent**, not in the row. Per-row `.sheet` modifiers
/// inside a LazyVStack get invalidated when SwiftUI recycles offscreen rows — on
/// Mac Catalyst this means the sheet stays visible but its `@Environment(\.dismiss)`
/// has no live parent to drive, so Cancel becomes a no-op. The parent passes
/// `onAddToPlaylist` / `onDownload` callbacks; it owns the @State and presents
/// the sheets itself.
struct IPadTrackRow: View {
    let index: Int?
    let track: Track
    let isPlaying: Bool
    let onTap: () -> Void
    let onAddToPlaylist: (Track) -> Void
    let onDownload: (Track) -> Void
    /// Optional "remove from this collection" — for example, removing a track from a
    /// user playlist row. nil for read-only sources like search/leaderboard.
    var onRemove: (() -> Void)? = nil
    @State private var hovering = false
    @ObservedObject private var downloads = DownloadStore.shared

    private var shareText: String {
        var s = track.name
        if !track.singer.isEmpty { s += " - \(track.singer)" }
        return s
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // # column
            Group {
                if hovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DS.Palette.brandStart)
                } else if let index {
                    Text("\(index)")
                        .font(DS.Typo.numeric)
                        .foregroundStyle(isPlaying ? DS.Palette.brandStart : DS.Palette.textTertiary)
                }
            }
            .frame(width: 32, alignment: .center)

            Artwork(url: downloads.displayCoverURL(for: track), size: IPad.Layout.listArtworkSize, radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isPlaying ? DS.Palette.brandStart : DS.Palette.textPrimary)
                        .lineLimit(1)
                    if !track.qualities.isEmpty,
                       let badge = QualityBadgeStyle(highestIn: track.qualities) {
                        QualityBadge(style: badge)
                    }
                    if track.extras["mvId"]?.isEmpty == false {
                        IPadMVTag()
                    }
                }
                Text(track.singer)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Album (collapses below 720pt content width)
            if let album = track.albumName, !album.isEmpty {
                Text(album)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .frame(width: 200, alignment: .leading)
                    .layoutPriority(-1)
            }

            // Duration
            if let dur = track.duration {
                Text(formatDuration(dur))
                    .font(DS.Typo.numeric)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .frame(width: 52, alignment: .trailing)
            }

            Menu {
                trackActionItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.4)
        }
        .padding(.horizontal, 18)
        .frame(height: IPad.Layout.listRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? DS.Palette.brandStart.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering = $0 }
        // 长按菜单 — 给 LazyVStack 里的行补上 iPhone List 那种 trackRowSwipe 的长按入口。
        // iPad 上 LazyVStack 不支持 .swipeActions,所以长按 + 右边 "..." 菜单是两条等价的路径。
        .contextMenu { trackActionItems }
    }

    /// Same set of items used by both the "..." Menu and the long-press contextMenu —
    /// mirrors `TrackRowSwipe.contextMenu` on iPhone so users get the same toolkit
    /// regardless of device.
    @ViewBuilder
    private var trackActionItems: some View {
        Button { onAddToPlaylist(track) } label: { Label("收藏", systemImage: "heart") }
        Button { onDownload(track) } label: { Label("下载", systemImage: "arrow.down.circle") }
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

    private func formatDuration(_ sec: Int) -> String {
        String(format: "%d:%02d", sec / 60, sec % 60)
    }
}

/// "MV" tag — same visual as iPhone search row but tuned for the iPad list density.
struct IPadMVTag: View {
    var body: some View {
        Text("MV")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(DS.Palette.brandStart)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(DS.Palette.brandStart, lineWidth: 1)
            )
    }
}

// MARK: - "ContentMaxWidth" modifier

extension View {
    /// Cap content to `IPad.Layout.contentMaxWidth` and center it. Use on the
    /// detail-pane root so a 1366pt iPad Pro doesn't render rows that span the
    /// full width — anything wider than ~1280pt starts to feel like a website.
    func ipadContentWidth() -> some View {
        self
            .frame(maxWidth: IPad.Layout.contentMaxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
