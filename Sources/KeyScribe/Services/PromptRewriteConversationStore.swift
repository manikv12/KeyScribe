import AppKit
import CryptoKit
import Foundation

struct PromptRewriteConversationTurn: Codable, Equatable {
    let userText: String
    let assistantText: String
    let timestamp: Date

    init(userText: String, assistantText: String, timestamp: Date = Date()) {
        self.userText = userText
        self.assistantText = assistantText
        self.timestamp = timestamp
    }
}

struct PromptRewriteConversationContext: Codable, Equatable, Identifiable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let screenLabel: String
    let fieldLabel: String

    var displayName: String {
        let normalizedScreen = screenLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedField = fieldLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedScreen.isEmpty && normalizedField.isEmpty {
            return appName
        }
        if normalizedField.isEmpty {
            return "\(appName) - \(normalizedScreen)"
        }
        if normalizedScreen.isEmpty {
            return "\(appName) - \(normalizedField)"
        }
        return "\(appName) - \(normalizedScreen) - \(normalizedField)"
    }

    var providerContextLabel: String {
        let normalizedScreen = screenLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedField = fieldLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedScreen.isEmpty && normalizedField.isEmpty {
            return appName
        }
        if normalizedField.isEmpty {
            return "\(appName), screen: \(normalizedScreen)"
        }
        if normalizedScreen.isEmpty {
            return "\(appName), field: \(normalizedField)"
        }
        return "\(appName), screen: \(normalizedScreen), field: \(normalizedField)"
    }
}

struct PromptRewriteConversationContextSummary: Identifiable, Equatable {
    let id: String
    let displayName: String
    let appName: String
    let screenLabel: String
    let fieldLabel: String
    let lastUpdatedAt: Date
    let turnCount: Int
}

@MainActor
final class PromptRewriteConversationStore: ObservableObject {
    static let shared = PromptRewriteConversationStore()

    struct RequestContext {
        let context: PromptRewriteConversationContext
        let history: [PromptRewriteConversationTurn]
        let usesPinnedContext: Bool
    }

    private struct StoredContext: Codable {
        var context: PromptRewriteConversationContext
        var turns: [PromptRewriteConversationTurn]
        var lastUpdatedAt: Date
    }

    private struct PersistedState: Codable {
        var contexts: [StoredContext]
    }

    @Published private(set) var contextSummaries: [PromptRewriteConversationContextSummary] = []

    private let defaults = UserDefaults.standard
    private let storageKey = "KeyScribe.promptRewriteConversationState"
    private let maxStoredContexts = 24

    private var contextsByID: [String: StoredContext] = [:]

    private init() {
        load()
        refreshSummaries()
    }

    func prepareRequestContext(
        capturedContext: PromptRewriteConversationContext,
        timeoutMinutes: Double,
        turnLimit: Int,
        pinnedContextID: String?
    ) -> RequestContext {
        pruneStaleContexts(timeoutMinutes: timeoutMinutes)

        let normalizedPinnedID = pinnedContextID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedContext: StoredContext?
        if let normalizedPinnedID, !normalizedPinnedID.isEmpty {
            pinnedContext = contextsByID[normalizedPinnedID]
        } else {
            pinnedContext = nil
        }

        let resolvedContext: PromptRewriteConversationContext
        let usesPinnedContext: Bool
        if let pinnedContext {
            resolvedContext = pinnedContext.context
            usesPinnedContext = true
        } else {
            resolvedContext = capturedContext
            usesPinnedContext = false
            upsertContext(capturedContext, updatedAt: Date(), preserveTurns: true)
        }

        let maxTurns = normalizedTurnLimit(turnLimit)
        let history = contextsByID[resolvedContext.id]?.turns.suffix(maxTurns).map { $0 } ?? []

        return RequestContext(
            context: resolvedContext,
            history: history,
            usesPinnedContext: usesPinnedContext
        )
    }

