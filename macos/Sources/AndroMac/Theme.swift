import SwiftUI

/// The few numbers the interface is built from, in one place.
///
/// This is not a design framework and should not become one. It exists because the same handful of
/// sizes and gaps were written out by hand in a dozen files, so they drifted. Naming them is what
/// makes the app look like one app.
enum Theme {

    /// Type scale. Every size in the UI is one of these; if a new one seems necessary, the layout
    /// is usually what needs fixing.
    enum Font {
        /// The welcome window's page titles, the one place the app speaks above panel scale.
        static let display: SwiftUI.Font = .system(size: 22, weight: .semibold)
        static let title: SwiftUI.Font = .system(size: 15, weight: .semibold)
        static let heading: SwiftUI.Font = .system(size: 13, weight: .semibold)
        static let body: SwiftUI.Font = .system(size: 12)
        static let label: SwiftUI.Font = .system(size: 11)
        static let caption: SwiftUI.Font = .system(size: 10)
    }

    /// One spacing scale, 4-point based. Control Center density: tight inside a group, one step
    /// more between groups.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    /// Radii nest: a card inside the panel is the panel radius minus the panel inset, a control
    /// inside a card is a capsule, so corners stay concentric at every level.
    enum Radius {
        static let small: CGFloat = 6
        /// A row's hover and open highlight on the panel: round enough to read as the system's
        /// own menu highlight rather than a box.
        static let row: CGFloat = 10
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        /// The menu bar panel's own corner before macOS 26.
        static let legacyPanel: CGFloat = 10
        /// The menu bar panel's window corner on macOS 26+, measured on a 2x capture of the real
        /// `MenuBarExtra` window on macOS 27 (32-33 px). The window does not hand its shape to
        /// SwiftUI, so without this `ConcentricRectangle` fell back to its 6 pt minimum.
        static let panel: CGFloat = 16
    }

    /// The window content inset.
    static let inset: CGFloat = Space.medium
    /// The menu bar panel's inset: every row starts this far from the edge, on all four sides.
    static let panelInset: CGFloat = Space.large
    /// The panel width, close to Control Center's.
    static let panelWidth: CGFloat = 320
}

extension View {

    /// Let a scrolling list fade under the surface above it instead of stopping at a hard line.
    /// The pre-26 fallback is simply no effect.
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

    /// A round icon control in the panel's control layer: Liquid Glass on 26+, a bordered circle
    /// before it. Works on `Button` and on `Menu`.
    @ViewBuilder
    func glassIcon() -> some View {
        let shaped = self.buttonBorderShape(.circle).controlSize(.small)
        if #available(macOS 26.0, *) {
            shaped.buttonStyle(.glass)
        } else {
            shaped.buttonStyle(.bordered)
        }
    }

    /// Groups nearby glass shapes so they blend as one layer on 26+. A no-op before.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = Theme.Space.small) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}
