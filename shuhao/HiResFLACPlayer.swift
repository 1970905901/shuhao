import Foundation
import AVFoundation

/// libFLAC-backed **streaming** player for 24-bit (Hi-Res) FLAC streams that AVFoundation
/// rejects with AVErrorFileFormatNotRecognized (-11828).
///
/// Pipeline (no full pre-download):
///   1. A URLSession data task streams bytes into a blocking `StreamingByteBuffer`.
///   2. A dedicated decode thread runs libFLAC via `init_stream`; its read callback pulls
///      from the byte buffer (blocking when the network is behind).
///   3. Each decoded FLAC frame is converted to Float32 PCM, appended to an in-memory store
///      (kept for seeking), and incrementally scheduled onto an AVAudioPlayerNode.
///   4. Playback starts as soon as the first frame is decoded — typically well under a second.
///
/// `HiResFLACPlayer` is the @MainActor-facing wrapper; the heavy lifting lives in
/// `FLACStreamPipeline`, which is thread-safe and drives the audio graph off the main thread.
@MainActor
final class HiResFLACPlayer {

    enum PlayerError: LocalizedError {
        case network(Error)
        case notFLAC(formatHint: String)
        case decoderInitFailed(String)
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .network(let e): return "网络错误: \(e.localizedDescription)"
            case .notFLAC(let hint): return "不是可解码的 FLAC 流(\(hint))"
            case .decoderInitFailed(let s): return "FLAC 解码器初始化失败: \(s)"
            case .engineStartFailed(let s): return "音频引擎启动失败: \(s)"
            }
        }
    }

    private var pipeline: FLACStreamPipeline?
    private(set) var isPlaying: Bool = false
    var onPlaybackEnded: (() -> Void)?

    /// 应用内独立音量(0…1)。pipeline 每首歌重建,所以记在这里,play 时再带过去。
    var volume: Float = 1 {
        didSet { pipeline?.volume = volume }
    }

    var currentTime: Double { pipeline?.currentTime ?? 0 }
    var duration: Double { pipeline?.duration ?? 0 }

    /// Starts streaming + decoding. Resolves once playback has actually started (first frame
    /// decoded and the engine is running). Throws if the stream isn't FLAC or the network fails
    /// before any audio plays — the caller then falls back to the quality cascade.
    func play(url: URL) async throws {
        stop()
        let pipe = FLACStreamPipeline()
        pipe.volume = volume
        self.pipeline = pipe
        pipe.onEnded = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.onPlaybackEnded?()
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pipe.start(url: url) { result in
                cont.resume(with: result)
            }
        }
        isPlaying = true
    }

    func pause() {
        pipeline?.pause()
        isPlaying = false
    }

    func resume() {
        pipeline?.resume()
        isPlaying = true
    }

    func seek(to seconds: Double) {
        pipeline?.seek(to: seconds)
    }

    func stop() {
        pipeline?.stop()
        pipeline = nil
        isPlaying = false
    }
}

// MARK: - Streaming pipeline (thread-safe, off-main)

