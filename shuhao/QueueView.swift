import SwiftUI

/// "Up Next" — current playback queue with reorder / remove / tap-to-play.
/// Shown as a sheet from PlayerView.
///
/// ⚠️ 不观察 PlaybackEngine:它的 currentTime 每 0.25 秒发布一次,观察它就等于
/// 每秒重建 4 次整张队列 sheet(拖动/滚动时尤其明显)。这里只观察低频镜像
/// NowPlayingBar,队列数据经引擎快照在低频时机(出现 / 切歌)刷新。
struct QueueView: View {
    @ObservedObject private var now = NowPlayingBar.shared
    @ObservedObject private var downloads = DownloadStore.shared
    @Environment(\.dismiss) var dismiss
    /// 队列快照 —— 不随 4Hz 进度重建,只在出现 / 切歌 / 本页操作后刷新。
    @State private var queue: [Track] = []
    @State private var queueIndex: Int = 0

    private var engine: PlaybackEngine? { AppServices.shared.playback }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modeBar
                if queue.isEmpty {
                    BrandedEmpty(icon: "music.note.list",
                                 title: "队列空空如也",
                                 subtitle: "从搜索、排行榜或歌单点歌后,接下来播放的歌会显示在这里",
                                 topPadding: 80)
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(Array(queue.enumerated()), id: \.element.id) { idx, track in
                                row(idx: idx, track: track)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            }
                            .onMove { src, dst in
                                guard let from = src.first else { return }
                                engine?.moveInQueue(from: from, to: dst)
                                refreshSnapshot()
                            }
                            .onDelete { idxs in
                                guard let e = engine else { return }
                                for i in idxs.sorted(by: >) { e.removeFromQueue(at: i) }
                                refreshSnapshot()
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
                if !queue.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            engine?.clearQueue()
                            dismiss()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .onAppear { refreshSnapshot() }
        .shOnChange(of: now.track?.id) { refreshSnapshot() }
    }

    /// 从引擎拉一次队列快照(只读,不订阅)。切歌 / 出现 / 本页操作后调用。
    private func refreshSnapshot() {
        guard let e = engine else { return }
        queue = e.queue
        queueIndex = e.queueIndex
    }

    @ViewBuilder
    private func row(idx: Int, track: Track) -> some View {
        let isCurrent = idx == queueIndex
        HStack(spacing: 10) {
            // Leading: either an animated "now playing" indicator or the queue number
            ZStack {
                if isCurrent {
                    Image(systemName: now.isPlaying ? "waveform" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.accentColor)
                        .variableColorEffect(isActive: now.isPlaying)
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
                engine?.togglePlayPause()
            } else {
                engine?.jump(to: idx)
            }
        }
    }

    /// Single combined cycle-mode pill (shared with PlayerView controlSection) on the
    /// left, queue count on the right. Replaces the previous two-button design which
    /// duplicated controls the PlayerView already exposed.
    private var modeBar: some View {
        let cycle = PlaybackCycleMode.current(shuffle: now.shuffle, loop: now.loopMode)
        return HStack(spacing: 10) {
            Button {
                if let e = engine { cycle.advanced().apply(to: e) }
            } label: {
                Label(cycle.label, systemImage: cycle.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(DS.Palette.brandGradient, in: Capsule())
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            Spacer()
            if !queue.isEmpty {
                Text("\(queue.count) 首")
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
