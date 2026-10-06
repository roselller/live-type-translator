import Foundation
import Observation

struct RecentResult: Identifiable {
    let id = UUID()
    let createdAt = Date()
    let request: TranslationRequest
    var result: TranslationResult
    var preview: String {
        String(request.source.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(70))
    }
}

/// Intentionally not Codable; retains no AX elements, window handles, or destination.
@MainActor @Observable
final class RecentResults {
    private(set) var entries: [RecentResult] = []
    @discardableResult func add(request: TranslationRequest, result: TranslationResult) -> UUID {
        let entry = RecentResult(request: request, result: result)
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(10))
        return entry.id
    }
    func update(_ id: UUID, result: TranslationResult) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let checked = try? result.validated(for: entries[index].request) else { return }
        entries[index].result = checked
    }
    func clear() { entries.removeAll() }
}
