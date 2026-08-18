import SwiftUI

// MARK: - Mac (Catalyst) root
//
// First-pass: Mac Catalyst gets the same content + layout as iPad, but with
// Mac-specific window chrome: hidden title bar, unified toolbar (search +
// account button), keyboard-friendly focus. As Mac gets its own treatment
// (NSWindow customizations, native menu commands, …) the divergence lives
// inside this file rather than leaking into shared code.
//
// `ProcessInfo.isMacCatalystApp` is the runtime branch — `RootTabView` uses it
// to route here vs. IPadRootView vs. phoneTabs.

struct MacRootView: View {
    var onOpenPlayer: () -> Void = {}

    var body: some View {
        IPadRootView(onOpenPlayer: onOpenPlayer)
            // Mac Catalyst exposes the macOS `.windowToolbarStyle(.unified)`
            // and `.containerBackground(...)` modifiers through the Catalyst
            // shim, but apps that opt into iPad-style chrome via
            // `UIRequiresFullScreen` / `UIDesignsForMac=NO` will just see the
            // iPad title bar. Most of the visual difference is delegated to
            // the platform here on purpose — we'll add custom chrome
            // (Mac-only toolbar, keyboard shortcuts) once the iPad layout has
            // baked.
            .ignoresSafeArea(edges: .top)
    }
}
