import Foundation
import Combine

/// Watches PlaybackEngine for track changes and records the home-screen
/// "recent plays" / "now playing" snapshot into the App Group container
/// (`SharedRecentStore` / `SharedNowPlayingStore`): downloads the cover to the
/// shared container and pushes a `SharedRecentTrack` entry on every track change.
///
/// Historically this fed the home-screen widget via `WidgetCenter`; the widget
/// target was removed, but the recording logic is kept (it's cheap and the
/// shared store can still be consumed by other surfaces, e.g. a future
/// Live Activity or Shortcuts lookup).
@MainActor
final class RecentTracksRecorder: ObservableObject {
    private weak var playback: PlaybackEngine?
    private var cancellables = Set<AnyCancellable>()
    private var lastTrackID: String?

    func bind(to playback: PlaybackEngine) {
        self.playback = playback
        // Two observers. Both use `.receive(on: DispatchQueue.main)` to hop to
        // the next runloop: Combine's `@Published` emits in `willSet`, so if we
        // read `playback.isPlaying` synchronously in the sink we'd see the
        // *old* value (the snapshot would then capture the inverted play/pause
        // state). Hopping one runloop lets `didSet` complete and the property
        // reflect its new value before we snapshot.
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
    }

    /// Writes the current snapshot (title/artist/cover/isPlaying/elapsed)
    /// into the App-Group store. Consumers extrapolate `elapsed` from `updatedAt`
    /// so we don't need to write every second.
    private func snapshotNowPlaying() {
        guard let playback else { return }
        guard let track = playback.currentTrack else {
            SharedNowPlayingStore.clear()
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
            updatedAt: Date()
        )
        SharedNowPlayingStore.write(snapshot)
    }

    private func handleTrackChange(_ track: Track?) {
        guard let track else {
            SharedNowPlayingStore.clear()
            return
        }
        guard track.id != lastTrackID else { return }
        lastTrackID = track.id

        let id = track.id
        let title = track.name
        let artist = track.singer.isEmpty ? track.source.displayName : track.singer
        let sourceName = track.source.displayName
        let coverURL = track.picURL

        // Push immediately without cover so the recent-plays tile can show
        // *something* within seconds (brand-gradient + first-character
        // placeholder), then update again once the real image is on disk.
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
