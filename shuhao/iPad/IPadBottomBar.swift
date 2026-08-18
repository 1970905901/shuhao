import SwiftUI

// MARK: - iPad / Mac bottom playback bar
//
// 只占右侧内容区(不覆盖左 sidebar)。布局参考 QQ 音乐桌面端 :
//
//   ┌─────────────────────────────────────────────────────────────────┐
//   │ [cover]  Song name  [Hi-Res]   ❤   ⏮  ●▶  ⏭   🔁  📋  词       │
//   │          singer                                                  │
//   │  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 02:09 ── 04:09        │
//   └─────────────────────────────────────────────────────────────────┘
//
// 整体 92pt 高(上排 72pt + 进度条 20pt),`.regularMaterial` 背景 + 顶部 0.5pt 分隔线。

struct IPadBottomBar: View {
    @EnvironmentObject var playback: PlaybackEngine
    @ObservedObject private var downloads = DownloadStore.shared
    var onOpenPlayer: () -> Void
    /// True when the full-screen player is open above this bar. Used to hide
    /// the cover thumbnail (since the big vinyl already shows the artwork)
    /// while keeping the rest of the bar in place.
    var compactMode: Bool = false

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showQueue = false
    @State private var volumeBeforeMute: Float = 0.7

    // MV state — owned here so the bar can present its own fullScreenCover and
    // doesn't depend on PlayerView being visible.
    @State private var mvInfo: MusicVideoInfo?
    @State private var mvNotice: String?
    @State private var loadingMv = false

    private var hasTrack: Bool { playback.currentTrack != nil }
    /// True when the catalog flagged the current track as having an MV. The
    /// resolver may still 404 (especially Kuwo's anti.s), but this is the
    /// best up-front indicator we have for showing the badge / button.
    private var hasMv: Bool {
        (playback.currentTrack?.extras["mvId"]).flatMap { $0.isEmpty ? nil : $0 } != nil
    }

    /// Three-state cycle mode (顺序 / 单曲 / 随机) for the loop button.
    private var cycleMode: PlaybackCycleMode {
        PlaybackCycleMode.current(shuffle: playback.shuffle, loop: playback.loopMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            progressRow
        }
        .frame(height: 92)
        .background(.regularMaterial)
        .overlay(
            // 顶部细线 — 跟内容区做明确视觉分隔
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5),
            alignment: .top
        )
        // 播放队列 — Mac → .popover(点外面/Esc 关,跟设置弹窗一致);iPad → .sheet,
        // large detent only(默认半屏太矮看不到几首歌)。
        #if targetEnvironment(macCatalyst)
        .popover(isPresented: $showQueue) {
            NavigationStack { QueueView() }
                .environmentObject(playback)
                .frame(width: 480, height: 640)
        }
        #else
        .sheet(isPresented: $showQueue) {
            NavigationStack { QueueView() }
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
        }
        #endif
        // MV player presented as full-screen — video deserves edge-to-edge.
        .fullScreenCover(item: $mvInfo) { info in
            if let track = playback.currentTrack {
                // fullScreenCover 启的是新展示上下文,@EnvironmentObject 不会自动
                // 跨边界继承(Catalyst 上必崩),手动把 MvPlayerView 用到的注回去。
                MvPlayerView(info: info, track: track, onClose: { mvInfo = nil })
                    .environmentObject(playback)
            }
        }
        // Toast for "正在获取 MV…" / "暂无可用 MV". Floats over the bar so it
        // doesn't reflow the layout.
        .overlay(alignment: .top) {
            if let mvNotice {
                Text(mvNotice)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                    .offset(y: -36)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: mvNotice)
    }

    // MARK: - Top row

