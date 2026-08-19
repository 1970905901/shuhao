import SwiftUI
import Combine

/// Single playback event — recorded each time a track starts. Keeps enough to
/// build the listening-report stats (count, total time, per-source breakdown,
/// day-by-day heatmap) without re-running the playlist resolver.
struct PlayEvent: Codable, Hashable {
    let trackID: String
    let playedAt: Date
    /// Track duration (seconds) at the moment of play — captured so we can
    /// compute "total listening time" without re-resolving each track. nil for
    /// tracks where the engine never knew the duration (rare).
    let duration: Int?
}

/// Recently-played tracks + event stream. Recorded by PlaybackEngine via `onTrackPlayed`
/// and persisted to disk so history survives relaunches.
@MainActor
final class PlayHistoryStore: ObservableObject {
    /// Most-recent first, deduped by id — used by the "Recently Played" list UI.
    @Published private(set) var tracks: [Track] = []
    /// Full event stream (no dedup), newest first. Powers all statistics.
    /// Capped at `maxEvents` so the JSON stays small (~50KB at cap).
    @Published private(set) var events: [PlayEvent] = []

    private let tracksURL: URL
    private let eventsURL: URL
    private let maxEntries = 200
    private let maxEvents = 5000

    init() {
        let dir = AppPaths.documents
        self.tracksURL = dir.appendingPathComponent("playHistory.json")
        self.eventsURL = dir.appendingPathComponent("playEvents.json")
        load()
    }

    /// Insert at top of tracks (dedup by id) **and** append a fresh event to the
    /// event stream. Caller hits this on every successful play start.
    func record(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
        if tracks.count > maxEntries { tracks.removeLast(tracks.count - maxEntries) }
        // Push the event (newest first to match `tracks` ordering)
        events.insert(PlayEvent(trackID: track.id, playedAt: Date(), duration: track.duration), at: 0)
        if events.count > maxEvents { events.removeLast(events.count - maxEvents) }
        save()
    }

    func remove(_ trackID: String) {
        tracks.removeAll { $0.id == trackID }
        // Keep the event stream intact — historical events about a removed
        // track are still part of "what you listened to". Removing them would
        // skew the report.
        save()
    }

    func clear() {
        tracks.removeAll()
        events.removeAll()
        save()
    }

    /// Looks up a Track by id in the most-recent list. Used by the stats page
    /// to render "Top 10 most-played" entries since events only carry trackIDs.
    func track(for id: String) -> Track? {
        tracks.first(where: { $0.id == id })
    }

    private func load() {
        if let data = try? Data(contentsOf: tracksURL),
           let decoded = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = decoded
        }
        if let data = try? Data(contentsOf: eventsURL),
           let decoded = try? JSONDecoder().decode([PlayEvent].self, from: data) {
            events = decoded
        } else if !tracks.isEmpty {
            // First-run migration: synthesize one event per existing track so
            // the stats page isn't completely empty for upgrading users. Times
            // are approximate (now) — better than nothing.
            events = tracks.map { PlayEvent(trackID: $0.id, playedAt: Date(), duration: $0.duration) }
            try? JSONEncoder().encode(events).write(to: eventsURL, options: .atomic)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: tracksURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: eventsURL, options: .atomic)
        }
    }
}

// MARK: - 播放历史

struct PlayHistoryView: View {
    @EnvironmentObject var history: PlayHistoryStore
    @State private var showClear = false

    var body: some View {
        VStack(spacing: 0) {
            #if targetEnvironment(macCatalyst)
            MacPageHeader("最近播放") {
                if !history.tracks.isEmpty {
                    Button { showClear = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空播放历史")
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            #endif
            historyList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if targetEnvironment(macCatalyst)
        // 和资料库等 Mac 详情页保持同一背景 — brandedSurface 的底色和外层容器
        // (IPadRootView 的 contentBackground)不同,顶部安全区会露出一条色带。
        .background(IPad.Color.contentBackground)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .brandedSurface()
        .navigationTitle("播放历史")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !history.tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showClear = true } label: { Image(systemName: "trash") }
                }
            }
        }
        #endif
        .overlay {
            if history.tracks.isEmpty {
                BrandedEmpty(icon: "clock.arrow.circlepath",
                             title: "还没有播放记录",
                             subtitle: "播放过的歌曲会出现在这里",
                             topPadding: 80)
            }
        }
        // confirmationDialog attached to a toolbar Button was rendering as a
        // popover anchored to the trash icon (top-right) instead of a centered
        // sheet — iOS 26 changed the behavior. .alert always centers + always
        // shows both buttons, which is the experience we actually want here.
        .alert("清空播放历史?", isPresented: $showClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { history.clear() }
        } message: {
            Text("清空后无法恢复")
        }
    }

    private var historyList: some View {
        List {
            if !history.tracks.isEmpty {
                // Section header: count + clear shortcut feel like a small toolbar
                // attached to the list, rather than a stripe of secondary text.
                Section {
                    ForEach(Array(history.tracks.enumerated()), id: \.element.id) { idx, t in
                        HStack(alignment: .center, spacing: 4) {
                            Text("\(idx + 1)")
                                .font(DS.Typo.numeric)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .frame(width: 28)
                            TrackRow(track: t)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { AppServices.shared.playback?.play(track: t, in: history.tracks, startIndex: idx) }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { history.remove(t.id) } label: {
                                Label("移除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("最近播放")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.textTertiary)
                        Spacer()
                        Text("\(history.tracks.count) 首")
                            .font(DS.Typo.numeric)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
