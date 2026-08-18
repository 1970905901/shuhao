import SwiftUI
import Combine

/// Sleep-timer state shared between the menu in the player and any indicator UI.
/// Two modes:
///   - `.duration(minutes)`: fires after N minutes
///   - `.endOfTrack`: pauses when the current track finishes
@MainActor
final class SleepTimer: ObservableObject {
    enum Mode: Equatable {
        case duration(minutes: Int)
        case endOfTrack
    }

    @Published private(set) var mode: Mode?
    /// Remaining seconds while a `.duration` timer is counting down. nil otherwise.
    @Published private(set) var remainingSeconds: Int?

    private var endsAt: Date?
    private var tickTask: Task<Void, Never>?
    private var trackObserver: AnyCancellable?

    weak var playback: PlaybackEngine?

    func bind(to playback: PlaybackEngine) {
        self.playback = playback
        // Watch for track changes; if mode is .endOfTrack and the track that was
        // playing when we armed has just changed, pause and clear.
        trackObserver = playback.$currentTrack
            .removeDuplicates(by: { $0?.id == $1?.id })
            .dropFirst()  // skip the initial value the moment we subscribe
            .sink { [weak self] _ in
                guard let self else { return }
                if case .endOfTrack = self.mode {
                    self.fire()
                }
            }
    }

    func arm(_ mode: Mode) {
        cancel()
        self.mode = mode
        switch mode {
        case .duration(let minutes):
            let seconds = max(1, minutes) * 60
            endsAt = Date().addingTimeInterval(TimeInterval(seconds))
            remainingSeconds = seconds
            startTicking()
        case .endOfTrack:
            endsAt = nil
            remainingSeconds = nil
        }
    }

    func cancel() {
        tickTask?.cancel()
        tickTask = nil
        endsAt = nil
        remainingSeconds = nil
        mode = nil
    }

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await MainActor.run {
                    guard let endsAt = self.endsAt else { return }
                    let remaining = Int(endsAt.timeIntervalSinceNow.rounded())
                    if remaining <= 0 {
                        self.fire()
                    } else {
                        self.remainingSeconds = remaining
                    }
                }
            }
        }
    }

    private func fire() {
        playback?.pause()
        cancel()
    }

    /// Formatted "MM:SS" countdown for the active duration timer; nil for endOfTrack or off.
    var countdownText: String? {
        guard let s = remainingSeconds else { return nil }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Sheet UI for arming / cancelling the sleep timer. Lives next to the model.
struct SleepTimerSheet: View {
    @EnvironmentObject var sleepTimer: SleepTimer
    @Environment(\.dismiss) var dismiss

    private let presets: [Int] = [5, 10, 15, 30, 60]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(presets, id: \.self) { minutes in
                        Button {
                            sleepTimer.arm(.duration(minutes: minutes))
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundStyle(DS.Palette.brandGradient)
                                    .frame(width: 24)
                                Text("\(minutes) 分钟后")
                                    .foregroundStyle(DS.Palette.textPrimary)
                                Spacer()
                                if case .duration(let m) = sleepTimer.mode, m == minutes {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DS.Palette.brandStart)
                                }
                            }
                        }
                    }
                    Button {
                        sleepTimer.arm(.endOfTrack)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "music.note")
                                .foregroundStyle(DS.Palette.brandGradient)
                                .frame(width: 24)
                            Text("当前歌曲结束后")
                                .foregroundStyle(DS.Palette.textPrimary)
                            Spacer()
                            if case .endOfTrack = sleepTimer.mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DS.Palette.brandStart)
                            }
                        }
                    }
                } header: {
                    Text("到点后自动暂停播放")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .textCase(nil)
                }

                if sleepTimer.mode != nil {
                    Section {
                        Button(role: .destructive) {
                            sleepTimer.cancel()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle")
                                    .frame(width: 24)
                                Text("取消定时")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("睡眠定时")
            .navigationBarTitleDisplayMode(.inline)
            .sheetNavBarSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
