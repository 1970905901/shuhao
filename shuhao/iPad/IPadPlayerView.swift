import SwiftUI
import UIKit

// MARK: - iPad / Mac full-screen player
struct IPadPlayerView: View {
    let onClose: () -> Void

    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var sources: SourceManager
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var sleepTimer: SleepTimer
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var eq: EQStore
    @StateObject private var artwork = ArtworkColors()

    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var showQueue = false
    @State private var showEQ = false
    @State private var showSleepSheet = false
    @State private var trackToFavorite: Track?
    @State private var trackToDownload: Track?
    @State private var lyrics: [LyricLine] = []
    @State private var loadingLyrics = false
    private var cycleMode: PlaybackCycleMode {
        PlaybackCycleMode.current(shuffle: playback.shuffle, loop: playback.loopMode)
    }

    // MARK: - Mac Catalyst 精准判定
    private var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        ZStack {
            PlayerBackdrop(primary: artwork.primary, secondary: artwork.secondary)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                HStack(alignment: .top, spacing: 36) {
                    leftPane
                    rightPane
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 24)
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            extractColors()
            loadLyrics()
        }
        .shOnChange(of: playback.currentTrack?.id) {
            extractColors()
            loadLyrics()
        }
        // 弹窗:Mac → .popover(点外面/Esc 关,跟设置弹窗一致,env objects 显式透传),
        // iPad → .sheet 不变。
        #if targetEnvironment(macCatalyst)
        .popover(isPresented: $showQueue) {
            NavigationStack { QueueView() }
                .environmentObject(playback)
                .frame(width: 480, height: 640)
        }
        .popover(isPresented: $showEQ) {
            NavigationStack { EQView() }
                .environmentObject(eq)
                .frame(width: 480, height: 640)
        }
        .popover(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .environmentObject(sleepTimer)
                .frame(width: 420, height: 520)
        }
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
        .sheet(isPresented: $showQueue) {
            NavigationStack { QueueView() }
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEQ) {
            NavigationStack { EQView() }
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $trackToFavorite) { t in
            AddToPlaylistSheet(track: t)
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $trackToDownload) { t in
            DownloadSheet(track: t)
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        #endif
    }

    // MARK: - Top bar 动态视图适配
    private var iconTint: Color { DS.Palette.cassetteBody.opacity(0.85) }
    private var iconBorder: Color { DS.Palette.cassetteBody.opacity(0.22) }

    private var topBar: some View {
        HStack(spacing: 14) {
            if isMacCatalyst {
                // 【Mac Catalyst 模式】：左侧留空，控件全部靠右，收起键在最右侧
                Spacer()
                airPlayButton
                menuButton
                closeButton
            } else {
                // 【iPad 原生模式】：维持经典两端分布，收起键在左侧
                closeButton
                Spacer()
                airPlayButton
                menuButton
            }
        }
    }

    // MARK: - 顶栏独立组件
    
    /// 收起/下拉按钮
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(iconBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("收起")
    }

