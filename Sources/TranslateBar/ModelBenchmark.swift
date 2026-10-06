import Foundation

/// Repeatable fixed fixtures only. Prints timing/count metadata, never text.
@MainActor
enum ModelBenchmark {
    static func run() async -> Bool {
        let edgeCases = CommandLine.arguments.contains("--edge-fixtures")
        let dateCases = CommandLine.arguments.contains("--date-fixtures")
        let guidanceCases = CommandLine.arguments.contains("--guidance-fixtures")
        let fixtures: [(String, TranslationRequest)] = guidanceCases ? [
            ("account-safety", .init(source: "A compromised account can expose private documents. Use a unique password and never share your sign-in code.", languages: [.japanese])),
            ("course-guidance", .init(source: "Ask the lecturer which online tools are permitted for this assignment.\nVerify the answers and keep personal records out of shared tools.", languages: [.japanese, .korean])),
            ("data-warning", .init(source: "Warning: a data breach may expose your email address. Please contact the support team if you notice an unfamiliar login.", languages: [.simplifiedChinese, .traditionalChinese, .japanese]))
        ] : dateCases ? [
            ("date-japanese", .init(source: "Announcement dated 8 July 2024", languages: [.japanese])),
            ("date-lines", .init(source: "Announcement dated\n8 February 2024", languages: [.japanese])),
            ("date-three", .init(source: "The meeting is on 8 August 2024.", languages: [.traditionalChinese, .japanese, .korean]))
        ] : edgeCases ? [
            ("blank-lines", .init(source: "Please review the plan.\r\n\r\nThank you for your help.\r\n")),
            ("glossary", .init(source: "Please send the Atlas report by 3 PM.\nThe meeting link is https://example.com.",
                profile: .init(audience: "University project teammates", glossary: [.init(source: "Atlas", replacement: "Atlas")]))),
            ("multiline-three", .init(source: "Please review the plan.\nThe deadline is Friday.",
                languages: [.korean, .traditionalChinese, .simplifiedChinese])),
            ("ambiguous", .init(source: "Let us touch base after the meeting.\nThe ball is in your court.", languages: [.japanese]))
        ] : [
            ("short-two", .init(source: "Thank you for your help. Please review the proposal.")),
            ("multiline-two", .init(source: """
                Please choose a communication channel and check it every day.
                Assign a facilitator, a note taker, a timekeeper, and a presenter.
                If you miss a meeting, read the notes and add your comments later.
                Listen respectfully and give everyone time to explain their ideas.
                """)),
            ("short-three", .init(source: "Thank you for your help. Please review the proposal.",
                languages: [.traditionalChinese, .simplifiedChinese, .japanese]))
        ]
        var passed = true
        for round in 1...(edgeCases || guidanceCases ? 1 : 3) {
            for (name, request) in fixtures {
                let engine = FoundationModelsEngine()
                engine.prewarm()
                try? await Task.sleep(for: .seconds(2))
                engine.prewarm()
                let timing = Timing()
                do {
                    let result = try await engine.translate(request)
                    print("benchmark case=\(name) round=\(round) pass=true calls=\(result.modelCalls) elapsed_ms=\(String(format: "%.2f", timing.elapsedMilliseconds))")
                } catch {
                    passed = false
                    print("benchmark case=\(name) round=\(round) pass=false elapsed_ms=\(String(format: "%.2f", timing.elapsedMilliseconds)) error=\((error as? AppFailure)?.errorDescription ?? "Cancelled")")
                }
            }
        }
        return passed
    }
}
