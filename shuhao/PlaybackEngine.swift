import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

/// Snapshot of the player persisted between launches so we can restore where the user left off.
private struct PersistedPlaybackState: Codable {
    var queue: [Track]
    var queueIndex: Int
    var position: Double
    var loopMode: String
    var shuffle: Bool
}

@MainActor
final class PlaybackEngine: ObservableObject {
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering: Bool = false
    @Published var queue: [Track] = []
    @Published private(set) var queueIndex: Int = 0
    @Published var loopMode: LoopMode = .all
    @Published var shuffle: Bool = false
    @Published var lastError: String?  // surfaced to UI when URL resolution / playback fails
    @Published var cascadeNotice: String?  // soft notice when AVPlayer rejected a quality and we auto-downgraded
    @Published private(set) var currentOrigin: ResolveOrigin?  // which mechanism produced the playing URL
    @Published private(set) var currentQuality: Quality?  // actual quality of the playing URL (after cascade)
    /// 文件头实测的真实规格(FLAC 位深/采样率、MP3 码率)。音源后端可能静默降级而
    /// lx 协议只回传 URL,所以这里不信任 currentQuality,自己探测。探测中/失败为 nil。
    @Published private(set) var currentAudioSpec: AudioSpec?

    /// 角标用的音质:按实测规格把声称档位往下钳。酷我等后端会静默降级
    /// (请求 hires 实发 16/44.1 FLAC 甚至 128k MP3),协议只回 URL 无从得知,
    /// 只能靠文件头实测校正。探测未完成/失败时按声称档位显示。
    var displayQuality: Quality? {
        guard let claimed = currentQuality else { return nil }
        guard let spec = currentAudioSpec else { return claimed }
        let ceiling: Quality
        if spec.codec == "MP3" {
            ceiling = (spec.bitrateKbps ?? 0) >= 256 ? .k320 : .k128
        } else if let bps = spec.bitsPerSample, bps > 16 {
            // 母带要求 24bit 且 ≥176.4kHz;普通 24bit 最高算 Hi-Res。
            ceiling = spec.sampleRate >= 176400 ? .master : .hires
        } else {
            // 16bit FLAC:全景声 2.0 是 16/44.1 双声道渲染,规格上和 CD 无异,放行。
            if claimed == .atmos || claimed == .atmosPlus { return claimed }
            ceiling = .flac
        }
        let rank = { (q: Quality) in Quality.ranked.firstIndex(of: q) ?? 0 }
        return rank(claimed) < rank(ceiling) ? ceiling : claimed
    }
    /// 应用内独立音量(0…1),与系统音量无关。目前只有 Mac 暴露 UI;iPhone/iPad
    /// 不出 UI、默认 1,行为与从前完全一致。两条播放链路(AVPlayer / libFLAC)都吃它。
    @Published var volume: Float = UserDefaults.standard.object(forKey: "playback.volume") as? Float ?? 1 {
        didSet {
            let v = min(max(volume, 0), 1)
            if v != volume { volume = v; return }
            player?.volume = v
            hiResPlayer.volume = v
            UserDefaults.standard.set(v, forKey: "playback.volume")
        }
    }

    enum LoopMode: String, CaseIterable {
        case off, all, one
        var icon: String {
            switch self {
            case .off: return "arrow.right.to.line"
            case .all: return "repeat"
            case .one: return "repeat.1"
            }
        }
    }

    private var player: AVPlayer?
    /// Single tap doing both EQ + RMS. Recreated each startPlayback so biquad
    /// state lines resets between songs. (RMS/音浪已删除,仅保留 EQ 功能。)
    private var audioTap: EQAudioTap?
    /// Optional EQ binding — PlaybackEngine doesn't own EQStore, shuhaoApp
    /// injects one on launch via `bindEQ(_:)` so settings + DSP stay in sync.
    private weak var eqStore: EQStore?
    private var eqObservation: AnyCancellable?
    /// libFLAC-backed player used when AVFoundation rejects a Hi-Res FLAC (-11828).
    private let hiResPlayer = HiResFLACPlayer()
    private var usingHiRes = false
    private var currentURL: URL?
    private var hiResProgressTimer: Timer?
    /// Per-track: only attempt the libFLAC path once so a genuinely broken file still cascades.
    private var triedHiRes = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var newAccessLogObserver: NSObjectProtocol?
    private var newErrorLogObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?

