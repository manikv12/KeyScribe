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
            // Header
            headerSection
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // Recording indicator
            if viewModel.isDictating {
                RecordingIndicatorView(audioLevel: viewModel.currentAudioLevel)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Divider()
                .opacity(0.5)
                .padding(.horizontal, 12)

            // Menu items
            VStack(spacing: 2) {
                PopoverMenuRow(
                    icon: viewModel.isContinuousMode ? "stop.fill" : "mic.fill",
                    label: viewModel.isContinuousMode ? "Stop Dictation" : "Start Dictation",
                    tint: viewModel.isContinuousMode ? .red : .accentColor,
                    isDisabled: !viewModel.permissionsReady
                ) {
                    viewModel.onToggleDictation?()
                }

                PopoverMenuRow(icon: "doc.on.clipboard", label: "Paste Last Transcript", shortcut: "⌘⌥V") {
                    viewModel.onPasteLastTranscript?()
                }

                PopoverMenuRow(icon: "clock.arrow.circlepath", label: "History") {
                    viewModel.onOpenHistory?()
                }

                PopoverMenuRow(icon: "brain.head.profile", label: "AI Memory Studio") {
                    viewModel.onOpenAIMemoryStudio?()
                }

                PopoverMenuRow(icon: "gearshape", label: "Settings", shortcut: "⌘,") {
                    viewModel.onOpenSettings?()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()
                .opacity(0.5)
                .padding(.horizontal, 12)

            // Quit
            PopoverMenuRow(icon: "power", label: "Quit", tint: .secondary) {
                viewModel.onQuit?()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 260)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor).opacity(0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .animation(.easeInOut(duration: 0.2), value: viewModel.isDictating)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text("KeyScribe")
                .font(.system(.title3, design: .rounded).bold())

            Spacer()

            statusPill
        }
    }

    private var statusPill: some View {
        Text(viewModel.uiStatus.menuText)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(statusPillColor.opacity(0.15))
            )
            .foregroundStyle(statusPillColor)
    }

    private var statusPillColor: Color {
        switch viewModel.uiStatus {
        case .ready:
            return .green
        case .listening:
            return .green
        case .finalizing:
            return .orange
        case .copiedFromHistory, .copiedToClipboard:
            return .blue
        case .pasteUnavailable, .accessibilityHint:
            return .orange
        default:
            return .secondary
        }
    }
}

// MARK: - Menu Row

private struct PopoverMenuRow: View {
    let icon: String
    let label: String
    var shortcut: String? = nil
    var tint: Color = .primary
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .opacity(isDisabled ? 0.3 : 1)
                    .frame(width: 20, alignment: .center)

                Text(label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .opacity(isDisabled ? 0.3 : 1)

                Spacer()

                if let shortcut {
                    Text(shortcut)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Recording Indicator

private struct RecordingIndicatorView: View {
    var audioLevel: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { timeline in
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulseOpacity(date: timeline.date))

                WaveformBarsView(audioLevel: audioLevel, date: timeline.date)

                Text("Recording…")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.08))
            )
        }
    }

    private func pulseOpacity(date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate * 3
        return 0.5 + 0.5 * sin(phase)
    }
}

private struct WaveformBarsView: View {
    var audioLevel: Float
    var date: Date

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                let phase = date.timeIntervalSinceReferenceDate * 4.8 + Double(i) * 0.8
                let level = max(Double(audioLevel), (sin(phase) + 1) * 0.3)
                let height = 4 + 14 * level

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 3, height: height)
            }
        }
        .frame(height: 18)
    }
}
