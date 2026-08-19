import SwiftUI
import UIKit

struct PlayerView: View {
    /// 刻意不观察 PlaybackEngine:它的 currentTime 每 0.25 秒发布一次,一旦
    /// @EnvironmentObject 挂上,body 就每秒重建 4 次,播放中 / 关闭时都掉帧。
    /// 取指令走 AppServices.shared.playback(运行时取值,非观察);
    /// 展示字段走 NowPlayingBar 的低频镜像(只在换歌 / 播放状态变化时更新)。
    private var engine: PlaybackEngine? { AppServices.shared.playback }
    @ObservedObject private var now = NowPlayingBar.shared
    @EnvironmentObject var sources: SourceManager
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var sleepTimer: SleepTimer
    @ObservedObject private var downloads = DownloadStore.shared
    /// Called when the user dismisses the player via the left-edge swipe-back
    /// (唯一关闭方式)。Set by RootTabView's ZStack — we're no longer a
    /// modal, so `@Environment(\.dismiss)` doesn't apply.
    let onClose: () -> Void
    @StateObject private var artwork = ArtworkColors()
    @State private var showSleepSheet = false
    @State private var page: Int = 0  // 0 = cover, 1 = lyrics
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    @State private var loadingLyrics = false
    @State private var trackToFavorite: Track?
    @State private var trackToDownload: Track?
    @State private var showEQ = false
    /// MV (music video) sheet state. nil = closed, set = open with that info.
    @State private var mvInfo: MusicVideoInfo?
    /// Inflight indicator while we hit the per-source MV endpoint.
    @State private var loadingMv = false
    /// Toast-like message shown briefly after MV resolution fails / starts.
    @State private var mvNotice: String?
    /// 是否处于"已展开"。由 RootTabView 用动画驱动:true 时停在原位(swipeBackOffset
    /// 通常 0),false 时停靠在屏幕右缘外侧(x = 屏宽)。进出场都是纯 transform,
    /// SwiftUI 不会对本视图做快照过渡 —— 那正是关闭瞬间残留影的根因。
    @Binding var isOpen: Bool
    /// 左缘向右滑的横向位移。跟随手指,松开后要么飞向右侧关闭,要么弹回原位。
    @State private var swipeBackOffset: CGFloat = 0

    /// 进场弹簧(右缘滑入),与 RootTabView.openPlayer 手感一致。
    static let playerSpring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// 关闭弹簧(右缘滑出):比进场更短、阻尼更高,跟随手指滑出一段后收得干脆,
    /// 不会有拖尾或回弹感。
    static let playerCloseSpring = Animation.spring(response: 0.34, dampingFraction: 0.88)

    /// Shared selector — see `PlaybackCycleMode` in PlaybackEngine.swift.
    private var cycleMode: PlaybackCycleMode {
        PlaybackCycleMode.current(shuffle: now.shuffle, loop: now.loopMode)
    }

    var body: some View {
        // iPhone-only player. The iPad/Mac dual-pane layout used to live in
        // IPadPlayerView (now deleted); this app targets iOS / iPhone only.
        //
        // 不包 AnyView:AnyView 会抹掉底层视图的具名类型,SwiftUI 无法做差分,
        // 每个 0.25 秒的 currentTime 更新都会把整棵子树拆掉重建 —— 正好和开场
        // 的弹簧滑入动画抢主线程,表现为"从迷你播放器点开时严重掉帧"。去掉后
        // SwiftUI 能复用不变的子视图(封面/背景/控制条),只更新真正变化的叶子。
        compactBody
    }

