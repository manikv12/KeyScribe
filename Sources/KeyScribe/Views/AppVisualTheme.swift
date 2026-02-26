import AppKit
import SwiftUI

enum AppVisualTheme {
    static let baseTint = Color(red: 0.24, green: 0.21, blue: 0.27)
    static let accentTint = Color(red: 0.63, green: 0.58, blue: 0.83)
    static let canvasBase = Color(red: 0.08, green: 0.08, blue: 0.12)
    static let canvasDeep = Color(red: 0.05, green: 0.05, blue: 0.08)
    static let sidebarTint = Color(red: 0.13, green: 0.12, blue: 0.18)
    static let panelTint = Color(red: 0.17, green: 0.15, blue: 0.21)
    static let rowSelection = Color(red: 0.42, green: 0.38, blue: 0.56)
    static let historyTint = Color(red: 0.56, green: 0.78, blue: 0.62)
    static let aiStudioTint = Color(red: 0.72, green: 0.62, blue: 0.90)
    static let settingsTint = Color(red: 0.86, green: 0.72, blue: 0.52)
    static let mutedText = Color.white.opacity(0.62)
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
            AppVisualTheme.canvasDeep
            AppLiquidGlassEffectView(
                material: .underPageBackground,
                blendingMode: .behindWindow
            )
            .opacity(0.88)
            LinearGradient(
                colors: [
                    AppVisualTheme.canvasDeep.opacity(0.90),
                    tint.opacity(0.22),
                    AppVisualTheme.canvasBase.opacity(0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    AppVisualTheme.accentTint.opacity(0.11),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 28,
                endRadius: 680
            )
            RadialGradient(
                colors: [
                    Color.white.opacity(0.05),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 22,
                endRadius: 600
            )
        }
        .overlay(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.14),
                    Color.black.opacity(0.36)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea()
    }
}

struct AppSplitChromeBackground: View {
    var leadingPaneFraction: CGFloat = 0.32
    var leadingPaneMaxWidth: CGFloat = 340
    var leadingTint: Color = AppVisualTheme.sidebarTint
    var trailingTint: Color = Color.black
    var accent: Color = AppVisualTheme.accentTint

    var body: some View {
        GeometryReader { proxy in
            let calculatedWidth = proxy.size.width * leadingPaneFraction
            let leadingWidth = min(leadingPaneMaxWidth, max(200, calculatedWidth))

            ZStack {
                trailingTint.opacity(0.90)

                LinearGradient(
                    colors: [
                        AppVisualTheme.canvasDeep.opacity(0.82),
                        trailingTint.opacity(0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                HStack(spacing: 0) {
                    ZStack {
                        AppLiquidGlassEffectView(
                            material: .sidebar,
                            blendingMode: .behindWindow
                        )
                        .opacity(0.84)

                        LinearGradient(
                            colors: [
                                leadingTint.opacity(0.08),
                                leadingTint.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        RadialGradient(
                            colors: [
                                accent.opacity(0.04),
                                Color.clear
                            ],
                            center: .topLeading,
                            startRadius: 12,
                            endRadius: 360
                        )
                    }
                    .frame(width: leadingWidth)
                    .overlay(alignment: .trailing) {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.16),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: 1)
                    }

                    Spacer(minLength: 0)
                }

                RadialGradient(
                    colors: [
                        accent.opacity(0.04),
                        Color.clear
                    ],
                    center: .bottomTrailing,
                    startRadius: 30,
                    endRadius: 420
                )
            }
            .overlay(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.08),
                        Color.black.opacity(0.24)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .ignoresSafeArea()
    }
}

struct AppIconBadge: View {
    let symbol: String
    var tint: Color = AppVisualTheme.accentTint
    var size: CGFloat = 30
    var symbolSize: CGFloat = 13
    var isEmphasized = false

    var body: some View {
        let cornerRadius = max(8, size * 0.30)
        let topColor = Color.white.opacity(isEmphasized ? 0.13 : 0.08)
        let bottomColor = Color.white.opacity(isEmphasized ? 0.08 : 0.05)
        let symbolColor = isEmphasized ? tint.opacity(0.96) : tint.opacity(0.84)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [topColor, bottomColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.black.opacity(0.32), lineWidth: 0.6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(isEmphasized ? 0.10 : 0.05))
                )

            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(symbolColor)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(isEmphasized ? 0.18 : 0.10), radius: isEmphasized ? 4 : 2, x: 0, y: 1)
    }
}

struct AppSidebarSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppVisualTheme.mutedText)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.7)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.black.opacity(0.30), lineWidth: 0.5)
        )
    }
}

extension View {
    func appThemedSurface(
        cornerRadius: CGFloat = 12,
        tint: Color = AppVisualTheme.baseTint,
        strokeOpacity: Double = 0.17,
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
                    .opacity(0.74)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.045))
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

    func appSidebarSurface(
        cornerRadius: CGFloat = 16,
        tint: Color = AppVisualTheme.sidebarTint
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.clear)
                .background(
                    AppLiquidGlassEffectView(
                        material: .sidebar,
                        blendingMode: .withinWindow
                    )
                    .opacity(0.93)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(0.03))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.30), lineWidth: 0.55)
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
