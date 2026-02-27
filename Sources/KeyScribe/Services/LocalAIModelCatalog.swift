import Foundation

struct LocalAIModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let sizeLabel: String
    let performanceLabel: String
    let summary: String
    let isRecommended: Bool
}

enum LocalAIModelCatalog {
    static let curatedModels: [LocalAIModelOption] = [
        LocalAIModelOption(
            id: "qwen2.5:3b",
            displayName: "Qwen 2.5 3B",
            sizeLabel: "~2.0 GB",
            performanceLabel: "Fast",
            summary: "Best balance for rewrite quality and memory-lesson extraction on most Macs.",
            isRecommended: true
        ),
        LocalAIModelOption(
            id: "llama3.2:3b",
            displayName: "Llama 3.2 3B",
            sizeLabel: "~2.0 GB",
            performanceLabel: "Fast",
            summary: "Good all-around local model with broad compatibility.",
            isRecommended: false
        ),
        LocalAIModelOption(
            id: "gemma2:2b",
            displayName: "Gemma 2 2B",
            sizeLabel: "~1.6 GB",
            performanceLabel: "Very Fast",
            summary: "Smallest download option. Faster startup with modest quality tradeoffs.",
            isRecommended: false
        )
    ]

    static var recommendedModel: LocalAIModelOption {
        curatedModels.first(where: { $0.isRecommended }) ?? curatedModels[0]
    }

    static func model(withID modelID: String) -> LocalAIModelOption? {
        curatedModels.first { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }
    }
}
