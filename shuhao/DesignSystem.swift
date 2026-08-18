import SwiftUI
import UIKit
import Combine

// MARK: - Tokens

enum DS {
    enum Spacing {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 44
    }
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 18
        static let xlarge: CGFloat = 28
    }
    enum Typography {
        static let largeTitle = Font.system(size: 32, weight: .heavy, design: .rounded)
        static let sectionTitle = Font.system(size: 22, weight: .bold, design: .rounded)
        static let trackTitle = Font.system(size: 16, weight: .semibold)
        static let trackSubtitle = Font.system(size: 13, weight: .regular)
        static let chip = Font.system(size: 11, weight: .semibold)
    }

    // MARK: New v1 visual tokens (Liquid Glass + cover-driven, dark-led).
    // Old tokens above are kept for back-compat; new code should prefer these.

    enum Palette {
        // Brand — burgundy → antique brass. Inspired by Tidal HiFi / B&O / 丰隐
        // 圣谷 palettes. Reads as "成熟、有重量、不轻浮", which fits the multi-
        // source HiFi positioning better than the original orange→red gradient
        // (which felt energetic but a bit "小众活泼").
        static let brandStart = Color(red: 0.545, green: 0.141, blue: 0.251)  // #8B2440 酒红
        static let brandEnd   = Color(red: 0.757, green: 0.541, blue: 0.310)  // #C18A4F 古铜金
        static let brand      = Color.accentColor
        static let brandGradient = LinearGradient(
            colors: [brandStart, brandEnd],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )

        // Surfaces — light/dark pairs defined as Color Sets in Assets.
        static let bgBase       = Color("BGBase")
        static let bgElevated   = Color("BGElevated")
        static let bgSunken     = Color("BGSunken")
        static let strokeSubtle = Color("StrokeSubtle")
        static let strokeStrong = Color("StrokeStrong")

        // Text
        static let textPrimary   = Color("TextPrimary")
        static let textSecondary = Color("TextSecondary")
        static let textTertiary  = Color("TextTertiary")

        /// Warm beige used on the cassette body in the app icon. Re-used as the
        /// player's primary action button surface so the on-icon-press feeling
        /// echoes the brand mark.
        static let cassetteBody = Color(red: 0.910, green: 0.788, blue: 0.604)  // #E8C99A
    }

    /// Three-step glass material scale. Use base material as the body; layer a
    /// brand or cover tint on top for state. Don't introduce new opacity values.
    enum Glass {
        static let thin: Material = .ultraThinMaterial      // chips, mini cards
        static let mid: Material = .regularMaterial         // sheets, mini player
        static let heavy: Material = .thickMaterial         // full-player overlays
    }

    /// Three elevation levels. Helpers attach a shadow tinted to the supplied color
    /// (defaults to black) so cover-color shadows work cleanly on the player.
    enum Elevation {
        static func e1(_ color: Color = .black) -> ShadowSpec {
            ShadowSpec(color: color.opacity(0.08), radius: 6, y: 2)
        }
        static func e2(_ color: Color = .black) -> ShadowSpec {
            ShadowSpec(color: color.opacity(0.14), radius: 14, y: 6)
        }
        static func e3(_ color: Color = .black) -> ShadowSpec {
            ShadowSpec(color: color.opacity(0.22), radius: 32, y: 12)
        }
    }

    /// One motion language. Pick the closest preset rather than inventing new timings.
    enum Motion {
        static let micro    = Animation.easeOut(duration: 0.18)                        // chip / focus
        static let standard = Animation.spring(response: 0.36, dampingFraction: 0.82)  // page / sheet
        static let emphasis = Animation.spring(response: 0.55, dampingFraction: 0.78)  // hero / scale
        static let lyric    = Animation.easeInOut(duration: 0.28)
    }

    /// Type scale used by v1+ surfaces. Named `Typo` (not `Type`) because Swift
    /// reserves `.Type` for metatype access. Numbers use monospacedDigit so
    /// time / counts / ranks don't jitter as values change.
    enum Typo {
        static let display     = Font.system(size: 34, weight: .bold,    design: .rounded)
        static let title       = Font.system(size: 22, weight: .bold,    design: .rounded)
        static let bodyStrong  = Font.system(size: 16, weight: .semibold)
        static let body        = Font.system(size: 15, weight: .regular)
        static let caption     = Font.system(size: 12, weight: .medium)
        static let caption2    = Font.system(size: 11, weight: .regular)
        static let numeric     = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
        static let lyricBig    = Font.system(size: 26, weight: .bold)
        static let lyricSmall  = Font.system(size: 17, weight: .medium)
    }
}