    private var compactBody: some View {
        ZStack {
            // Backdrop fills the entire ZStack — `.ignoresSafeArea` here
            // (rather than on PlayerView in RootTabView) makes sure the
            // gradient extends behind status bar + home indicator, not just
            // to safe-area bounds. Without this the bottom of the screen
            // showed the underlying TabBar peeking through during transitions.
            PlayerBackdrop(primary: artwork.primary, secondary: artwork.secondary)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                TabView(selection: $page) {
                    coverPage.tag(0)
                    lyricsPage.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)

                pageDots
                    .padding(.bottom, DS.Spacing.s)

                progressSection
                controlSection
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, DS.Spacing.l)
            // Cap the working width on iPad / large iPhones — the backdrop
            // still spans edge to edge for that "we own the screen" feel, but
            // controls stay reachable instead of stretching across a tablet.
            .frame(maxWidth: 520)
        }
        // Force the player to claim the full screen. Without an explicit fill,
        // ZStack sized itself to the intrinsic content height — making the
        // backdrop short AND triggering SwiftUI to recalculate layout mid-
        // transition, which manifested as the cover "jittering" during slide-up.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 刻意不挂 .preferredColorScheme(.dark):本播放器是 RootTabView 同一 UIWindow
        // 内的全屏子视图,在根视图强制深色会把整窗(含系统 UITabBar)的 trait 带成
        // 深色 —— 表现为"打开播放器整窗变黑、排行榜底部 tab 变透明",卸载后恢复。
        // 播放器本身用显式白字 + 不透明黑背景(PlayerBackdrop),移除强制深色后仍是
        // 暗色外观,却不再污染整窗。内部依赖 scheme 的玻璃材质已改为显式深色填充。
        // 关闭方式统一为一种:左缘向右滑(edge swipe-back)。收起状态固定停靠在
        // 屏幕右缘外侧 (x = 屏宽),打开时从右缘滑入 —— 整个播放器像"右缘的下一页",
        // 与右滑关闭的手势方向天然一致。
        .offset(x: isOpen ? swipeBackOffset : UIScreen.main.bounds.width, y: 0)
        // 左缘向右滑关闭,像 iOS NavigationStack 的返回手势。只在拖动起点落在左缘
        // 24pt 内且横向位移大于纵向时激活 —— 否则会跟封面的 cover ↔ 歌词 横向翻页
        // 冲突。拖过 100pt 或甩得够快就关闭,否则弹回。
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    let startedAtEdge = v.startLocation.x < 24
                    let mostlyHorizontal = abs(v.translation.width) > abs(v.translation.height)
                    if (startedAtEdge && mostlyHorizontal) || swipeBackOffset > 0 {
                        swipeBackOffset = max(0, v.translation.width)
                    }
                }
                .onEnded { v in
                    if swipeBackOffset > 100 || v.predictedEndTranslation.width > 200 {
                        onClose()
                    } else {
                        withAnimation(DS.Motion.standard) { swipeBackOffset = 0 }
                    }
                }
        )
        .onAppear {
            sync()
        }
        // isOpen 翻成 false(关闭)时把拖动残余量归零:这样既不影响"从当前拖动位置
        // 向右滑出"的动画(关闭瞬间 offset 已是屏宽,忽略 swipeBackOffset),又能
        // 保证随后若快速重开时从干净位置(0)滑入,不会卡在半路。
        .shOnChange(of: isOpen) {
            if !isOpen { swipeBackOffset = 0 }
        }
        .shOnChange(of: now.track?.id) { sync() }
        // All sheets below are forced back to the system's real color scheme +
        // re-injected with the brand tint. Both default-inherit through SwiftUI
        // ancestors, but `.preferredColorScheme` re-roots the sheet so we lose
        // the `.tint(Color("AccentColor"))` set by shuhaoApp — without
        // putting it back, Toggle/Picker/system controls fall back to iOS green.
        .sheet(isPresented: $showQueue) {
            QueueView()
                .inheritedAppearance()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $trackToFavorite) { track in
            AddToPlaylistSheet(track: track)
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $trackToDownload) { track in
            DownloadSheet(track: track)
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .inheritedAppearance()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEQ) {
            // EQView uses navigationTitle, so wrap in its own NavigationStack —
            // PlayerView's fullScreenCover doesn't provide one.
            NavigationStack { EQView() }
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        // MV uses fullScreenCover (not sheet) — video benefits from edge-to-edge,
        // and the user explicitly opted into "watch a video", not a peek.
        .fullScreenCover(item: $mvInfo) { info in
            if let track = now.track, let e = engine {
                // fullScreenCover 启的是新展示上下文,@EnvironmentObject 不会自动
                // 跨边界继承(Catalyst 上必崩),手动把 MvPlayerView 用到的注回去。
                MvPlayerView(info: info, track: track, onClose: { mvInfo = nil })
                    .environmentObject(e)
            }
        }
        .overlay(alignment: .top) {
            if let mvNotice {
                Text(mvNotice)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: mvNotice)
    }

    /// Triggered from the ⋯ menu's "播放 MV" item. Hits the per-source MV
    /// endpoint; on success opens MvPlayerView, otherwise flashes a toast.
    private func fetchMv() {
        guard let track = now.track else { return }
        loadingMv = true
        showFlash("正在获取 MV…")
        Task {
            let info = await MvResolver.getMvUrl(for: track)
            await MainActor.run {
                loadingMv = false
                if let info, info.bestUrl() != nil {
                    mvNotice = nil
                    mvInfo = info
                } else {
                    showFlash("暂无可用 MV")
                }
            }
        }
    }

    /// Show a transient banner that auto-clears after 1.8 s. Replaces any active
    /// banner so taps in rapid succession don't queue up.
    private func showFlash(_ text: String) {
        mvNotice = text
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                if mvNotice == text { mvNotice = nil }
            }
        }
    }

    private func sync() {
        artwork.extract(from: now.track.flatMap { downloads.displayCoverURL(for: $0) })
        lyrics = []
        guard let track = now.track else { return }
        loadingLyrics = true
        Task {
            let lines = await LyricsFetcher.shared.fetch(for: track, sources: sources)
            await MainActor.run {
                self.lyrics = lines
                self.loadingLyrics = false
            }
        }
    }

    // MARK: - Top bar

    /// Dismissal is driven by the left-edge swipe-back gesture (see `simultaneousGesture`
    /// on body), so no chevron is needed. The center shows source/quality/origin only when
    /// `settings.showDebugNotices` is on. The right side carries a chrome-less "⋯"
    /// menu — anchored where every iOS music app puts secondary actions.
    private var topBar: some View {
        ZStack {
            if settings.showDebugNotices {
                HStack(spacing: 5) {
                    Text(now.track?.source.displayName ?? "")
                        .font(DS.Typo.bodyStrong)
                        .foregroundColor(.white)
                    if let q = engine?.displayQuality {
                        Text(QualityBadgeStyle(quality: q).label)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(Color.white.opacity(0.75), lineWidth: 1)
                            )
                    }
                    if let origin = now.currentOrigin {
                        HStack(spacing: 3) {
                            Image(systemName: origin.iconName).font(.system(size: 9, weight: .bold))
                            Text(origin.displayLabel).font(.system(size: 10, weight: .semibold))
                        }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    // 显式深色填充(不依赖 .preferredColorScheme):移除了根视图的强制
                    // 深色后,DS.Glass.thin 在浅色 scheme 下会偏亮;这里用半透明黑保证
                    // 在任意 scheme 下都呈暗色胶囊,与原来深色玻璃观感一致。
                    .background(.black.opacity(0.28), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    }
                }
            }
            HStack {
                Spacer()
                AirPlayButton()
                    .frame(width: 36, height: 36)
                Menu {
                    Button { if let t = now.track { trackToFavorite = t } } label: {
                        Label("收藏", systemImage: "heart")
                    }
                    Button { if let t = now.track { trackToDownload = t } } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                    Divider()
                    Button { showEQ = true } label: {
                        Label("均衡器", systemImage: "slider.vertical.3")
                    }
                    Button { fetchMv() } label: {
                        if loadingMv {
                            Label("正在获取 MV…", systemImage: "play.rectangle")
                        } else {
                            Label("播放 MV", systemImage: "play.rectangle")
                        }
                    }
                    .disabled(loadingMv || now.track == nil)
                    Button { showSleepSheet = true } label: {
                        // Active timer shows its label so the user can see what's armed at a glance.
                        switch sleepTimer.mode {
                        case .duration:
                            Label("睡眠 · \(sleepTimer.countdownText ?? "")", systemImage: "moon.zzz.fill")
                        case .endOfTrack:
                            Label("睡眠 · 当前歌曲结束", systemImage: "moon.zzz.fill")
                        case .none:
                            Label("睡眠定时", systemImage: "moon.zzz")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .frame(width: 44, height: 36)   // generous hit area, no visible chrome
                        .contentShape(Rectangle())
                }
                .disabled(now.track == nil)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .padding(.top, 8)
    }


    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { i in
                let on = page == i
                Capsule()
                    .fill(on
                          ? AnyShapeStyle(DS.Palette.brandGradient)
                          : AnyShapeStyle(Color.white.opacity(0.25)))
                    .frame(width: on ? 22 : 8, height: 4)
                    .animation(DS.Motion.standard, value: page)
            }
        }
    }

    // MARK: - Cover page

    private var coverPage: some View {
        VStack(spacing: 0) {
            Spacer()
            // Album art + title/subtitle wrapped in one id'd container so SwiftUI
            // crossfades the whole "track identity" block when the song changes,
            // instead of hard-cutting on each property update. Scale on the way in
            // gives a tiny "rise" — feels like the new song settled into place.
            ZStack {
                if let track = now.track {
                    VStack(spacing: 0) {
                        Artwork(url: downloads.displayCoverURL(for: track), size: 320, radius: DS.Radius.xlarge)
                            .elevation(DS.Elevation.e3(artwork.primary))
                            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                            .scaleEffect(now.isPlaying ? 1.0 : 0.92)
                            .animation(DS.Motion.emphasis, value: now.isPlaying)

                        VStack(spacing: 6) {
                            Text(track.name)
                                .font(DS.Typo.title)
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(track.subtitle)
                                .font(DS.Typo.body)
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                            // 角标(按实测校正后的档位)+ 文件头实测规格 — 角标在前。
                            // 背景是封面动态色,用白描边白字而非 QualityBadge 的彩色 tint,
                            // 避免和大色块对比度不够。任一存在就显示这一行。
                            if engine?.displayQuality != nil || now.currentAudioSpec != nil {
                                HStack(spacing: 6) {
                                    if let q = engine?.displayQuality {
                                        Text(QualityBadgeStyle(quality: q).label)
                                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                    .stroke(Color.white.opacity(0.75), lineWidth: 1)
                                            )
                                    }
                                    if let spec = now.currentAudioSpec {
                                        Text(spec.displayText)
                                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                                            .foregroundColor(.white.opacity(0.5))
                                            .monospacedDigit()
                                    }
                                }
                                .transition(.opacity)
                            }
                        }
                        .padding(.top, DS.Spacing.xl)
                        .animation(DS.Motion.standard, value: now.currentAudioSpec)
                        .animation(DS.Motion.standard, value: engine?.displayQuality)
                    }
                    .id(track.id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .opacity
                    ))
                }
            }
            .animation(DS.Motion.standard, value: now.track?.id)

            AudioWave(active: now.isPlaying && !now.isBuffering)
                .frame(height: 68)
                .padding(.horizontal, 4)
                .padding(.top, DS.Spacing.l)
            Spacer()
        }
        .offset(y: -18)
    }

    // MARK: - Lyrics page

    private var lyricsPage: some View {
        LyricsPageView(lines: lyrics, loading: loadingLyrics, onSeek: { engine?.seek(to: $0) })
    }

    // MARK: - Progress section

    private var progressSection: some View {
        ProgressSectionView()
    }

    // MARK: - Controls

    /// Bottom control row. Cycle mode (left) is the combined shuffle/loop selector;
    /// list.bullet (right) opens the playback queue — both used to live in TopBar.
    ///
    /// Secondary buttons all use `cassetteBody.opacity(0.5)` so they share the warm
    /// palette of the main play button + slider thumb but read as supporting cast
    /// rather than competing for attention.
    private var controlSection: some View {
        let secondaryTint = DS.Palette.cassetteBody.opacity(0.5)
        return HStack {
            Button {
                if let e = engine { cycleMode.advanced().apply(to: e) }
            } label: {
                Image(systemName: cycleMode.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(secondaryTint)
            }
            Spacer()
            Button { engine?.previous() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(secondaryTint)
            }
            Spacer()
            Button { engine?.togglePlayPause() } label: {
                ZStack {
                    // Warm beige disc echoes the cassette body in the app icon —
                    // pressing it feels like pressing a cassette key. Glyph is
                    // the deep burgundy half of brand, not the gradient, so the
                    // small triangle reads as a single solid color (gradient at
                    // this size just smears into "dark blob").
                    Circle().fill(DS.Palette.cassetteBody)
                        .frame(width: 76, height: 76)
                        .shadow(color: artwork.primary.opacity(0.55), radius: 22, y: 8)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    if now.isBuffering {
                        UIKitSpinner(style: .medium, color: UIColor(DS.Palette.brandStart))
                    } else {
                        // Top→bottom burgundy → brass mini-gradient gives the
                        // glyph a subtle "metal-warmed" feel, and 0.85 opacity
                        // lets the beige disc bleed through a bit so the
                        // triangle/pause bars don't punch as hard.
                        Image(systemName: now.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        DS.Palette.brandStart.opacity(0.85),
                                        DS.Palette.brandEnd.opacity(0.85)
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .offset(x: now.isPlaying ? 0 : 2)
                    }
                }
            }
            Spacer()
            Button { engine?.next() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(secondaryTint)
            }
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(secondaryTint)
            }
        }
    }

}