    /// AirPlay / 输出设备选择
    private var airPlayButton: some View {
        AirPlayButton(tint: UIColor(iconTint))
            .frame(width: 38, height: 38)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(iconBorder, lineWidth: 0.5))
            .help("AirPlay")
    }

    /// 更多菜单按钮
    private var menuButton: some View {
        Menu {
            Button { if let t = playback.currentTrack { trackToFavorite = t } } label: {
                Label("收藏", systemImage: "heart")
            }
            Button { if let t = playback.currentTrack { trackToDownload = t } } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
            Divider()
            Button { showEQ = true } label: {
                Label("均衡器", systemImage: "slider.vertical.3")
            }
            Button { showSleepSheet = true } label: {
                Label("睡眠定时", systemImage: "moon.zzz")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(iconBorder, lineWidth: 0.5))
        }
        .disabled(playback.currentTrack == nil)
    }

    // MARK: - Left pane (cover + meta + controls)
    private var playProgress: Double {
        guard playback.duration > 0 else { return 0 }
        return max(0, min(1, playback.currentTime / playback.duration))
    }

    private var leftPane: some View {
        VStack(spacing: 22) {
            GeometryReader { geo in
                let available = min(geo.size.width, geo.size.height) - 24
                let discSize = max(280, min(available, 520))
                ZStack {
                    if let track = playback.currentTrack {
                        IPadVinylDisc(
                            imageURL: downloads.displayCoverURL(for: track),
                            isPlaying: playback.isPlaying,
                            vinylTint: saturatedTint(artwork.primary),
                            size: discSize,
                            progress: playProgress
                        )
                        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: track.id)
                        .animation(.linear(duration: 0.5), value: playProgress)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(maxWidth: 520, maxHeight: 520)
            .aspectRatio(1, contentMode: .fit)

            if let track = playback.currentTrack {
                VStack(spacing: 8) {
                    Text(track.name)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Palette.cassetteBody)
                        .lineLimit(1)
                    Text(track.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.cassetteBody.opacity(0.65))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle().fill(track.source.tint).frame(width: 6, height: 6)
                            Text(track.source.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DS.Palette.cassetteBody.opacity(0.85))
                        }
                        // 只显示实际播放音质(同 iPhone) — 解析出 URL 前不显示,
                        // 避免占位的"名义最高音质"和最终实际音质不一致误导用户。
                        if let q = playback.displayQuality {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Palette.cassetteBody.opacity(0.45))
                            QualityBadge(style: QualityBadgeStyle(quality: q))
                        }
                        // 文件头实测规格(位深/采样率/码率),不信任后端声称的档位。
                        if let spec = playback.currentAudioSpec {
                            Text(spec.displayText)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(DS.Palette.cassetteBody.opacity(0.6))
                                .monospacedDigit()
                        }
                        if track.extras["mvId"]?.isEmpty == false {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Palette.cassetteBody.opacity(0.45))
                            IPadMVTag()
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 560)
    }

    private func saturatedTint(_ color: Color) -> Color {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.25 || b < 0.20 {
            return DS.Palette.brandStart
        }
        return Color(UIColor(hue: h, saturation: min(s * 1.3, 1.0), brightness: max(b, 0.55), alpha: 1))
    }

    // MARK: - Right pane (lyrics)
    private var rightPane: some View {
        Group {
            if loadingLyrics {
                VStack {
                    Spacer()
                    UIKitSpinner(style: .medium, color: UIColor(DS.Palette.cassetteBody))
                    Spacer()
                }
            } else if lyrics.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(DS.Palette.cassetteBody.opacity(0.45))
                    Text("暂无歌词")
                        .foregroundStyle(DS.Palette.cassetteBody.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                LyricsScroll(
                    lines: lyrics,
                    currentTime: playback.currentTime,
                    onTap: { time in playback.seek(to: time) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(DS.Palette.cassetteBody.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(DS.Palette.cassetteBody.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Progress + controls
    private var progressBlock: some View {
        VStack(spacing: 6) {
            ProgressSlider(
                value: Binding(
                    get: { isSeeking ? seekValue : playback.currentTime },
                    set: { seekValue = $0; isSeeking = true }
                ),
                in: 0...max(playback.duration, 1),
                onChangeBegan: { isSeeking = true },
                onChangeEnded: {
                    playback.seek(to: seekValue)
                    isSeeking = false
                }
            )
            HStack {
                Text(format(time: isSeeking ? seekValue : playback.currentTime))
                Spacer()
                Text(format(time: playback.duration))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var controlBlock: some View {
        let secondaryTint = Color.white.opacity(0.7)
        return HStack {
            Button {
                cycleMode.advanced().apply(to: playback)
            } label: {
                Image(systemName: cycleMode.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(cycleMode == .sequence ? secondaryTint : Color.white)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { playback.previous() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(secondaryTint)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { playback.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(DS.Palette.brandGradient)
                        .frame(width: 72, height: 72)
                        .shadow(color: DS.Palette.brandStart.opacity(0.55), radius: 18, y: 8)
                    if playback.isBuffering {
                        UIKitSpinner(style: .medium, color: .white)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundStyle(.white)
                            .offset(x: playback.isPlaying ? 0 : 1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button { playback.next() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(secondaryTint)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(secondaryTint)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers
    private func extractColors() {
        guard let track = playback.currentTrack,
              let pic = downloads.displayCoverURL(for: track) else { return }
        artwork.extract(from: pic)
    }

    private func loadLyrics() {
        lyrics = []
        guard let track = playback.currentTrack else { return }
        loadingLyrics = true
        Task {
            let lines = await LyricsFetcher.shared.fetch(for: track, sources: sources)
            await MainActor.run {
                if playback.currentTrack?.id == track.id {
                    lyrics = lines
                    loadingLyrics = false
                }
            }
        }
    }

    private func format(time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
