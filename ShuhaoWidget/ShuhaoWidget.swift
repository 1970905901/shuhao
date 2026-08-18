import WidgetKit
import SwiftUI
import AppIntents

/// "Now Playing / Resume" home-screen widget.
///
/// State machine:
///   - 正在播放 (or paused mid-track): cover + title + artist + transport
///   - 队列空但有最近记录: 最近一首封面 + "继续播放" CTA
///   - 完全没数据: 引导文案 + 跳 App
///
/// AppIntent buttons → Darwin notification → main app's CommandBridge → engine.
/// Widgets reload on every track change because the main app calls
/// `WidgetCenter.reloadAllTimelines()` from RecentTracksRecorder.

private let brandStart = Color(red: 1.00, green: 0.48, blue: 0.27)  // #FF7A45
private let brandEnd   = Color(red: 1.00, green: 0.24, blue: 0.35)  // #FF3D5A
private let brandGradient = LinearGradient(
    colors: [brandStart, brandEnd],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

// MARK: - Entry / Provider

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let nowPlaying: SharedNowPlaying?
    let mostRecent: SharedRecentTrack?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), nowPlaying: nil, mostRecent: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // Single entry — we rely on the app calling reloadAllTimelines on every
        // play/pause/track change. The .after refresh is just a long fallback.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [currentEntry()], policy: .after(next)))
    }

    private func currentEntry() -> NowPlayingEntry {
        NowPlayingEntry(
            date: Date(),
            nowPlaying: SharedNowPlayingStore.read(),
            mostRecent: SharedRecentStore.read().first
        )
    }
}

// MARK: - Widget

struct ShuhaoWidget: Widget {
    let kind: String = "ShuhaoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    ZStack {
                        Color(red: 0.04, green: 0.02, blue: 0.07)  // bgBase
                        brandGradient.opacity(0.18)
                    }
                }
        }
        .configurationDisplayName("正在播放")
        .description("一眼看到当前歌曲并直接控制播放")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryRectangular, .accessoryCircular])
    }
}

// MARK: - Root view

private struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemMedium:         medium
        case .accessoryRectangular: accessoryRect
        case .accessoryCircular:    accessoryCirc
        default:                    small
        }
    }

    // MARK: - systemSmall (2×2)
    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Big cover stacks above title; uses available data preferentially.
            if let np = entry.nowPlaying {
                cover(title: np.title, path: np.coverLocalPath, size: 72)
                // Title always shown; second line is the live lyric when
                // available (Apple Music-style), otherwise the artist.
                titleSecondary(title: np.title,
                               secondary: np.currentLyric ?? np.artist,
                               isLyric: np.currentLyric != nil)
                Spacer(minLength: 0)
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(brandGradient)
                        .padding(8)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else if let recent = entry.mostRecent {
                cover(title: recent.title, path: recent.coverLocalPath, size: 72)
                titleArtist(title: recent.title, artist: recent.artist)
                Spacer(minLength: 0)
                Button(intent: PlayRecentIntent()) {
                    Label("继续播放", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(brandGradient, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                emptyState
            }
        }
    }

    // MARK: - systemMedium (4×2) — cover + meta + 3 transport buttons
    private var medium: some View {
        HStack(spacing: 12) {
            // Cover anchored left at a bigger size — this widget's whole reason
            // for existing is "I want to see what's playing".
            let primary = entry.nowPlaying.map { (title: $0.title, path: $0.coverLocalPath) }
                ?? entry.mostRecent.map { (title: $0.title, path: $0.coverLocalPath) }
            if let primary {
                cover(title: primary.title, path: primary.path, size: 88)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("正在播放")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(brandGradient)
                if let np = entry.nowPlaying {
                    titleArtist(title: np.title, artist: np.artist, titleSize: 14)
                    if let lyric = np.currentLyric, !lyric.isEmpty {
                        // Live lyric line under the artist when the song has lyrics.
                        // Brand gradient + medium weight so it reads as "what's
                        // playing right now" rather than just another caption.
                        Text(lyric)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(brandGradient)
                            .lineLimit(1)
                    }
                    progressBar(elapsed: np.projectedElapsed(), duration: np.duration)
                        .padding(.top, 2)
                    transportRow(isPlaying: np.isPlaying)
                        .padding(.top, 6)
                } else if let recent = entry.mostRecent {
                    titleArtist(title: recent.title, artist: recent.artist, titleSize: 14)
                    Button(intent: PlayRecentIntent()) {
                        Label("继续播放", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(brandGradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                } else {
                    emptyState
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Lock-screen accessory (rectangular)
    private var accessoryRect: some View {
        let np = entry.nowPlaying
        let label = np?.title ?? entry.mostRecent?.title ?? "暂无播放"
        // Prefer live lyric, fall back to artist
        let sub = np?.currentLyric ?? np?.artist ?? entry.mostRecent?.artist ?? "打开 shuhao 听歌"
        return HStack(spacing: 6) {
            Image(systemName: np?.isPlaying == true ? "waveform" : "music.note")
                .font(.system(size: 14, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(sub)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .widgetAccentable()
    }

    // MARK: - Lock-screen accessory (circular)
    private var accessoryCirc: some View {
        let isPlaying = entry.nowPlaying?.isPlaying == true
        return ZStack {
            AccessoryWidgetBackground()
            Image(systemName: isPlaying ? "waveform" : "music.note")
                .font(.system(size: 18, weight: .bold))
        }
        .widgetAccentable()
    }

    // MARK: - Subviews

    private func titleArtist(title: String, artist: String, titleSize: CGFloat = 13) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(artist)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    /// Title + a single configurable second line. When the second line is a
    /// lyric, render it with the brand gradient so it's distinguishable from
    /// "artist" at a glance.
    private func titleSecondary(title: String, secondary: String, isLyric: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if isLyric {
                Text(secondary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(brandGradient)
                    .lineLimit(1)
            } else {
                Text(secondary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    private func transportRow(isPlaying: Bool) -> some View {
        HStack(spacing: 16) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            Button(intent: PlayPauseIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(brandGradient)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 22))
                .foregroundStyle(brandGradient)
            Text("还没有播放记录")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("打开 shuhao 听歌")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func cover(title: String, path: String?, size: CGFloat) -> some View {
        let firstChar = title.first.map(String.init) ?? "♪"
        let shape = RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
        shape
            .fill(brandGradient)
            .frame(width: size, height: size)
            .overlay {
                Text(firstChar)
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            .overlay {
                if let path, let img = UIImage(contentsOfFile: path) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(shape)
                }
            }
    }

    @ViewBuilder
    private func progressBar(elapsed: Double, duration: Double) -> some View {
        let progress = duration > 0 ? max(0, min(1, elapsed / duration)) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(brandGradient)
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 3)
    }
}

#Preview(as: .systemSmall) {
    ShuhaoWidget()
} timeline: {
    NowPlayingEntry(date: .now,
        nowPlaying: SharedNowPlaying(trackID: "kw_xx", title: "黄昏", artist: "周传雄",
            coverLocalPath: nil, isPlaying: true, elapsed: 80, duration: 343,
            currentLyric: "过完整个夏天 忧伤并没有好一些",
            updatedAt: .now),
        mostRecent: nil)
}

#Preview(as: .systemMedium) {
    ShuhaoWidget()
} timeline: {
    NowPlayingEntry(date: .now,
        nowPlaying: SharedNowPlaying(trackID: "kw_xx", title: "黄昏", artist: "周传雄",
            coverLocalPath: nil, isPlaying: true, elapsed: 80, duration: 343,
            currentLyric: "过完整个夏天 忧伤并没有好一些",
            updatedAt: .now),
        mostRecent: nil)
}
