import SwiftUI

/// Brand splash shown for ~800ms on cold launch, sitting above RootTabView.
///
/// Why we don't put this in `LaunchScreen.storyboard` instead: storyboards
/// can't run SwiftUI, can't animate, and don't share design tokens with the
/// rest of the app. The system LaunchScreen still shows for the first ~200ms
/// (image+dark bg), then this view fades in and takes over for the spring
/// reveal — the transition feels intentional rather than jumpy.
struct SplashView: View {
    @State private var logoScale: CGFloat = 0.86
    @State private var contentOpacity: CGFloat = 0
    @State private var ringScale: CGFloat = 0.6
    @State private var ringOpacity: CGFloat = 0.0

    var body: some View {
        ZStack {
            // Same base color as LaunchScreen.storyboard so the transition from
            // system splash → our SplashView is seamless (no color flash).
            DS.Palette.bgBase
                .ignoresSafeArea()
            // Brand-tinted glow centered behind the logo — gives the cold-launch
            // a "warmup" feel.
            RadialGradient(
                colors: [DS.Palette.brandStart.opacity(0.35), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 260
            )
            .ignoresSafeArea()

            VStack(spacing: DS.Spacing.l) {
                ZStack {
                    // Soft animated halo ring behind the logo.
                    Circle()
                        .stroke(DS.Palette.brandGradient, lineWidth: 2)
                        .frame(width: 132, height: 132)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)
                    // Logo card — uses the AppIcon image asset cropped to a
                    // rounded square so it reads as "the shuhao app launching"
                    // immediately.
                    appLogo
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: DS.Palette.brandStart.opacity(0.45), radius: 24, y: 6)
                        .scaleEffect(logoScale)
                }
                VStack(spacing: 4) {
                    Text("shuhao")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Palette.brandGradient)
                    Text("随便听")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .opacity(contentOpacity)
            }
        }
        .onAppear {
            // Logo settles in
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                logoScale = 1.0
            }
            withAnimation(.easeOut(duration: 0.55).delay(0.15)) {
                contentOpacity = 1
            }
            // Halo pulse — expands outward and fades.
            withAnimation(.easeOut(duration: 0.9)) {
                ringScale = 1.25
                ringOpacity = 0.6
            }
            withAnimation(.easeIn(duration: 0.6).delay(0.55)) {
                ringOpacity = 0
            }
        }
    }

    /// Tries the same icon the system shows on the home screen. If for some
    /// reason it isn't reachable (assets reorganized), fall back to a brand
    /// gradient square with a music glyph.
    @ViewBuilder
    private var appLogo: some View {
        if let ui = UIImage(named: "AppIcon")
            ?? Bundle.main.icon {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                DS.Palette.brandGradient
                Image(systemName: "music.note")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}

private extension Bundle {
    /// `UIImage(named: "AppIcon")` doesn't reliably load the app's actual icon
    /// since it's special-cased by the system. This pulls the icon by its file
    /// name listed in Info.plist's `CFBundleIcons` → `CFBundlePrimaryIcon`.
    var icon: UIImage? {
        guard let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        return UIImage(named: last)
    }
}
