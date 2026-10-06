import AppKit
import Testing
@testable import TranslateBar

@Suite
struct GoogleDocsReliabilityTests {
    @Test func detectsHTMLCellSelectionsIncludingSingleColumnAndUTF16() {
        for html in ["<table><tr><td>First</td><td>Second</td></tr></table>",
                     "<TABLE><TR><TD>First</TD></TR><TR><TD>Second</TD></TR></TABLE>",
                     "<td colspan='2'>Merged</td>"] {
            for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
                #expect(SelectionStructure.requiresCellNavigation(text: "First\nSecond",
                    html: html.data(using: encoding), rtf: nil))
            }
        }
    }

    @Test func detectsRTFAndPlainTextTables() {
        #expect(SelectionStructure.requiresCellNavigation(text: "First\tSecond", html: nil, rtf: nil))
        #expect(SelectionStructure.requiresCellNavigation(text: "First\nSecond", html: nil,
            rtf: Data(#"{\rtf1\trowd\cellx1200 First\cell Second\cell\row}"#.utf8)))
    }

    @Test func ordinaryRichParagraphsAndEscapedCodeAreAllowed() {
        #expect(!SelectionStructure.requiresCellNavigation(text: "First\nSecond", html:
            Data(#"<p><b>First</b></p><p>Second &lt;table&gt;</p><img src="https://example.invalid/image.png">"#.utf8),
            rtf: Data(#"{\rtf1\b First\b0\par Second}"#.utf8)))
    }

    @MainActor @Test func rejectedTableCopyRestoresOriginalClipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original fixture", forType: .string)
        let session = try PasteboardSession(board: board)
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("First\nSecond", forType: .string)
        item.setString("<table><tr><td>First</td></tr><tr><td>Second</td></tr></table>", forType: .html)
        #expect(board.writeObjects([item]))
        #expect(session.recordCopyChange())
        #expect(throws: AppFailure.tableSelection) { try session.acceptCopy() }
        #expect(try session.restore() == .restored)
        #expect(board.string(forType: .string) == "Original fixture")
    }

    @Test func rejectsIntroducedForeignMonthEvenInsideShortCJKLine() {
        for language in TargetLanguage.allCases {
            #expect(TranslationLanguageCheck.isClearlyWrong("2024年8 juilletの発表", expected: language,
                source: "Announcement on 8 July 2024", profile: .init()))
        }
        #expect(TranslationLanguageCheck.isClearlyWrong("2024年8 FÉVRIERの発表", expected: .japanese,
            source: "Announcement on 8 February 2024", profile: .init()))
    }

    @Test func permitsLocalizedDatesSourceNamesAndGlossaryWords() {
        #expect(!TranslationLanguageCheck.isClearlyWrong("2024年7月8日の発表です。", expected: .japanese,
            source: "Announcement on 8 July 2024", profile: .init()))
        #expect(!TranslationLanguageCheck.isClearlyWrong("Juilletの報告書を確認してください。", expected: .japanese,
            source: "Please review Juillet's report.", profile: .init()))
        #expect(!TranslationLanguageCheck.isClearlyWrong("2024年8 juilletの発表です。", expected: .japanese,
            source: "Announcement on 8 July 2024", profile: .init(glossary: [.init(source: "July", replacement: "juillet")])))
    }

    @Test func rejectsForeignPhraseHiddenByJapaneseButPreservesQuotedSource() {
        let phrase = "Veuillez confirmer votre présence à la réunion"
        #expect(TranslationLanguageCheck.isClearlyWrong("明日の会議です。\(phrase)。", expected: .japanese,
            source: "Please confirm your attendance at the meeting.", profile: .init()))
        #expect(!TranslationLanguageCheck.isClearlyWrong("引用です：\(phrase)。", expected: .japanese,
            source: "Quote: \(phrase)", profile: .init()))
    }

    @Test func foreignMonthFailsCompletedResultValidation() {
        let request = TranslationRequest(source: "Announcement on 8 July 2024", languages: [.japanese])
        let result = TranslationResult(translations: [
            .init(language: .japanese, text: "2024年8 juilletの発表です。", notes: [], phrases: [])
        ])
        #expect(throws: AppFailure.wrongLanguage) { try result.validated(for: request) }
    }
}
