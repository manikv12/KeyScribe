import AppKit
import SwiftUI

private enum HUDLayout {
    static let width: CGFloat = 92
    static let height: CGFloat = 24
    static let bottomInset: CGFloat = 10
    static let dockClearance: CGFloat = 6
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
            styleMask: [.borderless],
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

        let panelFrame = panel.frame
        let visible = screen.visibleFrame
        let full = screen.frame

        let x = visible.midX - (panelFrame.width * 0.5)

        // visibleFrame excludes Dock/menu bar. Pin HUD just above Dock area.
        let dockTop = visible.minY
        let y = max(full.minY + HUDLayout.bottomInset, dockTop + HUDLayout.dockClearance)

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
        let attack: Double = 0.40
        let release: Double = 0.20
        level += delta * (delta > 0 ? attack : release)

        let spike = max(0, delta)
        impulse = max(spike, impulse * 0.82)
        targetLevel *= 0.90

        // Faster, clean motion without "warping" the shape.
        phase += 0.22 + (level * 0.56) + (impulse * 0.34)
    }
}

struct WaveformPanelView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.90, green: 0.42, blue: 0.88),
                            Color(red: 0.50, green: 0.67, blue: 0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 7, height: 7)
                .shadow(color: .white.opacity(0.2), radius: 1, x: 0, y: 0)

            SoundWaveLine(level: model.level, phase: model.phase, impulse: model.impulse)
                .frame(height: 12)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.6)
                )
        )
        .frame(width: HUDLayout.width, height: HUDLayout.height)
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
    }
}

struct SoundWaveLine: View {
    let level: Double
    let phase: Double
    let impulse: Double

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let baseline = size.height * 0.53
            let baseAmplitude = 1.8 + (level * 1.7) + (impulse * 0.85)
            let phaseShift = phase * 0.075

            let wavePath = Path { path in
                let width = max(1, size.width)
                let samples = max(28, Int(width * 1.5))

                for step in 0...samples {
                    let t = Double(step) / Double(samples)
                    let x = CGFloat(t) * width
                    // Signature-style profile: one major wave and smaller tail ripples.
                    let bigWave = sin((t * 2.2 + phaseShift) * .pi * 2.0)
                        * exp(-pow((t - 0.31) / 0.23, 2)) * 1.0
                    let ripple = sin((t * 7.6 + phaseShift * 1.7) * .pi * 2.0)
                        * exp(-pow((t - 0.67) / 0.19, 2)) * 0.24
                    let tail = sin((t * 10.5 + phaseShift * 2.2) * .pi * 2.0)
                        * exp(-pow((t - 0.82) / 0.14, 2)) * 0.10
                    let y = baseline - CGFloat((bigWave + ripple + tail) * baseAmplitude)

                    if step == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }

            ZStack {
                wavePath
                    .applying(CGAffineTransform(translationX: 0, y: 0.7))
                    .stroke(
                        Color.black.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                    )

                wavePath
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.58, green: 0.82, blue: 0.98).opacity(0.8),
                                Color(red: 0.53, green: 0.66, blue: 0.98).opacity(0.86),
                                Color(red: 0.78, green: 0.52, blue: 0.92).opacity(0.74)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }
}
