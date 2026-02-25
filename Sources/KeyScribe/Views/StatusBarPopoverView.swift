import SwiftUI

// MARK: - View Model

final class StatusBarViewModel: ObservableObject {
    @Published var uiStatus: DictationUIStatus = .ready
    @Published var isDictating: Bool = false
    @Published var currentAudioLevel: Float = 0
    @Published var isContinuousMode: Bool = false
    @Published var permissionsReady: Bool = false

    var onToggleDictation: (() -> Void)?
    var onPasteLastTranscript: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenAIMemoryStudio: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
}

// MARK: - Popover View

struct StatusBarPopoverView: View {
    @ObservedObject var viewModel: StatusBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            if viewModel.isDictating {
                RecordingIndicatorView(audioLevel: viewModel.currentAudioLevel)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()
                .padding(.horizontal, 16)
                .opacity(0.6)

            VStack(spacing: 4) {
                PopoverMenuRow(
                    icon: viewModel.isContinuousMode ? "stop.circle.fill" : "mic.circle.fill",
                    label: viewModel.isContinuousMode ? "Stop Dictation" : "Start Dictation",
                    shortcut: nil,
                    iconTint: viewModel.isContinuousMode ? .red : .accentColor,
                    isDisabled: !viewModel.permissionsReady
                ) {
                    viewModel.onToggleDictation?()
                }

                PopoverMenuRow(
                    icon: "doc.on.clipboard",
                    label: "Paste Last Transcript",
                    shortcut: "⌘⌥V"
                ) {
                    viewModel.onPasteLastTranscript?()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 16)
                .opacity(0.6)

            VStack(spacing: 4) {
                PopoverMenuRow(icon: "clock.arrow.circlepath", label: "History") {
                    viewModel.onOpenHistory?()
                }

                PopoverMenuRow(icon: "brain.head.profile", label: "AI Memory Studio") {
                    viewModel.onOpenAIMemoryStudio?()
                }

                PopoverMenuRow(icon: "gearshape.fill", label: "Settings", shortcut: "⌘,") {
                    viewModel.onOpenSettings?()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 16)
                .opacity(0.6)

            VStack(spacing: 4) {
                PopoverMenuRow(
                    icon: "power",
                    label: "Quit KeyScribe",
                    iconTint: .primary.opacity(0.6)
                ) {
                    viewModel.onQuit?()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .padding(.bottom, 4)
        }
        .frame(width: 280)
        .appThemedSurface(cornerRadius: 16, strokeOpacity: 0.16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.4)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isDictating)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.accentColor.opacity(0.8), .accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                    .shadow(color: .accentColor.opacity(0.3), radius: 3, x: 0, y: 2)

                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("KeyScribe")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))

                Text(viewModel.uiStatus.menuText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusPillColor)
            }

            Spacer()
        }
    }

    private var statusPillColor: Color {
        switch viewModel.uiStatus {
        case .ready: return .secondary
        case .listening: return .green
        case .finalizing: return .orange
        case .copiedFromHistory, .copiedToClipboard: return .blue
        case .pasteUnavailable, .accessibilityHint: return .red
        default: return .secondary
        }
    }
}

// MARK: - Menu Row

private struct PopoverMenuRow: View {
    let icon: String
    let label: String
    var shortcut: String? = nil
    var iconTint: Color = .primary
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isHovered ? .white : iconTint)
                    .frame(width: 20, alignment: .center)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered ? .white : .primary)

                Spacer()

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(isHovered ? Color.white.opacity(0.8) : Color.secondary.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.accentColor : Color.clear)
            )
            .opacity(isDisabled ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            if !isDisabled {
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
        }
    }
}

// MARK: - Recording Indicator

private struct RecordingIndicatorView: View {
    var audioLevel: Float
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 24, height: 24)
                    .scaleEffect(isAnimating ? 1.4 : 0.8)
                    .opacity(isAnimating ? 0 : 1)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: isAnimating)

                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Listening...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)

                WaveformBarsView(audioLevel: audioLevel)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.red.opacity(0.1), lineWidth: 1)
                )
        )
        .onAppear {
            isAnimating = true
        }
    }
}

private struct WaveformBarsView: View {
    var audioLevel: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { i in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 5.0 + Double(i) * 0.8
                    let level = max(Double(audioLevel), (sin(phase) + 1) * 0.25)
                    let height = 4 + 12 * level

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.red.opacity(0.7))
                        .frame(width: 3, height: CGFloat(height))
                }
            }
            .frame(height: 16, alignment: .center)
        }
    }
}
