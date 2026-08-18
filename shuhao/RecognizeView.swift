import SwiftUI

/// 听歌识曲页。聆听时显示脉冲动画,命中后展示歌曲卡片,
/// 由调用方决定"搜索这首歌"之后做什么(填入搜索框并搜索)。
struct RecognizeView: View {
    /// 识别成功后用户点"搜索这首歌"的回调,参数是 "歌名 歌手"。
    var onSearch: (String) -> Void

    @StateObject private var recognizer = SongRecognizer()
    @EnvironmentObject var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    @State private var pulse = false

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.l) {
                Spacer()
                switch recognizer.state {
                case .idle, .listening:
                    listeningPane
                case .matched(let match):
                    matchedPane(match)
                case .noMatch:
                    resultHint(icon: "questionmark.circle",
                               title: "没有听出来",
                               subtitle: "凑近声源一点,再试一次")
                case .micDenied:
                    resultHint(icon: "mic.slash",
                               title: "麦克风权限未开启",
                               subtitle: "请到 设置 > 隐私与安全性 > 麦克风 中允许")
                case .failed(let message):
                    resultHint(icon: "exclamationmark.triangle",
                               title: "识别失败",
                               subtitle: message)
                }
                Spacer()
                bottomButton
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .brandedSurface()
            .navigationTitle("听歌识曲")
            .navigationBarTitleDisplayMode(.inline)
            .sheetNavBarSurface()
            // Mac 上是 popover,点外部即可关闭,不需要关闭按钮。
            #if !targetEnvironment(macCatalyst)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            #endif
        }
        .onAppear {
            // 识别的是环境声,先把自己的播放停掉,免得识别出正在放的歌。
            if playback.isPlaying { playback.pause() }
            recognizer.start()
        }
        .onDisappear { recognizer.stop() }
    }

    // MARK: - Listening

    private var listeningPane: some View {
        VStack(spacing: DS.Spacing.l) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(DS.Palette.brandGradient, lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulse ? 1.9 : 1.0)
                        .opacity(pulse ? 0 : 0.55)
                        .animation(
                            .easeOut(duration: 1.8)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.6),
                            value: pulse)
                }
                Circle()
                    .fill(DS.Palette.brandGradient)
                    .frame(width: 120, height: 120)
                Image(systemName: "music.note")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(height: 230)
            .onAppear { pulse = true }

            Text("正在聆听…")
                .font(DS.Typo.bodyStrong)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Matched

    private func matchedPane(_ match: SongRecognizer.Match) -> some View {
        VStack(spacing: DS.Spacing.m) {
            Artwork(url: match.artworkURL?.absoluteString, size: 160, radius: DS.Radius.medium)
            Text(match.title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            Text(match.artist)
                .font(DS.Typo.body)
                .foregroundColor(.secondary)

            Button {
                onSearch("\(match.title) \(match.artist)")
                dismiss()
            } label: {
                Label("搜索这首歌", systemImage: "magnifyingglass")
                    .font(DS.Typo.bodyStrong)
                    .frame(maxWidth: 240)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, DS.Spacing.s)
        }
    }

    private func resultHint(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: DS.Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .medium))
                .foregroundColor(.secondary)
            Text(title).font(DS.Typo.bodyStrong)
            Text(subtitle)
                .font(DS.Typo.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var bottomButton: some View {
        Group {
            switch recognizer.state {
            case .matched, .noMatch, .failed:
                Button {
                    pulse = false
                    recognizer.start()
                } label: {
                    Label("再听一次", systemImage: "arrow.clockwise")
                        .font(DS.Typo.bodyStrong)
                }
                .buttonStyle(.bordered)
            case .listening:
                Button("停止") { recognizer.stop(); dismiss() }
                    .foregroundColor(.secondary)
            case .idle, .micDenied:
                EmptyView()
            }
        }
        .padding(.bottom, DS.Spacing.m)
    }
}
