import Foundation
import Combine
import WidgetKit

/// Watches PlaybackEngine for track changes and keeps the home-screen widget's
/// data fresh: downloads the cover to the App Group container, pushes a
/// `SharedRecentTrack` entry, and asks WidgetCenter to reload timelines.
///
/// This was previously folded into `LiveActivityController`; now that LA is
/// gone, the widget still needs the same data flow, so it lives here as a
/// dedicated, single-responsibility component.
@MainActor
final class RecentTracksRecorder: ObservableObject {
    private weak var playback: PlaybackEngine?
    private var cancellables = Set<AnyCancellable>()
    private var lastTrackID: String?
    /// Last lyric we wrote to the widget store — used to dedupe so we only
    /// reload widgets when the line actually changes (otherwise WidgetKit
    /// throttles us into uselessness within minutes).
    private var lastLyric: String?

    func bind(to playback: PlaybackEngine) {
        self.playback = playback
        // Two observers. Both use `.receive(on: DispatchQueue.main)` to hop to
        // the next runloop: Combine's `@Published` emits in `willSet`, so if we
        // read `playback.isPlaying` synchronously in the sink we'd see the
        // *old* value (widget would then render the inverted play/pause state).
        // Hopping one runloop lets `didSet` complete and the property reflect
        // its new value before we snapshot.
        playback.$currentTrack
            .removeDuplicates(by: { $0?.id == $1?.id })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in self?.handleTrackChange(track) }
            .store(in: &cancellables)
        playback.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.snapshotNowPlaying() }
            .store(in: &cancellables)
        // Lyric-line watcher: throttle currentTime to ~1 Hz, only re-snapshot
        // when the active line text actually changes. Keeps the widget within
        // its hourly reloadAllTimelines budget while still feeling "live".
        playback.$currentTime
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.refreshLyricIfChanged() }
            .store(in: &cancellables)
    }

    private func refreshLyricIfChanged() {
        guard let playback else { return }
        let line = playback.currentLyricLine()
        guard line != lastLyric else { return }
        lastLyric = line
        snapshotNowPlaying()
    }

    /// Writes the current snapshot (title/artist/cover/isPlaying/elapsed/lyric)
    /// into the App-Group store and reloads widget timelines. The widget
    /// extrapolates `elapsed` from `updatedAt` so we don't need to write every second.
    private func snapshotNowPlaying() {
        guard let playback else { return }
        guard let track = playback.currentTrack else {
            SharedNowPlayingStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        let snapshot = SharedNowPlaying(
            trackID: track.id,
            title: track.name,
            artist: track.singer.isEmpty ? track.source.displayName : track.singer,
            coverLocalPath: SharedRecentStore.read().first(where: { $0.id == track.id })?.coverLocalPath,
            isPlaying: playback.isPlaying,
            elapsed: playback.currentTime,
            duration: playback.duration,
            currentLyric: playback.currentLyricLine(),
            updatedAt: Date()
        )
        SharedNowPlayingStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func handleTrackChange(_ track: Track?) {
        guard let track else {
            SharedNowPlayingStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        guard track.id != lastTrackID else { return }
        lastTrackID = track.id
        lastLyric = nil  // new song → re-arm the lyric dedupe

        let id = track.id
        let title = track.name
        let artist = track.singer.isEmpty ? track.source.displayName : track.singer
        let sourceName = track.source.displayName
        let coverURL = track.picURL

        // Push immediately without cover so widget can show *something* within
        // seconds (brand-gradient + first-character placeholder), then update
        // again once the real image is on disk.
        SharedRecentStore.push(SharedRecentTrack(
            id: id, title: title, artist: artist,
            coverLocalPath: nil, sourceName: sourceName))
        snapshotNowPlaying()

        Task {
            guard let localPath = await CoverCache.fetch(coverURL)?.path else { return }
            await MainActor.run {
                guard self.lastTrackID == id else { return }
                SharedRecentStore.push(SharedRecentTrack(
                    id: id, title: title, artist: artist,
                    coverLocalPath: localPath, sourceName: sourceName))
                self.snapshotNowPlaying()  // refresh NowPlaying with cover path
            }
        }
    }
}