/// Owns the audio graph + libFLAC decoder + network stream. All mutable state is guarded by
/// `lock`. Marked @unchecked Sendable because we hand-verify thread safety: the decode thread,
/// the audio render thread (scheduleBuffer completions), and the main thread (transport controls)
/// all funnel state mutations through `lock`.
final class FLACStreamPipeline: NSObject, @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }
    private let lock = NSLock()
    private let bytes = StreamingByteBuffer()

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var decodeThread: Thread?

    // Stream format (set once STREAMINFO arrives).
    private var sampleRate: Double = 0
    private var channels: Int = 0
    private var bitsPerSample: Int = 0
    private var totalSamples: UInt64 = 0
    private var format: AVAudioFormat?

    // In-memory planar Float32 store of everything decoded so far (kept for seeking).
    private var store: [UnsafeMutablePointer<Float>] = []
    private var storeCapacity = 0
    private var decodedFrames = 0    // total frames decoded into `store`
    private var scheduledFrames = 0  // frames already handed to the player node

    private var baseFrame = 0        // store-frame at the player's sampleTime 0 (shifts on seek)
    private var lastKnownFrame = 0   // last valid progress reading — survives engine stops (interruptions)
    private var downloadedBytes = 0  // diagnostics: total bytes received from the network
    private var headMagic = Data()   // first 16 bytes of the stream — identifies non-FLAC payloads
    private var generation = 0       // bumped on seek/stop to invalidate stale completion handlers
    private var started = false      // engine running + first buffer scheduled
    private var producingDone = false// decode loop finished (EOF reached)
    private var ended = false        // onEnded already fired
    private var aborted = false

    var onEnded: (() -> Void)?
    private var readyHandler: ((Result<Void, Error>) -> Void)?
    private var networkError: Error?

    override init() {
        super.init()
        engine.attach(player)
    }

    deinit {
        for p in store { p.deallocate() }
    }

    // MARK: Public transport

    func start(url: URL, ready: @escaping (Result<Void, Error>) -> Void) {
        lock.lock(); readyHandler = ready; lock.unlock()

        if url.isFileURL {
            // Downloaded / local FLAC: URLSession data tasks don't support file:// URLs, so feed
            // the bytes into the buffer directly off-thread.
            Thread { [weak self] in
                guard let self else { return }
                if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                    self.bytes.append(data)
                    self.bytes.markEOF()
                } else {
                    self.bytes.abort()
                }
            }.start()
        } else {
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 30
            let cfg = URLSessionConfiguration.default
            let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: req)
            self.task = task
            task.resume()
        }

        let thread = Thread { [weak self] in self?.decodeLoop() }
        thread.name = "HiResFLAC.decode"
        thread.stackSize = 1 << 20
        self.decodeThread = thread
        thread.start()
    }

    func pause() {
        player.pause()
    }

    func resume() {
        if !engine.isRunning {
            // 中断(电话/Siri)停掉引擎时,player node 上已调度的缓冲被清空,时间轴也归零 ——
            // 直接 play() 会无声。从最后已知进度重新调度(seek 会重建 chunk 并重启引擎)。
            let t = currentTime
            seek(to: t)
            return
        }
        player.play()
    }

    func seek(to seconds: Double) {
        lock.lock()
        guard started, sampleRate > 0, let format else { lock.unlock(); return }
        let target = max(0, min(Int(seconds * sampleRate), decodedFrames))
        generation &+= 1
        let gen = generation
        let avail = decodedFrames - target
        baseFrame = target
        lastKnownFrame = target
        scheduledFrames = decodedFrames
        let snapshotChannels = channels
        // Build a contiguous buffer for [target, decodedFrames) from the store.
        let chunk = makeBuffer(format: format, from: target, count: avail, channels: snapshotChannels)
        lock.unlock()

        player.stop()   // clears the queue; fires stale completions (ignored via generation)
        if !engine.isRunning { try? engine.start() }
        if let chunk, avail > 0 {
            scheduleChunk(chunk, generation: gen)
        }
        player.play()
    }

    func stop() {
        lock.lock()
        generation &+= 1
        aborted = true
        let pending = readyHandler      // resume a still-awaiting play() so its continuation never leaks
        readyHandler = nil
        lock.unlock()
        pending?(.failure(CancellationError()))
        bytes.abort()           // unblock the decode thread's read callback
        task?.cancel()
        session?.invalidateAndCancel()
        player.stop()
        engine.stop()
    }

    // MARK: Progress

    var currentTime: Double {
        lock.lock(); let base = baseFrame; let sr = sampleRate; let known = lastKnownFrame; lock.unlock()
        guard sr > 0 else { return 0 }
        // 引擎被中断(电话/Siri)停掉后 lastRenderTime 变 nil —— 此时退回最后一次
        // 有效读数,而不是 baseFrame(那会把进度跳回上次 seek 的位置)。
        var frame = known
        if let nodeTime = player.lastRenderTime,
           let pt = player.playerTime(forNodeTime: nodeTime) {
            frame = base + Int(pt.sampleTime)
            lock.lock(); lastKnownFrame = frame; lock.unlock()
        }
        return max(0, Double(frame) / sr)
    }

    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        guard sampleRate > 0 else { return 0 }
        if totalSamples > 0 { return Double(totalSamples) / sampleRate }
        return Double(decodedFrames) / sampleRate   // grows while streaming if header lacked it
    }

    // MARK: Decode thread

    private func decodeLoop() {
        guard let decoder = FLAC__stream_decoder_new() else {
            finishReady(.failure(HiResFLACPlayer.PlayerError.decoderInitFailed("alloc")))
            return
        }
        defer { FLAC__stream_decoder_delete(decoder) }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let initStatus = FLAC__stream_decoder_init_stream(
            decoder,
            flac_read_cb,
            nil, nil, nil, nil,   // seek / tell / length / eof — input is a forward-only network stream
            flac_write_cb,
            flac_metadata_cb,
            flac_error_cb,
            selfPtr
        )
        guard initStatus == FLAC__STREAM_DECODER_INIT_STATUS_OK else {
            finishReady(.failure(HiResFLACPlayer.PlayerError.decoderInitFailed("init_stream=\(initStatus.rawValue)")))
            return
        }
        defer { _ = FLAC__stream_decoder_finish(decoder) }

        let processOK = FLAC__stream_decoder_process_until_end_of_stream(decoder) != 0
        let endState = FLAC__stream_decoder_get_state(decoder)

        // Decode loop returned: either EOF (success) or aborted/error.
        lock.lock()
        producingDone = true
        let didStart = started
        let netErr = networkError
        let wasAborted = aborted
        // If nothing ever played, surface the right failure.
        let endFrame = decodedFrames
        let gen = generation
        let total = totalSamples
        let dl = downloadedBytes
        let head = headMagic
        lock.unlock()
        print("[HiResFLAC] decode loop ended: ok=\(processOK) state=\(endState.rawValue) decodedFrames=\(endFrame) totalSamples=\(total) downloaded=\(dl)B started=\(didStart) aborted=\(wasAborted)")

        if !didStart && !wasAborted {
            if let netErr {
                finishReady(.failure(HiResFLACPlayer.PlayerError.network(netErr)))
            } else {
                let hint = Self.formatHint(head: head)
                let hex = head.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("[HiResFLAC] stream is not FLAC — head: [\(hex)] guess: \(hint)")
                finishReady(.failure(HiResFLACPlayer.PlayerError.notFLAC(formatHint: hint)))
            }
            return
        }
        // Flush any decoded-but-not-yet-scheduled tail (the last partial batch).
        maybeScheduleBatch(force: true)
        // Decode finished. If playback has already reached the end (e.g. a very short clip whose
        // final completion fired before producingDone was set), end now; otherwise the last
        // buffer's dataPlayedBack completion will. Either way checkEnd judges by real play position.
        checkEnd(generation: gen)
    }

    /// Identify what the server actually sent when it isn't FLAC, from the stream's magic bytes.
    static func formatHint(head: Data) -> String {
        func has(_ s: String) -> Bool { head.starts(with: Array(s.utf8)) }
        if head.isEmpty { return "空响应" }
        if has("fLaC") { return "FLAC 但数据损坏" }
        if has("MAC ") { return "APE 格式" }
        if has("ID3") || (head.count >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) { return "MP3 格式" }
        if has("OggS") { return "OGG 格式" }
        if has("RIFF") { return "WAV 格式" }
        if has("FRM8") || has("DSD ") { return "DSD 格式" }
        if head.dropFirst(4).starts(with: Array("ftyp".utf8)) { return "MP4/M4A 格式" }
        if has("yeelion") { return "酷我加密格式 kwm" }
        if has("{") || has("<") { return "接口返回了文本/错误页" }
        let hex = head.prefix(4).map { String(format: "%02X", $0) }.joined()
        return "未知格式 0x\(hex)"
    }

    // Called from libFLAC read callback (decode thread). Returns CONTINUE / END_OF_STREAM / ABORT.
    fileprivate func provideBytes(into buffer: UnsafeMutablePointer<UInt8>, bytes wanted: UnsafeMutablePointer<Int>) -> FLAC__StreamDecoderReadStatus {
        let want = wanted.pointee
        guard want > 0 else { wanted.pointee = 0; return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE }
        guard let chunk = bytes.read(maxLength: want) else {
            wanted.pointee = 0
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT      // aborted (stop())
        }
        if chunk.isEmpty {
            wanted.pointee = 0
            return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
        }
        chunk.withUnsafeBytes { raw in
            buffer.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: chunk.count)
        }
        wanted.pointee = chunk.count
        return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE
    }

    // Called from libFLAC metadata callback (decode thread).
    fileprivate func setStreamInfo(sampleRate sr: UInt32, channels ch: UInt32, bits: UInt32, total: UInt64) {
        lock.lock()
        sampleRate = Double(sr)
        channels = Int(ch)
        bitsPerSample = Int(bits)
        totalSamples = total
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sr), channels: ch, interleaved: false)
        let initial = total > 0 ? Int(total) : 1 << 20
        storeCapacity = initial
        store = (0..<Int(ch)).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: initial) }
        lock.unlock()
        print("[HiResFLAC] STREAMINFO: \(sr)Hz \(ch)ch \(bits)bit totalSamples=\(total) (\(total > 0 ? String(format: "%.1f", Double(total)/Double(sr)) : "?")s)")
    }

    // Called from libFLAC write callback (decode thread), once per FLAC frame. Just converts the
    // frame into the planar store; scheduling happens in batches (see maybeScheduleBatch) so we
    // don't flood the engine with thousands of tiny buffers (which caused HALC overload + glitches).
    fileprivate func appendFrame(samples: UnsafePointer<UnsafePointer<Int32>?>, frameCount n: Int) -> FLAC__StreamDecoderWriteStatus {
        lock.lock()
        guard channels > 0, !aborted else { lock.unlock(); return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE }
        ensureCapacityLocked(extra: n)
        let scale = 1.0 / Float(1 << (bitsPerSample - 1))
        let startInStore = decodedFrames
        for c in 0..<channels {
            guard let src = samples[c] else { continue }
            let dst = store[c].advanced(by: startInStore)
            for i in 0..<n { dst[i] = Float(src[i]) * scale }
        }
        decodedFrames += n
        lock.unlock()
        maybeScheduleBatch(force: false)
        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
    }

    /// Schedule the not-yet-scheduled tail of the store as a single buffer, but only once enough
    /// has accumulated (or `force` on EOF). First batch uses a small threshold for fast start;
    /// later batches are larger to keep the scheduled-buffer count (and overhead) low.
    private func maybeScheduleBatch(force: Bool) {
        lock.lock()
        guard let format, channels > 0, !aborted, sampleRate > 0 else { lock.unlock(); return }
        let pending = decodedFrames - scheduledFrames
        let threshold = started ? Int(sampleRate * 0.5) : Int(sampleRate * 0.2)
        guard pending > 0, force || pending >= threshold else { lock.unlock(); return }
        let from = scheduledFrames
        let chunk = makeBuffer(format: format, from: from, count: pending, channels: channels)
        scheduledFrames = decodedFrames
        let firstSchedule = !started
        let gen = generation
        if firstSchedule { started = true }
        lock.unlock()

        if firstSchedule, !engine.isRunning {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do { try engine.start() }
            catch {
                finishReady(.failure(HiResFLACPlayer.PlayerError.engineStartFailed(error.localizedDescription)))
                lock.lock(); aborted = true; lock.unlock()
                bytes.abort()
                return
            }
        }
        if let chunk { scheduleChunk(chunk, generation: gen) }
        if firstSchedule {
            player.play()
            finishReady(.success(()))
        }
    }

    // MARK: Helpers (most assume `lock` already held where noted)

    private func ensureCapacityLocked(extra: Int) {
        let needed = decodedFrames + extra
        if needed <= storeCapacity { return }
        let newCap = max(needed, storeCapacity * 2)
        var newStore: [UnsafeMutablePointer<Float>] = []
        for old in store {
            let new = UnsafeMutablePointer<Float>.allocate(capacity: newCap)
            new.update(from: old, count: decodedFrames)
            old.deallocate()
            newStore.append(new)
        }
        store = newStore
        storeCapacity = newCap
    }

    /// Copy [from, from+count) of the planar store into a fresh non-interleaved Float32 buffer.
    /// Assumes `lock` is held (reads `store`).
    private func makeBuffer(format: AVAudioFormat, from: Int, count: Int, channels: Int) -> AVAudioPCMBuffer? {
        guard count > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let dst = buf.floatChannelData else { return nil }
        for c in 0..<channels {
            memcpy(dst[c], store[c].advanced(by: from), count * MemoryLayout<Float>.size)
        }
        buf.frameLength = AVAudioFrameCount(count)
        return buf
    }

    private func scheduleChunk(_ buf: AVAudioPCMBuffer, generation gen: Int) {
        // `.dataPlayedBack` fires when the buffer has *actually been heard*, not merely consumed
        // into the render pipeline. With the default (.dataConsumed) the engine drains every
        // scheduled buffer within the first moment of playback, so completions would fire seconds
        // early. We still don't trust the completion alone for end-of-track — see checkEnd().
        player.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.checkEnd(generation: gen)
        }
    }

    /// Fire onEnded only once the *player has actually played through to the end of the stream*.
    /// We judge by the real render position (player time), not by decode progress — streaming
    /// decodes the whole file within seconds while playback is still near the start, so a
    /// decode-progress check would end the track immediately. Called both from buffer-played-back
    /// completions and once when the decode loop finishes (covers the race where the final buffer's
    /// completion fires before `producingDone` is set).
    private func checkEnd(generation gen: Int) {
        lock.lock()
        guard gen == generation, started, !ended, producingDone, sampleRate > 0 else { lock.unlock(); return }
        let target = totalSamples > 0 ? Int(totalSamples) : decodedFrames
        let base = baseFrame
        lock.unlock()

        var played = base
        if let nodeTime = player.lastRenderTime,
           let pt = player.playerTime(forNodeTime: nodeTime) {
            played = base + Int(pt.sampleTime)
        }
        guard played >= target - 2 else { return }   // small tolerance for the final partial frame

        lock.lock()
        let fire = !ended && gen == generation
        if fire { ended = true }
        let cb = fire ? onEnded : nil
        lock.unlock()
        cb?()
    }

    private func finishReady(_ result: Result<Void, Error>) {
        lock.lock()
        let h = readyHandler
        readyHandler = nil
        lock.unlock()
        h?(result)
    }
}

