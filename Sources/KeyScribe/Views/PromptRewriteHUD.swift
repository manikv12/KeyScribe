import AppKit
import SwiftUI

@MainActor
enum PromptRewritePreviewChoice {
    case useSuggested
    case editThenInsert
    case insertOriginal
}

@MainActor
final class PromptRewriteHUDManager {
    static let shared = PromptRewriteHUDManager()

    private struct PendingSuggestion: Identifiable {
        let id: UUID
        let originalText: String
        let suggestion: PromptRewriteSuggestion
        let continuation: CheckedContinuation<PromptRewritePreviewChoice, Never>
    }

    private var window: NSPanel?
    private var pendingSuggestions: [PendingSuggestion] = []
    private var selectedSuggestionIndex: Int = 0

    func present(originalText: String, suggestion: PromptRewriteSuggestion) async -> PromptRewritePreviewChoice {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: .zero),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window = panel
        }

        guard let window else { return .insertOriginal }

        return await withCheckedContinuation { continuation in
            pendingSuggestions.append(
                PendingSuggestion(
                    id: UUID(),
                    originalText: originalText,
                    suggestion: suggestion,
                    continuation: continuation
                )
            )
            selectedSuggestionIndex = max(0, pendingSuggestions.count - 1)
            render(in: window)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func render(in explicitWindow: NSPanel? = nil) {
        guard let window = explicitWindow ?? self.window else { return }
        guard !pendingSuggestions.isEmpty else {
            window.contentViewController = nil
            window.orderOut(nil)
            selectedSuggestionIndex = 0
            return
        }

        selectedSuggestionIndex = min(max(0, selectedSuggestionIndex), pendingSuggestions.count - 1)

        let pages = pendingSuggestions.map { pending in
            PromptRewriteDiscussionPage(
                id: pending.id,
                originalText: pending.originalText,
                suggestion: pending.suggestion
            )
        }

        let view = PromptRewriteHUDView(
            pages: pages,
            selectedIndex: selectedSuggestionIndex,
            onSelectPage: { [weak self] newIndex in
                self?.selectPage(newIndex)
            },
            onChoice: { [weak self] choice in
                self?.finishSelected(with: choice)
            }
        )

        let hosting = NSHostingController(rootView: view)
        window.contentViewController = hosting

        let targetSize = hosting.sizeThatFits(in: NSSize(width: 460, height: 900))
        let frame = NSRect(
            x: 0,
            y: 0,
            width: 460,
            height: min(760, max(300, targetSize.height))
        )
        hosting.view.frame = frame

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let x = screen.frame.midX - (frame.width * 0.5)
            let y = screen.frame.minY + 180
            window.setFrame(NSRect(x: x, y: y, width: frame.width, height: frame.height), display: true)
        }
    }

    private func selectPage(_ index: Int) {
        guard !pendingSuggestions.isEmpty else { return }
        selectedSuggestionIndex = min(max(0, index), pendingSuggestions.count - 1)
        render()
    }

    private func finishSelected(with choice: PromptRewritePreviewChoice) {
        guard !pendingSuggestions.isEmpty else { return }

        let index = min(max(0, selectedSuggestionIndex), pendingSuggestions.count - 1)
        let pending = pendingSuggestions.remove(at: index)
        pending.continuation.resume(returning: choice)

        guard !pendingSuggestions.isEmpty else {
            window?.contentViewController = nil
            window?.orderOut(nil)
            selectedSuggestionIndex = 0
            return
        }

        selectedSuggestionIndex = min(index, pendingSuggestions.count - 1)
        render()
    }
}

private struct PromptRewriteDiscussionPage: Identifiable, Equatable {
    let id: UUID
    let originalText: String
    let suggestion: PromptRewriteSuggestion
}

private struct PromptRewriteHUDView: View {
    let pages: [PromptRewriteDiscussionPage]
    let selectedIndex: Int
    let onSelectPage: (Int) -> Void
    let onChoice: (PromptRewritePreviewChoice) -> Void

    private var safeSelectedIndex: Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(0, selectedIndex), pages.count - 1)
    }

    private var selectedPage: PromptRewriteDiscussionPage? {
        guard !pages.isEmpty else { return nil }
        return pages[safeSelectedIndex]
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.purple)
                Text("AI Discussion")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }

            if pages.count > 1 {
                HStack(spacing: 10) {
                    Button {
                        onSelectPage(safeSelectedIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(safeSelectedIndex == 0)

                    Text("Suggestion \(safeSelectedIndex + 1) of \(pages.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        onSelectPage(safeSelectedIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(safeSelectedIndex >= pages.count - 1)

                    Spacer()
                }
            }

            if let selectedPage {
                suggestionDetail(for: selectedPage)
            } else {
                Text("No suggestion available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button {
                    onChoice(.useSuggested)
                } label: {
                    Text("Use Suggested")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(selectedPage == nil)

                Button {
                    onChoice(.editThenInsert)
                } label: {
                    Text("Edit")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(selectedPage == nil)

                Button {
                    onChoice(.insertOriginal)
                } label: {
                    Text("Insert Original")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(selectedPage == nil)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .appThemedSurface(cornerRadius: 16, strokeOpacity: 0.18)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
        )
        .frame(width: 460)
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
    }

    @ViewBuilder
    private func suggestionDetail(for page: PromptRewriteDiscussionPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let memoryContext = page.suggestion.memoryContext,
               !memoryContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory Context")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                    Text(memoryContext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()
                    .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Suggested")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(page.suggestion.suggestedText)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 80, maxHeight: 220)
            }

            Divider()
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Original")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(page.originalText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 56, maxHeight: 150)
            }
        }
    }
}