/// Plain value type so callers can store and re-apply a shadow preset.
struct ShadowSpec {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
}

extension View {
    /// Apply a `ShadowSpec` from `DS.Elevation`. Use instead of raw `.shadow(...)`
    /// for any surface that needs to participate in the elevation scale.
    func elevation(_ spec: ShadowSpec) -> some View {
        shadow(color: spec.color, radius: spec.radius, x: 0, y: spec.y)
    }

    /// Restores the brand appearance(color-scheme + accent tint) on a sheet
    /// that was opened from a parent forcing `.preferredColorScheme(...)`
    /// (i.e. PlayerView). Both default to inherited, but a forced scheme on the
    /// sheet re-roots its environment and resets `.tint`, so we have to put both
    /// back deliberately.
    func inheritedAppearance() -> some View {
        let scheme: ColorScheme = UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        return self
            .preferredColorScheme(scheme)
            .tint(Color("AccentColor"))
    }

    /// Mac Catalyst 弹窗(popover)里 NavigationStack 的导航栏修复:内容滚到栏下方后,
    /// 系统给栏切换成 chrome material 毛玻璃,而 popover 是独立浮窗,栏的 chrome 会被
    /// 解析成深色 —— 毛玻璃变黑、标题变白字。只钉背景色不够(标题仍是白字,栏底还会
    /// 漏出一条没盖住的深色毛玻璃),必须同时把栏的配色方案钉成和弹窗内容一致。
    /// 仅 Catalyst 生效,iPad/iPhone 上是 no-op。
    func sheetNavBarSurface() -> some View {
        modifier(SheetNavBarSurfaceModifier())
    }

    /// Top-level tab surface: a brand gradient wash on top of the base. Dark mode
    /// uses heavier opacity so the wash actually reads on a deep background;
    /// light mode is half-strength so it stays Apple-Music-restrained rather than
    /// going full朝霞-pink. Detail pages use a stronger cover-driven gradient
    /// (~55%) for immersion.
    func brandedSurface() -> some View {
        modifier(BrandedSurfaceModifier())
    }
}

// MARK: - Source theming

extension SourceID {
    var tint: Color {
        switch self {
        case .kw: return Color(red: 0.95, green: 0.43, blue: 0.30)   // 橙
        case .kg: return Color(red: 0.10, green: 0.69, blue: 0.94)   // 蓝
        case .tx: return Color(red: 0.20, green: 0.80, blue: 0.55)   // 绿
        case .wy: return Color(red: 0.95, green: 0.27, blue: 0.32)   // 红
        case .mg: return Color(red: 0.95, green: 0.54, blue: 0.10)   // 橙黄
        case .local: return Color(.systemGray)
        }
    }
}

// MARK: - Source chip

struct SourceChip: View {
    let source: SourceID
    var body: some View {
        Text(source.displayName)
            .font(DS.Typography.chip)
            .foregroundColor(source.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(source.tint.opacity(0.14))
            )
    }
}

// MARK: - Horizontal chip selector

/// A horizontally-scrolling row of selectable pills. Use when there are too many options
/// for a segmented control (e.g. 4 platforms, or 5 sort categories).
struct ChipBar<T: Hashable>: View {
    let items: [T]
    let title: (T) -> String
    @Binding var selection: T

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    let on = item == selection
                    Text(title(item))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(on ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(on
                                           ? AnyShapeStyle(DS.Palette.brandGradient)
                                           : AnyShapeStyle(Color(.secondarySystemBackground)))
                        )
                        .contentShape(Capsule())
                        .onTapGesture {
                            withAnimation(DS.Motion.micro) { selection = item }
                        }
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, 2)
        }
        // RootTabView 在 TabView 上挂了 .contentMargins(.bottom) 给迷你播放器让位。
        // 那个修饰符是走环境广播的,子树里**所有**滚动视图都会吃到 —— 包括这条横向
        // chip 条,于是 chip 下面凭空多出一大片空白。这里显式复位成 0。
        // 新增横向 ScrollView 时记得照做。
        .contentMargins(.bottom, 0, for: .scrollContent)
        // Subtle haptic on every selection change — the kind of "click" Apple uses on
        // segmented controls. Doesn't fire on the initial value, only on change.
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Quality badge

/// Mirrors lx-music-mobile's `useQualityTag` (components/OnlineList/ListItem.tsx#15):
/// pick the highest available quality and render it as a coloured pill.
/// Returns nil for 128k (no badge in the official UI).
enum QualityBadgeStyle {
    case master     // 臻品母带
    case atmos      // 臻品全景声 / 2.0
    case hires      // flac24bit / hires
    case lossless   // flac
    case hq         // 320k
    case sq         // 128k (rendered only when forced, e.g. in player)