// MARK: - 进度条(独立订阅 4Hz,不牵连整页)

/// 只订阅 PlaybackTicker 的 currentTime/duration,自己每 0.25 秒刷新,
/// 不观察 PlaybackEngine。进度条更新不会触发整个 PlayerView 重绘,
/// 封面/背景/控制条等重视图在播放期间保持稳定,开场滑入也不卡。
private struct ProgressSectionView: View {
    /// 同 PlayerView:不观察 PlaybackEngine,只经 AppServices 取指令,4Hz 进度走 clock。
    private var engine: PlaybackEngine? { AppServices.shared.playback }
    @ObservedObject private var clock = PlaybackTicker.shared
    @State private var isSeeking: Bool = false
    @State private var seekValue: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            ProgressSlider(
                value: Binding(
                    get: { isSeeking ? seekValue : clock.currentTime },
                    set: { seekValue = $0; isSeeking = true }
                ),
                in: 0...max(clock.duration, 1),
                onChangeBegan: { isSeeking = true },
                onChangeEnded: {
                    engine?.seek(to: seekValue)
                    isSeeking = false
                }
            )
            HStack {
                Text(format(time: isSeeking ? seekValue : clock.currentTime))
                Spacer()
                Text("-" + format(time: max(0, clock.duration - (isSeeking ? seekValue : clock.currentTime))))
            }
            .font(DS.Typo.numeric)
            // Same beige family as the thumb/transport row, kept very low
            // opacity so the time-readout sits in the background and the eye
            // lands on the cover + play button first.
            .foregroundStyle(DS.Palette.cassetteBody.opacity(0.36))
        }
        .padding(.bottom, DS.Spacing.l)
    }

    private func format(time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "00:00" }
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 歌词页(独立订阅 4Hz)