    deinit {
        // 常驻观察者(生命周期 = engine 生命周期)在 deinit 里统一摘除,
        // 避免持有悬挂的 NotificationCenter token。临时观察者由
        // cleanupPlayer() 负责(切歌/换链路时反复创建销毁)。
        if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = routeChangeObserver { NotificationCenter.default.removeObserver(obs) }
        hiResProgressTimer?.invalidate()
    }

    private var currentArtwork: MPMediaItemArtwork?
    /// 当前曲目封面。锁屏封面本来就要下载,顺手发布出来给迷你播放器用 ——
    /// 标签栏配件位那个宿主不跑 .task,也收不到别的 ObservableObject 的更新,
    /// 只有挂在它已经在观察的 playback 上才保证刷新;顺带也省一次重复下载。
    @Published private(set) var nowPlayingCover: UIImage?
    /// Per-track cap on quality. When AVPlayer rejects a high-bitrate file (e.g. Kugou's
    /// 24-bit FLAC that AVFoundation can't decode), we cascade down: flac24bit → flac → 320k → 128k.
    /// `nil` means "respect the user's preferred quality" — set when a new track starts.
    @Published private(set) var qualityCap: Quality? = nil
    /// Tracks which qualities we've already tried on the current track so we don't loop.
    private var triedQualities: Set<Quality> = []
    private var resolveURLHandler: ((Track) async throws -> ResolvedTrack)?
    /// Audio-session lifetime observers (interruptions like calls/Siri/nav prompts, and route
    /// changes like unplugging CarPlay/headphones). Live for the engine's whole lifetime.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    /// Whether we were playing when an interruption began, so we know to auto-resume after it ends.
    private var wasPlayingBeforeInterruption = false
    /// Where the last session (queue + position) is persisted so we can restore on next launch.
    private let stateURL: URL = {
        let dir = AppPaths.documents
        return dir.appendingPathComponent("playbackState.json")
    }()
    private var lastPersist = Date.distantPast
    /// 锁屏/控制中心 now-playing 信息上次刷新的时间 —— 见 updateNowPlayingTime 的节流说明。
    private var lastNowPlayingUpdate = Date.distantPast
    /// Set while restoring a previous session: we defer creating the AVPlayer until the user hits
    /// play, then seek to this position once the item is ready.
    private var pendingRestorePosition: Double?
    private var needsLoad = false
    /// Last track id written to play history — avoids double-recording on quality cascades.
    private var lastRecordedTrackID: String?
    /// Called when a track actually begins playing. Used by the app to record play history.
    var onTrackPlayed: ((Track) -> Void)?

    /// 已下载歌曲的本地封面文件(AppServices 注入 DownloadStore.embeddedCoverURL)。
    /// 锁屏 / Now Playing 封面优先走它,离线也能显示。
    var localArtworkProvider: ((Track) -> URL?)?

    init() {
        configureAudioSession()
        setupRemoteCommands()
        setupAudioSessionObservers()
        hiResPlayer.volume = volume
    }

    func setURLResolver(_ resolver: @escaping (Track) async throws -> ResolvedTrack) {
        self.resolveURLHandler = resolver
    }

