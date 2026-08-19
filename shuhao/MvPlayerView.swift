import SwiftUI
import AVKit
import AVFoundation
import Combine

/// MV viewer — full-screen video page over the audio player.
///
/// UX (revised):
///   - Auto-hides all controls after 3 s of inactivity (like QQ 音乐 MV / 系统视频 app).
///   - Tap anywhere on the video → toggles the control overlay.
///   - Overlay: top bar (close + title + quality menu), bottom bar (prev / play-pause
///     / next + queue list), centered scrubber with time labels.
///   - Always plays the highest-quality variant the resolver returned (MvResolver
///     already sorts qualities desc; we pick `[0]`).
struct MvPlayerView: View {
    let initialTrack: Track
    let initialInfo: MusicVideoInfo
    let onClose: () -> Void

    @State private var track: Track
    @State private var info: MusicVideoInfo
    @State private var selectedQualityIndex = 0
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var showQueueSheet = false
    @State private var errorMessage: String?

    // ⚠️ 刻意不观察 PlaybackEngine:它的 currentTime 每 0.25 秒发布一次,观察它就
    // 等于让全屏 MV 页面每秒重建 4 次(视频播放中非常伤)。要读队列 / 暂停音频时
    // 经 AppServices 取引擎指令(取值,非观察)。
    private var engine: PlaybackEngine? { AppServices.shared.playback }

    // Playback observation
    @State private var isPlaying = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserverToken: Any?
    @State private var statusObserver: AnyCancellable?

    // Control overlay auto-hide
    @State private var controlsVisible = true
    @State private var hideWorkItem: DispatchWorkItem?

    init(info: MusicVideoInfo, track: Track, onClose: @escaping () -> Void) {
        self.initialInfo = info
        self.initialTrack = track
        self.onClose = onClose
        self._track = State(initialValue: track)
        self._info = State(initialValue: info)
    }

    /// Tracks in the playback queue that carry an mvId hint. Used by prev/next.
    private var mvQueue: [Track] {
        engine?.queue.filter { $0.extras["mvId"]?.isEmpty == false } ?? []
    }

