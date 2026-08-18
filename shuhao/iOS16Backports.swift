import SwiftUI

// MARK: - iOS 16 backports
//
// The app's deployment target is iOS 16.0. Several SwiftUI APIs used elsewhere
// are iOS 17+ (`onChange(of:initial:_:)`, `sensoryFeedback`, `ContentUnavailableView`)
// or iOS 18+ (the new `Tab(...)` tab-bar API). These helpers give equivalent
// behaviour on iOS 16 so a single codebase builds and runs across 16 / 17 / 18.

extension View {
    /// iOS 16-compatible replacement for `onChange(of:initial:_:)` (iOS 17+).
    ///
    /// Mirrors the iOS 17 default `initial: true`: the action also runs the first
    /// time the view appears, not just on subsequent changes. The trailing closure
    /// takes no parameters — read the watched value from the enclosing view when you
    /// need the new value (it is already the current value when the closure fires).
    @ViewBuilder
    func shOnChange<V: Equatable>(of value: V, perform action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value, initial: true) { action() }
        } else {
            onAppear { action() }
                .onChange(of: value) { _ in action() }
        }
    }

    /// iOS 16 no-op replacement for `sensoryFeedback(_:trigger:)` (iOS 17+).
    /// On iOS 16 we simply drop the haptic — the surrounding UI is unaffected.
    func shSensoryFeedback<V: Equatable>(_ trigger: V) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }
}

/// iOS 16-compatible replacement for `ContentUnavailableView` (iOS 17+).
/// On iOS 17+ it forwards to the real `ContentUnavailableView`; on iOS 16 it
/// renders an equivalent icon + title + optional description stack.
struct ShUnavailableView: View {
    let title: String
    let systemImage: String
    var description: Text? = nil

    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView(title, systemImage: systemImage, description: description)
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                if let description {
                    description
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Spacing.l)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
