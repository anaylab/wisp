// Minimal stand-ins for the app types BrainMorningSuggestions touches, so its pure logic
// (material, parsing, quote verification) compiles without the whole app.
import Foundation

struct MorningSuggestion: Identifiable, Equatable {
    enum Action: Equatable { case askQuestion(String) }
    let id: String
    let title: String
    let symbolName: String
    let action: Action
}

enum AppBundleConfiguration {
    static func stringValue(forKey key: String) -> String? { nil }
}

enum LocalOllamaAPI {
    static var activeContextWindowTokens: Int { 8192 }
    static let modelResidencyWindow = "5m"
}
