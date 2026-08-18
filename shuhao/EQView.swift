import SwiftUI

/// 均衡器 — 5-band parametric EQ visible inside Settings / Player ⋯ menu.
///
/// Layout:
///   Master toggle + reset
///   Curve preview (5 sliders overlay on a frequency-response strip)
///   5 vertical sliders, -12 .. +12 dB, labeled with band name
///   Preset chip grid
///
/// All edits flow through `EQStore.setGain` / `apply(preset:)` — no local
/// state, so changes appear instantly in the playing track.
struct EQView: View {
    @EnvironmentObject var eq: EQStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                masterRow
                sliderRow
                presetGrid
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.top, DS.Spacing.m)
            .padding(.bottom, DS.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandedSurface()
        .navigationTitle("均衡器")
        .navigationBarTitleDisplayMode(.large)
        .sheetNavBarSurface()
    }

    // MARK: - Master row

    private var masterRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EQ 开启")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(eq.settings.enabled ? "正在影响当前播放" : "关闭后音频按原始信号输出")
                    .font(DS.Typo.caption2)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { eq.settings.enabled },
                set: { eq.settings.enabled = $0 }
            ))
            .labelsHidden()
        }
        .padding(DS.Spacing.m)
        .background(DS.Glass.thin, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(DS.Palette.strokeSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Sliders

    private var sliderRow: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            sectionTitle("频段", subtitle: nil)
            // 10 columns horizontally — tight but fits on all iPhones from
            // mini upward. spacing: 0 + .frame(maxWidth: .infinity) inside the
            // band column lets each one claim 1/10 of the row.
            HStack(alignment: .top, spacing: 0) {
                ForEach(EQBand.allCases, id: \.self) { band in
                    bandColumn(band)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.m)
            .background(DS.Glass.thin, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .strokeBorder(DS.Palette.strokeSubtle, lineWidth: 0.5)
            )
            .opacity(eq.settings.enabled ? 1.0 : 0.55)   // dim when EQ master off
        }
    }

    private func bandColumn(_ band: EQBand) -> some View {
        let binding = Binding<Double>(
            // Defensive: if `gains` got out of sync (e.g. mid-migration), the
            // store may have fewer entries than there are bands. Treat the
            // missing slot as 0 dB and let `setGain` resize on first write.
            get: { eq.settings.gains.indices.contains(band.rawValue)
                   ? eq.settings.gains[band.rawValue] : 0 },
            set: { eq.setGain($0, for: band) }
        )
        let gain = eq.settings.gains.indices.contains(band.rawValue)
            ? eq.settings.gains[band.rawValue] : 0
        return VStack(spacing: 4) {
            // Numeric readout, monospaced so width doesn't jump as digits change
            Text(gain.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false))))
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(abs(gain) < 0.5
                                 ? AnyShapeStyle(DS.Palette.textTertiary)
                                 : AnyShapeStyle(DS.Palette.brandGradient))
            // Vertical slider — SwiftUI Slider only ships horizontal, so rotate.
            VerticalEQSlider(value: binding, range: -12...12)
                .frame(height: 180)
            Text(band.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }

    // MARK: - Presets

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            sectionTitle("预设", subtitle: nil)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(EQPreset.allCases.filter { $0 != .custom }) { preset in
                    presetChip(preset)
                }
            }
        }
    }

    private func presetChip(_ preset: EQPreset) -> some View {
        let active = eq.settings.preset == preset
        return Button {
            eq.apply(preset: preset)
        } label: {
            Text(preset.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.white : DS.Palette.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    active
                    ? AnyShapeStyle(DS.Palette.brandGradient)
                    : AnyShapeStyle(DS.Glass.thin)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(active ? Color.clear : DS.Palette.strokeSubtle, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String, subtitle: String?) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.textSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            Spacer()
            if eq.settings.gains.contains(where: { abs($0) > 0.5 }) {
                Button("重置") { eq.reset() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Palette.brandStart)
            }
        }
        .padding(.leading, 2)
    }
}

/// Vertical Slider — rotates a horizontal SwiftUI Slider 90° so the user drags
/// up/down. The center 0 dB sticks because Slider goes through the SwiftUI
/// path that supports continuous values.
private struct VerticalEQSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            // The rotated Slider needs an explicit frame in its un-rotated
            // orientation. Width here becomes the visible height after rotation.
            Slider(value: $value, in: range, step: 0.5)
                .tint(DS.Palette.brandStart)
                .rotationEffect(.degrees(-90))
                .frame(width: geo.size.height, height: geo.size.width)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
