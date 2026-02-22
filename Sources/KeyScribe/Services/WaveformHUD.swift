import AppKit
import SwiftUI

private enum HUDLayout {
    static let width: CGFloat = 106
    static let height: CGFloat = 28
    static let bottomInset: CGFloat = 24
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
        let x = visible.midX - (panelFrame.width * 0.5)
        let y = visible.minY + HUDLayout.bottomInset
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
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.74))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.6)
                )

            SoundWaveLine(level: model.level, phase: model.phase, impulse: model.impulse)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
        }
        .frame(width: HUDLayout.width, height: HUDLayout.height)
        .shadow(color: .black.opacity(0.24), radius: 5, x: 0, y: 2)
    }
}

struct SoundWaveLine: View {
    let level: Double
    let phase: Double
    let impulse: Double

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let baseline = size.height * 0.52
            let baseAmplitude = 2.2 + (level * 2.1) + (impulse * 1.0)
            let phaseShift = phase * 0.08

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
                    .applying(CGAffineTransform(translationX: 0, y: 0.9))
                    .stroke(
                        Color.black.opacity(0.35),
                        style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                    )

                wavePath
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.58, green: 0.82, blue: 0.98).opacity(0.82),
                                Color(red: 0.53, green: 0.66, blue: 0.98).opacity(0.88),
                                Color(red: 0.78, green: 0.52, blue: 0.92).opacity(0.78)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }
}
