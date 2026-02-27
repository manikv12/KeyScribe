#!/usr/bin/env swift

import AppKit
import SwiftUI

// MARK: - Icon View (speech bubbles + microphone + sparkles)

struct AppIconView: View {
    let size: CGFloat

    private let darkBubble = Color(red: 0.10, green: 0.14, blue: 0.22)
    private let tealBubbleLeading = Color(red: 0.18, green: 0.42, blue: 0.48)
    private let tealBubbleTrailing = Color(red: 0.24, green: 0.58, blue: 0.56)
    private let sparkleColor = Color.white.opacity(0.85)
    private let containerTop = Color(red: 0.20, green: 0.24, blue: 0.33)
    private let containerBottom = Color(red: 0.07, green: 0.09, blue: 0.15)
    private let glowColor = Color(red: 0.48, green: 0.72, blue: 0.82)

    private var containerDiameter: CGFloat { size * 0.86 }
    private var logoDiameter: CGFloat { containerDiameter * 0.90 }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [containerTop, containerBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    glowColor.opacity(0.36),
                                    glowColor.opacity(0.12),
                                    Color.clear
                                ],
                                center: UnitPoint(x: 0.68, y: 0.34),
                                startRadius: 0,
                                endRadius: containerDiameter * 0.52
                            )
                        )
                )
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.10),
                                    Color.white.opacity(0.01),
                                    Color.black.opacity(0.30)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.32),
                                    Color.white.opacity(0.08),
                                    Color.black.opacity(0.35)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: max(1, size * 0.0055)
                        )
                )
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.24), lineWidth: max(1, size * 0.0025))
                )
                .shadow(color: .black.opacity(0.22), radius: size * 0.03, x: 0, y: size * 0.010)

            Canvas { context, canvasSize in
                let s = min(canvasSize.width, canvasSize.height) / 256
                let cx = canvasSize.width / 2
                let cy = canvasSize.height / 2

                // ── Left (dark) speech bubble ──
                let leftBubble = speechBubblePath(
                    center: CGPoint(x: cx - 30 * s, y: cy + 8 * s),
                    width: 140 * s, height: 100 * s,
                    tailOnRight: false, scale: s
                )
                context.fill(leftBubble, with: .color(darkBubble))

                // ── Right (teal) speech bubble ──
                let rightBubble = speechBubblePath(
                    center: CGPoint(x: cx + 30 * s, y: cy + 8 * s),
                    width: 140 * s, height: 100 * s,
                    tailOnRight: true, scale: s
                )
                context.fill(
                    rightBubble,
                    with: .linearGradient(
                        Gradient(colors: [tealBubbleLeading, tealBubbleTrailing]),
                        startPoint: CGPoint(x: cx - 10 * s, y: cy - 40 * s),
                        endPoint: CGPoint(x: cx + 70 * s, y: cy + 60 * s)
                    )
                )

                // Text lines on right bubble
                let lineY = cy
                for i in 0..<3 {
                    let w: CGFloat = i == 2 ? 36 : 50
                    let rect = CGRect(x: cx + 8 * s, y: lineY + CGFloat(i) * 14 * s, width: w * s, height: 4 * s)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2 * s), with: .color(.white.opacity(0.35)))
                }

                // Sound wave lines on left bubble
                let waveX = cx - 50 * s
                let waveY = cy + 2 * s
                let waveHeights: [CGFloat] = [16, 28, 40, 28, 16]
                for (i, h) in waveHeights.enumerated() {
                    let x = waveX + CGFloat(i) * 10 * s
                    let rect = CGRect(x: x - 2 * s, y: waveY - h / 2 * s, width: 4 * s, height: h * s)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2 * s), with: .color(.white.opacity(0.3)))
                }

                // ── Microphone ──
                let micHeadRect = CGRect(x: cx - 22 * s, y: cy - 64 * s, width: 44 * s, height: 72 * s)
                let micHead = Path(roundedRect: micHeadRect, cornerRadius: 22 * s)
                context.fill(
                    micHead,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.22, green: 0.26, blue: 0.36),
                            Color(red: 0.12, green: 0.14, blue: 0.22)
                        ]),
                        startPoint: CGPoint(x: cx - 22 * s, y: cy - 64 * s),
                        endPoint: CGPoint(x: cx + 22 * s, y: cy + 8 * s)
                    )
                )
                context.stroke(micHead, with: .color(.white.opacity(0.15)), lineWidth: 1.5 * s)

                // Mic grille lines
                for i in 0..<5 {
                    let gy = cy - 48 * s + CGFloat(i) * 12 * s
                    let gw: CGFloat = i == 0 || i == 4 ? 20 : 30
                    let grilleLine = Path { p in
                        p.move(to: CGPoint(x: cx - gw / 2 * s, y: gy))
                        p.addLine(to: CGPoint(x: cx + gw / 2 * s, y: gy))
                    }
                    context.stroke(grilleLine, with: .color(.white.opacity(0.18)), lineWidth: 1.2 * s)
                }

                // Mic stand
                let stemRect = CGRect(x: cx - 4 * s, y: cy + 8 * s, width: 8 * s, height: 40 * s)
                context.fill(Path(roundedRect: stemRect, cornerRadius: 3 * s), with: .color(Color(red: 0.14, green: 0.16, blue: 0.24)))

                // Mic base
                let baseRect = CGRect(x: cx - 20 * s, y: cy + 44 * s, width: 40 * s, height: 8 * s)
                context.fill(Path(roundedRect: baseRect, cornerRadius: 4 * s), with: .color(Color(red: 0.14, green: 0.16, blue: 0.24)))

                // ── Sparkles ──
                drawSparkle(in: &context, at: CGPoint(x: cx + 60 * s, y: cy - 52 * s), size: 10 * s)
                drawSparkle(in: &context, at: CGPoint(x: cx + 76 * s, y: cy - 38 * s), size: 6 * s)
                drawSparkle(in: &context, at: CGPoint(x: cx + 68 * s, y: cy - 68 * s), size: 5 * s)
                drawSparkle(in: &context, at: CGPoint(x: cx + 84 * s, y: cy - 56 * s), size: 4 * s)
            }
            .frame(width: logoDiameter, height: logoDiameter)
            .offset(y: -containerDiameter * 0.01)
            .shadow(color: .black.opacity(0.25), radius: size * 0.014, x: 0, y: size * 0.004)
        }
        .frame(width: containerDiameter, height: containerDiameter)
        .frame(width: size, height: size)
    }
 
    private func speechBubblePath(center: CGPoint, width: CGFloat, height: CGFloat, tailOnRight: Bool, scale: CGFloat) -> Path {
        Path { p in
            let r = height * 0.38
            let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            p.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
            let tailX = tailOnRight ? rect.maxX - 24 * scale : rect.minX + 24 * scale
            let tailDir: CGFloat = tailOnRight ? 1 : -1
            p.move(to: CGPoint(x: tailX, y: rect.maxY - 4 * scale))
            p.addLine(to: CGPoint(x: tailX + 12 * tailDir * scale, y: rect.maxY + 14 * scale))
            p.addLine(to: CGPoint(x: tailX + 20 * tailDir * scale, y: rect.maxY - 4 * scale))
        }
    }
 
    private func drawSparkle(in context: inout GraphicsContext, at point: CGPoint, size: CGFloat) {
        let spark = Path { p in
            p.move(to: CGPoint(x: point.x, y: point.y - size))
            p.addLine(to: CGPoint(x: point.x + size * 0.25, y: point.y - size * 0.25))
            p.addLine(to: CGPoint(x: point.x + size, y: point.y))
            p.addLine(to: CGPoint(x: point.x + size * 0.25, y: point.y + size * 0.25))
            p.addLine(to: CGPoint(x: point.x, y: point.y + size))
            p.addLine(to: CGPoint(x: point.x - size * 0.25, y: point.y + size * 0.25))
            p.addLine(to: CGPoint(x: point.x - size, y: point.y))
            p.addLine(to: CGPoint(x: point.x - size * 0.25, y: point.y - size * 0.25))
            p.closeSubpath()
        }
        context.fill(spark, with: .color(sparkleColor))
    }
}

