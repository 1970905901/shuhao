import SwiftUI
import Combine

/// 迷你播放器的尺寸常量。放一处,免得 RootTabView 里的留白和这里的高度各改各的对不上。
enum MiniPlayerMetrics {
    /// 悬浮条自身高度
    static let barHeight: CGFloat = 52
    /// 左右缩进 —— 要比 tabbar 那颗胶囊窄一点
    static let horizontalInset: CGFloat = 20
    /// 悬浮条与 tabbar 之间想要的缝隙。
    ///
    /// 这是**设计值**,不是设备参数 —— 嫌宽窄改这一个数就行,所有机型跟着变。
    /// 用户要求"几乎无缝贴合,仅一条细缝":取 1pt(≈0.16mm),视觉上悬浮条
    /// 紧贴 tabbar 上缘,只有一条发丝般的缝隙。
    /// (历史:52 → 10 → 6 → 2 → 0 → 12.8(2mm,用户觉得太大)→ 1(本次)。
    ///  0pt 时贴死没有呼吸感;1pt 是"细缝"的最小可感值。)
    static let desiredGap: CGFloat = 1
    /// 量不到真实 tabbar 时的兜底垫高。现在走 `.overlay(alignment: .bottom)`,
    /// 所以兜底是"tabbar 顶边距屏幕底 + desiredGap"的 iPhone 15 Pro 实测值。
    /// (tabbar 顶边距屏底实测约 83pt + 1pt 细缝 = 84pt。)
    static let fallbackBottomGap: CGFloat = 84
    /// 列表最后一行与悬浮条之间的呼吸空间。
    /// 刻意不复用 desiredGap —— 那个是"悬浮条和 tabbar 的缝",两码事,
    /// 共用会导致调间距时把列表留白也一起改了。
    static let scrollBreathingRoom: CGFloat = 10
    /// 列表底部要额外让出的高度,给 .bottomContentMargin 用。
    /// 系统已经把 tabbar 那段算进安全区,所以这里只需让开悬浮条本身 + 与 tabbar 的缝隙,
    /// 再留一点呼吸空间。
    static let scrollBottomMargin: CGFloat = barHeight + desiredGap + scrollBreathingRoom
}

/// 量真实 UITabBar 的位置,算出迷你播放器该垫多高。
///
/// 之前把迷你播放器挂在 `TabView` 的 `.safeAreaInset` 上,靠底部安全区来定位;
/// 但实测在带 NavigationStack 的 tab 里行为不一致 —— 排行榜/歌单页会把悬浮条甩到
/// 屏幕中间,而搜索页正常。现在改回 `.overlay(alignment: .bottom)`,直接把悬浮条
/// 铺在 TabView 底部,再用这里量出来的 tabbar 顶边到屏幕底距离把它抬到 tabbar
/// 上方。这样定位不再依赖 `.safeAreaInset` 的隐式行为。
///
/// 公式:悬浮条底边距屏幕底 = tabbar 顶边距屏幕底 + 想要的缝隙(desiredGap)
///
/// ⚠️ 高度计算不依赖递归找 UITabBar:SwiftUI TabView 的底层实现各 iOS 版本不同
/// (iOS 26 上尤其明显),递归遍历整个 window 既慢又可能在层级变化时找不到 →
/// 兜底值永远生效、用户改 desiredGap 后"没变化"。改用系统 API 直接算:
///   tabbar 顶边距屏幕底 = UITabBar 标准内容高 49pt + 底部安全区(home indicator)
/// 这在 iOS 16~26 全程稳定,任何机型都精确。
@MainActor
final class TabBarMetrics: ObservableObject {
    static let shared = TabBarMetrics()

    /// 悬浮条底边应该距屏幕底多远(用于 `.overlay(alignment: .bottom)` 的
    /// `.padding(.bottom, ...)`)。量不到就用 iPhone 15 Pro 实测的兜底值。
    @Published private(set) var bottomGap: CGFloat = MiniPlayerMetrics.fallbackBottomGap

    /// tabbar 未必在首次布局时就进了视图树,量不到就下一轮再试,最多几次。
    private var retriesLeft = 5

    func refresh() {
        retriesLeft = 5
        // 稍微延迟一帧,等 TabView/UITabBar 完成最终布局再量,避免在转场/切页
        // 中间拿到临时 frame,把悬浮条甩到错误位置。
        DispatchQueue.main.async { [weak self] in self?.attempt() }
    }

