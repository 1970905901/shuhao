import Foundation
import Combine
import AVFoundation
import CoreAudio       // UnsafeMutableAudioBufferListPointer — not transitive on Mac Catalyst
import MediaToolbox
import Accelerate
import os.lock
import UIKit  // CADisplayLink for level smoothing

/// Real-time 5-band equalizer attached to an `AVPlayerItem` via
/// `MTAudioProcessingTap`. Implements each band as a single biquad and chains
/// the 5 in series. Coefficients are recalculated every time the user moves a
/// slider; the live audio thread reads them through an `os_unfair_lock`-guarded
/// snapshot so we don't tear in the middle of a process callback.
///
/// Same caveat as `AudioLevelTap`: taps don't work for HLS streams. Plain
/// MP3/FLAC URLs (what shuhao serves) work fine.
///
/// We process each channel independently with its own pair of delay-line state
/// arrays (z1, z2) per band — biquads are stateful and bleeding state across
/// channels would create wrong stereo separation.
@MainActor
final class EQAudioTap: ObservableObject {

    /// Smoothed RMS volume 0…1 — same role as the old `AudioLevelTap.level`.
    /// EQAudioTap subsumes the level tap so we only install one
    /// `MTAudioProcessingTap` per AVPlayerItem (the API only allows one).
    @Published private(set) var level: Float = 0

    private var tap: MTAudioProcessingTap?
    private var displayLink: CADisplayLink?

    /// Mutable processing state. Lives outside any actor — touched from the
    /// audio thread inside the C callbacks below.
    final class State {
        /// One `[a0, a1, a2, b1, b2]` array per band. Updated atomically when
        /// the user drags a slider.
        /// 10-band ISO graphic EQ — one [a0,a1,a2,b1,b2] per band.
        var coefficients: [[Double]] = Array(repeating: [1, 0, 0, 0, 0], count: 10)
        /// `[band][channel]` history. Allocated when we first see a buffer.
        var z1: [[Double]] = []
        var z2: [[Double]] = []
        var sampleRate: Double = 44_100
        var enabled: Bool = false
        /// Latest RMS calculated by the process callback. Read on the main
        /// thread via the smoothing displayLink.
        var rawLevel: Float = 0
        /// **Heap-allocated** lock so the pointer is rock-stable across threads,
        /// independent of any Swift exclusivity / inout shenanigans around taking
        /// `&self.lock` on a class stored property. The audio thread and the main
        /// thread both pass this raw pointer straight to `os_unfair_lock_lock`,
        /// no `&` operator, no Swift access machinery in the way.
        let lock: UnsafeMutablePointer<os_unfair_lock_s>
        init() {
            lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
            lock.initialize(to: os_unfair_lock())
        }
        deinit {
            lock.deinitialize(count: 1)
            lock.deallocate()
        }
    }
    let state = State()

    // MARK: - Public API (main thread)

    /// Recompute coefficients for all 5 bands and swap them in under the lock.
    /// Safe to call as often as the user drags a slider.
    func setGains(_ gains: [Double]) {
        // Don't crash if a stale 5-band store leaks through during migration —
        // pad or truncate to current band count.
        let bandCount = EQBand.allCases.count
        var resized = gains
        if resized.count < bandCount {
            resized.append(contentsOf: Array(repeating: 0, count: bandCount - resized.count))
        } else if resized.count > bandCount {
            resized = Array(resized.prefix(bandCount))
        }
        let sr = state.sampleRate
        var newCoeffs: [[Double]] = []
        for (idx, band) in EQBand.allCases.enumerated() {
            newCoeffs.append(Self.biquadCoefficients(
                type: band.filterType,
                frequency: band.frequency,
                sampleRate: sr,
                gainDB: resized[idx]
            ))
        }
        os_unfair_lock_lock(state.lock)
        state.coefficients = newCoeffs
        os_unfair_lock_unlock(state.lock)
    }

