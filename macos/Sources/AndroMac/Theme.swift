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
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        /// The menu bar panel's own corner before macOS 26, which has no container shape to derive
        /// the card corner from. On 26+ the window's shape is read instead (`panelCard`).
        static let legacyPanel: CGFloat = 10
    }

    /// The window content inset.
    static let inset: CGFloat = Space.medium
    /// The menu bar panel's own inset, one step tighter than a window's.
    static let panelInset: CGFloat = Space.small
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

    /// The same round glass control for a `Menu`. With `.menuStyle(.button)` a menu is drawn by
    /// the button style, so it takes exactly the bezel `glassIcon` gives a button and keeps the
    /// menu's own full-size hit area. (Painting glass around a plain menu label left only the
    /// 16 pt glyph clickable, and the interactive glass layer on top ate the rest of the clicks.)
    func glassMenu() -> some View {
        self.menuStyle(.button).menuIndicator(.hidden).glassIcon()
    }

    /// A card's plate, concentric with the window it sits in. On 26+ the corner is derived from
    /// the container (the panel window), so it follows whatever radius the system gives the panel;
    /// before 26 it is the panel radius minus the inset, with a floor so it never turns square.
    @ViewBuilder
    func panelCard(_ fill: some ShapeStyle) -> some View {
        if #available(macOS 26.0, *) {
            self.background(fill, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(Theme.Radius.small)), isUniform: true))
        } else {
            self.background(fill, in: RoundedRectangle(
                cornerRadius: max(Theme.Radius.legacyPanel - Theme.panelInset, Theme.Radius.small)
            ))
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
