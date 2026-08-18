import SwiftUI

// MARK: - iPad / Mac Vinyl Disc (高级透明彩胶)
//
// 完美复刻 QQ 音乐最新桌面端“透明彩胶”视觉美学：
// 1. 唱针轴心外推至右上角安全区，长臂自然向右下方倾斜下垂。
// 2. 保持硬朗的大折角机械感，整体长度紧凑。
// 3. 极简纯白流线圆润胶囊唱头（Pill Shape），完美顺应长杆切线夹角。
// 4. 高阶全景高斯模糊悬空软阴影，营造完美的空气悬浮立体感。
// 5. 【终极精准校准】扫过角度完美定死在 +17.2 度，确保起点贴紧最外圈，终点死死咬在内圈封面边缘，绝不过头！

struct IPadVinylDisc: View {
    let imageURL: String?
    let isPlaying: Bool
    
    /// 彩胶染色基底 — 外部可传入封面提取的色彩
    var vinylTint: Color = .blue
    var size: CGFloat = 520
    
    /// 播放进度 0...1
    /// 歌曲切换时重置为 0（落针最外圈 groove），歌曲结束时为 1（精准推进至内圈封面边缘）
    var progress: Double = 0

    @State private var angle: Double = 0
    @State private var lastTickAt: Date = Date()
    @State private var ticker: Timer?

    /// Disc 实际直径 (去掉外圈光晕的空间)
    private var discSize: CGFloat { size * 0.82 }
    /// 封面圆形大小 (嵌在唱片中心)
    private var coverSize: CGFloat { discSize * 0.55 }

    // MARK: - 唱针物理几何参数 (精密契合全轨迹，拒绝任何过头或脱轨)
    /// 唱针总扫过角度：+17.2度 (🛠️ 经过严密实测的终极黄金角：既保证进得去，又卡死在封面外圈切线上)
    private let armSweepDegrees: Double = 17.2
    /// 唱针旋转与渲染的绝对对齐基准轴心 (右上角)
    private let armAnchor = UnitPoint(x: 0.94, y: 0.12)

    var body: some View {
        ZStack {
            // 1. 外圈柔光染色晕 (Bloom 散射)
            bloom

            // 2. 唱片本体 + 圆形封面 (一起旋转，30秒/圈)
            ZStack {
                discBody
                cover
            }
            .frame(width: discSize, height: discSize)
            .rotationEffect(.degrees(angle))

            // 3. 顶部高亮高光层 (不旋转 — 相对光源固定)
            glossyHighlight
                .frame(width: discSize, height: discSize)
                .blendMode(.screen)
                .allowsHitTesting(false)

            // 4. 中心轴孔
//            spindle
            
            // 5. 【终极完美版】右下侧现代流线型长唱针
            tonearmCanvas
                .frame(width: size, height: size)
                .rotationEffect(
                    .degrees(armSweepDegrees * max(0, min(1, progress))),
                    anchor: armAnchor
                )
                .allowsHitTesting(false)
                .zIndex(10)
        }
        .frame(width: size, height: size)
        .onAppear {
            if isPlaying { startTicker() }
        }
        .onDisappear { stopTicker() }
        .shOnChange(of: isPlaying) {
            if isPlaying {
                startTicker()
            } else {
                stopTicker()
            }
        }
    }

    // MARK: - Disc Body (彩胶唱片本体)
    private var discBody: some View {
        Canvas { ctx, sz in
            let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let outer = min(sz.width, sz.height) / 2
            let inner = outer * 0.55 + 4

            // 1. 半透明彩胶染色基底 — 模拟塑料厚度光透感
            ctx.fill(
                Path(ellipseIn: CGRect(x: 0, y: 0, width: sz.width, height: sz.height)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: vinylTint.opacity(0.85), location: 0.0),
                        .init(color: vinylTint.opacity(0.70), location: 0.5),
                        .init(color: vinylTint.opacity(0.55), location: 0.85),
                        .init(color: vinylTint.opacity(0.45), location: 1.0),
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: outer
                )
            )

            // 2. 密接声学沟槽细线
            let grooveCount = 48
            for i in 0..<grooveCount {
                let frac = CGFloat(i) / CGFloat(grooveCount - 1)
                let r = inner + (outer - inner - 4) * frac
                let alpha = 0.18 + 0.10 * Double(i % 5) / 5.0
                let w: CGFloat = (i % 8 == 0) ? 1.3 : 0.55
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                    with: .color(.black.opacity(alpha)),
                    lineWidth: w
                )
            }

            // 3. 封面边缘外的“标签”亮环
            let labelOuter = inner + 2
            ctx.stroke(
                Path(ellipseIn: CGRect(x: center.x - labelOuter, y: center.y - labelOuter, width: labelOuter * 2, height: labelOuter * 2)),
                with: .color(.white.opacity(0.55)),
                lineWidth: 2
            )