    private var currentIndex: Int {
        mvQueue.firstIndex(where: { $0.id == track.id }) ?? -1
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)   // we own the tap layer below
            }

            // Transparent tap layer — toggles controls.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }

            if loading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
            }

            // Control overlay — fades in/out together.
            controlOverlay
                .opacity(controlsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.22), value: controlsVisible)
                .allowsHitTesting(controlsVisible)
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: !controlsVisible)
        .onAppear { startup() }
        .onDisappear { teardown() }
        // MV 队列 —— Mac → .popover(点外面/Esc 关,跟设置弹窗一致),iOS → .sheet。
        #if targetEnvironment(macCatalyst)
        .popover(isPresented: $showQueueSheet) {
            MvQueueSheet(
                queue: mvQueue,
                currentTrackID: track.id,
                onSelect: { selected in
                    showQueueSheet = false
                    loadMV(for: selected)
                }
            )
            .preferredColorScheme(.dark)
            .frame(width: 440, height: 600)
        }
        #else
        .sheet(isPresented: $showQueueSheet) {
            MvQueueSheet(
                queue: mvQueue,
                currentTrackID: track.id,
                onSelect: { selected in
                    showQueueSheet = false
                    loadMV(for: selected)
                }
            )
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        #endif
        .overlay(alignment: .top) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 80)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: errorMessage)
    }

    // MARK: - Control overlay

    @ViewBuilder
    private var controlOverlay: some View {
        ZStack {
            // Subtle top + bottom scrim so white controls stay readable against
            // any video frame. Pointer-throughtable thanks to .allowsHitTesting
            // on the outer Color.clear tap layer.
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerControls
                Spacer()
                bottomBar
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            controlButton(systemName: "chevron.down", size: 16) { onClose() }
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name ?? track.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.singer)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            qualityMenu
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// Center transport: large play/pause in the middle, prev/next flanking.
    /// This is the "main" interaction surface — bottom bar carries scrub +
    /// queue, but the center is what users reach for first when controls show.
    private var centerControls: some View {
        HStack(spacing: 56) {
            transportButton(systemName: "backward.fill", size: 24, disabled: !canGoPrev) {
                step(by: -1)
            }
            Button(action: togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            transportButton(systemName: "forward.fill", size: 24, disabled: !canGoNext) {
                step(by: 1)
            }
        }
    }

    /// Bottom bar — scrubber + queue button. Time labels are monospace so
    /// they don't jitter as digits change.
    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(formatTime(currentTime))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                MvScrubber(
                    value: $currentTime,
                    bounds: 0...max(duration, 0.001),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing { seek(to: currentTime) }
                    }
                )
                .frame(height: 18)
                Text(formatTime(duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: 16) {
                Spacer()
                if !mvQueue.isEmpty {
                    smallButton(systemName: "list.bullet", label: "\(currentIndex + 1)/\(mvQueue.count)") {
                        showQueueSheet = true
                        keepControlsVisible()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 26)
    }

    // MARK: - Reusable buttons

    private func controlButton(systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: { action(); keepControlsVisible() }) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func transportButton(systemName: String, size: CGFloat, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { action(); keepControlsVisible() }) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(disabled ? Color.white.opacity(0.25) : .white)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func smallButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName).font(.system(size: 13, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var qualityMenu: some View {
        if info.qualities.count > 1 {
            Menu {
                ForEach(Array(info.qualities.enumerated()), id: \.offset) { idx, q in
                    Button {
                        switchQuality(to: idx)
                        keepControlsVisible()
                    } label: {
                        Label(q.type, systemImage: selectedQualityIndex == idx ? "checkmark" : "")
                    }
                }
            } label: {
                let label = info.qualities.indices.contains(selectedQualityIndex)
                    ? info.qualities[selectedQualityIndex].type : "画质"
                HStack(spacing: 4) {
                    Text(label).font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            }
        }
    }

    private var canGoPrev: Bool { currentIndex > 0 }
    private var canGoNext: Bool { currentIndex >= 0 && currentIndex < mvQueue.count - 1 }

    // MARK: - Auto-hide

    private func toggleControls() {
        if controlsVisible {
            controlsVisible = false
            hideWorkItem?.cancel()
        } else {
            controlsVisible = true
            scheduleHide()
        }
    }

    /// Reset the auto-hide timer — used whenever the user touches a control so
    /// they don't lose the overlay mid-interaction.
    private func keepControlsVisible() {
        controlsVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { controlsVisible = false }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    // MARK: - State actions

    private func startup() {
        // 看 MV 时暂停音频 —— 经引擎取指令,不观察
        if let e = engine, e.isPlaying { e.pause() }
        mount(url: info.bestUrl())
        scheduleHide()
    }

    private func teardown() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        statusObserver?.cancel()
        statusObserver = nil
        player?.pause()
        player = nil
        hideWorkItem?.cancel()
    }

    /// Build an `AVURLAsset` with per-source HTTP headers. 各家 CDN 对 UA / Referer
    /// 的检查严格度不一样,但默认 URLSession UA 几乎所有 MV CDN 都拒(返回 403 / 抽风),
    /// 所以给每个源都明确配置 Referer + UA。
    /// - wy: 必须 music.163.com Referer,否则 403
    /// - tx: y.qq.com Referer,免鉴权 freeflow URL
    /// - kw: mobile UA 才认
    /// - kg / mg: 桌面浏览器 UA 普遍工作
    private func makeAsset(for url: URL) -> AVURLAsset {
        var headers: [String: String] = [:]
        let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        switch track.source {
        case .wy:
            headers["Referer"] = "https://music.163.com/"
            headers["User-Agent"] = desktopUA
        case .tx:
            headers["Referer"] = "https://y.qq.com/"
            headers["User-Agent"] = desktopUA
        case .kw:
            // 用 kw web 端的 Referer,API 接口认 okhttp UA 但流媒体 CDN 认浏览器。
            headers["Referer"] = "http://www.kuwo.cn/"
            headers["User-Agent"] = desktopUA
        case .kg:
            headers["Referer"] = "https://www.kugou.com/"
            headers["User-Agent"] = desktopUA
        case .mg:
            headers["Referer"] = "https://music.migu.cn/"
            headers["User-Agent"] = desktopUA
        default:
            break
        }
        let options: [String: Any] = headers.isEmpty ? [:] : [
            "AVURLAssetHTTPHeaderFieldsKey": headers
        ]
        return AVURLAsset(url: url, options: options)
    }

    private func mount(url raw: String?) {
        guard let raw, let url = URL(string: raw) else { return }
        let asset = makeAsset(for: url)
        let item = AVPlayerItem(asset: asset)

        if let player {
            player.replaceCurrentItem(with: item)
            player.play()
        } else {
            let p = AVPlayer(playerItem: item)
            p.play()
            self.player = p
        }

        attachObservers(to: player ?? AVPlayer(), item: item)
    }

    /// Wire up time + duration observers so the scrubber stays in sync.
    private func attachObservers(to player: AVPlayer, item: AVPlayerItem) {
        // Remove old time observer
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        loading = true
        // 0.5s tick is enough for the scrubber — saves CPU vs 0.1s.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            guard !isScrubbing else { return }
            currentTime = time.seconds.isFinite ? time.seconds : 0
            isPlaying = player.timeControlStatus == .playing
            // 数据真的开始流就摘掉 loading;在 readyToPlay 之后还可能短暂卡 buffering,
            // 但只要 time observer 跑起来就说明可视层至少不卡死了。
            if loading, time.seconds.isFinite, time.seconds > 0 { loading = false }
        }
        // Item duration arrives async (after AVAsset metadata loads).
        statusObserver?.cancel()
        statusObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    let d = item.asset.duration.seconds
                    duration = d.isFinite && d > 0 ? d : 0
                    loading = false
                case .failed:
                    loading = false
                    let err = item.error as NSError?
                    print("[MvPlayerView] AVPlayerItem failed source=\(track.source.rawValue) " +
                          "code=\(err?.code ?? 0) domain=\(err?.domain ?? "?") msg=\(err?.localizedDescription ?? "?")")
                    showError(mvPlaybackErrorMessage(for: err))
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
    }

    /// Map AVFoundation 错误到用户能看懂的中文提示。MV CDN 拒绝场景比音频还多
    /// (DRM 包装、地域限制、过期签名),不要直接抛 NSError 给用户。
    private func mvPlaybackErrorMessage(for err: NSError?) -> String {
        guard let err else { return "MV 播放失败" }
        switch err.code {
        case -11828, -11829: return "MV 格式不支持(可能被音源加密)"
        case -1009: return "网络不可用"
        case -1001: return "MV 加载超时"
        case -1003, -1100, -1102: return "MV 链接已失效"
        default: return "MV 播放失败(\(err.code))"
        }
    }

    private func togglePlayPause() {
        guard let p = player else { return }
        if p.timeControlStatus == .playing {
            p.pause(); isPlaying = false
        } else {
            p.play(); isPlaying = true
        }
        keepControlsVisible()
    }

    private func seek(to seconds: Double) {
        guard let p = player else { return }
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func switchQuality(to idx: Int) {
        guard info.qualities.indices.contains(idx) else { return }
        selectedQualityIndex = idx
        mount(url: info.qualities[idx].url)
    }

    private func step(by delta: Int) {
        let target = currentIndex + delta
        guard mvQueue.indices.contains(target) else { return }
        loadMV(for: mvQueue[target])
    }

    /// Re-resolve MV URL for a different track and swap the player item.
    private func loadMV(for newTrack: Track) {
        loading = true
        Task {
            let result = await MvResolver.getMvUrl(for: newTrack)
            await MainActor.run {
                loading = false
                guard let result, result.bestUrl() != nil else {
                    showError("\(newTrack.name) 暂无可用 MV")
                    return
                }
                self.track = newTrack
                self.info = result
                self.selectedQualityIndex = 0
                self.duration = 0
                self.currentTime = 0
                mount(url: result.bestUrl())
                keepControlsVisible()
            }
        }
    }

    private func showError(_ text: String) {
        errorMessage = text
        Task {
            // 3.5s 比之前 1.8s 长 — MV 解析+加载失败的提示要看得清,
            // 别让用户以为是按钮没生效。
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            await MainActor.run {
                if errorMessage == text { errorMessage = nil }
            }
        }
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Scrubber

/// Custom scrubber — Slider with a thinner track + brand-colored fill.
/// Kept inside this file because no other surface uses it.
private struct MvScrubber: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        Slider(value: $value, in: bounds, onEditingChanged: onEditingChanged)
            .tint(.white)
    }
}

/// Sheet listing all tracks in the audio queue that have an mvId.
private struct MvQueueSheet: View {
    let queue: [Track]
    let currentTrackID: String
    let onSelect: (Track) -> Void
    @ObservedObject private var downloads = DownloadStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { idx, t in
                        Button {
                            onSelect(t)
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .frame(width: 22)
                                Artwork(url: downloads.displayCoverURL(for: t), size: 38, radius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(t.name)
                                            .font(.system(size: 14, weight: t.id == currentTrackID ? .semibold : .regular))
                                            .foregroundStyle(t.id == currentTrackID ? AnyShapeStyle(DS.Palette.brandGradient) : AnyShapeStyle(Color.white))
                                            .lineLimit(1)
                                        Text("MV")
                                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(DS.Palette.brandStart.opacity(0.7), in: Capsule())
                                    }
                                    Text(t.singer)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if t.id == currentTrackID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(DS.Palette.brandStart)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("MV 列表")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("\(queue.count) 个 MV")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