    func recordTurn(
        originalText: String,
        finalText: String,
        context: PromptRewriteConversationContext,
        timeoutMinutes: Double,
        maxTurns: Int
    ) {
        let normalizedOriginal = collapsedWhitespace(originalText)
        let normalizedFinal = collapsedWhitespace(finalText)
        guard !normalizedOriginal.isEmpty, !normalizedFinal.isEmpty else {
            return
        }

        pruneStaleContexts(timeoutMinutes: timeoutMinutes)

        let now = Date()
        var stored = contextsByID[context.id] ?? StoredContext(
            context: context,
            turns: [],
            lastUpdatedAt: now
        )

        stored.context = context
        stored.lastUpdatedAt = now
        stored.turns.append(
            PromptRewriteConversationTurn(
                userText: snippet(normalizedOriginal, limit: 420),
                assistantText: snippet(normalizedFinal, limit: 420),
                timestamp: now
            )
        )

        let limit = normalizedTurnLimit(maxTurns)
        if stored.turns.count > limit {
            stored.turns = Array(stored.turns.suffix(limit))
        }

        contextsByID[context.id] = stored
        trimStoredContextsIfNeeded()
        persist()
        refreshSummaries()
    }

    func clearContext(id: String) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        guard contextsByID.removeValue(forKey: normalizedID) != nil else { return }
        persist()
        refreshSummaries()
    }

    func clearAll() {
        guard !contextsByID.isEmpty else { return }
        contextsByID.removeAll()
        persist()
        refreshSummaries()
    }

    func hasContext(id: String) -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return false }
        return contextsByID[normalizedID] != nil
    }

    private func upsertContext(_ context: PromptRewriteConversationContext, updatedAt: Date, preserveTurns: Bool) {
        if var existing = contextsByID[context.id] {
            existing.context = context
            existing.lastUpdatedAt = updatedAt
            if !preserveTurns {
                existing.turns = []
            }
            contextsByID[context.id] = existing
        } else {
            contextsByID[context.id] = StoredContext(
                context: context,
                turns: [],
                lastUpdatedAt: updatedAt
            )
        }
    }

    private func normalizedTurnLimit(_ value: Int) -> Int {
        min(10, max(1, value))
    }

    private func normalizedTimeoutMinutes(_ value: Double) -> Double {
        let fallback = 25.0
        guard value.isFinite else { return fallback }
        return min(240, max(2, value))
    }

    private func pruneStaleContexts(timeoutMinutes: Double) {
        guard !contextsByID.isEmpty else { return }

        let timeout = normalizedTimeoutMinutes(timeoutMinutes) * 60
        let now = Date()
        let staleIDs = contextsByID.compactMap { (id, stored) in
            now.timeIntervalSince(stored.lastUpdatedAt) > timeout ? id : nil
        }

        guard !staleIDs.isEmpty else { return }
        for id in staleIDs {
            contextsByID.removeValue(forKey: id)
        }
        persist()
        refreshSummaries()
    }

    private func trimStoredContextsIfNeeded() {
        guard contextsByID.count > maxStoredContexts else { return }

        let sortedIDs = contextsByID
            .sorted { lhs, rhs in
                lhs.value.lastUpdatedAt > rhs.value.lastUpdatedAt
            }
            .map(\.key)

        for id in sortedIDs.dropFirst(maxStoredContexts) {
            contextsByID.removeValue(forKey: id)
        }
    }

    private func refreshSummaries() {
        contextSummaries = contextsByID
            .values
            .sorted { lhs, rhs in
                lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
            .map { stored in
                PromptRewriteConversationContextSummary(
                    id: stored.context.id,
                    displayName: stored.context.displayName,
                    appName: stored.context.appName,
                    screenLabel: stored.context.screenLabel,
                    fieldLabel: stored.context.fieldLabel,
                    lastUpdatedAt: stored.lastUpdatedAt,
                    turnCount: stored.turns.count
                )
            }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            contextsByID = [:]
            return
        }

        guard let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            contextsByID = [:]
            return
        }

        var next: [String: StoredContext] = [:]
        for item in state.contexts {
            next[item.context.id] = item
        }
        contextsByID = next
    }

    private func persist() {
        let sorted = contextsByID
            .values
            .sorted { lhs, rhs in
                lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
        let state = PersistedState(contexts: sorted)
        guard let encoded = try? JSONEncoder().encode(state) else { return }
        defaults.set(encoded, forKey: storageKey)
    }

    private func collapsedWhitespace(_ value: String) -> String {
        let parts = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    private func snippet(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 3))) + "..."
    }
}