    private func attempt() {
        guard let window = Self.keyWindow() else { return retry() }

        // 直接算 tabbar 顶边距屏底:内容高 49 + 底部安全区(home indicator)。
        // 不用 findTabBar 递归 —— SwiftUI TabView 层级各版本不同,递归既慢又不可靠。
        let tabBarContentHeight: CGFloat = 49
        let safeBottom = window.safeAreaInsets.bottom
        let topFromBottom = tabBarContentHeight + safeBottom
        let value = topFromBottom + MiniPlayerMetrics.desiredGap

        // 量到离谱的值宁可用兜底,也不要把悬浮条甩到屏幕中间去。
        // 正常 iPhone 在 50~100pt 之间;超过 150 几乎肯定是临时 frame/错误窗口。
        guard value.isFinite, value > 0, value < 150 else { return retry() }
        // ⚠️ 不用 >0.5 的死区判断:那个会让"差 0.5pt 以内的修改被吞掉",
        // 用户改 desiredGap 后感觉"没生效"。@Published 只在值变化时发布,
        // 直接赋值即可,同值不会触发多余刷新。
        if value != bottomGap { bottomGap = value }
    }

    private func retry() {
        guard retriesLeft > 0 else { return }
        retriesLeft -= 1
        DispatchQueue.main.async { [weak self] in self?.attempt() }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
    }
}

struct MiniPlayer: View {
    /// 刻意**不**观察 PlaybackEngine —— 它的 currentTime 每 0.25 秒发布一次,
    /// 观察它就等于每秒重建 4 次,配件位里正在进行的触摸会被打断(见 NowPlayingBar)。
    /// 这里只观察低频镜像;要发指令时才通过 engine 取引擎,那是取值不是观察。
    @ObservedObject private var now = NowPlayingBar.shared

    @Environment(\.colorScheme) private var colorScheme
    var onTap: () -> Void

    private var engine: PlaybackEngine? { AppServices.shared.playback }