/// 只订阅 PlaybackTicker,歌词滚动的 4Hz 更新局限在 LyricsScroll 内部,
/// 不影响整页。loading/lines 由 PlayerView 经构造参数传入(低频变化)。
private struct LyricsPageView: View {
    let lines: [LyricLine]
    let loading: Bool
    let onSeek: (Double) -> Void
    @ObservedObject private var clock = PlaybackTicker.shared

    var body: some View {
        Group {
            if loading {
                UIKitSpinner(style: .medium, color: .white)
            } else if lines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.white.opacity(0.5))
                    Text("暂无歌词").foregroundColor(.white.opacity(0.7))
                }
            } else {
                LyricsScroll(lines: lines, currentTime: clock.currentTime, onTap: onSeek)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Audio rhythm wave

/// Horizontal flowing waveform: a few overlapping sine waves with different amplitude/wavelength/
/// speed/opacity (the varying opacity gives the depth look). Drifts while playing, freezes on pause.
///
/// If `level > 0` is supplied it overrides the synthetic "beat" envelope — the
/// waves then ride the *real* audio RMS sampled by `AudioLevelTap`. Falls back
/// to the synthetic beat when level isn't available (e.g. audio tap couldn't
/// install — happens on HLS or right at song-start before the asset loads).
struct AudioWave: View {
    var active: Bool
    var color: Color = .white
    /// 0…1, smoothed RMS。直接从独立的 AudioLevel 单例读取,避免 60Hz 更新波及其父视图
    /// (之前 audioLevel 挂在 PlaybackEngine 上,每秒几十次触发全 app 重绘、造成掉帧)。
    /// 0 means "use synthetic"。
    @ObservedObject private var audioLevel = AudioLevel.shared
    private var level: Float { audioLevel.value }

    // (baseAmp fraction, wavelength, drift speed, pulse speed, pulse phase, max opacity, line width)
    private let waves: [(amp: CGFloat, wl: CGFloat, drift: Double, pulse: Double, pPhase: Double, opacity: Double, width: CGFloat)] = [
        (1.00, 235, 0.70, 2.6, 0.0, 0.45, 1.3),
        (0.74, 165, 1.10, 3.4, 1.1, 0.85, 1.1),
        (0.52, 125, 1.65, 4.3, 2.4, 0.32, 0.9),
    ]

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height / 2
                let W = size.width
                for w in waves {
                    let pulse: Double
                    if level > 0.02 {
                        // Real-audio path: amplitude follows live RMS. Floor at
                        // 0.15 so the wave doesn't completely collapse during
                        // quiet passages.
                        pulse = max(0.15, Double(level))
                    } else {
                        // Synthetic fallback: two summed sines with a wide swing → snappy, music-like rise/fall
                        let beat = 0.5 + 0.38 * sin(t * w.pulse + w.pPhase) + 0.22 * sin(t * w.pulse * 1.9 + w.pPhase * 1.7)
                        pulse = max(0.08, beat)
                    }
                    // Clamp so the tallest peak always stays inside the view (no clipping). 0.92 leaves
                    // a little headroom for the line width on top of the half-height.
                    let amp = min(w.amp * CGFloat(pulse), 0.92) * size.height / 2
                    let phase = t * w.drift * 2.2
                    var path = Path()
                    var x: CGFloat = 0
                    func y(at x: CGFloat) -> CGFloat {
                        // envelope: 0 at both ends, 1 in the middle → all lines converge at the edges
                        let env = sin(Double(x / W) * .pi)
                        return midY + CGFloat(sin(Double(x / w.wl) * 2 * .pi + phase)) * amp * CGFloat(env)
                    }
                    path.move(to: CGPoint(x: 0, y: y(at: 0)))
                    while x <= W {
                        path.addLine(to: CGPoint(x: x, y: y(at: x)))
                        x += 2
                    }
                    // lighter at both ends, darker in the middle
                    let grad = Gradient(stops: [
                        .init(color: color.opacity(0), location: 0.0),
                        .init(color: color.opacity(w.opacity), location: 0.5),
                        .init(color: color.opacity(0), location: 1.0),
                    ])
                    ctx.stroke(path,
                               with: .linearGradient(grad,
                                                     startPoint: CGPoint(x: 0, y: midY),
                                                     endPoint: CGPoint(x: W, y: midY)),
                               lineWidth: w.width)
                }
            }
        }
    }
}

