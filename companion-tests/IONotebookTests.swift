import XCTest
@testable import RayNeoCompanion

final class IONotebookTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IONotebookTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor func testCreateEditReloadDeleteAndExactUnicodeExport() throws {
        let root = try directory()
        let store = IONotebookStore(directoryURL: root)
        let id = try store.create(title: "直播话术", text: "原稿")
        let text = "中文 👨‍👩‍👧‍👦 e\u{301}\r\n下一句。"
        try store.stageEdit(id, title: "更新标题", text: text)
        XCTAssertTrue(store.hasUnsavedChanges)
        try store.saveAllDrafts()
        let restored = IONotebookStore(directoryURL: root)
        XCTAssertNil(restored.loadIssue)
        XCTAssertEqual(restored.note(id)?.title, "更新标题")
        XCTAssertEqual(try restored.exportTXT(id), Data(text.utf8))
        try restored.delete(id)
        XCTAssertTrue(IONotebookStore(directoryURL: root).notes.isEmpty)
    }

    @MainActor func testWriteFailureKeepsDiskAndRecoverableDraftThenRetries() throws {
        let root = try directory()
        let original = IONotebookStore(directoryURL: root)
        let id = try original.create(title: "已保存", text: "旧内容")
        let before = try Data(contentsOf: original.fileURL)
        var fail = true
        let store = IONotebookStore(directoryURL: root, writer: { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        try store.stageEdit(id, title: "未丢失的草稿", text: "新内容 👓")
        XCTAssertThrowsError(try store.saveDraft(id))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(store.note(id)?.text, "旧内容")
        XCTAssertEqual(store.draft(id)?.text, "新内容 👓")
        XCTAssertEqual(try store.exportTXT(id), Data("新内容 👓".utf8))
        XCTAssertThrowsError(try store.delete(id))
        XCTAssertNotNil(store.note(id))
        XCTAssertNotNil(store.drafts[id])
        fail = false
        try store.saveDraft(id)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(IONotebookStore(directoryURL: root).note(id)?.text, "新内容 👓")
    }

    @MainActor func testCorruptStoreIsNeverOverwritten() throws {
        let root = try directory()
        let original = IONotebookStore(directoryURL: root)
        let broken = Data("{\"version\":1,\"notes\":[broken".utf8)
        try broken.write(to: original.fileURL)
        let store = IONotebookStore(directoryURL: root)
        XCTAssertNotNil(store.loadIssue)
        XCTAssertThrowsError(try store.create(title: "不能覆盖"))
        XCTAssertEqual(try Data(contentsOf: original.fileURL), broken)
    }

    @MainActor func testBadImportsDoNotChangeExistingNoteOrSource() throws {
        let root = try directory()
        let store = IONotebookStore(directoryURL: root)
        let id = try store.create(title: "保留", text: "原内容")
        let before = try Data(contentsOf: store.fileURL)
        for bytes in [Data([0xC3, 0x28]), Data([65, 0, 66]), Data([0xFF, 0xFE, 0x00]),
                      Data([0xFF, 0xFE, 0x00, 0xD8]), Data([0xFE, 0xFF, 0xDC, 0x00]),
                      Data(repeating: 65, count: IONotebookIO.maximumTextBytes + 1)] {
            let source = root.appendingPathComponent(UUID().uuidString + ".txt")
            try bytes.write(to: source)
            XCTAssertThrowsError(try store.importTXT(source))
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
            XCTAssertEqual(store.note(id)?.text, "原内容")
        }
    }

    @MainActor func testTXTImportDecodesBOMAndPreservesSource() throws {
        let root = try directory()
        let store = IONotebookStore(directoryURL: root)
        let text = "中文 👓\r\n逐字保留"
        let variants = [Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8), Data([0xFF, 0xFE]) + (try XCTUnwrap(text.data(using: .utf16LittleEndian)))]
        for bytes in variants {
            let source = root.appendingPathComponent(UUID().uuidString + ".TXT")
            try bytes.write(to: source)
            let id = try store.importTXT(source)
            XCTAssertEqual(store.note(id)?.text, text)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testUnicodeByteLimitNotCharacterCountAndDecodedUTF16Expansion() throws {
        let fitting = String(repeating: "你", count: IONotebookIO.maximumTextBytes / 3)
        XCTAssertNoThrow(try IONotebookIO.validate(title: "", text: fitting))
        XCTAssertThrowsError(try IONotebookIO.validate(title: "", text: fitting + "你"))
        let encoded = Data([0xFF, 0xFE]) + (try XCTUnwrap((fitting + "你").data(using: .utf16LittleEndian)))
        XCTAssertLessThan(encoded.count, IONotebookIO.maximumTextBytes)
        XCTAssertThrowsError(try IONotebookIO.decodeTXT(encoded))
        XCTAssertThrowsError(try IONotebookIO.validate(title: String(repeating: "你", count: 86), text: ""))
    }

    @MainActor func testRejectedOversizedEditPreservesSavedAndStagedContent() throws {
        let store = IONotebookStore(directoryURL: try directory())
        let id = try store.create(text: "已保存")
        try store.stageEdit(id, title: "草稿", text: "还在编辑")
        XCTAssertThrowsError(try store.stageEdit(id, title: "草稿", text: String(repeating: "👓", count: IONotebookIO.maximumTextBytes / 4 + 1)))
        XCTAssertEqual(store.note(id)?.text, "已保存")
        XCTAssertEqual(store.draft(id)?.text, "还在编辑")
    }

    @MainActor func testNoteCapacityRejectsNewRecordWithoutReplacingExistingOnes() throws {
        let root = try directory()
        let store = IONotebookStore(directoryURL: root)
        for index in 0..<IONotebookIO.maximumNotes { try store.create(title: "笔记 \(index)", text: "内容") }
        let before = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.create(title: "超出容量"))
        XCTAssertEqual(store.notes.count, IONotebookIO.maximumNotes)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(IONotebookStore(directoryURL: root).notes.count, IONotebookIO.maximumNotes)
    }
}
