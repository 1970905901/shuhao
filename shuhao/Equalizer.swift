import Foundation
import Combine

/// 5-band parametric equalizer state.
///
/// Bands are centered at conventional Hi-Fi frequencies. We treat the first
/// band as a low-shelf (lifts everything below 60 Hz) and the last as a
/// high-shelf (lifts everything above 14 kHz); the three middle bands are
/// peaking filters (boost/cut around their center frequency). Combined this
/// covers what users intuitively call "bass / low-mid / mid / high-mid / treble".
struct EQSettings: Codable, Equatable {
    /// dB gain per band — ±12 dB clamp. Order matches `EQBand.allCases`.
    /// 10 bands (ISO standard 10-band graphic EQ, same as iTunes/Foobar2000).
    var gains: [Double] = Array(repeating: 0, count: 10)
    /// Which preset produced the current `gains` (or `.custom` if user dragged).
    /// Stored alongside so the UI can highlight the active chip on relaunch.
    var preset: EQPreset = .flat
    /// Master toggle. Off → tap skips DSP and audio path is bit-perfect.
    var enabled: Bool = false
}

/// ISO standard 10-band graphic equalizer frequencies (octave spacing).
/// Same band set as iTunes' EQ, foobar2000, AIMP, etc. — what most listeners
/// expect from a "10-band EQ".
enum EQBand: Int, CaseIterable {
    case b32, b64, b125, b250, b500, b1k, b2k, b4k, b8k, b16k
    /// Center frequency in Hz.
    var frequency: Double {
        switch self {
        case .b32:  return 32
        case .b64:  return 64
        case .b125: return 125
        case .b250: return 250
        case .b500: return 500
        case .b1k:  return 1000
        case .b2k:  return 2000
        case .b4k:  return 4000
        case .b8k:  return 8000
        case .b16k: return 16000
        }
    }
    /// Short label for the UI slider — kept compact so 10 columns fit on iPhone.
    var label: String {
        switch self {
        case .b32:  return "32"
        case .b64:  return "64"
        case .b125: return "125"
        case .b250: return "250"
        case .b500: return "500"
        case .b1k:  return "1k"
        case .b2k:  return "2k"
        case .b4k:  return "4k"
        case .b8k:  return "8k"
        case .b16k: return "16k"
        }
    }
    /// First band is low-shelf (lifts everything below 32 Hz), last is
    /// high-shelf (above 16 kHz), the middle 8 are peaking filters.
    var filterType: BiquadType {
        switch self {
        case .b32:  return .lowShelf
        case .b16k: return .highShelf
        default:    return .peaking
        }
    }
}

enum BiquadType {
    case lowShelf, peaking, highShelf
}

/// Curated presets — picked to be useful for the source material shuhao serves
/// (Chinese pop / classical / Hi-Res rips). Numbers are dB.
enum EQPreset: String, CaseIterable, Codable, Identifiable {
    case flat        = "标准"
    case bassBoost   = "低音增强"
    case trebleBoost = "高音增强"
    case vocal       = "人声"
    case rock        = "摇滚"
    case pop         = "流行"
    case jazz        = "爵士"
    case classical   = "古典"
    case acoustic    = "原声"
    case dance       = "电子"
    case hiphop      = "嘻哈"
    case custom      = "自定义"

    var id: String { rawValue }

    /// dB gain per band, ordered to match `EQBand.allCases`:
    /// 32 / 64 / 125 / 250 / 500 / 1k / 2k / 4k / 8k / 16k Hz
    ///
    /// Curves adapted from iTunes / foobar2000 stock presets, tuned mildly
    /// (cap ±7 dB) so combining presets doesn't blow the headroom.
    var gains: [Double] {
        switch self {
        //                  32   64  125  250  500   1k   2k   4k   8k  16k
        case .flat:        return [ 0,   0,   0,   0,   0,   0,   0,   0,   0,   0]
        case .bassBoost:   return [ 7,   6,   4,   2,   0,   0,   0,   0,   0,   1]
        case .trebleBoost: return [ 0,   0,   0,   0,   0,   0,   1,   3,   5,   7]
        case .vocal:       return [-2,  -1,   0,   2,   4,   4,   3,   1,  -1,  -2]
        case .rock:        return [ 5,   4,   2,  -1,  -2,  -1,   1,   3,   4,   5]
        case .pop:         return [-1,   0,   2,   4,   3,   2,   1,   0,  -1,  -1]
        case .jazz:        return [ 3,   2,   1,   2,  -1,  -2,   0,   1,   2,   4]
        case .classical:   return [ 4,   3,   2,   0,   0,   0,   0,   1,   2,   4]
        case .acoustic:    return [ 3,   2,   1,   2,   3,   2,   1,   2,   3,   4]
        case .dance:       return [ 6,   5,   1,  -1,  -2,  -1,   1,   3,   5,   5]
        case .hiphop:      return [ 5,   4,   2,   3,  -1,  -1,   1,  -1,   2,   3]
        case .custom:      return Array(repeating: 0, count: 10)
        }
    }
}

/// `@MainActor` because UI binds to `settings` directly via `@Published`.
/// Persists to `UserDefaults.standard` (settings, not user data → no need for iCloud).
@MainActor
final class EQStore: ObservableObject {
    @Published var settings: EQSettings {
        didSet { save() }
    }

    private let key = "eq.settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(EQSettings.self, from: data) {
            self.settings = decoded
            // Migration guard: earlier builds persisted 5-band gains. New code
            // assumes 10. If the stored count doesn't match the current
            // EQBand layout, drop the old curve rather than crash on index access.
            // Preset stays as-is so the UI can re-apply the matching curve next.
            if self.settings.gains.count != EQBand.allCases.count {
                self.settings.gains = self.settings.preset.gains
                if self.settings.gains.count != EQBand.allCases.count {
                    // Preset itself was also stale (e.g. custom 5-band) → flatline.
                    self.settings.gains = Array(repeating: 0, count: EQBand.allCases.count)
                    self.settings.preset = .flat
                }
            }
        } else {
            self.settings = EQSettings()
        }
    }

    /// Apply a preset → mirror its gains into `settings.gains`. UI calls this
    /// when a chip is tapped; subsequent slider drags will flip preset to .custom.
    func apply(preset: EQPreset) {
        settings.gains = preset.gains
        settings.preset = preset
    }

    /// Called when the UI drags a single band slider. Marks preset as .custom
    /// unless the new gain set happens to match a known preset exactly.
    func setGain(_ value: Double, for band: EQBand) {
        // Defensive: callers shouldn't, but a stale slider during migration
        // could ask to write past the array. Resize instead of crashing.
        if settings.gains.count != EQBand.allCases.count {
            settings.gains = Array(repeating: 0, count: EQBand.allCases.count)
        }
        let clamped = max(-12, min(12, value))
        settings.gains[band.rawValue] = clamped
        // Slight optimization: re-detect preset so the user sees the chip
        // highlight if they happen to drag into a stock curve.
        if let match = EQPreset.allCases.first(where: { $0 != .custom && $0.gains == settings.gains }) {
            settings.preset = match
        } else {
            settings.preset = .custom
        }
    }

    func reset() {
        settings.gains = Array(repeating: 0, count: 10)
        settings.preset = .flat
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