enum PromptRewriteConversationContextResolver {
    static func captureCurrentContext(fallbackApp: NSRunningApplication?) -> PromptRewriteConversationContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app: NSRunningApplication?
        if let frontmost,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app = frontmost
        } else if let fallbackApp,
                  fallbackApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app = fallbackApp
        } else {
            app = nil
        }

        let appName = normalizedLabel(app?.localizedName) ?? "Current App"
        let bundleID = normalizedLabel(app?.bundleIdentifier) ?? "unknown.app"

        let metadata = focusedElementMetadata()
        let screenLabel = metadata.windowTitle
            ?? metadata.documentLabel
            ?? "Current Screen"
        let fieldLabel = metadata.fieldLabel ?? "Focused Input"

        let signature = [
            bundleID.lowercased(),
            collapsedWhitespace(screenLabel).lowercased(),
            collapsedWhitespace(fieldLabel).lowercased()
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(signature.utf8))
        let digestPrefix = digest.map { String(format: "%02x", $0) }.joined().prefix(20)
        let contextID = "ctx-\(digestPrefix)"

        return PromptRewriteConversationContext(
            id: contextID,
            appName: appName,
            bundleIdentifier: bundleID,
            screenLabel: snippet(screenLabel, limit: 56),
            fieldLabel: snippet(fieldLabel, limit: 48)
        )
    }

    private struct FocusMetadata {
        let windowTitle: String?
        let documentLabel: String?
        let fieldLabel: String?
    }

    private static func focusedElementMetadata() -> FocusMetadata {
        guard AXIsProcessTrusted() else {
            return FocusMetadata(windowTitle: nil, documentLabel: nil, fieldLabel: nil)
        }

        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedElement = axElementAttribute(kAXFocusedUIElementAttribute as CFString, from: systemWide) else {
            return FocusMetadata(windowTitle: nil, documentLabel: nil, fieldLabel: nil)
        }

        let role = axStringAttribute(kAXRoleAttribute as CFString, from: focusedElement)
        let subrole = axStringAttribute(kAXSubroleAttribute as CFString, from: focusedElement)
        let title = axStringAttribute(kAXTitleAttribute as CFString, from: focusedElement)
        let identifier = axStringAttribute(kAXIdentifierAttribute as CFString, from: focusedElement)
        let description = axStringAttribute(kAXDescriptionAttribute as CFString, from: focusedElement)
        let placeholder = axStringAttribute(kAXPlaceholderValueAttribute as CFString, from: focusedElement)

        let fieldComponents = [title, placeholder, identifier, description, role]
            .compactMap(normalizedLabel)
            .filter { !$0.isEmpty }
        let fieldLabel: String?
        if let first = fieldComponents.first {
            if let subrole = normalizedLabel(subrole), !subrole.isEmpty,
               !first.localizedCaseInsensitiveContains(subrole) {
                fieldLabel = "\(first) (\(subrole))"
            } else {
                fieldLabel = first
            }
        } else if let role = normalizedLabel(role), !role.isEmpty {
            if let subrole = normalizedLabel(subrole), !subrole.isEmpty {
                fieldLabel = "\(role) (\(subrole))"
            } else {
                fieldLabel = role
            }
        } else {
            fieldLabel = nil
        }

        let windowElement = axElementAttribute(kAXWindowAttribute as CFString, from: focusedElement)
        let windowTitle = windowElement.flatMap { axStringAttribute(kAXTitleAttribute as CFString, from: $0) }
        let documentPath = windowElement.flatMap { axStringAttribute(kAXDocumentAttribute as CFString, from: $0) }
        let documentLabel = documentPath.flatMap(deriveDocumentLabel)

        return FocusMetadata(
            windowTitle: normalizedLabel(windowTitle),
            documentLabel: documentLabel,
            fieldLabel: fieldLabel
        )
    }

    private static func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(valueRef, to: AXUIElement.self)
    }

    private static func axStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }
        return valueRef as? String
    }

    private static func normalizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = collapsedWhitespace(raw)
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func deriveDocumentLabel(from rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            if url.isFileURL {
                let name = url.deletingPathExtension().lastPathComponent
                return normalizedLabel(name)
            }
            if let host = url.host, !host.isEmpty {
                return normalizedLabel(host)
            }
            return normalizedLabel(url.lastPathComponent)
        }

        let fileURL = URL(fileURLWithPath: trimmed)
        let name = fileURL.deletingPathExtension().lastPathComponent
        return normalizedLabel(name)
    }

    private static func snippet(_ value: String, limit: Int) -> String {
        let normalized = collapsedWhitespace(value)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit - 3))) + "..."
    }
}
