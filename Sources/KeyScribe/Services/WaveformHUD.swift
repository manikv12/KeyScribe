import AppKit
import SwiftUI

private enum HUDLayout {
    static let width: CGFloat = 100
    static let height: CGFloat = 34
    /// Fixed offset from the bottom of the screen so the HUD always sits
    /// above the Dock region, even on screens that don't host the Dock.
    static let dockReserve: CGFloat = 80
}

@MainActor
final class WaveformHUDManager {
    private var panel: NSPanel?
    private let model = WaveformModel()

    func show() {
        if panel == nil {
            createPanel()
        }
        guard let panel else { return }
        model.reset()
        model.startAnimating()
        repositionAtBottom()
        panel.orderFrontRegardless()
    }

    func hide() {
        model.stopAnimating()
        model.reset()
        panel?.orderOut(nil)
    }

    func updateLevel(_ level: Float) {
        model.updateLevel(level)
    }

    private func createPanel() {
        let frame = NSRect(x: 0, y: 0, width: HUDLayout.width, height: HUDLayout.height)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let hosting = NSHostingController(rootView: WaveformPanelView(model: model))
        hosting.view.frame = frame
        panel.contentViewController = hosting
        self.panel = panel
    }

    private func repositionAtBottom() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let x = screen.frame.midX - (panel.frame.width * 0.5)
        let y = screen.frame.minY + HUDLayout.dockReserve

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class WaveformModel: ObservableObject {
    @Published var level: Double = 0
    @Published var phase: Double = 0
    @Published var impulse: Double = 0

    private var targetLevel: Double = 0
    private var animationTimer: Timer?

    func reset() {
        level = 0
        phase = 0
        impulse = 0
        targetLevel = 0
    }

    func updateLevel(_ value: Float) {
        targetLevel = max(0, min(1, Double(value)))
    }

    func startAnimating() {
        guard animationTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func tick() {
        let delta = targetLevel - level
        let attack: Double = 0.14
        let release: Double = 0.08
        level += delta * (delta > 0 ? attack : release)

        let spike = max(0, delta)
        impulse = max(spike, impulse * 0.85)
        targetLevel *= 0.93

        // Gentle, smooth phase progression
        phase += 0.12 + (level * 0.30) + (impulse * 0.15)
    }
}

struct WaveformPanelView: View {
    @ObservedObject var model: WaveformModel
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)

            SoundWaveLine(level: model.level, phase: model.phase, impulse: model.impulse, theme: settings.waveformTheme)
                .frame(height: 22)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            ZStack {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(Color.white.opacity(0.06))
                Capsule()
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            }
        )
        .frame(width: HUDLayout.width, height: HUDLayout.height, alignment: .center)
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
    }
}

struct SoundWaveLine: View {
    let level: Double
    let phase: Double
    let impulse: Double
    let theme: WaveformTheme

    private let barCount = 7
    private let barSpacing: CGFloat = 3.0

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                BarView(index: index, barCount: barCount, level: level, phase: phase, impulse: impulse, theme: theme)
            }
        }
        .frame(height: 24, alignment: .center)
    }
}

struct BarView: View {
    let index: Int
    let barCount: Int
    let level: Double
    let phase: Double
    let impulse: Double
    let theme: WaveformTheme

    var body: some View {
        Capsule()
            .fill(barGradient)
            .frame(width: 4.0, height: calculateHeight())
    }

    private var barGradient: LinearGradient {
        let mix = min(1, level + impulse * 0.3)
        // Increase opacity for a more vibrant, colourful look while keeping it professional
        let opacity = 0.75 + mix * 0.25
        let t = Double(index) / Double(max(1, barCount - 1))
        let tint = barTint(at: t)
        
        return LinearGradient(
            colors: [
                tint.opacity(opacity * 0.5),
                tint.opacity(opacity)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private func barTint(at t: Double) -> Color {
        switch theme {
        case .vibrantSpectrum:
            let blue = (r: 0.26, g: 0.52, b: 0.96)
            let red = (r: 0.92, g: 0.26, b: 0.21)
            let yellow = (r: 0.98, g: 0.74, b: 0.02)
            let green = (r: 0.20, g: 0.66, b: 0.33)
            return interpolate(t: t, colors: [blue, red, yellow, green])
            
        case .professionalTech:
            let cyan = (r: 0.15, g: 0.85, b: 1.0)
            let indigo = (r: 0.35, g: 0.35, b: 0.95)
            let violet = (r: 0.75, g: 0.25, b: 0.85)
            return interpolate(t: t, colors: [cyan, indigo, violet])
            
        case .monochrome:
            let white = (r: 1.0, g: 1.0, b: 1.0)
            let gray = (r: 0.6, g: 0.6, b: 0.6)
            return interpolate(t: t, colors: [white, gray, white, gray])
            
        case .neonLagoon:
            let c1 = (r: 0.00, g: 1.00, b: 0.53) // #00FF87
            let c2 = (r: 0.38, g: 0.94, b: 1.00) // #60EFFF
            return interpolate(t: t, colors: [c1, c2])
            
        case .sunsetCandy:
            let c1 = (r: 1.00, g: 0.06, b: 0.48) // #FF0F7B
            let c2 = (r: 0.97, g: 0.61, b: 0.16) // #F89B29
            return interpolate(t: t, colors: [c1, c2])
            
        case .cosmicPop:
            let c1 = (r: 0.25, g: 0.79, b: 1.00) // #40C9FF
            let c2 = (r: 0.91, g: 0.11, b: 1.00) // #E81CFF
            return interpolate(t: t, colors: [c1, c2])
            
        case .mintBlush:
            let c1 = (r: 0.66, g: 1.00, b: 0.41) // #A9FF68
            let c2 = (r: 1.00, g: 0.54, b: 0.54) // #FF8989
            return interpolate(t: t, colors: [c1, c2])
        }
    }
    
    private func interpolate(t: Double, colors: [(r: Double, g: Double, b: Double)]) -> Color {
        if colors.count == 1 {
            let c = colors[0]
            return Color(red: c.r, green: c.g, blue: c.b)
        }
        
        let segment = 1.0 / Double(colors.count - 1)
        
        for i in 0..<(colors.count - 1) {
            let startT = Double(i) * segment
            let endT = Double(i + 1) * segment
            
            if t <= endT || i == colors.count - 2 {
                let p = max(0, min(1, (t - startT) / segment))
                let c1 = colors[i]
                let c2 = colors[i+1]
                return Color(
                    red: c1.r + (c2.r - c1.r) * p,
                    green: c1.g + (c2.g - c1.g) * p,
                    blue: c1.b + (c2.b - c1.b) * p
                )
            }
        }
        
        let last = colors.last!
        return Color(red: last.r, green: last.g, blue: last.b)
    }

    private func calculateHeight() -> CGFloat {
        let t = Double(index) / Double(max(1, barCount - 1))

        let speed = phase * 0.15
        let centerOffset = abs(t - 0.5) * 2.0
        let bellCurve = exp(-pow(centerOffset / 0.7, 2))

        let wave = sin((t * 2.5 + speed + Double(index) * 0.6) * .pi * 2.0)
        let intensity = 0.18 + (level * 0.85) + (impulse * 0.3)

        let minHeight: CGFloat = 5.0
        let maxHeight: CGFloat = 22.0
        let diff = maxHeight - minHeight

        let heightVariation = CGFloat(abs(wave)) * CGFloat(intensity) * CGFloat(bellCurve) * diff
        return min(maxHeight, minHeight + heightVariation)
    }
}
