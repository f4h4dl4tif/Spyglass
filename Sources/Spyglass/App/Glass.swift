import SwiftUI

/// Optional Liquid Glass theme (Settings › General). Off by default; needs macOS 26.
enum GlassTheme {
    static let key = "glassTheme"
    static var supported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

private struct GlassOnKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when the glass theme is turned on and the system supports it.
    var glassOn: Bool {
        get { self[GlassOnKey.self] }
        set { self[GlassOnKey.self] = newValue }
    }
}

/// Reads the stored setting and publishes `glassOn` to the views below.
struct GlassThemeRoot: ViewModifier {
    @AppStorage(GlassTheme.key) private var stored = false
    func body(content: Content) -> some View {
        content.environment(\.glassOn, stored && GlassTheme.supported)
    }
}

extension View {
    func glassThemeRoot() -> some View { modifier(GlassThemeRoot()) }

    /// Glass in `shape` when `on`; otherwise the view is returned untouched.
    @ViewBuilder
    func glassPanel<S: Shape>(_ on: Bool, in shape: S, interactive: Bool = false) -> some View {
        if on {
            if #available(macOS 26, *) {
                self.glassEffect(Glass.regular.interactive(interactive), in: shape)
            } else { self }
        } else { self }
    }

    /// A floating surface: Liquid Glass when `on`, otherwise the original material, hairline and shadow.
    @ViewBuilder
    func floatingSurface<S: InsettableShape>(_ on: Bool, in shape: S) -> some View {
        if on, GlassTheme.supported {
            self.glassPanel(true, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }

    /// A soft accent wash behind dashboard pages so the glass cards on them have something to refract.
    @ViewBuilder
    func glassBackdrop(_ on: Bool) -> some View {
        if on {
            self.background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    LinearGradient(colors: [Color.accentColor.opacity(0.16), Color.purple.opacity(0.07), Color.teal.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        } else { self }
    }
}
