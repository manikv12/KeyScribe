import AppKit
import SwiftUI

private enum HUDLayout {
    static let width: CGFloat = 90
    static let height: CGFloat = 28
    static let bottomInset: CGFloat = 10
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
    @Published var verticalLift: Double = 0

    private var targetLevel: Double = 0
    private var animationTimer: Timer?

    func reset() {
        level = 0
        phase = 0
        impulse = 0
        verticalLift = 0
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
        let attack: Double = 0.45
        let release: Double = 0.24
        level += delta * (delta > 0 ? attack : release)

        let spike = max(0, delta)
        impulse = max(spike, impulse * 0.84)
        targetLevel *= 0.88
        let targetLift = (level * 3.6) + (impulse * 5.8)
        verticalLift += (targetLift - verticalLift) * 0.34

        // Keep a subtle idle motion so it still feels alive between level samples.
        phase += 0.15 + (level * 0.70) + (impulse * 0.42)
    }
}

struct WaveformPanelView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.08, blue: 0.12).opacity(0.92),
                            Color(red: 0.05, green: 0.06, blue: 0.10).opacity(0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
                )

            SoundWaveLine(level: model.level, phase: model.phase, impulse: model.impulse)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
        }
        .frame(width: HUDLayout.width, height: HUDLayout.height)
        .offset(y: -model.verticalLift)
        .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 2)
    }
}

struct SoundWaveLine: View {
    let level: Double
    let phase: Double
    let impulse: Double

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let baseline = size.height * 0.54
            let baseAmplitude = 1.9 + (level * 2.8) + (impulse * 1.5)
            let phaseShift = phase * 0.18

            let wavePath = Path { path in
                let width = max(1, size.width)
                let samples = max(24, Int(width * 1.25))

                for step in 0...samples {
                    let t = Double(step) / Double(samples)
                    let x = CGFloat(t) * width
                    let primary = sin((t * 2.6 + phaseShift) * .pi * 2.0) * 0.74
                    let detail = sin((t * 7.8 + phaseShift * 1.3) * .pi * 2.0) * 0.22
                    let sparkle = sin((t * 12.4 + phaseShift * 2.1) * .pi * 2.0) * 0.10
                    let centerWeight = 0.42 + (sin(t * .pi) * 0.58)
                    let y = baseline - CGFloat((primary + detail + sparkle) * centerWeight * baseAmplitude)

                    if step == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }

            ZStack {
                wavePath
                    .applying(CGAffineTransform(translationX: 0, y: 1.0))
                    .stroke(
                        Color.black.opacity(0.35),
                        style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round)
                    )

                wavePath
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.51, green: 0.79, blue: 0.95).opacity(0.82),
                                Color(red: 0.48, green: 0.61, blue: 0.97).opacity(0.90),
                                Color(red: 0.70, green: 0.42, blue: 0.91).opacity(0.82)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }
}
