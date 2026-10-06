import Foundation
import OSLog

struct Timing: Sendable {
    static let logger = Logger(subsystem: "local.translatebar.TranslateBar", category: "pipeline")
    private let start = ContinuousClock.now
    static func event(_ name: String, count: Int = 0) {
        logger.info("event=\(name, privacy: .public) count=\(count, privacy: .public)")
    }
    func mark(_ stage: String, count: Int = 0) {
        let ms = elapsedMilliseconds
        // Callers pass constant stage identifiers and numeric counts only.
        Self.logger.info("stage=\(stage, privacy: .public) elapsed_ms=\(ms, privacy: .public) count=\(count, privacy: .public)")
    }
    var elapsedMilliseconds: Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
    func modelMark(_ stage: String, call: Int) {
        let ms = elapsedMilliseconds
        Self.logger.info("model_stage=\(stage, privacy: .public) request_ms=\(ms, privacy: .public) call=\(call, privacy: .public)")
        if CommandLine.arguments.contains("--smoke-model") || CommandLine.arguments.contains("--check-model-stdin") || CommandLine.arguments.contains("--benchmark-model") {
            print("model_stage=\(stage) request_ms=\(String(format: "%.2f", ms)) call=\(call)")
        }
    }
}
