import AppKit
import Testing
@testable import TranslateBar

@Suite
struct ReviewDocumentTests {
    @Test func editsRepeatedPhrasesIndependentlyAndMovesUTF16Ranges() throws {
        let original = LanguageTranslation(language: .japanese, text: "🌱語と語、終わり。", notes: [], phrases: [
            .init(source: "first", used: "語", alternatives: ["🌏新しい表現", "短"]),
            .init(source: "second", used: "語", alternatives: ["別の語", "言葉"]),
            .init(source: "end", used: "終わり", alternatives: ["結び", "完了"])
        ])
        var review = ReviewedTranslation(original)
        let first = try #require(review.highlights.first)
        let second = review.highlights[1]
        let last = review.highlights[2]
        let firstChanged = review.choose("🌏新しい表現", for: first.id)
        #expect(firstChanged)
        let secondChanged = review.choose("別の語", for: second.id)
        #expect(secondChanged)
        let lastChanged = review.choose("結び", for: last.id)
        #expect(lastChanged)
        #expect(review.text == "🌱🌏新しい表現と別の語、結び。")
        let reverted = review.choose("語", for: first.id) // Keep the second occurrence.
        #expect(reverted)
        #expect(review.text == "🌱語と別の語、結び。")
        #expect((review.text as NSString).substring(with: review.highlights[1].range) == "別の語")
        #expect(original.text == "🌱語と語、終わり。")
    }

    @Test func skipsMissingOverlappingAndMultilineFlags() {
        let value = LanguageTranslation(language: .japanese, text: "最初です。\n次です。", notes: [], phrases: [
            .init(source: "missing", used: "不在", alternatives: ["A", "B"]),
            .init(source: "all", used: "最初です。\n次です。", alternatives: ["A", "B"]),
            .init(source: "first", used: "最初です。", alternatives: ["A", "B"]),
            .init(source: "overlap", used: "最初", alternatives: ["A", "B"])
        ])
        let review = ReviewedTranslation(value)
        #expect(review.highlights.count == 1)
        #expect(review.highlights[0].source == "first")
    }

    @Test func rejectsArbitraryEmptyOrLineBreakingChoices() throws {
        var review = ReviewedTranslation(.init(language: .japanese, text: "言葉", notes: [], phrases: [
            .init(source: "word", used: "言葉", alternatives: ["", " ", "改\n行", "\0", "語", "語"])
        ]))
        let phrase = try #require(review.highlights.first)
        #expect(phrase.choices == ["言葉", "語"])
        let unlisted = review.choose("unlisted", for: phrase.id)
        #expect(!unlisted)
        let unknown = review.choose("語", for: UUID())
        #expect(!unknown)
        #expect(review.text == "言葉")
    }

    @Test func bothInsertModesUseEditedTextInOriginalLanguageOrder() throws {
        var document = ReviewDocument(.init(translations: [
            .init(language: .korean, text: "첫째입니다.\n둘째입니다.", notes: ["Note"], phrases: []),
            .init(language: .japanese, text: "一つ目です。\n二つ目です。", notes: [], phrases: [
                .init(source: "first", used: "一つ目", alternatives: ["最初", "第一"])
            ])
        ], usedContextFallback: true, modelCalls: 3))
        document.select(1)
        let changed = document.choose("最初", for: try #require(document.current.highlights.first).id)
        #expect(changed)
        let all = document.result(for: .all)
        #expect(all.translations.map(\.language) == [.korean, .japanese])
        #expect(all.pastePayload == "\n첫째입니다.\n둘째입니다.\n最初です。\n二つ目です。")
        let single = document.result(for: .current)
        #expect(single.translations.map(\.language) == [.japanese])
        #expect(single.pastePayload == "\n最初です。\n二つ目です。")
        #expect(single.usedContextFallback && single.modelCalls == 3)
        document.moveLanguage(by: 1)
        #expect(document.current.language == .korean)
        document.moveLanguage(by: -1)
        #expect(document.current.language == .japanese)
        document.select(50)
        #expect(document.current.language == .japanese)
    }
}

@Suite
struct ReviewKeyboardTests {
    @Test func insertOccursOnceOnReleaseAndDoesNotRepeatIntoTheEditor() {
        var keyboard = ReviewKeyboardState()
        let down = keyboard.handle(type: .keyDown, key: 0x24, flags: [])
        #expect(down.handled && down.action == nil)
        let repeated = keyboard.handle(type: .keyDown, key: 0x24, flags: [], repeated: true)
        #expect(repeated.handled && repeated.action == nil)
        #expect(keyboard.handle(type: .keyUp, key: 0x24, flags: []).action == .insertAll)
        #expect(keyboard.handle(type: .keyUp, key: 0x24, flags: []).action == nil)
    }

    @Test func optionAtKeyDownSelectsCurrentEvenIfReleasedFirst() {
        var keyboard = ReviewKeyboardState()
        #expect(keyboard.handle(type: .keyDown, key: 0x24, flags: [.option, .capsLock]).handled)
        #expect(keyboard.handle(type: .keyUp, key: 0x24, flags: []).action == .insertCurrent)
    }

    @Test func escapeAndArrowsAreHandledWhileOtherShortcutsRemainNative() {
        var keyboard = ReviewKeyboardState()
        #expect(keyboard.handle(type: .keyDown, key: 0x35, flags: []).handled)
        #expect(keyboard.handle(type: .keyUp, key: 0x35, flags: []).action == .cancel)
        #expect(keyboard.handle(type: .keyDown, key: 0x7B, flags: [.function, .numericPad]).action == .previousLanguage)
        #expect(keyboard.handle(type: .keyDown, key: 0x7C, flags: []).action == .nextLanguage)
        #expect(!keyboard.handle(type: .keyDown, key: 0x08, flags: [.command]).handled)
        #expect(!keyboard.handle(type: .keyDown, key: 0x24, flags: [.command]).handled)
        #expect(!keyboard.handle(type: .keyDown, key: 0x24, flags: [.shift]).handled)
    }

    @Test func placementStaysOnSmallAndNegativeCoordinateScreens() {
        for visible in [NSRect(x: -1440, y: 200, width: 1440, height: 850),
                        NSRect(x: 0, y: -600, width: 480, height: 500)] {
            for point in [NSPoint(x: visible.minX, y: visible.minY),
                          NSPoint(x: visible.maxX, y: visible.maxY)] {
                let frame = ReviewPlacement.frame(near: point, visibleFrame: visible)
                #expect(visible.insetBy(dx: 8, dy: 8).contains(frame))
            }
        }
    }
}