// MARK: - URLSession streaming → byte buffer

extension FLACStreamPipeline: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        downloadedBytes += data.count
        if headMagic.count < 16 { headMagic.append(data.prefix(16 - headMagic.count)) }
        lock.unlock()
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            lock.lock(); networkError = error; lock.unlock()
            bytes.abort()
        } else {
            bytes.markEOF()
        }
    }
}

// MARK: - Blocking byte buffer (network producer → decoder consumer)

private final class StreamingByteBuffer: @unchecked Sendable {
    private let cond = NSCondition()
    private var data = Data()
    private var eof = false
    private var aborted = false

    func append(_ d: Data) {
        cond.lock(); data.append(d); cond.signal(); cond.unlock()
    }

    func markEOF() {
        cond.lock(); eof = true; cond.broadcast(); cond.unlock()
    }

    func abort() {
        cond.lock(); aborted = true; cond.broadcast(); cond.unlock()
    }

    /// Blocks until at least one byte is available, or EOF/abort. Returns:
    ///   - nil   → aborted (stop)
    ///   - empty → clean EOF
    ///   - data  → up to `maxLength` bytes
    func read(maxLength: Int) -> Data? {
        cond.lock(); defer { cond.unlock() }
        while data.isEmpty && !eof && !aborted { cond.wait() }
        if aborted { return nil }
        if data.isEmpty && eof { return Data() }
        let n = min(maxLength, data.count)
        let chunk = data.prefix(n)
        data.removeFirst(n)
        return Data(chunk)
    }
}