    /// Wire up the equalizer. Called once on launch by shuhaoApp.
    /// Every change to EQStore.settings.gains pushes new coefficients into the
    /// live tap without restarting the player — slider drags are real-time.
    func bindEQ(_ store: EQStore) {
        self.eqStore = store
        eqObservation = store.$settings
            .removeDuplicates()
            .sink { [weak self] s in
                self?.audioTap?.setEnabled(s.enabled)
                self?.audioTap?.setGains(s.gains)
            }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("[PlaybackEngine] AudioSession setup failed: \(error)")
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let evt = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: evt.positionTime) }
            return .success
        }
    }

    private func setupAudioSessionObservers() {
        let nc = NotificationCenter.default
        // Interruptions: phone call, Siri, navigation voice prompt, another audio app, etc.
        interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            // The system tells us via .shouldResume whether it's appropriate to pick back up.
            let shouldResume: Bool = {
                guard type == .ended, let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt
                else { return false }
                return AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            }()
            Task { @MainActor [weak self] in
                self?.handleInterruption(type: type, shouldResume: shouldResume)
            }
        }
        // 兜底:通话期间 App 往往被系统挂起,挂起的 App 收不到 .ended 中断通知(Apple 文档
        // 明确说 begin 不保证有配对的 end)。回前台时发现还欠一次恢复就主动续播。
        foregroundObserver = nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.wasPlayingBeforeInterruption, !self.isPlaying else { return }
                self.wasPlayingBeforeInterruption = false
                try? AVAudioSession.sharedInstance().setActive(true)
                self.resume()
            }
        }
        // Route changes: CarPlay / headphones / Bluetooth connected or disconnected.
        routeChangeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reason: reason)
            }
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            // Something took the audio session — remember whether we were playing so we can resume.
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            // Resume only if we were playing before AND the system permits it (e.g. not after the
            // user manually started a different audio app).
            if wasPlayingBeforeInterruption && shouldResume {
                try? AVAudioSession.sharedInstance().setActive(true)
                resume()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        // The previous output device went away (unplugged CarPlay / pulled out headphones).
        // Pause instead of suddenly blasting through the iPhone speaker — matches system apps.
        if reason == .oldDeviceUnavailable, isPlaying {
            pause()
        }
    }

    func play(track: Track, in newQueue: [Track]? = nil, startIndex: Int? = nil) {
        print("[PlaybackEngine] play(\(track.source.rawValue)_\(track.songmid) \(track.name)) queue.count=\(newQueue?.count ?? queue.count) currentQueueSize=\(queue.count)")
        if let nq = newQueue {
            queue = nq
            queueIndex = startIndex ?? (nq.firstIndex(where: { $0.id == track.id }) ?? 0)
        } else if let idx = queue.firstIndex(where: { $0.id == track.id }) {
            queueIndex = idx
        } else {
            queue = [track]
            queueIndex = 0
        }
        Task { await loadAndPlayCurrent() }
    }

    private func loadAndPlayCurrent() async {
        guard queueIndex >= 0, queueIndex < queue.count else { return }
        let track = queue[queueIndex]
        // Reset per-track state when actually switching songs.
        if currentTrack?.id != track.id {
            qualityCap = nil
            triedQualities = []
            cascadeNotice = nil
            triedHiRes = false
            // A pending restore-seek only applies to the song we restored; a different song
            // means the user moved on, so drop it.
            pendingRestorePosition = nil
        } else {
            // Same track re-resolving. Failed qualities are recorded at the failure sites
            // (item .failed / libFLAC catch) — 这里不能无条件记:单曲循环、输出设备切换
            // 等也会触发同曲重 resolve,把刚播成功的音质记成"失败"会让降级跳过它。
            // Each quality level gets its own libFLAC attempt — a lower-quality URL is a
            // different stream that may well be decodable even if the hires one wasn't.
            triedHiRes = false
        }
        currentTrack = track
        currentOrigin = nil
        currentQuality = nil
        isBuffering = true
        lastError = nil
        do {
            let url: URL
            if track.source == .local, !track.songmid.hasPrefix(LocalMusicStore.scheme),
               let directURL = URL(string: track.songmid) {
                url = directURL
                currentOrigin = .localFile
            } else if let resolver = resolveURLHandler {
                let resolved = try await resolver(track)
                url = resolved.url
                currentOrigin = resolved.origin
                currentQuality = resolved.quality
                if let warning = resolved.warning {
                    // Informational (换源/降级), not a real error — gated by the debug-notices toggle.
                    cascadeNotice = warning
                }
            } else {
                throw NSError(domain: "Playback", code: -1, userInfo: [NSLocalizedDescriptionKey: "No URL resolver"])
            }
            // Record into play history once per song (not on quality-cascade re-resolves).
            if track.id != lastRecordedTrackID {
                lastRecordedTrackID = track.id
                onTrackPlayed?(track)
            }
            startPlayback(url: url)
        } catch {
            isBuffering = false
            isPlaying = false
            lastError = "无法播放《\(track.name)》: \(error.localizedDescription)"
            print("[PlaybackEngine] resolve URL failed for \(track.name): \(error)")
        }
    }

    private func startPlayback(url: URL) {
        cleanupPlayer()
        // Hand control back to AVPlayer (HiRes path re-enables itself on -11828).
        hiResPlayer.stop()
        stopHiResProgressTimer()
        usingHiRes = false
        currentURL = url
        print("[PlaybackEngine] startPlayback url=\(url.absoluteString)")
        currentAudioSpec = nil
        Task { [weak self] in
            let spec = await AudioSpecProbe.probe(url: url)
            guard let self, self.currentURL == url else { return }
            self.currentAudioSpec = spec
            if let spec { print("[PlaybackEngine] probed spec: \(spec.displayText)") }
        }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        p.volume = volume
        self.player = p

        // One MTAudioProcessingTap per playback session — handles EQ.
        // AVMutableAudioMixInputParameters can only carry one audioTapProcessor.
        let tap = EQAudioTap()
        self.audioTap = tap
        if let s = eqStore?.settings {
            tap.setGains(s.gains)
            tap.setEnabled(s.enabled)
        }
        tap.install(on: item)

        // KVO: AVPlayerItem.status — fires when item loads / fails.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    print("[PlaybackEngine] item ready, duration=\(item.duration.seconds)")
                    // qualityCap 保持不动:同一首歌再次 resolve(单曲循环/重播)直接复用
                    // 验证过的档位,不用从 preferred 重吃一遍 404。切歌时会重置(见
                    // loadAndPlayCurrent 的 track-switch 分支)。
                    // Restoring a previous session: jump to where we left off, now that we can seek.
                    if let pos = self.pendingRestorePosition {
                        self.pendingRestorePosition = nil
                        if pos > 1 { self.seek(to: pos) }
                    }
                case .failed:
                    let err = item.error?.localizedDescription ?? "未知错误"
                    let nsErr = item.error as NSError?
                    print("[PlaybackEngine] item failed: \(err) [domain=\(nsErr?.domain ?? "?") code=\(nsErr?.code ?? 0)]")
                    // Recover from "format not recognised" by trying a lower quality.
                    // -11828 = AVErrorFileFormatNotRecognized (Hi-Res FLAC etc. AVFoundation rejects).
                    let isFormatErr = (nsErr?.domain == AVFoundationErrorDomain) && (nsErr?.code == -11828 || nsErr?.code == -11829)
                    if isFormatErr, !self.triedHiRes, let url = self.currentURL {
                        // libFLAC decodes 24-bit FLAC that AVFoundation rejects, on the *same* URL.
                        // Works for both script-resolved tracks AND pasted direct URLs (source .local).
                        // If the stream isn't really FLAC, the decoder fails and we fall through to
                        // the cascade / error below. One attempt per track.
                        self.triedHiRes = true
                        print("[PlaybackEngine] AVPlayer rejected format, trying libFLAC decoder")
                        Task { await self.tryHiResPlayback(url: url) }
                        return
                    }
                    // URL 级失败:音源脚本常按规则拼高音质文件名而不验证存在性,
                    // CDN 上没这个文件就 404(-1100),vkey 无效/无权限是 403(-1102)。
                    // 这类错误脚本调用本身是成功的,SourceManager 的降级链不会触发,
                    // 只能在这里降一档音质重新 resolve。真正断网(-1009 等)不走这条路。
                    let isURLErr = (nsErr?.domain == NSURLErrorDomain)
                        && (nsErr?.code == NSURLErrorFileDoesNotExist
                            || nsErr?.code == NSURLErrorNoPermissionsToReadFile)
                    // Cascade down to a lower quality and re-resolve — only meaningful for script
                    // sources (direct/local URLs have no resolver or alternate qualities).
                    if isFormatErr || isURLErr, let track = self.currentTrack, track.source != .local,
                       let nextQ = self.nextLowerQuality(below: self.currentQuality ?? .flac24,
                                                         excluding: self.triedQualities) {
                        let fromQ = self.currentQuality?.displayName ?? "Hi-Res"
                        print("[PlaybackEngine] \(isURLErr ? "URL not playable" : "format not supported") at \(self.currentQuality?.rawValue ?? "?"), retrying at \(nextQ.rawValue)")
                        if let q = self.currentQuality { self.triedQualities.insert(q) }
                        self.qualityCap = nextQ
                        // Surface to UI so the user actually sees the cascade triggering.
                        // Uses its own field (not lastError) so loadAndPlayCurrent's reset doesn't wipe it.
                        self.cascadeNotice = isURLErr
                            ? "音源没有 \(fromQ) 的文件,已自动降级到 \(nextQ.displayName)"
                            : "iOS 无法解码 \(fromQ),已自动降级到 \(nextQ.displayName)"
                        Task { await self.loadAndPlayCurrent() }
                        return
                    }
                    self.isBuffering = false
                    self.isPlaying = false
                    self.lastError = isFormatErr
                        ? "AVFoundation 无法解码这首歌的任何音质版本(可能是 Kugou Hi-Res FLAC 的私有封装)"
                        : "播放失败: \(err)"
                case .unknown:
                    print("[PlaybackEngine] item status unknown")
                @unknown default: break
                }
            }
        }
        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { item, _ in
            if item.isPlaybackBufferEmpty {
                print("[PlaybackEngine] buffer empty (likely stall)")
            }
        }
        newErrorLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main
        ) { [weak self] _ in
            if let last = (self?.player?.currentItem?.errorLog()?.events ?? []).last {
                print("[PlaybackEngine] AVPlayerItem error event: domain=\(last.errorDomain) code=\(last.errorStatusCode) uri=\(last.uri ?? "?") comment=\(last.errorComment ?? "?")")
            }
        }

        // Watch for AVPlayerItem failures so we don't silently spin forever.
        let failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "未知错误"
            Task { @MainActor in
                print("[PlaybackEngine] failed-to-play-to-end: \(err)")
                self?.isBuffering = false
                self?.isPlaying = false
                self?.lastError = "播放失败: \(err)"
            }
        }
        self.failObserver = failObserver
        stalledObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
        ) { _ in
            print("[PlaybackEngine] playback stalled")
        }

        // 0.5s 进度发布(实测 4Hz 的 @Published currentTime 会让播放器进度条/歌词
        // 每秒重建 4 次,播放中打开播放器时正好和开合动画抢主线程 —— 用户反馈
        // "播放时开合动画卡顿、暂停时正常"的第二个元凶)。0.5s 的进度粒度肉眼
        // 完全顺滑,CarPlay/锁屏歌词由 LyricSync.leadSeconds 提前量补偿,无感知。
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds.isFinite ? time.seconds : 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds
                if let total = self.player?.currentItem?.duration.seconds, total.isFinite, total > 0 {
                    self.duration = total
                }
                self.isBuffering = (self.player?.currentItem?.isPlaybackLikelyToKeepUp == false)
                self.updateNowPlayingTime()
                self.persistState()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleItemEnded() }
        }
        p.play()
        isPlaying = true
        isBuffering = true
        updateNowPlayingInfo()
        loadArtwork()
        persistState(force: true)
    }

    private func cleanupPlayer() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = failObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = stalledObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = newAccessLogObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = newErrorLogObserver { NotificationCenter.default.removeObserver(obs) }
        statusObservation?.invalidate(); statusObservation = nil
        bufferEmptyObservation?.invalidate(); bufferEmptyObservation = nil
        timeObserver = nil
        endObserver = nil
        failObserver = nil
        stalledObserver = nil
        newAccessLogObserver = nil
        newErrorLogObserver = nil
        player?.pause()
        player = nil
    }

    /// Called when AVPlayer rejects a FLAC file. Tears down AVPlayer and decodes via libFLAC.
    /// On success the rest of the UI keeps working (progress driven by a timer instead of KVO);
    /// on failure we fall back to the quality cascade.
    private func tryHiResPlayback(url: URL) async {
        cleanupPlayer()
        isBuffering = true
        do {
            try await hiResPlayer.play(url: url)
            usingHiRes = true
            isBuffering = false
            isPlaying = true
            duration = hiResPlayer.duration
            if let pos = pendingRestorePosition {
                pendingRestorePosition = nil
                if pos > 1 { hiResPlayer.seek(to: pos); currentTime = pos }
            }
            cascadeNotice = "iOS 原生解码失败,已用内置 Hi-Res 解码器(libFLAC)播放"
            hiResPlayer.onPlaybackEnded = { [weak self] in
                Task { @MainActor in self?.handleItemEnded() }
            }
            startHiResProgressTimer()
            updateNowPlayingInfo()
            loadArtwork()
            } catch {
            print("[PlaybackEngine] libFLAC decode failed: \(error)")
            usingHiRes = false
            // Fall back to the quality cascade — but only for script sources. A direct/local URL
            // (e.g. 贴 URL 播放) has no resolver and isn't in the queue, so loadAndPlayCurrent
            // can't re-fetch it; just surface the error.
            if let track = currentTrack, track.source != .local,
               let nextQ = nextLowerQuality(below: currentQuality ?? .flac24,
                                            excluding: triedQualities) {
                if let q = currentQuality { triedQualities.insert(q) }
                qualityCap = nextQ
                cascadeNotice = "Hi-Res 解码失败,已降级到 \(nextQ.displayName)"
                await loadAndPlayCurrent()
            } else {
                isBuffering = false
                isPlaying = false
                lastError = "无法播放(含 Hi-Res 解码): \(error.localizedDescription)"
            }
        }
    }

    private func startHiResProgressTimer() {
        hiResProgressTimer?.invalidate()
        hiResProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.usingHiRes else { return }
                self.currentTime = self.hiResPlayer.currentTime
                self.duration = self.hiResPlayer.duration
                self.isBuffering = false
                self.updateNowPlayingTime()
                self.persistState()
            }
        }
    }

    private func stopHiResProgressTimer() {
        hiResProgressTimer?.invalidate()
        hiResProgressTimer = nil
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        if usingHiRes { hiResPlayer.pause() } else { player?.pause() }
        isPlaying = false
        updateNowPlayingTime(force: true)
        persistState(force: true)
    }

    func resume() {
        // Restored session: the AVPlayer wasn't created yet — load now and seek to the saved position.
        if needsLoad {
            needsLoad = false
            Task { await loadAndPlayCurrent() }
            return
        }
        if currentTrack == nil, !queue.isEmpty {
            queueIndex = max(0, min(queueIndex, queue.count - 1))
            Task { await loadAndPlayCurrent() }
            return
        }
        // 长时间中断(电话)后网络流的 CDN URL 可能已过期,item 进入 .failed —— 对它
        // play() 没有任何效果。重新解析同一首,并记住进度,readyToPlay 时 seek 回去,
        // 而不是让用户重新点歌从头播。
        if !usingHiRes, let item = player?.currentItem, item.status == .failed {
            if currentTime > 1 { pendingRestorePosition = currentTime }
            Task { await loadAndPlayCurrent() }
            return
        }
        if usingHiRes { hiResPlayer.resume() } else { player?.play() }
        isPlaying = true
        updateNowPlayingTime(force: true)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        if usingHiRes {
            hiResPlayer.seek(to: clamped)
        } else {
            player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        }
        currentTime = clamped
        updateNowPlayingTime(force: true)
        persistState(force: true)
    }

    func next() {
        guard !queue.isEmpty else { return }
        if shuffle {
            queueIndex = Int.random(in: 0..<queue.count)
        } else {
            queueIndex = (queueIndex + 1) % queue.count
        }
        Task { await loadAndPlayCurrent() }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0); return
        }
        if shuffle {
            queueIndex = Int.random(in: 0..<queue.count)
        } else {
            queueIndex = (queueIndex - 1 + queue.count) % queue.count
        }
        Task { await loadAndPlayCurrent() }
    }

    private func handleItemEnded() {
        switch loopMode {
        case .one:
            seek(to: 0)
            if usingHiRes { hiResPlayer.resume() } else { player?.play() }
            isPlaying = true
        case .all:
            next()
        case .off:
            if queueIndex + 1 < queue.count { next() } else { pause(); seek(to: 0) }
        }
    }

    /// Jump to a specific index in the current queue without changing the queue itself.
    func jump(to index: Int) {
        guard !queue.isEmpty else { return }
        queueIndex = max(0, min(index, queue.count - 1))
        Task { await loadAndPlayCurrent() }
    }

    /// Remove a track at `index`. If it was the current one, advance to the next (or stop).
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let wasCurrent = (index == queueIndex)
        queue.remove(at: index)
        if queue.isEmpty {
            clearQueue()
            return
        }
        if wasCurrent {
            // Keep the same index — that's now the next track. Clamp first.
            queueIndex = min(queueIndex, queue.count - 1)
            Task { await loadAndPlayCurrent() }
        } else if index < queueIndex {
            // Removed a track before the current one; shift index back so currentTrack is unchanged.
            queueIndex -= 1
        }
        persistState(force: true)
    }

    /// Move a track within the queue (drag-reorder).
    func moveInQueue(from source: Int, to destination: Int) {
        guard queue.indices.contains(source) else { return }
        let track = queue.remove(at: source)
        let target = min(destination, queue.count)
        queue.insert(track, at: target)
        if source == queueIndex {
            queueIndex = target
        } else if source < queueIndex, target >= queueIndex {
            queueIndex -= 1
        } else if source > queueIndex, target <= queueIndex {
            queueIndex += 1
        }
        persistState(force: true)
    }

    func clearQueue() {
        cleanupPlayer()
        hiResPlayer.stop()
        stopHiResProgressTimer()
        usingHiRes = false
        queue = []
        currentTrack = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        needsLoad = false
        pendingRestorePosition = nil
        lastRecordedTrackID = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        persistState(force: true)
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.name
        info[MPMediaItemPropertyArtist] = track.singer
        if let album = currentTrack?.albumName { info[MPMediaItemPropertyAlbumTitle] = album }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let art = currentArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingTime(force: Bool = false) {
        // ⚠️ 节流:这个方法被 periodicTimeObserver 每 0.5s 调用一次,而
        // MPNowPlayingInfoCenter.default().nowPlayingInfo 写入是跨进程 XPC
        // (主线程 → mediaserverd),播放中持续 4Hz 调用是打开/关闭播放器动画
        // 卡顿的元凶之一(播放时有、暂停时无,正好吻合"播放时卡、不播放时正常")。
        // 锁屏/控制中心的秒针按 1s 粒度即可;用户主动操作(暂停/恢复/拖动)传 force。
        if !force {
            let now = Date()
            if now.timeIntervalSince(lastNowPlayingUpdate) < 1.0 { return }
            lastNowPlayingUpdate = now
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = duration
        if let album = currentTrack?.albumName { info[MPMediaItemPropertyAlbumTitle] = album }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork() {
        currentArtwork = nil
        nowPlayingCover = nil
        guard let track = currentTrack else { return }
        // 已下载的歌:封面读本地缓存(文件内嵌封面提取的),离线可用;否则走网络 picURL。
        let localURL = localArtworkProvider?(track)
        let remoteURL = track.picURL.flatMap(URL.init(string:))
        guard localURL != nil || remoteURL != nil else { return }
        Task.detached { [weak self] in
            var img: UIImage?
            if let localURL, let data = try? Data(contentsOf: localURL) { img = UIImage(data: data) }
            if img == nil, let remoteURL, let data = try? Data(contentsOf: remoteURL) { img = UIImage(data: data) }
            guard let img else { return }
            await MainActor.run { [weak self] in
                self?.currentArtwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self?.nowPlayingCover = img
                self?.updateNowPlayingInfo()
            }
        }
    }

    // MARK: - Session persistence

    /// Write the current queue + position to disk. Throttled to ~once every 5s for the frequent
    /// time-observer calls; pass `force` for one-off events (play/pause/seek/queue edits).
    ///
    /// ⚠️ 性能优化:JSON 编码 + 原子写盘从主线程移到后台 utility 队列 —— 播放中
    /// periodicTimeObserver 每 0.5s 调一次,若在主线程做(编码大队列 + 写盘)会
    /// 造成持续卡顿(用户反馈"播放中开合动画卡顿")。主线程只做轻量快照。
    private func persistState(force: Bool = false) {
        guard !queue.isEmpty, currentTrack != nil else {
            let url = stateURL
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
            return
        }
        let now = Date()
        if !force, now.timeIntervalSince(lastPersist) < 5 { return }
        lastPersist = now
        // 主线程快照(轻量)
        let state = PersistedPlaybackState(
            queue: queue,
            queueIndex: queueIndex,
            position: currentTime,
            loopMode: loopMode.rawValue,
            shuffle: shuffle
        )
        // 编码 + 写盘放后台
        let url = stateURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(state) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Restore the last session on launch: rebuild the queue and show the track in a paused state
    /// (no autoplay). The AVPlayer is created lazily when the user hits play, seeking to `position`.
    func restoreLastSession() {
        guard currentTrack == nil, queue.isEmpty,
              let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedPlaybackState.self, from: data),
              state.queue.indices.contains(state.queueIndex) else { return }
        queue = state.queue
        queueIndex = state.queueIndex
        loopMode = LoopMode(rawValue: state.loopMode) ?? .all
        shuffle = state.shuffle
        let track = state.queue[state.queueIndex]
        currentTrack = track
        currentTime = state.position
        duration = Double(track.duration ?? 0)
        pendingRestorePosition = state.position
        needsLoad = true
        isPlaying = false
        isBuffering = false
        // Show the restored track on the lock screen / CarPlay even before playback starts.
        updateNowPlayingInfo()
        loadArtwork()
    }

    /// Cascade: master → … → flac24bit → flac → 320k → 128k. Returns the next quality
    /// below `current` that isn't in `excluding`, or nil at the 128k floor.
    nonisolated func nextLowerQuality(below current: Quality,
                                      excluding tried: Set<Quality> = []) -> Quality? {
        let cascade: [Quality] = Quality.ranked
        guard let idx = cascade.firstIndex(of: current), idx + 1 < cascade.count else { return nil }
        let candidates = cascade[(idx + 1)...].filter { !tried.contains($0) }
        // 只降一档:这里不做可用性判断(元数据经常漏标无损档,见 pickPlayQuality),
        // 交给 resolve 时的 pickPlayQuality 按脚本能力挑 cap 之下真正可用的档位 ——
        // 那一步是本地判断,不花网络请求;真不存在的档位 404 后会继续往下走。
        return candidates.first
    }
}

/// User-facing three-state cycle selector. Combines the underlying `shuffle: Bool`
/// and `LoopMode` so the UI can present a single button that walks through
/// 顺序循环 → 单曲循环 → 随机循环 (and back). Shared between PlayerView's
/// control row and QueueView's mode bar so both stay in lockstep.
enum PlaybackCycleMode: CaseIterable {
    case sequence
    case single
    case shuffle

    var icon: String {
        switch self {
        case .sequence: return "repeat"
        case .single:   return "repeat.1"
        case .shuffle:  return "shuffle"
        }
    }
    var label: String {
        switch self {
        case .sequence: return "顺序循环"
        case .single:   return "单曲循环"
        case .shuffle:  return "随机循环"
        }
    }
    static func current(shuffle: Bool, loop: PlaybackEngine.LoopMode) -> PlaybackCycleMode {
        if shuffle { return .shuffle }
        if loop == .one { return .single }
        return .sequence   // both .all and legacy .off collapse to "sequence" for UI purposes
    }
    func advanced() -> PlaybackCycleMode {
        switch self {
        case .sequence: return .single
        case .single:   return .shuffle
        case .shuffle:  return .sequence
        }
    }
    func apply(to playback: PlaybackEngine) {
        switch self {
        case .sequence: playback.shuffle = false; playback.loopMode = .all
        case .single:   playback.shuffle = false; playback.loopMode = .one
        case .shuffle:  playback.shuffle = true;  playback.loopMode = .all
        }
    }
}
