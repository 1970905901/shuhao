import Foundation
import Combine
import ShazamKit
import AVFAudio

/// ShazamKit 听歌识曲。
///
/// 用底层 `SHSession` + `AVAudioEngine` 而不是 `SHManagedSession.result()` —— 后者
/// 在 iOS 26.x 上有内部竞态:`result()` 的 main-thread 完成路径会和 XPC 投递的
/// `session:didNotFindMatchForSignature:error:` 抢 unfair lock,触发框架内部 nil
/// 解引用,实测 `EXC_BAD_ACCESS at 0x2` 闪退。Apple 自己的示例代码用的也是底层 API。
@MainActor
final class SongRecognizer: ObservableObject {
    struct Match: Equatable {
        let title: String
        let artist: String
        let artworkURL: URL?
    }

    enum State: Equatable {
        case idle
        case listening
        case matched(Match)
        case noMatch
        case micDenied
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var session: SHSession?
    private var delegateProxy: SessionDelegateProxy?
    private let audioEngine = AVAudioEngine()
    private var timeoutTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?

    func start() {
        stop()
        state = .listening
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let granted = await AVAudioApplication.requestRecordPermission()
            guard !Task.isCancelled else { return }
            guard granted else { self.state = .micDenied; return }
            self.beginListening()
        }
    }

    func stop() {
        permissionTask?.cancel()
        permissionTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        teardownAudio()
        if state == .listening { state = .idle }
    }

    // MARK: - Internal

    private func beginListening() {
        // 显式配置 AVAudioSession —— 默认 category 在播放刚停时和 ShazamKit
        // 冲突,iOS 26 上更严。.measurement + .mixWithOthers 是 Apple 示例用法。
        // 预先指定 44.1k + 50ms buffer,免得硬件路由初始化时格式抽风。
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
            try? s.setPreferredSampleRate(44100)
            try? s.setPreferredIOBufferDuration(0.05)
            try s.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .failed("音频会话准备失败:\(error.localizedDescription)")
            return
        }

        let session = SHSession()
        let proxy = SessionDelegateProxy { [weak self] outcome in
            Task { @MainActor in self?.handle(outcome) }
        }
        session.delegate = proxy
        self.session = session
        self.delegateProxy = proxy

        // 装新 tap 前先卸 —— start/stop/start 快速循环时旧 tap 没清会抛 -10878。
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        // prepare 之后硬件路由才真正初始化,在此之前 outputFormat 可能拿到
        // sampleRate=0 / channels=0,installTap 直接抛 AVAudioEngine 异常。
        audioEngine.prepare()
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate < 1 || format.channelCount < 1 {
            // 兜底:用 AVAudioSession 实际采样率构造一个合法 format。
            // 1 通道(单声道)对 Shazam 完全够用,功耗也低。
            let sr = AVAudioSession.sharedInstance().sampleRate
            let fallbackSR = sr > 0 ? sr : 44100
            guard let fallback = AVAudioFormat(standardFormatWithSampleRate: fallbackSR, channels: 1) else {
                state = .failed("麦克风格式无效")
                teardownAudio()
                return
            }
            format = fallback
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak session] buffer, audioTime in
            session?.matchStreamingBuffer(buffer, at: audioTime)
        }

        do {
            try audioEngine.start()
        } catch {
            state = .failed("麦克风启动失败:\(error.localizedDescription)")
            teardownAudio()
            return
        }

        // 12s 还没匹配上就当 noMatch —— ShazamKit 不会主动报"识别不到",得自己设兜底。
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.state == .listening { self.state = .noMatch }
                self.teardownAudio()
            }
        }
    }

    private func handle(_ outcome: SessionDelegateProxy.Outcome) {
        // noMatch 不立即收手 —— 一次音频片段没匹配上不代表整次识别失败,
        // 后续 buffer 还可能命中。让 12s timeout 兜底。
        switch outcome {
        case .match(let match):
            timeoutTask?.cancel()
            timeoutTask = nil
            if let item = match.mediaItems.first {
                state = .matched(Match(
                    title: item.title ?? "未知歌曲",
                    artist: item.artist ?? "未知歌手",
                    artworkURL: item.artworkURL))
            } else {
                state = .noMatch
            }
            teardownAudio()
        case .noMatch:
            return
        case .error(let error):
            timeoutTask?.cancel()
            timeoutTask = nil
            state = .failed(error.localizedDescription)
            teardownAudio()
        }
    }

    private func teardownAudio() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        } else {
            // 即使 engine 没在跑,装过 tap 也要卸,免得下次 install 时 -10878。
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        // delegate 持有 session,session 持有 SHSession —— 先断引用让 ARC 收。
        session?.delegate = nil
        session = nil
        delegateProxy = nil
        // 把音频会话让回给主播放器。
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// SHSessionDelegate 桥接 —— 回调走在 ShazamKit 内部 queue,统一封成 enum 后
    /// 让闭包 hop 回主 actor 处理。NSObject 子类不能直接 @MainActor 标注,所以独立出来。
    private final class SessionDelegateProxy: NSObject, SHSessionDelegate {
        enum Outcome {
            case match(SHMatch)
            case noMatch
            case error(Error)
        }
        let onOutcome: (Outcome) -> Void
        init(onOutcome: @escaping (Outcome) -> Void) {
            self.onOutcome = onOutcome
        }
        func session(_ session: SHSession, didFind match: SHMatch) {
            onOutcome(.match(match))
        }
        func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
            if let error { onOutcome(.error(error)) } else { onOutcome(.noMatch) }
        }
    }
}
