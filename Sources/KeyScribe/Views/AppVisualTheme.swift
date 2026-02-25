import AppKit
import SwiftUI

enum AppVisualTheme {
    static let baseTint = Color(red: 0.24, green: 0.27, blue: 0.32)
    static let accentTint = Color(red: 0.32, green: 0.56, blue: 0.88)
}

private struct AppLiquidGlassEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(frame: .zero)
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.isEmphasized = emphasized
    }
}

struct AppChromeBackground: View {
    var tint: Color = AppVisualTheme.baseTint

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08)
            AppLiquidGlassEffectView(
                material: .underPageBackground,
                blendingMode: .behindWindow
            )
            .opacity(0.84)
            LinearGradient(
                colors: [
                    Color.black.opacity(0.60),
                    tint.opacity(0.22),
                    Color(red: 0.16, green: 0.18, blue: 0.22).opacity(0.40)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 28,
                endRadius: 740
            )
        }
        .overlay(Color.black.opacity(0.18))
        .ignoresSafeArea()
    }
}

extension View {
    func appThemedSurface(
        cornerRadius: CGFloat = 12,
        tint: Color = AppVisualTheme.baseTint,
        strokeOpacity: Double = 0.18,
        tintOpacity: Double = 0.03
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.clear)
                .background(
                    AppLiquidGlassEffectView(
                        material: .windowBackground,
                        blendingMode: .withinWindow
                    )
                    .opacity(0.72)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.24))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(tintOpacity))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(strokeOpacity * 0.45), lineWidth: 0.45)
        )
    }

    func appScrollbars(tint: Color = AppVisualTheme.baseTint) -> some View {
        background(AppScrollBarTintView(tint: tint))
    }
}

struct AppScrollBarTintView: NSViewRepresentable {
    let tint: Color

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let hostView = nsView.superview else { return }
            applyScrollStyling(in: hostView, tint: NSColor(tint))
        }
    }

    private func applyScrollStyling(in view: NSView, tint: NSColor) {
        if let scrollView = view as? NSScrollView {
            configure(scrollView: scrollView, tint: tint)
        }
        for subview in view.subviews {
            applyScrollStyling(in: subview, tint: tint)
        }
    }

    private func configure(scrollView: NSScrollView, tint: NSColor) {
        guard let scroller = scrollView.verticalScroller else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scroller.wantsLayer = true
        scroller.layer?.cornerRadius = max(3, scroller.bounds.width * 0.5)
        scroller.layer?.backgroundColor = tint.withAlphaComponent(0.38).cgColor
        scroller.alphaValue = 0.98
    }
}
