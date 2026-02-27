import AppKit
import SwiftUI

enum AppVisualTheme {
    static let baseTint = Color(red: 0.20, green: 0.24, blue: 0.32)
    static let accentTint = Color(red: 0.23, green: 0.67, blue: 0.92)
    static let canvasBase = Color(red: 0.08, green: 0.08, blue: 0.10)
    static let canvasDeep = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let sidebarTint = Color(red: 0.16, green: 0.17, blue: 0.20)
    static let panelTint = Color(red: 0.14, green: 0.15, blue: 0.18)
    static let rowSelection = Color(red: 0.29, green: 0.33, blue: 0.39)
    static let historyTint = Color(red: 0.25, green: 0.72, blue: 0.56)
    static let aiStudioTint = Color(red: 0.31, green: 0.63, blue: 0.93)
    static let settingsTint = Color(red: 0.91, green: 0.56, blue: 0.22)
    static let mutedText = Color.white.opacity(0.68)
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
                    Color.black.opacity(0.06),
                    Color.black.opacity(0.22)
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
    var leadingPaneWidth: CGFloat? = nil
    var leadingTint: Color = AppVisualTheme.sidebarTint
    var trailingTint: Color = Color.black
    var accent: Color = AppVisualTheme.accentTint
    var leadingPaneTransparent = false

    var body: some View {
        GeometryReader { proxy in
            let calculatedWidth = proxy.size.width * leadingPaneFraction
            let dynamicWidth = min(leadingPaneMaxWidth, max(200, calculatedWidth))
            let preferredWidth = leadingPaneWidth ?? dynamicWidth
            let maxAllowedWidth = max(180, proxy.size.width - 220)
            let leadingWidth = min(maxAllowedWidth, max(180, preferredWidth))

            ZStack {
                AppVisualTheme.canvasDeep.opacity(0.84)

                HStack(spacing: 0) {
                    Group {
                        if leadingPaneTransparent {
                            ZStack {
                                AppLiquidGlassEffectView(
                                    material: .sidebar,
                                    blendingMode: .behindWindow
                                )
                                .opacity(0.79)

                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.09),
                                        Color.black.opacity(0.06)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )

                                LinearGradient(
                                    colors: [
                                        leadingTint.opacity(0.08),
                                        leadingTint.opacity(0.02)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            }
                        } else {
                            ZStack {
                                AppLiquidGlassEffectView(
                                    material: .sidebar,
                                    blendingMode: .behindWindow
                                )
                                .opacity(0.90)

                                LinearGradient(
                                    colors: [
                                        leadingTint.opacity(0.16),
                                        leadingTint.opacity(0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )

                                RadialGradient(
                                    colors: [
                                        accent.opacity(0.06),
                                        Color.clear
                                    ],
                                    center: .topLeading,
                                    startRadius: 12,
                                    endRadius: 360
                                )
                            }
                        }
                    }
                    .frame(width: leadingWidth)
                    .overlay(alignment: .trailing) {
                        if !leadingPaneTransparent {
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.16),
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(width: 1)
                        }
                    }

                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(red: 0.08, green: 0.09, blue: 0.11),
                                Color(red: 0.05, green: 0.06, blue: 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .opacity(0.96)

                        trailingTint.opacity(0.32)

                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.03),
                                Color.black.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottom
                        )
                    }
                }

            }
            .overlay(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.04),
                        Color.black.opacity(0.16)
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
        let baseTop = Color(red: 0.12, green: 0.15, blue: 0.21)
        let baseBottom = Color(red: 0.08, green: 0.10, blue: 0.15)
        let tintTop = tint.opacity(isEmphasized ? 0.94 : 0.82)
        let tintBottom = tint.opacity(isEmphasized ? 0.76 : 0.62)
        let symbolColor = Color.white.opacity(0.98)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [baseTop, baseBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tintTop, tintBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .saturation(isEmphasized ? 1.18 : 1.10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.34),
                                    Color.white.opacity(0.05),
                                    Color.black.opacity(0.35)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.9
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.black.opacity(0.45), lineWidth: 0.6)
                )

            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .bold))
                .foregroundStyle(symbolColor)
                .shadow(color: Color.black.opacity(0.28), radius: 1.2, x: 0, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(
            color: Color.black.opacity(isEmphasized ? 0.24 : 0.18),
            radius: isEmphasized ? 3.5 : 2.5,
            x: 0,
            y: 1.5
        )
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
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        )
    }
}

extension View {
    func appThemedSurface(
        cornerRadius: CGFloat = 12,
        tint: Color = AppVisualTheme.baseTint,
        strokeOpacity: Double = 0.14,
        tintOpacity: Double = 0.02
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06 + tintOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 4)
    }

    func appSidebarSurface(
        cornerRadius: CGFloat = 16,
        tint: Color = AppVisualTheme.sidebarTint
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
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
        scroller.layer?.backgroundColor = tint.withAlphaComponent(0.30).cgColor
        scroller.alphaValue = 0.98
    }
}
