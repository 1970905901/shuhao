import SwiftUI
import Charts

/// "听歌报告" — a Spotify-Wrapped-lite drawn from `PlayHistoryStore.events`.
///
/// Layout (vertical scroll):
///   1. Hero card: total listening time + total play count (brand gradient bg)
///   2. Top 10 most-played tracks (numbered list with covers)
///   3. Source breakdown (donut chart — 酷我 / 网易云 / 酷狗 / QQ 音乐 …)
///   4. Last-30-day listen heat strip (one bar per day, plays count)
struct StatsView: View {
    @EnvironmentObject var history: PlayHistoryStore
    @EnvironmentObject var playback: PlaybackEngine
    @ObservedObject private var downloads = DownloadStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                #if targetEnvironment(macCatalyst)
                MacPageHeader("听歌报告")
                #endif
                heroCard
                topPlayedSection
                sourcePieSection
                dailyStripSection
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.bottom, DS.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if targetEnvironment(macCatalyst)
        // 和资料库等 Mac 详情页保持同一背景 — brandedSurface 的底色和外层容器
        // (IPadRootView 的 contentBackground)不同,顶部安全区会露出一条色带。
        .background(IPad.Color.contentBackground)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .brandedSurface()
        .navigationTitle("听歌报告")
        .navigationBarTitleDisplayMode(.large)
        #endif
        .overlay {
            if history.events.isEmpty {
                BrandedEmpty(icon: "chart.bar.xaxis",
                             title: "还没有可统计的播放",
                             subtitle: "听几首歌再回来,这里会出现你的听歌报告",
                             topPadding: 100)
            }
        }
    }

    // MARK: - Aggregates (cheap; recomputed on every body, fine for <5000 events)

    private var totalPlays: Int { history.events.count }
    /// Total seconds listened. Defensive: events without a duration count as 0.
    /// Caps any single event to its duration (we don't track actual listen %).
    private var totalSeconds: Int {
        history.events.reduce(0) { $0 + ($1.duration ?? 0) }
    }
    private var top10: [(trackID: String, count: Int)] {
        Dictionary(grouping: history.events, by: \.trackID)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map { $0 }
    }
    /// Per-source play counts. Keyed by SourceID rawValue so we can pull
    /// `SourceID.displayName` + tint reliably.
    private var sourceBreakdown: [(source: SourceID, count: Int)] {
        var counts: [SourceID: Int] = [:]
        for event in history.events {
            guard let t = history.track(for: event.trackID) else { continue }
            counts[t.source, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
    /// Plays per day for the last 30 calendar days, oldest first.
    private var dailyPlays: [(day: Date, count: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var result: [(Date, Int)] = []
        for offset in (0..<30).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let next = cal.date(byAdding: .day, value: 1, to: day) ?? day
            let count = history.events.filter { $0.playedAt >= day && $0.playedAt < next }.count
            result.append((day, count))
        }
        return result
    }

    // MARK: - Hero card

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "music.note.list")
                    .font(.system(size: 14, weight: .bold))
                Text("总览")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.85))

            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xl) {
                statBlock(value: durationString(totalSeconds), unit: "累计听歌")
                statBlock(value: "\(totalPlays)", unit: "次播放")
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.brandGradient, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .elevation(DS.Elevation.e2(DS.Palette.brandStart))
    }

    private func statBlock(value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    // MARK: - Top 10

    @ViewBuilder
    private var topPlayedSection: some View {
        if !top10.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                sectionTitle("最常听", systemImage: "trophy.fill")
                VStack(spacing: 0) {
                    ForEach(Array(top10.enumerated()), id: \.element.trackID) { idx, item in
                        topRow(rank: idx + 1, trackID: item.trackID, count: item.count)
                        if idx < top10.count - 1 {
                            Divider().background(DS.Palette.strokeSubtle)
                                .padding(.leading, 56)  // align past rank+cover
                        }
                    }
                }
                .background(DS.Glass.thin, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                        .strokeBorder(DS.Palette.strokeSubtle, lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private func topRow(rank: Int, trackID: String, count: Int) -> some View {
        if let track = history.track(for: trackID) {
            HStack(spacing: 12) {
                // Rank — first 3 get the brand gradient, rest are tertiary
                Text("\(rank)")
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(rank <= 3
                                     ? AnyShapeStyle(DS.Palette.brandGradient)
                                     : AnyShapeStyle(DS.Palette.textTertiary))
                    .frame(width: 20, alignment: .center)
                Artwork(url: downloads.displayCoverURL(for: track), size: 36, radius: DS.Radius.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(1)
                    Text(track.singer)
                        .font(DS.Typo.caption2)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(count) 次")
                    .font(DS.Typo.numeric)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .contentShape(Rectangle())
            .onTapGesture {
                playback.play(track: track)
            }
        }
    }

    // MARK: - Source breakdown (donut)

    @ViewBuilder
    private var sourcePieSection: some View {
        if !sourceBreakdown.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                sectionTitle("音源分布", systemImage: "chart.pie.fill")
                HStack(spacing: DS.Spacing.xl) {
                    // Donut chart
                    Chart(sourceBreakdown, id: \.source) { entry in
                        SectorMark(
                            angle: .value("count", entry.count),
                            innerRadius: .ratio(0.6),
                            angularInset: 2
                        )
                        .foregroundStyle(entry.source.tint)
                    }
                    .frame(width: 120, height: 120)

                    // Legend
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sourceBreakdown.prefix(5), id: \.source) { entry in
                            HStack(spacing: 6) {
                                Circle().fill(entry.source.tint).frame(width: 8, height: 8)
                                Text(entry.source.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DS.Palette.textPrimary)
                                Spacer(minLength: 6)
                                Text("\(entry.count)")
                                    .font(DS.Typo.numeric)
                                    .foregroundStyle(DS.Palette.textTertiary)
                            }
                        }
                    }
                }
                .padding(DS.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Glass.thin, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                        .strokeBorder(DS.Palette.strokeSubtle, lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Daily strip

    @ViewBuilder
    private var dailyStripSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            sectionTitle("近 30 天", systemImage: "calendar")
            Chart(dailyPlays, id: \.day) { entry in
                BarMark(
                    x: .value("day", entry.day, unit: .day),
                    y: .value("count", entry.count)
                )
                .foregroundStyle(DS.Palette.brandGradient)
                .cornerRadius(2)
            }
            .frame(height: 120)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisValueLabel(format: .dateTime.month().day(), centered: false)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(DS.Palette.strokeSubtle)
                    AxisValueLabel().foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .padding(DS.Spacing.l)
            .background(DS.Glass.thin, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .strokeBorder(DS.Palette.strokeSubtle, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Section title helper

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(DS.Palette.brandStart)
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Palette.textPrimary)
        }
        .padding(.leading, 2)
    }

    // MARK: - Format

    /// "12 h 34 min" / "12 min 5 s" — picks the largest non-zero unit pair.
    private func durationString(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min \(s) s" }
        return "\(s) s"
    }
}