// MARK: - Custom progress slider

struct ProgressSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onChangeBegan: () -> Void
    var onChangeEnded: () -> Void

    init(value: Binding<Double>, in range: ClosedRange<Double>,
         onChangeBegan: @escaping () -> Void = {},
         onChangeEnded: @escaping () -> Void = {}) {
        self._value = value
        self.range = range
        self.onChangeBegan = onChangeBegan
        self.onChangeEnded = onChangeEnded
    }

    @State private var dragging = false
    @State private var lastWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let progress = max(0, min(1, (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)))
            let trackHeight: CGFloat = dragging ? 6 : 4
            let thumbSize: CGFloat = dragging ? 16 : 10
            let thumbX = geo.size.width * progress
            ZStack(alignment: .leading) {
                // Glass track (unfilled): white@18% capsule
                Capsule().fill(Color.white.opacity(0.18))
                    .frame(height: trackHeight)
                // Filled portion: brand gradient
                Capsule().fill(DS.Palette.brandGradient)
                    .frame(width: thumbX, height: trackHeight)
                // Thumb: half-opacity cassette beige — same warm palette as the
                // main play button, but soft enough to read as "secondary
                // control" rather than competing for the eye.
                Circle()
                    .fill(DS.Palette.cassetteBody.opacity(0.5))
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .offset(x: thumbX - thumbSize / 2)
            }
            .frame(height: 24, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { dragging = true; onChangeBegan() }
                        let x = max(0, min(geo.size.width, v.location.x))
                        let p = x / max(geo.size.width, 1)
                        value = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        dragging = false
                        onChangeEnded()
                    }
            )
            .animation(DS.Motion.micro, value: dragging)
            .onAppear { lastWidth = geo.size.width }
        }
        .frame(height: 24)
    }
}