    func setEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(state.lock)
        state.enabled = enabled
        os_unfair_lock_unlock(state.lock)
    }

    init() {
        setupTap()
        startLevelSmoothing()
    }

    /// 60 Hz display link smooths the raw RMS into a "fast attack / slow
    /// release" envelope — same logic the old AudioLevelTap had. We can't put
    /// a `@Published` write inside the audio thread (it ManagedObservableObject
    /// touches main-actor) so we sample on the main runloop instead.
    private func startLevelSmoothing() {
        let link = CADisplayLink(target: DisplayLinkProxy(owner: self),
                                 selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func tick() {
        let boosted = min(1, state.rawLevel * 3.5)
        if boosted > level {
            level = level * 0.5 + boosted * 0.5     // fast attack
        } else {
            level = level * 0.85 + boosted * 0.15   // slow release
        }
    }

    /// Mounts the tap onto the first audio track of `item`. Mirrors
    /// `AudioLevelTap.install(on:)` — same async-load-tracks dance to satisfy
    /// the iOS 16+ deprecation of `asset.tracks(withMediaType:)`.
    func install(on item: AVPlayerItem) {
        guard let tap else { return }
        Task {
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                guard let audioTrack = tracks.first else { return }
                await MainActor.run {
                    // If an existing audioMix already carries a tap (e.g. AudioLevelTap),
                    // append our params alongside it — AVMutableAudioMix accepts multiple
                    // inputParameters but in practice they share the same audioTrack,
                    // so we merge into a single AVMutableAudioMixInputParameters with
                    // the eq tap. Caller (PlaybackEngine) decides who owns the mix.
                    let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
                    inputParams.audioTapProcessor = tap
                    let mix = (item.audioMix as? AVMutableAudioMix) ?? AVMutableAudioMix()
                    mix.inputParameters = [inputParams]
                    item.audioMix = mix
                }
            } catch {}
        }
    }

    // MARK: - Tap setup

    private func setupTap() {
        // Hand the audio thread a **retained** ref so it can never deref freed memory.
        // 之前用的是 passUnretained —— 一旦 EQAudioTap 在 audio callback 还在飞的时候
        // 被 PlaybackEngine 释放,storage 指向的 State 就被 release 了,audio 线程下
        // 一拍调 `os_unfair_lock_lock(s.lock)` 拿到的是 freed/garbage 内存,
        // libplatform 会把它当成 "lock corrupt / owner thread exited without unlocking"
        // 然后 SIGKILL。crash trace 就是这个签名(EXC_BREAKPOINT + Abort Cause 15920)。
        // passRetained + 在 finalize 里 release 是 Core Audio + Swift class 的标准做法 ——
        // tap 自己持一份 State 的强引用,callbacks 一定能看到活的内存。MTAudioProcessingTap
        // 自己被释放时会触发 finalize,在那里 release,生命周期就闭环了。
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(state).toOpaque()),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                // Balance the passRetained above. After this runs, no more callbacks
                // will fire on this tap (per Core Audio contract), so it's safe to
                // drop the strong ref the audio thread was holding.
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<State>.fromOpaque(storage).release()
            },
            prepare: { tap, _, format in
                // Read sample rate from stream format so coefficients match.
                let sr = format.pointee.mSampleRate
                let storage = MTAudioProcessingTapGetStorage(tap)
                let s = Unmanaged<State>.fromOpaque(storage).takeUnretainedValue()
                os_unfair_lock_lock(s.lock)
                s.sampleRate = sr
                // Lazy-allocate the delay lines once we know channel count.
                let channels = Int(format.pointee.mChannelsPerFrame)
                s.z1 = Array(repeating: Array(repeating: 0, count: channels), count: 10)
                s.z2 = Array(repeating: Array(repeating: 0, count: channels), count: 10)
                os_unfair_lock_unlock(s.lock)
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                var timeRange = CMTimeRange()
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut
                )
                guard status == noErr, numberFramesOut.pointee > 0 else { return }

                let storage = MTAudioProcessingTapGetStorage(tap)
                let s = Unmanaged<State>.fromOpaque(storage).takeUnretainedValue()
                os_unfair_lock_lock(s.lock)
                defer { os_unfair_lock_unlock(s.lock) }

                let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                let frames = Int(numberFramesOut.pointee)

                // Pass 1: optional EQ (5-stage biquad chain). Skipped when the
                // user has the master toggle off — preserves perfect bit-for-bit
                // audio path for Hi-Res purists.
                if s.enabled {
                    for (chIdx, buffer) in bufferList.enumerated() {
                        guard chIdx < s.z1[0].count else { continue }
                        guard let data = buffer.mData else { continue }
                        let samples = data.bindMemory(to: Float.self, capacity: frames)
                        // Direct-Form II Transposed biquad:
                        //   y[n] = a0*x[n] + z1
                        //   z1   = a1*x[n] - b1*y[n] + z2
                        //   z2   = a2*x[n] - b2*y[n]
                        for band in 0..<10 {
                            let c = s.coefficients[band]
                            let a0 = c[0], a1 = c[1], a2 = c[2], b1 = c[3], b2 = c[4]
                            var z1 = s.z1[band][chIdx]
                            var z2 = s.z2[band][chIdx]
                            for i in 0..<frames {
                                let x = Double(samples[i])
                                let y = a0 * x + z1
                                z1 = a1 * x - b1 * y + z2
                                z2 = a2 * x - b2 * y
                                samples[i] = Float(y)
                            }
                            s.z1[band][chIdx] = z1
                            s.z2[band][chIdx] = z2
                        }
                    }
                }

                // Pass 2: RMS for AudioWave. Always runs — this used to live
                // in AudioLevelTap, now merged so we only need one tap (the
                // AVMutableAudioMixInputParameters audioTapProcessor field
                // only carries one).
                var sumOfSquares: Float = 0
                var totalSamples: vDSP_Length = 0
                for buffer in bufferList {
                    guard let data = buffer.mData else { continue }
                    let bytes = Int(buffer.mDataByteSize)
                    let count = bytes / 4   // assume Float32 PCM
                    let samples = data.bindMemory(to: Float.self, capacity: count)
                    var rms: Float = 0
                    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
                    sumOfSquares += rms * rms
                    totalSamples += vDSP_Length(count)
                }
                s.rawLevel = totalSamples > 0 ? min(1, sqrt(sumOfSquares)) : 0
            }
        )

        var created: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &created
        )
        if status == noErr {
            self.tap = created
        }
    }

    // MARK: - Biquad coefficients
    //
    // Robert Bristow-Johnson "Cookbook formulae for audio EQ biquad filter
    // coefficients" — the de-facto reference for audio plug-ins.
    // Returns [a0, a1, a2, b1, b2] with a0/a1/a2 normalized (divided by the
    // raw a0). Identity when gain == 0 dB.

    nonisolated static func biquadCoefficients(
        type: BiquadType,
        frequency: Double,
        sampleRate: Double,
        gainDB: Double
    ) -> [Double] {
        if abs(gainDB) < 0.01 {
            return [1, 0, 0, 0, 0]  // identity: passes signal unchanged
        }
        let A = pow(10, gainDB / 40)           // shelving gain (sqrt of linear)
        let w0 = 2 * .pi * frequency / sampleRate
        let cosW = cos(w0)
        let sinW = sin(w0)
        // Q-ish parameter. Peaking uses Q=1, shelves use S=1 (slope).
        // For shelves the cookbook uses `alpha = sinW/2 * sqrt((A+1/A)*(1/S - 1) + 2)`
        let alpha: Double
        switch type {
        case .peaking:
            let Q = 1.0
            alpha = sinW / (2 * Q)
        case .lowShelf, .highShelf:
            let S = 1.0
            alpha = sinW / 2 * sqrt((A + 1 / A) * (1 / S - 1) + 2)
        }

        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a0 = 0.0, a1 = 0.0, a2 = 0.0
        switch type {
        case .peaking:
            b0 = 1 + alpha * A
            b1 = -2 * cosW
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cosW
            a2 = 1 - alpha / A
        case .lowShelf:
            let twoSqrtAalpha = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosW + twoSqrtAalpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW)
            b2 = A * ((A + 1) - (A - 1) * cosW - twoSqrtAalpha)
            a0 = (A + 1) + (A - 1) * cosW + twoSqrtAalpha
            a1 = -2 * ((A - 1) + (A + 1) * cosW)
            a2 = (A + 1) + (A - 1) * cosW - twoSqrtAalpha
        case .highShelf:
            let twoSqrtAalpha = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosW + twoSqrtAalpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW)
            b2 = A * ((A + 1) + (A - 1) * cosW - twoSqrtAalpha)
            a0 = (A + 1) - (A - 1) * cosW + twoSqrtAalpha
            a1 = 2 * ((A - 1) - (A + 1) * cosW)
            a2 = (A + 1) - (A - 1) * cosW - twoSqrtAalpha
        }
        // Normalize by a0 so we don't need to track it in the inner loop.
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
}

/// CADisplayLink can't directly weakly target a Swift class with a `weak`
/// reference, so we hop through this proxy that holds the owner weakly.
private class DisplayLinkProxy {
    weak var owner: EQAudioTap?
    init(owner: EQAudioTap) { self.owner = owner }
    @objc func tick() { Task { @MainActor in owner?.tick() } }
}