    private var mainRow: some View {
        // 中间 transport 真正居中 — 左右两侧等宽,避免之前 trackInfo(320pt)
        // 跟 rightTools(200pt minWidth)宽度不对称导致中间按钮偏右。
        HStack(spacing: 16) {
            // 打开全屏播放器的热区只有左侧歌曲信息区(含右边的空白) ——
            // 中间 prev/play/next 和音量往右的工具区误触太烦,不参与。
            trackInfo
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onOpenPlayer() }
            transport
            // 下一首和音量之间的空白也可点开播放器;rightTools 本身(音量往右)不参与。
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenPlayer() }
                rightTools
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
    }

    @ViewBuilder
    private var trackInfo: some View {
        if let track = playback.currentTrack {
            Button(action: onOpenPlayer) {
                HStack(spacing: 12) {
                    // 全屏播放器打开时,大彩胶已经显示了封面 — 这里隐藏小封面
                    // 避免视觉冗余(同步 QQ 桌面端"播放器展开"时下方栏行为)
                    if !compactMode {
                        Artwork(url: downloads.displayCoverURL(for: track), size: 52, radius: 8)
                            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DS.Palette.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(track.singer)
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Palette.textTertiary)
                                .lineLimit(1)
                                .layoutPriority(1)
                            // Quality badge 放在歌手旁,小但能扫到 — 用户要求音质可见。
                            // 只显示实际播放音质(同 iPhone),解析前不显示占位值。
                            if let q = playback.displayQuality {
                                QualityBadge(style: QualityBadgeStyle(quality: q))
                            }
                            // MV 徽章 — 只要 catalog 给了 mvId 就显示,告诉用户
                            // "这首歌有 MV";真不能播时 fetchMv() 会 toast
                            if hasMv {
                                IPadMVTag()
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 12) {
                if !compactMode {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Palette.strokeSubtle.opacity(0.4))
                        .frame(width: 52, height: 52)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 20))
                                .foregroundStyle(DS.Palette.textTertiary)
                        )
                }
                Text("尚未播放")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textTertiary)
                Spacer(minLength: 0)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 22) {
            Button { playback.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(hasTrack ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack)

            // Brand-gradient play/pause — 视觉重心
            Button { playback.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(hasTrack
                              ? AnyShapeStyle(DS.Palette.brandGradient)
                              : AnyShapeStyle(DS.Palette.strokeSubtle.opacity(0.4)))
                    if playback.isBuffering {
                        UIKitSpinner(style: .medium, color: .white)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(.white)
                            .offset(x: playback.isPlaying ? 0 : 1)
                    }
                }
                .frame(width: 48, height: 48)
                .shadow(color: hasTrack ? DS.Palette.brandStart.opacity(0.4) : .clear,
                        radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack)

            Button { playback.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(hasTrack ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack)
        }
    }

    private var rightTools: some View {
        HStack(spacing: 14) {
            // 应用内音量 — 只在 Mac 出现(iPad/iPhone 用系统音量键,不需要)。
            // 跟状态栏菜单里的 slider 是同一个 playback.volume,双向同步。
            #if targetEnvironment(macCatalyst)
            HStack(spacing: 9) {
                // 点图标静音/恢复 — 恢复用静音前的音量
                Button {
                    if playback.volume > 0.001 {
                        volumeBeforeMute = playback.volume
                        playback.volume = 0
                    } else {
                        playback.volume = volumeBeforeMute > 0.001 ? volumeBeforeMute : 0.7
                    }
                } label: {
                    Image(systemName: playback.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 20, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(playback.volume <= 0.001 ? "恢复音量" : "静音")
                Slider(value: Binding(
                    get: {
                        // 逆运算：将底层的绝对音量开立方根，正确反馈到滑块的线性位置上
                        Double(cbrt(playback.volume))
                    },
                    set: {
                        // 正运算：滑块值进行 3 次方计算，让音量衰减曲线平滑、自然
                        playback.volume = Float(pow($0, 3))
                    }
                ), in: 0...1)
                .controlSize(.mini)
                // 0.7 缩放把 Catalyst 上偏大的滑块整体缩小(轨道+圆钮),
                // 先给 120 再缩到 84,内外宽度刚好对齐,不留布局空隙。
                .frame(width: 120)
                .scaleEffect(0.7)
                .frame(width: 84)
            }
            .help("音量")
            #endif

            // 播放模式 — 顺序 / 单曲 / 随机 三态循环。共享 PlaybackCycleMode
            // 跟 PlayerView/QueueView 保持同步。
            Button {
                cycleMode.advanced().apply(to: playback)
            } label: {
                Image(systemName: cycleMode.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(cycleMode == .sequence
                                     ? DS.Palette.textSecondary
                                     : DS.Palette.brandStart)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(cycleMode.label)

            // MV 按钮 — 只在 catalog 标记了 mvId 的曲目上出现。点击触发
            // MvResolver,成功 → fullScreenCover 打开 MvPlayerView,失败 → toast.
            if hasMv {
                Button { fetchMv() } label: {
                    HStack(spacing: 4) {
                        if loadingMv {
                            UIKitSpinner(style: .medium).scaleEffect(0.55).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text("MV").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(DS.Palette.brandStart)
                    .frame(height: 30)
                    .padding(.horizontal, 10)
                    .background(
                        Capsule().fill(DS.Palette.brandStart.opacity(0.1))
                    )
                    .overlay(
                        Capsule().stroke(DS.Palette.brandStart.opacity(0.35), lineWidth: 0.5)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(loadingMv)
            }

            // 队列 — 打开 QueueView sheet 显示播放列表
            toolButton("list.bullet", label: nil) { showQueue = true }
        }
    }

    // MARK: - MV fetch

    private func fetchMv() {
        guard let track = playback.currentTrack, !loadingMv else { return }
        loadingMv = true
        flash("正在获取 MV…")
        Task {
            let info = await MvResolver.getMvUrl(for: track)
            await MainActor.run {
                loadingMv = false
                if let info, info.bestUrl() != nil {
                    mvNotice = nil
                    mvInfo = info
                } else {
                    flash("暂无可用 MV")
                }
            }
        }
    }

    private func flash(_ text: String) {
        mvNotice = text
        let captured = text
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                if mvNotice == captured { mvNotice = nil }
            }
        }
    }

    private func toolButton(_ systemName: String, label: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .semibold))
                if let label {
                    Text(label).font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(DS.Palette.textSecondary)
            .frame(height: 30)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasTrack)
        .opacity(hasTrack ? 1 : 0.4)
    }

    // MARK: - Progress row

    private var progressRow: some View {
        HStack(spacing: 12) {
            Text(formatTime(displayCurrentTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.Palette.textTertiary)
                .frame(width: 40, alignment: .trailing)

            // 直接复用 iPhone PlayerView 的 ProgressSlider —— 同款 4pt 细 track
            // + 10pt 米色小圆 thumb(拖动时 16pt),不是系统 Slider 的大金属球。
            ProgressSlider(
                value: Binding(
                    get: { displayCurrentTime },
                    set: { v in scrubValue = v; isScrubbing = true }
                ),
                in: 0...max(playback.duration, 0.001),
                onChangeBegan: { isScrubbing = true },
                onChangeEnded: {
                    playback.seek(to: scrubValue)
                    isScrubbing = false
                }
            )
            .disabled(!hasTrack || playback.duration <= 0)

            Text(formatTime(playback.duration))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.Palette.textTertiary)
                .frame(width: 40, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .frame(height: 24)
    }

    private var displayCurrentTime: Double {
        isScrubbing ? scrubValue : playback.currentTime
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