// MARK: - Rendering

@MainActor
func renderIcon(size: Int) -> NSImage? {
    let view = AppIconView(size: CGFloat(size))
        .frame(width: CGFloat(size), height: CGFloat(size), alignment: .center)
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: CGFloat(size), height: CGFloat(size))
    renderer.scale = 1.0
    guard let cgImage = renderer.cgImage else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for \(path)")
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        print("Failed to write \(path): \(error)")
    }
}

// MARK: - Main

@MainActor
func main() {
let projectDir = FileManager.default.currentDirectoryPath
let iconsetDir = "/tmp/KeyScribeIcon.iconset"
let resourcesDir = projectDir + "/Resources"

// Create iconset directory
try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// Generate all required sizes
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for entry in sizes {
    print("Rendering \(entry.name) (\(entry.pixels)px)...")
    if let img = renderIcon(size: entry.pixels) {
        savePNG(img, to: "\(iconsetDir)/\(entry.name).png")
    }
}

// Also save 1024px as AppIcon.png
if let fullImg = renderIcon(size: 1024) {
    savePNG(fullImg, to: "\(resourcesDir)/AppIcon.png")
    print("Saved AppIcon.png")
}

// Run iconutil to create .icns
print("Creating .icns...")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir, "-o", "\(resourcesDir)/AppIcon.icns"]
try! process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Done! AppIcon.icns created successfully.")
} else {
    print("iconutil failed with status \(process.terminationStatus)")
}
} // end main()

MainActor.assumeIsolated { main() }
exit(0)
