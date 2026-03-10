import Foundation

enum AssistantCommandSafetyClass: Equatable, Sendable {
    case readOnly
    case validation
    case mutatingOrUnknown
}

enum AssistantModePolicy {
    static func commandSafetyClass(for command: String) -> AssistantCommandSafetyClass {
        let normalized = normalize(command)
        guard !normalized.isEmpty else { return .mutatingOrUnknown }

        if containsCompoundOrRedirectedShell(normalized) {
            return .mutatingOrUnknown
        }

        let tokens = executableTokens(from: normalized)
        guard let executable = tokens.first else {
            return .mutatingOrUnknown
        }

        let firstTwo = tokens.prefix(2).joined(separator: " ")

        switch executable {
        case "pwd", "ls", "rg", "find", "cat", "head", "tail":
            return .readOnly
        case "sed":
            return firstTwo == "sed -n" ? .readOnly : .mutatingOrUnknown
        case "git":
            switch firstTwo {
            case "git status", "git diff", "git show":
                return .readOnly
            default:
                return .mutatingOrUnknown
            }
        case "swift":
            switch firstTwo {
            case "swift build", "swift test":
                return .validation
            default:
                return .mutatingOrUnknown
            }
        case "xcodebuild":
            guard let action = tokens.dropFirst().first else {
                return .mutatingOrUnknown
            }
            return action == "build" || action == "test" ? .validation : .mutatingOrUnknown
        default:
            return .mutatingOrUnknown
        }
    }

    static func isAllowed(
        mode: AssistantInteractionMode,
        activityKind: AssistantActivityKind,
        command: String? = nil,
        toolName: String? = nil
    ) -> Bool {
        if mode == .agentic || mode == .plan {
            return true
        }

        switch activityKind {
        case .commandExecution:
            let commandClass = commandSafetyClass(for: command ?? "")
            switch mode {
            case .conversational:
                return commandClass == .readOnly
            case .plan:
                return true
            case .agentic:
                return true
            }
        case .webSearch:
            return true
        case .fileChange, .browserAutomation, .mcpToolCall, .dynamicToolCall, .subagent:
            _ = toolName
            return false
        case .reasoning:
            return true
        case .other:
            return false
        }
    }

    static func blockedMessage(
        mode: AssistantInteractionMode,
        activityTitle: String? = nil,
        commandClass: AssistantCommandSafetyClass? = nil
    ) -> String {
        let normalizedTitle = activityTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activityPhrase: String
        if let normalizedTitle, !normalizedTitle.isEmpty {
            activityPhrase = " before using \(normalizedTitle)"
        } else {
            activityPhrase = ""
        }

        switch mode {
        case .conversational:
            if normalizedTitle?.lowercased() == "computer use" || normalizedTitle?.lowercased() == "browser" {
                return "I stopped\(activityPhrase) because Chat mode cannot inspect the live screen or browser with computer-control tools. Chat mode can still analyze an attached image when the selected model supports image input. Switch to Agentic mode for live screen or browser inspection."
            }
            if commandClass == .validation {
                return "I stopped\(activityPhrase) because Chat mode can inspect files and search the web, but it cannot run build or test checks. Switch to Plan or Agentic mode if you want me to run checks."
            }
            return "I stopped\(activityPhrase) because Chat mode can inspect files, search the web, and read attached images when the selected model supports them, but it cannot make changes or use higher-risk tools. Switch to Agentic mode for execution."
        case .plan:
            return "Tool use is allowed in Plan mode."
        case .agentic:
            return "Tool use is allowed in Agentic mode."
        }
    }

    private static func normalize(_ command: String) -> String {
        command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func containsCompoundOrRedirectedShell(_ command: String) -> Bool {
        if command.contains("&&") || command.contains(";") {
            return true
        }
        if command.contains("|") || command.contains(">") || command.contains("<") {
            return true
        }
        return command.contains(" tee ")
    }

    private static func executableTokens(from command: String) -> [String] {
        var tokens = command.split(separator: " ").map(String.init)
        while let first = tokens.first, isEnvironmentAssignment(first) {
            tokens.removeFirst()
        }

        if tokens.first == "env" {
            tokens.removeFirst()
            while let first = tokens.first, isEnvironmentAssignment(first) {
                tokens.removeFirst()
            }
        }

        return tokens
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        token.range(
            of: #"^[a-z_][a-z0-9_]*=.*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
