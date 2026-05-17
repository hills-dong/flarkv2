import SwiftUI

/// Liquid Glass compatibility layer. On iOS 26 / macOS 26 it uses the real
/// `.glassEffect`; on iOS 17/18 it degrades to a Material so the app still
/// looks native everywhere. All chrome (bars, FAB, chips, docks) goes
/// through here so the visual language stays consistent.
extension View {
    /// Glass for bars / docks / floating controls.
    @ViewBuilder
    func glassSurface(_ shape: some Shape = Capsule()) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
    }

    /// Interactive glass for tappable controls (adds the press shimmer on 26).
    @ViewBuilder
    func glassButton(_ shape: some Shape = Capsule()) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.22), lineWidth: 0.5))
        }
    }

    /// Card surface — elevated content blocks.
    func cardSurface() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.flarkCard)
                .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
        )
    }
}

/// A container that lets sibling glass elements blend (iOS 26). No-op fallback.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

extension Color {
    static let flarkBackground = Color(white: 0.95)
    static let flarkCard = Color.platformBackground
    static let flarkTint = Color.accentColor

    static var platformBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
    static var platformGrouped: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