    var label: String {
        switch self {
        case .master:   return "Master"
        case .atmos:    return "Atmos"
        case .hires:    return "Hi-Res"
        case .lossless: return "SQ"
        case .hq:       return "HQ"
        case .sq:       return "STD"
        }
    }
    var tint: Color {
        switch self {
        case .master:   return Color(red: 0.84, green: 0.32, blue: 0.20)  // 赤铜
        case .atmos:    return Color(red: 0.20, green: 0.50, blue: 0.92)  // 蓝
        case .hires:    return Color(red: 0.85, green: 0.62, blue: 0.13)  // 金
        case .lossless: return Color(red: 0.40, green: 0.30, blue: 0.85)  // 紫
        case .hq:       return Color(red: 0.10, green: 0.55, blue: 0.42)  // 青绿
        case .sq:       return Color(.systemGray)
        }
    }
    init?(highestIn qualities: [Quality]) {
        guard let best = Quality.ranked.first(where: { qualities.contains($0) }),
              best != .k128 else { return nil }   // 128k or empty → no badge in list rows
        self.init(quality: best)
    }
    init(quality: Quality) {
        switch quality {
        case .master:           self = .master
        case .atmosPlus, .atmos: self = .atmos
        case .hires, .flac24:   self = .hires
        case .flac:             self = .lossless
        case .k320:             self = .hq
        case .k128:             self = .sq
        }
    }
}

struct QualityBadge: View {
    let style: QualityBadgeStyle
    var body: some View {
        Text(style.label)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundColor(style.tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(style.tint, lineWidth: 1)
            )
    }
}

// MARK: - Artwork view

struct Artwork: View {
    let url: String?
    var size: CGFloat = 50
    var radius: CGFloat = DS.Radius.small

    var body: some View {
        CoverImage(url: url, maxPixel: size) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            LinearGradient(
                colors: [Color(.tertiarySystemFill), Color(.quaternarySystemFill)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundColor(.secondary)
            )
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Loading placeholder
//
// We bridge `UIActivityIndicatorView` directly instead of using SwiftUI's
// `ProgressView()`. On iOS 26 the latter is rendered as an indeterminate linear
// capsule (even with `.progressViewStyle(.circular)`), which combined with our
// `maxWidth: .infinity` produced a bar stretching edge to edge. The UIKit
// indicator has a fixed intrinsic size and is always a circular spinner.
struct UIKitSpinner: UIViewRepresentable {
    var style: UIActivityIndicatorView.Style = .medium
    var color: UIColor? = nil

    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let v = UIActivityIndicatorView(style: style)
        v.hidesWhenStopped = false
        if let color { v.color = color }
        v.startAnimating()
        return v
    }
    func updateUIView(_ uiView: UIActivityIndicatorView, context: Context) {
        uiView.startAnimating()
    }
}

/// Backs `View.sheetNavBarSurface()`. ViewModifier 形式是为了读到弹窗内容自己的
/// `colorScheme` —— popover 的 SwiftUI 内容跟随应用的明暗是对的,错的只是 UIKit
/// 导航栏 chrome,所以让栏强制跟内容一个方案即可,深色模式下同样成立。
private struct SheetNavBarSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .toolbarBackground(DS.Palette.bgBase, for: .navigationBar)
            .toolbarColorScheme(scheme, for: .navigationBar)
        #else
        content
        #endif
    }
}