// MARK: - libFLAC C callbacks (plain C function pointers, no captures)

private func flac_read_cb(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ buffer: UnsafeMutablePointer<FLAC__byte>?,
    _ bytes: UnsafeMutablePointer<Int>?,
    _ clientData: UnsafeMutableRawPointer?
) -> FLAC__StreamDecoderReadStatus {
    guard let clientData, let buffer, let bytes else {
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT
    }
    let pipe = Unmanaged<FLACStreamPipeline>.fromOpaque(clientData).takeUnretainedValue()
    return pipe.provideBytes(into: buffer, bytes: bytes)
}

private func flac_write_cb(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ frame: UnsafePointer<FLAC__Frame>?,
    _ buffer: UnsafePointer<UnsafePointer<FLAC__int32>?>?,
    _ clientData: UnsafeMutableRawPointer?
) -> FLAC__StreamDecoderWriteStatus {
    guard let clientData, let frame, let buffer else {
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
    }
    let pipe = Unmanaged<FLACStreamPipeline>.fromOpaque(clientData).takeUnretainedValue()
    let blockSize = Int(frame.pointee.header.blocksize)
    return buffer.withMemoryRebound(to: UnsafePointer<Int32>?.self, capacity: 8) { typedBuf in
        pipe.appendFrame(samples: typedBuf, frameCount: blockSize)
    }
}

private func flac_metadata_cb(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ metadata: UnsafePointer<FLAC__StreamMetadata>?,
    _ clientData: UnsafeMutableRawPointer?
) {
    guard let metadata, let clientData else { return }
    guard metadata.pointee.type == FLAC__METADATA_TYPE_STREAMINFO else { return }
    let pipe = Unmanaged<FLACStreamPipeline>.fromOpaque(clientData).takeUnretainedValue()
    let info = metadata.pointee.data.stream_info
    pipe.setStreamInfo(sampleRate: info.sample_rate, channels: info.channels, bits: info.bits_per_sample, total: info.total_samples)
}

private func flac_error_cb(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ status: FLAC__StreamDecoderErrorStatus,
    _ clientData: UnsafeMutableRawPointer?
) {
    print("[HiResFLAC] decoder error status=\(status.rawValue)")
}
