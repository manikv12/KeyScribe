import Foundation

enum InsertionRetryPlan: Equatable {
    case retry(delay: TimeInterval, nextRetriesRemaining: Int)
    case complete(statusMessage: String?)
}

enum FocusActivationRetryPlan: Equatable {
    case retry(delay: TimeInterval, nextRetriesRemaining: Int)
    case proceed
}

enum InsertionRetryPolicy {
    static let retryDelay: TimeInterval = 0.12
    static let activationRetryDelay: TimeInterval = 0.18

    static func plan(for result: TextInserter.Result, retriesRemaining: Int) -> InsertionRetryPlan {
        let boundedRetries = max(0, retriesRemaining)

        switch result {
        case .pasted:
            return .complete(statusMessage: "Ready")
        case .copiedOnly:
            if boundedRetries > 0 {
                return .retry(delay: retryDelay, nextRetriesRemaining: boundedRetries - 1)
            }
            return .complete(statusMessage: "Copied to clipboard")
        case .notInserted:
            if boundedRetries > 0 {
                return .retry(delay: retryDelay, nextRetriesRemaining: boundedRetries - 1)
            }
            return .complete(statusMessage: "Paste unavailable")
        case .empty:
            return .complete(statusMessage: nil)
        }
    }

    static func activationPlan(hasTargetApplication: Bool, targetIsActive: Bool, retriesRemaining: Int) -> FocusActivationRetryPlan {
        let boundedRetries = max(0, retriesRemaining)

        guard hasTargetApplication else {
            return .proceed
        }

        guard !targetIsActive else {
            return .proceed
        }

        if boundedRetries > 0 {
            return .retry(delay: activationRetryDelay, nextRetriesRemaining: boundedRetries - 1)
        }

        return .proceed
    }
}
