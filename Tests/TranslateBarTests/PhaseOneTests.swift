import AppKit
import Testing
@testable import TranslateBar

@Suite @MainActor
struct ClipboardTests {
    @Test func restoresEveryItemAndTypeAfterLazyPaste() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let text = NSPasteboardItem()
        text.setString("Original fixture", forType: .string)
        text.setData(Data("{\\rtf1 Original fixture}".utf8), forType: .rtf)
        let custom = NSPasteboard.PasteboardType("local.fixture.binary")
        text.setData(Data([0, 1, 128, 255]), forType: custom)
        let picture = NSPasteboardItem()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
        picture.setData(png, forType: .png)
        #expect(board.writeObjects([text, picture]))
        let before = representations(board)
        let session = try PasteboardSession(board: board)
        let provider = try session.writePayload("\n翻訳\n번역")
        for type in PasteboardSession.markers { #expect(board.types?.contains(type) == true) }
        #expect(!provider.wasRequested)
        #expect(board.string(forType: .string) == "\n翻訳\n번역")
        #expect(provider.wasRequested)
        #expect(try session.restore() == .restored)
        #expect(representations(board) == before)
        #expect(try session.restore() == .untouched)
    }

    @Test func restoresCopyOnReadFailure() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let session = try PasteboardSession(board: board)
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .png)
        #expect(session.recordCopyChange())
        #expect(throws: AppFailure.noText) { try session.acceptCopy() }
        try session.restore()
        #expect(board.string(forType: .string) == "original")
    }

    @Test func neverOverwritesANewerClipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let session = try PasteboardSession(board: board)
        let provider = try session.writePayload("temporary")
        withExtendedLifetime(provider) {
            board.clearContents()
            board.setString("new user copy", forType: .string)
        }
        #expect(try session.restore() == .newerClipboardKept)
        #expect(board.string(forType: .string) == "new user copy")
    }

    @Test func restoresEmptyClipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let session = try PasteboardSession(board: board)
        let provider = try session.writePayload("temporary")
        _ = try withExtendedLifetime(provider) { try session.restore() }
        #expect((board.pasteboardItems ?? []).isEmpty)
    }

    @Test func denialDoesNotMutateClipboard() {
        struct Denied: PasteboardPrivacy {
            func requireReadable(_ pasteboard: NSPasteboard) throws { throw AppFailure.clipboardDenied }
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let count = board.changeCount
        #expect(throws: AppFailure.clipboardDenied) { try PasteboardSession(board: board, privacy: Denied()) }
        #expect(board.changeCount == count)
        #expect(board.string(forType: .string) == "original")
    }

    @Test func refusesStaleSnapshotBeforeWriting() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let session = try PasteboardSession(board: board)
        board.clearContents()
        board.setString("newer", forType: .string)
        #expect(throws: AppFailure.clipboardChanged) { try session.writePayload("translation") }
        #expect(try session.restore() == .untouched)
        #expect(board.string(forType: .string) == "newer")
    }

    private func representations(_ board: NSPasteboard) -> [[String: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.map { ($0.rawValue, item.data(forType: $0)!) })
        }
    }
}

@Suite
struct TranslationValidationTests {
    private let request = TranslationRequest(source: "Hello")
    private func translation(_ language: TargetLanguage, _ text: String) -> LanguageTranslation {
        .init(language: language, text: text, notes: [], phrases: [])
    }

    @Test func ordersResultsAndBuildsInsertBelowPayload() throws {
        let result = try TranslationResult(translations: [translation(.korean, "안녕하세요"), translation(.japanese, "こんにちは")])
            .validated(for: request)
        #expect(result.translations.map(\.language) == [.japanese, .korean])
        #expect(result.pastePayload == "\nこんにちは\n안녕하세요")
    }

    @Test func rejectsMissingDuplicateAndEmptyResults() {
        for translations in [
            [translation(.japanese, "こんにちは")],
            [translation(.japanese, "こんにちは"), translation(.japanese, "こんにちは")],
            [translation(.japanese, "こんにちは"), translation(.korean, " \n")]
        ] {
            #expect(throws: AppFailure.invalidResult) { try TranslationResult(translations: translations).validated(for: request) }
        }
    }

    @Test func filtersInvalidFlags() throws {
        var japanese = translation(.japanese, "こんにちは")
        japanese.phrases = [
            .init(source: "Hello", used: "不存在", alternatives: ["a", "b"]),
            .init(source: "Hello", used: "こんにちは", alternatives: ["a", "b"])
        ]
        let result = try TranslationResult(translations: [japanese, translation(.korean, "안녕하세요")]).validated(for: request)
        #expect(result.translations[0].phrases.count == 1)
    }

    @Test func rejectsLostLineBreaks() {
        #expect(throws: AppFailure.invalidResult) {
            try TranslationResult(translations: [translation(.japanese, "こんにちは"), translation(.korean, "안녕하세요")])
                .validated(for: TranslationRequest(source: "Hello\nHello"))
        }
    }

    @Test func detectionDefaultsToDocument() {
        let store = RulesConfiguration.seed
        #expect(store.rule(bundleID: "com.microsoft.Word", title: nil).mode == .document)
        #expect(store.rule(bundleID: "com.google.Chrome", title: "Example - Google Docs - Profile").titlePattern != nil)
        #expect(store.rule(bundleID: "unknown", title: "Chat").mode == .document)
    }

    @Test func mapsCancellationWithoutLeakingErrors() {
        #expect(FoundationModelsEngine.classify(CancellationError()) is CancellationError)
        #expect(FoundationModelsEngine.classify(NSError(domain: "fixture secret", code: 1)) as? AppFailure == .modelFailed)
    }
}
