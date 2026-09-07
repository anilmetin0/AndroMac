import SwiftUI

/// The few numbers the interface is built from, in one place.
///
/// This is not a design framework and should not become one. It exists because the same handful of
/// sizes and gaps were written out by hand in a dozen files, so they drifted: eleven different font
/// sizes, three kinds of "small gap", corner radii that did not match the container they sat in.
/// Naming them is what makes the app look like one app.
enum Theme {

    /// Type scale. Every size in the UI is one of these — if a new one seems necessary, the layout
    /// is usually what needs fixing.
    enum Font {
        static let title: SwiftUI.Font = .system(size: 15, weight: .semibold)
        static let heading: SwiftUI.Font = .system(size: 13, weight: .semibold)
        static let body: SwiftUI.Font = .system(size: 12)
        static let label: SwiftUI.Font = .system(size: 11)
        static let caption: SwiftUI.Font = .system(size: 10)
        static let micro: SwiftUI.Font = .system(size: 9, weight: .semibold)
        /// Section headers: small, spaced out, quiet.
        static let section: SwiftUI.Font = .system(size: 10, weight: .semibold)
    }

    /// A 4-point rhythm. Anything not on it looks like a mistake next to something that is.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 6
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let section: CGFloat = 20
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    /// The window and panel content inset. One number, so every surface lines up with every other.
    static let inset: CGFloat = 16
}

extension View {

    /// The soft translucent plate a floating surface sits on.
    ///
    /// On macOS 26 and later this is the real material — `glassEffect` renders the depth and the
    /// specular edge the system uses everywhere else, so the app stops looking like it was drawn
    /// before the OS was. Below that it falls back to a plain rounded fill, which is what the app
    /// looked like before and is still perfectly legible.
    ///
    /// Guarded rather than gated behind a raised deployment target: nothing here is
    /// `@backDeployed`, but a runtime check costs nothing and keeps macOS 14 working.
    @ViewBuilder
    func surface(radius: CGFloat = Theme.Radius.medium) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }

    /// Let a scrolling list fade under the surface above it instead of stopping at a hard line.
    /// The pre-26 fallback is simply no effect, which is the current behaviour.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }

    /// A control that reads as a real, pressable surface on 26+, and as a bordered button before it.
    @ViewBuilder
    func prominentAction() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryAction() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
