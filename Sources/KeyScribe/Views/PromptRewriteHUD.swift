import AppKit
import SwiftUI

@MainActor
enum PromptRewritePreviewChoice {
    case useSuggested
    case editThenInsert
    case insertOriginal
    case rejectSuggestion
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
                contentRect: NSRect(x: 0, y: 0, width: 392, height: .zero),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
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

        let targetSize = hosting.sizeThatFits(in: NSSize(width: 392, height: 420))
        let frame = NSRect(
            x: 0,
            y: 0,
            width: 392,
            height: min(340, max(142, targetSize.height))
        )
        hosting.view.frame = frame

        let placement = resolvedFrame(for: frame.size)
        window.setFrame(placement, display: true)
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

    private func resolvedFrame(for panelSize: NSSize) -> NSRect {
        let margin: CGFloat = 8
        let anchorRect = insertionAnchorRect() ?? mouseAnchorRect()
        let anchorPoint = NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = screenContaining(point: anchorPoint) ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)

        let preferredX = anchorRect.midX - (panelSize.width * 0.5)
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - panelSize.width - margin
        let x = min(max(preferredX, minX), maxX)

        let preferredAboveY = anchorRect.maxY + margin
        let preferredBelowY = anchorRect.minY - panelSize.height - margin
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - panelSize.height - margin

        let y: CGFloat
        if preferredAboveY <= maxY {
            y = preferredAboveY
        } else if preferredBelowY >= minY {
            y = preferredBelowY
        } else {
            y = min(max(preferredAboveY, minY), maxY)
        }

        return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }

    private func insertionAnchorRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedResult == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedElement = unsafeBitCast(focusedRef, to: AXUIElement.self)

        var selectedRangeRef: CFTypeRef?
        let selectedRangeResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )
        guard selectedRangeResult == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }
        let selectedRangeAXValue = unsafeBitCast(selectedRangeRef, to: AXValue.self)
        guard AXValueGetType(selectedRangeAXValue) == .cfRange else {
            return nil
        }

        var boundsRef: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRangeAXValue,
            &boundsRef
        )
        guard boundsResult == .success,
              let boundsRef,
              CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }

        let boundsAXValue = unsafeBitCast(boundsRef, to: AXValue.self)
        guard AXValueGetType(boundsAXValue) == .cgRect else {
            return nil
        }

        var cgRect = CGRect.zero
        guard AXValueGetValue(boundsAXValue, .cgRect, &cgRect) else {
            return nil
        }

        if let normalized = normalizeAccessibilityRectToScreen(cgRect) {
            return normalized
        }
        return nil
    }

    private func normalizeAccessibilityRectToScreen(_ rect: CGRect) -> NSRect? {
        let direct = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
        let directPoint = NSPoint(x: direct.midX, y: direct.midY)
        if screenContaining(point: directPoint) != nil {
            return direct
        }

        let globalMaxY = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let flippedY = globalMaxY - rect.origin.y - rect.height
        let flipped = NSRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
        let flippedPoint = NSPoint(x: flipped.midX, y: flipped.midY)
        if screenContaining(point: flippedPoint) != nil {
            return flipped
        }

        return nil
    }

    private func mouseAnchorRect() -> NSRect {
        let point = NSEvent.mouseLocation
        return NSRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(point)
        }
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
        Group {
            if let selectedPage {
                compactSuggestion(for: selectedPage)
            } else {
                Text("No suggestion available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .appThemedSurface(
                        cornerRadius: 14,
                        tint: AppVisualTheme.panelTint,
                        strokeOpacity: 0.12,
                        tintOpacity: 0.01
                    )
            }
        }
        .frame(width: 392)
        .tint(AppVisualTheme.accentTint)
    }

    @ViewBuilder
    private func compactSuggestion(for page: PromptRewriteDiscussionPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIconBadge(
                    symbol: "sparkles",
                    tint: AppVisualTheme.accentTint,
                    size: 20,
                    symbolSize: 9,
                    isEmphasized: true
                )
                Text("AI suggestion")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer(minLength: 0)
                if pages.count > 1 {
                    Text("\(safeSelectedIndex + 1)/\(pages.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppVisualTheme.mutedText)
                }
            }

            ScrollView {
                Text(page.suggestion.suggestedText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 1)
            }
            .frame(minHeight: 50, maxHeight: 170)

            HStack(spacing: 8) {
                Text("Esc to keep original")
                    .font(.caption2)
                    .foregroundStyle(AppVisualTheme.mutedText)
                Spacer(minLength: 0)
                Button("Insert") {
                    onChoice(.useSuggested)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(AppVisualTheme.accentTint)
            }
        }
        .padding(12)
        .appThemedSurface(
            cornerRadius: 14,
            tint: AppVisualTheme.panelTint,
            strokeOpacity: 0.12,
            tintOpacity: 0.01
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 0.5)
        )
        .overlay(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(45))
                .offset(x: 38, y: 6)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
        .onExitCommand {
            onChoice(.insertOriginal)
        }
    }

    @ViewBuilder
    private func suggestionDetail(for page: PromptRewriteDiscussionPage) -> some View {
        EmptyView()
    }
}