    // 💡 核心修复：直接读取 iOS 系统真正的白天/夜间外观，防止被歌单页局部的 .colorScheme(.dark) 污染
    private var isSystemDarkMode: Bool {
        #if os(iOS)
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            return window.traitCollection.userInterfaceStyle == .dark
        }
        #endif
        return colorScheme == .dark
    }

    var body: some View {
        if let track = now.track {
            HStack(spacing: 10) {
                // 普通 Button 即可。这里一度堆过 DragGesture / 自定义 UIKit 识别器,
                // 那是在跟 tabViewBottomAccessory 的宿主抢触摸 —— 现在不用配件位了
                // (见 RootTabView 里挂载方式的说明),触摸走正常路径,不需要任何特技。
                Button(action: onTap) {
                    HStack(spacing: 10) {
                    // 封面
                        Group {
                            if let img = now.cover {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                LinearGradient(colors: [Color(.tertiarySystemFill), Color(.quaternarySystemFill)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                                    .overlay(Image(systemName: "music.note").font(.system(size: 16)).foregroundColor(.secondary))
                            }
                        }
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(track.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    // 💡 改用全局安全的 isSystemDarkMode 判断
                                    .foregroundStyle(isSystemDarkMode ? Color.white : Color.black.opacity(0.9))
                                    .lineLimit(1)

                                if let q = now.quality {
                                    QualityBadge(style: QualityBadgeStyle(quality: q))
                                }
                            }
                            Text(track.singer)
                                .font(.system(size: 11))
                                // 💡 改用全局安全的 isSystemDarkMode 判断
                                .foregroundStyle(isSystemDarkMode ? Color.white.opacity(0.65) : Color.black.opacity(0.6))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                // 连同 Spacer 占的空白一起可点,不用非得戳中文字
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if now.isBuffering {
                    UIKitSpinner(style: .medium).frame(width: 30, height: 30)
                } else {
                    PlayPauseRing(isPlaying: now.isPlaying, isDark: isSystemDarkMode) {
                        engine?.togglePlayPause()
                    }
                }
                
                Button { engine?.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .semibold))
                        // 💡 改用全局安全的 isSystemDarkMode 判断
                        .foregroundStyle(isSystemDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.8))
                        // 图标 30,但命中区放到 44 —— 小于 44 的目标在手机上明显难点
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            // 自绘悬浮条:挂在 TabView 的 safeAreaInset 上,外观得自己给
            // (配件位时期这些是系统容器提供的)
            .frame(height: MiniPlayerMetrics.barHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSystemDarkMode ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                            lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(isSystemDarkMode ? 0.35 : 0.12), radius: 10, y: 3)
        }
    }

}

// MARK: - 进度环
//
// ⚠️ 这里是整个"播放时点不动"问题的根子,改动前先读完这段。
//
// 播放时 PlaybackEngine 每 0.25 秒发一次 currentTime。以前进度环用 SwiftUI 画,
// 观察 PlaybackTicker 拿进度 —— 于是每秒有 4 次 SwiftUI 内容失效发生在
// 标签栏配件位(tabViewBottomAccessory)里面。
//
// 之前试过把观察范围"收窄"到这个叶子视图,以为影响面小就没事了。没用:
// 配件位宿主只要收到内容失效就要重新布局一次,布局会把正在进行的触摸打断。
// 子树多小无所谓,4Hz 的布局照做 —— 一次点击 200~400ms,必然横跨 1~2 次,
// 所以表现就是"一播放就点不动,暂停了反而正常"。
//
// 真正的解法是让宿主根本不知道有更新:进度环整个下沉到 UIKit,由 CAShapeLayer
// 自己订阅、自己改 strokeEnd。SwiftUI 视图树从头到尾是静止的,不产生任何失效,
// 宿主不布局,触摸自然不会被打断。
//
// 因此:不要把进度重新接回任何 SwiftUI 的 @State/@ObservedObject。

/// 只负责画那圈进度。自己订阅 4Hz,只改图层,不碰 SwiftUI。
private final class RingLayerView: UIView {
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private var bag = Set<AnyCancellable>()
    private var lastValue: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // 关键:不吃触摸,点击要能穿过去落到外面那个 Button 上
        isUserInteractionEnabled = false

        for l in [trackLayer, progressLayer] {
            l.fillColor = UIColor.clear.cgColor
            l.lineWidth = 2
            l.lineCap = .round
            layer.addSublayer(l)
        }
        progressLayer.strokeEnd = 0

        // 直接订阅进度。注意这条链的终点是 CALayer,不是 SwiftUI ——
        // 这正是它不会打断触摸的原因。
        PlaybackTicker.shared.$fraction
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply(CGFloat($0)) }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setColors(track: UIColor, progress: UIColor) {
        trackLayer.strokeColor = track.cgColor
        progressLayer.strokeColor = progress.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = (min(bounds.width, bounds.height) - trackLayer.lineWidth) / 2
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        // 直接从 12 点起画,省掉旋转变换
        let path = UIBezierPath(arcCenter: c, radius: max(0, r),
                                startAngle: -.pi / 2, endAngle: 1.5 * .pi,
                                clockwise: true).cgPath
        trackLayer.frame = bounds
        progressLayer.frame = bounds
        trackLayer.path = path
        progressLayer.path = path
    }

    private func apply(_ raw: CGFloat) {
        let v = min(1, max(0, raw))
        defer { lastValue = v }

        // 换歌/拖动进度会整条跳,这种不做补间,否则会看到指针绕一圈
        let isJump = abs(v - lastValue) > 0.2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.strokeEnd = v
        CATransaction.commit()

        if !isJump {
            // 0.25 秒来一次,补一段 0.4 秒线性动画把台阶抹平(和原来 SwiftUI 的观感一致)
            let anim = CABasicAnimation(keyPath: "strokeEnd")
            anim.fromValue = lastValue
            anim.toValue = v
            anim.duration = 0.4
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            progressLayer.add(anim, forKey: "strokeEnd")
        } else {
            progressLayer.removeAnimation(forKey: "strokeEnd")
        }
    }
}

private struct RingProgress: UIViewRepresentable {
    let isDark: Bool

    func makeUIView(context: Context) -> RingLayerView { RingLayerView() }

    func updateUIView(_ v: RingLayerView, context: Context) {
        // 只在明暗切换时走到这里,低频,不影响触摸
        v.setColors(track: isDark ? UIColor(DS.Palette.strokeStrong) : UIColor(white: 0, alpha: 0.12),
                    progress: UIColor(DS.Palette.brandStart))
    }
}

/// 播放/暂停按钮。SwiftUI 这层只随 isPlaying / isDark 变化重建 —— 都是低频。
private struct PlayPauseRing: View {
    let isPlaying: Bool
    let isDark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RingProgress(isDark: isDark)
                    .frame(width: 30, height: 30)

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(DS.Palette.brandGradient)
            }
            // 进度环画 30,命中区放到 44
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