// MARK: - Lyrics scroll

struct LyricsScroll: View {
    let lines: [LyricLine]
    let currentTime: Double
    let onTap: (Double) -> Void

    var body: some View {
        // Look slightly ahead so the highlighted line lands as the vocal reaches it, matching
        // the CarPlay / lock-screen behavior.
        let active = LRCParser.activeIndex(at: currentTime + LyricSync.leadSeconds, in: lines)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    Color.clear.frame(height: 80)
                    ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                        LyricRow(line: line, isCurrent: idx == active, activeBinding: active, onTap: onTap)
                    }
                    Color.clear.frame(height: 200)
                }
                .padding(.horizontal, DS.Spacing.l)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.15),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .shOnChange(of: active) {
                if let active {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        proxy.scrollTo(lines[active].id, anchor: .center)
                    }
                }
            }
        }
    }
}

/// Single lyric row. Extracted from the ForEach body because Swift's type checker
/// times out on the inline conditional `AnyShapeStyle(...)` ternary.
private struct LyricRow: View {
    let line: LyricLine
    let isCurrent: Bool
    let activeBinding: Int?
    let onTap: (Double) -> Void

    private var foreground: AnyShapeStyle {
        isCurrent
            ? AnyShapeStyle(DS.Palette.brandGradient)
            : AnyShapeStyle(Color.white.opacity(0.42))
    }

    private var translationColor: Color {
        isCurrent ? .white.opacity(0.85) : .white.opacity(0.32)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(isCurrent ? DS.Typo.lyricBig : DS.Typo.lyricSmall)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .scaleEffect(isCurrent ? 1.0 : 0.94)
                .animation(DS.Motion.lyric, value: activeBinding)
            if let tr = line.translation, !tr.isEmpty {
                Text(tr)
                    .font(.system(size: isCurrent ? 14 : 12))
                    .foregroundColor(translationColor)
            }
        }
        .frame(maxWidth: .infinity)
        .id(line.id)
        .contentShape(Rectangle())
        .onTapGesture {
            if line.time >= 0 { onTap(line.time) }
        }
    }
}
