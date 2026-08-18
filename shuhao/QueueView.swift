import SwiftUI

/// "Up Next" — current playback queue with reorder / remove / tap-to-play.
/// Shown as a sheet from PlayerView.
struct QueueView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @ObservedObject private var downloads = DownloadStore.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modeBar
                if playback.queue.isEmpty {
                    BrandedEmpty(icon: "music.note.list",
                                 title: "队列空空如也",
                                 subtitle: "从搜索、排行榜或歌单点歌后,接下来播放的歌会显示在这里",
                                 topPadding: 80)
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(Array(playback.queue.enumerated()), id: \.element.id) { idx, track in
                                row(idx: idx, track: track)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            }
                            .onMove { src, dst in
                                guard let from = src.first else { return }
                                playback.moveInQueue(from: from, to: dst)
                            }
                            .onDelete { idxs in
                                for i in idxs.sorted(by: >) { playback.removeFromQueue(at: i) }
                            }
                        } header: {
                            // queue count已经移到 modeBar 右侧,这里只留 section 标题
                            Text("接下来播放")
                                .font(DS.Typo.caption)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .textCase(nil)   // 防止 List section header 默认全大写
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .sheetNavBarSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                if !playback.queue.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            playback.clearQueue()
                            dismiss()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(idx: Int, track: Track) -> some View {
        let isCurrent = idx == playback.queueIndex
        HStack(spacing: 10) {
            // Leading: either an animated "now playing" indicator or the queue number
            ZStack {
                if isCurrent {
                    Image(systemName: playback.isPlaying ? "waveform" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.accentColor)
                        .variableColorEffect(isActive: playback.isPlaying)
                } else {
                    Text("\(idx + 1)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 24)

            Artwork(url: downloads.displayCoverURL(for: track), size: 38, radius: 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(track.name)
                        .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? .accentColor : .primary)
                        .lineLimit(1)
                    if let style = QualityBadgeStyle(highestIn: track.qualities) {
                        QualityBadge(style: style)
                    }
                }
                HStack(spacing: 5) {
                    SourceChip(source: track.source)
                    Text(track.singer).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let d = track.duration {
                Text(format(d))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isCurrent {
                playback.togglePlayPause()
            } else {
                playback.jump(to: idx)
            }
        }
    }

    /// Single combined cycle-mode pill (shared with PlayerView controlSection) on the
    /// left, queue count on the right. Replaces the previous two-button design which
    /// duplicated controls the PlayerView already exposed.
    private var modeBar: some View {
        let cycle = PlaybackCycleMode.current(shuffle: playback.shuffle, loop: playback.loopMode)
        return HStack(spacing: 10) {
            Button {
                cycle.advanced().apply(to: playback)
            } label: {
                Label(cycle.label, systemImage: cycle.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(DS.Palette.brandGradient, in: Capsule())
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            Spacer()
            if !playback.queue.isEmpty {
                Text("\(playback.queue.count) 首")
                    .font(DS.Typo.numeric)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, 10)
    }

    private func format(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}

// symbolEffect(.variableColor.iterative) 仅 iOS 17+ 可用;iOS 16 上等价降级为无动画。
extension View {
    @ViewBuilder
    func variableColorEffect(isActive: Bool) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.variableColor.iterative, isActive: isActive)
        } else {
            self
        }
    }
}