/// Backs `View.brandedSurface()`. Pulled out as a ViewModifier so it can read
/// `@Environment(\.colorScheme)` and pick per-scheme opacities — light mode gets a
/// ~50% lighter wash than dark so it doesn't read as "朝霞 pink" against a near-white
/// base.
private struct BrandedSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let topOpacity: Double = scheme == .dark ? 0.14 : 0.07
        let midOpacity: Double = scheme == .dark ? 0.06 : 0.03
        let farOpacity: Double = scheme == .dark ? 0.02 : 0.01
        content.background(
            ZStack {
                DS.Palette.bgBase
                LinearGradient(
                    stops: [
                        .init(color: DS.Palette.brandStart.opacity(topOpacity), location: 0.00),
                        .init(color: DS.Palette.brandEnd.opacity(midOpacity),   location: 0.35),
                        .init(color: DS.Palette.brandEnd.opacity(farOpacity),   location: 0.70),
                        .init(color: .clear,                                     location: 1.00),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        )
    }
}

struct LoadingPlaceholder: View {
    var label: LocalizedStringKey?
    var topPadding: CGFloat = 60

    var body: some View {
        VStack(spacing: 10) {
            UIKitSpinner(style: .medium)
            if let label {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, topPadding)
    }
}

/// Branded empty state with a soft brand-gradient icon halo.
/// Use instead of bare `ContentUnavailableView` for primary surfaces (search/songlist/library)
/// to keep voice & visual treatment consistent.
struct BrandedEmpty: View {
    let icon: String
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var topPadding: CGFloat = 40

    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            ZStack {
                Circle()
                    .fill(DS.Palette.brandGradient)
                    .frame(width: 64, height: 64)
                    .opacity(0.18)
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(DS.Palette.brandGradient)
            }
            VStack(spacing: 4) {
                Text(title)
                    .font(DS.Typo.bodyStrong)
                    .foregroundStyle(DS.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, topPadding)
        .padding(.horizontal, DS.Spacing.xl)
    }
}

// MARK: - Pretty card for grid items

struct GridCard<Content: View>: View {
    let content: () -> Content
    var body: some View {
        content()
            .padding(DS.Spacing.m)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
    }
}

// MARK: - Color extraction from album art for player background

@MainActor
final class ArtworkColors: ObservableObject {
    @Published var primary: Color = .accentColor
    @Published var secondary: Color = Color(.systemBackground)

    private var inflightURL: String?

    func extract(from url: String?) {
        guard let url, url != inflightURL else { return }
        inflightURL = url
        guard let u = URL(string: url) else { return }
        Task.detached { [weak self] in
            guard let data = try? Data(contentsOf: u),
                  let img = UIImage(data: data) else { return }
            let cols = ArtworkColors.dominantColors(from: img)
            await MainActor.run { [weak self] in
                guard let self else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.primary = cols.primary
                    self.secondary = cols.secondary
                }
            }
        }
    }

    func reset() {
        inflightURL = nil
        withAnimation { primary = .accentColor; secondary = Color(.systemBackground) }
    }

    nonisolated static func dominantColors(from image: UIImage) -> (primary: Color, secondary: Color) {
        // Downsample heavily and average top quadrants for two distinct colors.
        let target = CGSize(width: 24, height: 24)
        UIGraphicsBeginImageContextWithOptions(target, true, 1)
        image.draw(in: CGRect(origin: .zero, size: target))
        let small = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let cg = small?.cgImage,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return (.accentColor, Color(.systemBackground))
        }
        let bpp = cg.bitsPerPixel / 8
        let bpr = cg.bytesPerRow
        var topR = 0, topG = 0, topB = 0, topN = 0
        var botR = 0, botG = 0, botB = 0, botN = 0
        let h = cg.height, w = cg.width
        for y in 0..<h {
            for x in 0..<w {
                let p = bytes + y * bpr + x * bpp
                let r = Int(p[0]); let g = Int(p[1]); let b = Int(p[2])
                if y < h / 2 { topR += r; topG += g; topB += b; topN += 1 }
                else { botR += r; botG += g; botB += b; botN += 1 }
            }
        }
        guard topN > 0, botN > 0 else { return (.accentColor, Color(.systemBackground)) }
        let primary = Color(red: Double(topR) / Double(topN) / 255,
                            green: Double(topG) / Double(topN) / 255,
                            blue: Double(topB) / Double(topN) / 255)
        let secondary = Color(red: Double(botR) / Double(botN) / 255,
                              green: Double(botG) / Double(botN) / 255,
                              blue: Double(botB) / Double(botN) / 255)
        return (primary, secondary)
    }
}

// MARK: - Mac 桌面版页内大标题
//
// Catalyst 上 UIKit 导航栏的 large title 左贴边+深色色带,跟桌面版其它页面
// (资料库/歌单广场的 32pt 圆体大标题)完全不搭 — 这些页面在 Mac 上隐藏导航栏
// 标题,改用这个组件;iPhone/iPad 不用,保持系统导航标题。
struct MacPageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.top, 8)
    }
}

extension MacPageHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title, trailing: { EmptyView() }) }
}

// MARK: - Background gradient for the player

struct PlayerBackdrop: View {
    let primary: Color
    let secondary: Color
    var body: some View {
        ZStack {
            // Opaque base — guarantees the backdrop never lets the underlying
            // tab view bleed through, no matter how transparent the cover-
            // color gradient ends up after extraction.
            Color.black
            LinearGradient(
                // All three stops are fully opaque now. The previous bottom
                // stop was `black @ 0.85` which, with the cover colors being
                // light tones (e.g. pale country-album beige), produced a
                // ~13% transparent floor that showed the home screen behind.
                colors: [primary, secondary, Color.black],
                startPoint: .top, endPoint: .bottom
            )
            // Soft noise / depth
            Color.black.opacity(0.15)
        }
        .ignoresSafeArea()
    }
}