            // 4. 内圈深色轨道边界线
            ctx.stroke(
                Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)),
                with: .color(.black.opacity(0.35)),
                lineWidth: 1
            )

            // 5. 外沿镜面反光切边
            ctx.stroke(
                Path(ellipseIn: CGRect(x: 1.5, y: 1.5, width: sz.width - 3, height: sz.height - 3)),
                with: .color(.white.opacity(0.45)),
                lineWidth: 2.5
            )
            // 外沿细小倒角阴影线
            ctx.stroke(
                Path(ellipseIn: CGRect(x: 4, y: 4, width: sz.width - 8, height: sz.height - 8)),
                with: .color(.black.opacity(0.25)),
                lineWidth: 0.8
            )
        }
    }

    // MARK: - Center Cover (中心封面)
    private var cover: some View {
        Group {
            if let urlStr = imageURL {
                CoverImage(url: urlStr, maxPixel: coverSize) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    coverPlaceholder
                }
            } else {
                coverPlaceholder
            }
        }
        .frame(width: coverSize, height: coverSize)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(.black.opacity(0.4), lineWidth: 2)
                .blur(radius: 1)
        )
        .overlay(
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    private var coverPlaceholder: some View {
        LinearGradient(
            colors: [vinylTint.opacity(0.6), vinylTint.opacity(0.25)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note")
                .font(.system(size: coverSize * 0.3, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        )
    }

    // MARK: - Outer Bloom (染色外圈漫反射)
    private var bloom: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        vinylTint.opacity(0.65),
                        vinylTint.opacity(0.35),
                        vinylTint.opacity(0.10),
                        .clear,
                    ],
                    center: .center,
                    startRadius: discSize * 0.35,
                    endRadius: size * 0.55
                )
            )
            .blur(radius: 22)
            .frame(width: size, height: size)
    }

    // MARK: - Glossy Highlight (弧形反光)
    private var glossyHighlight: some View {
        ZStack {
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.10), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: discSize * 1.05, height: discSize * 0.55)
                .offset(y: -discSize * 0.22)
                .rotationEffect(.degrees(-15))
                .blur(radius: 8)

            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: discSize * 0.22, height: discSize * 0.22)
                .offset(x: -discSize * 0.22, y: -discSize * 0.30)
                .blur(radius: 18)
        }
        .mask(Circle())
    }

    // MARK: - Spindle (中心轴)
    private var spindle: some View {
        ZStack {
            Circle()
                .fill(.black)
                .frame(width: 16, height: 16)
            Circle()
                .stroke(.white.opacity(0.45), lineWidth: 0.6)
                .frame(width: 16, height: 16)
        }
    }

    // MARK: - Tonearm Canvas (大折角高精对齐绘制层)
    private var tonearmCanvas: some View {
        Canvas { ctx, sz in
            let pivot = CGPoint(x: sz.width * armAnchor.x, y: sz.height * armAnchor.y)
            let bend = CGPoint(x: sz.width * 0.93, y: sz.height * 0.535)
            let stylus = CGPoint(x: sz.width * 0.85, y: sz.height * 0.705)

            // 1. 全景高斯模糊悬空软阴影层
            ctx.drawLayer { shadowCtx in
                shadowCtx.addFilter(.blur(radius: 8))
                var shadowPath = Path()
                shadowPath.move(to: CGPoint(x: pivot.x + 6, y: pivot.y + 10))
                shadowPath.addLine(to: CGPoint(x: bend.x + 6, y: bend.y + 10))
                shadowPath.addLine(to: CGPoint(x: stylus.x + 6, y: stylus.y + 10))
                
                shadowCtx.stroke(
                    shadowPath,
                    with: .color(.black.opacity(0.15)),
                    style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                )
            }

            // 2. 旋转中心轴底座
            let outerPivotR: CGFloat = 15
            let innerPivotR: CGFloat = 6
            ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - outerPivotR, y: pivot.y - outerPivotR, width: outerPivotR * 2, height: outerPivotR * 2)), with: .color(.white))
            ctx.stroke(Path(ellipseIn: CGRect(x: pivot.x - outerPivotR, y: pivot.y - outerPivotR, width: outerPivotR * 2, height: outerPivotR * 2)), with: .color(.init(white: 0.93)), lineWidth: 0.5)
            ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - innerPivotR, y: pivot.y - innerPivotR, width: innerPivotR * 2, height: innerPivotR * 2)), with: .color(.init(white: 0.90)))

            // 3. 纯白流线唱针金属杆
            var armPath = Path()
            armPath.move(to: pivot)
            armPath.addLine(to: bend)
            armPath.addLine(to: stylus)
            ctx.stroke(
                armPath,
                with: .color(.white),
                style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
            )

            // 4. 纯白流线圆润胶囊唱头
            ctx.drawLayer { bodyCtx in
                bodyCtx.translateBy(x: stylus.x, y: stylus.y)
                bodyCtx.rotate(by: Angle(radians: Double(atan2(stylus.y - bend.y, stylus.x - bend.x))))
                
                let pillW: CGFloat = 22
                let pillH: CGFloat = 9
                let pillRect = CGRect(x: -3, y: -pillH / 2, width: pillW, height: pillH)
                
                bodyCtx.fill(
                    Path(roundedRect: pillRect, cornerRadius: pillH / 2, style: .continuous),
                    with: .color(.white)
                )
            }
        }
    }

    // MARK: - Rotation Ticker (唱片匀速旋转)
    private func startTicker() {
        stopTicker()
        lastTickAt = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            let now = Date()
            let dt = now.timeIntervalSince(lastTickAt)
            lastTickAt = now
            angle += dt * 12.0
            if angle >= 360 { angle -= 360 }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

// MARK: - 越界安全防护扩展
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
