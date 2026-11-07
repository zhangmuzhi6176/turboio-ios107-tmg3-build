import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct IONote: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var text: String
    let createdAt: Date
    var updatedAt: Date
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名笔记" : title }
}

struct IONoteDraft: Equatable {
    var title: String
    var text: String
}

enum IONotebookError: LocalizedError {
    case capacity, textTooLarge, titleTooLarge, invalidText, invalidFile, corruptStore, unavailable, missing, writeFailed
    var errorDescription: String? {
        switch self {
        case .capacity: return "笔记空间已满，请先导出并整理现有笔记。"
        case .textTooLarge: return "单篇正文最多 128 KiB，请分成多篇保存。"
        case .titleTooLarge: return "标题过长，请缩短后重试。"
        case .invalidText: return "无法读取文字。请选择 UTF-8 或带 BOM 的 UTF-16 TXT 文件。"
        case .invalidFile: return "请选择本地 TXT 文件。原有笔记没有修改。"
        case .corruptStore: return "本地笔记文件无法读取，已停止写入以保留原文件。"
        case .unavailable: return "笔记存储暂时不可用，请重新读取后再编辑。"
        case .missing: return "这篇笔记已不存在。"
        case .writeFailed: return "保存失败，当前草稿仍保留在本次打开的 App 中。请保留 App 并重试保存或导出 TXT。"
        }
    }
}

enum IONotebookIO {
    static let maximumNotes = 100
    static let maximumTitleBytes = 256
    static let maximumTextBytes = 128 * 1024
    static let maximumStoreBytes = 8 * 1024 * 1024

    static func validate(title: String, text: String) throws {
        guard title.utf8.count <= maximumTitleBytes else { throw IONotebookError.titleTooLarge }
        guard text.utf8.count <= maximumTextBytes else { throw IONotebookError.textTooLarge }
        // Do not reject Unicode format characters: emoji ZWJ sequences are ordinary text.
        guard !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !text.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }) else {
            throw IONotebookError.invalidText
        }
    }

    static func decodeTXT(_ data: Data) throws -> String {
        guard data.count <= maximumTextBytes else { throw IONotebookError.textTooLarge }
        let text: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: Data(data.dropFirst(3)), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE]) {
            try validateUTF16(Data(data.dropFirst(2)), littleEndian: true)
            text = String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            try validateUTF16(Data(data.dropFirst(2)), littleEndian: false)
            text = String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text else { throw IONotebookError.invalidText }
        try validate(title: "", text: text)
        return text
    }

    private static func validateUTF16(_ data: Data, littleEndian: Bool) throws {
        guard data.count.isMultiple(of: 2) else { throw IONotebookError.invalidText }
        let bytes = [UInt8](data)
        var expectsLowSurrogate = false
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let value = littleEndian ? UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8 : UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            if expectsLowSurrogate {
                guard (0xDC00...0xDFFF).contains(value) else { throw IONotebookError.invalidText }
                expectsLowSurrogate = false
            } else if (0xD800...0xDBFF).contains(value) {
                expectsLowSurrogate = true
            } else if (0xDC00...0xDFFF).contains(value) {
                throw IONotebookError.invalidText
            }
        }
        guard !expectsLowSurrogate else { throw IONotebookError.invalidText }
    }

    // A resource's reported size is advisory: bound the actual read as well.
    static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL else { throw IONotebookError.invalidFile }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true else { throw IONotebookError.invalidFile }
        guard (info.fileSize ?? 0) <= limit else { throw IONotebookError.capacity }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var result = Data()
        while true {
            let chunk = try file.read(upToCount: min(65_536, limit + 1 - result.count)) ?? Data()
            if chunk.isEmpty { return result }
            result.append(chunk)
            guard result.count <= limit else { throw IONotebookError.capacity }
        }
    }

    static func exportName(_ title: String) -> String {
        var name = ""
        for character in title {
            let piece = String(character)
            if piece.rangeOfCharacter(from: .controlCharacters) != nil || piece.contains(where: { "/\\:*?\"<>|".contains($0) }) { continue }
            if name.utf8.count + piece.utf8.count > 120 { break }
            name += piece
        }
        let clean = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return clean.isEmpty ? "笔记" : clean
    }
}

@MainActor
final class IONotebookStore: ObservableObject {
    @Published private(set) var notes: [IONote] = []
    @Published private(set) var drafts: [UUID: IONoteDraft] = [:]
    @Published private(set) var loadIssue: String?
    @Published private(set) var lastError: String?
    let fileURL: URL
    private let write: (Data, URL) throws -> Void
    private struct Envelope: Codable { let version: Int; let notes: [IONote] }

    init(directoryURL: URL? = nil, writer: ((Data, URL) throws -> Void)? = nil) {
        let base = directoryURL ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("IONotebookV1", isDirectory: true)
        fileURL = base.appendingPathComponent("notes.json")
        write = writer ?? { data, url in
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        }
        readStore()
    }

    var hasUnsavedChanges: Bool { !drafts.isEmpty }
    func note(_ id: UUID) -> IONote? { notes.first { $0.id == id } }
    func draft(_ id: UUID) -> IONoteDraft? {
        drafts[id] ?? note(id).map { IONoteDraft(title: $0.title, text: $0.text) }
    }
    func retryLoad() { if loadIssue != nil && drafts.isEmpty { readStore() } }

    private func readStore() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let bytes = try IONotebookIO.read(fileURL, limit: IONotebookIO.maximumStoreBytes)
                let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
                guard envelope.version == 1, envelope.notes.count <= IONotebookIO.maximumNotes,
                      Set(envelope.notes.map(\.id)).count == envelope.notes.count else { throw IONotebookError.corruptStore }
                for note in envelope.notes { try IONotebookIO.validate(title: note.title, text: note.text) }
                notes = sorted(envelope.notes)
            }
            loadIssue = nil
        } catch {
            loadIssue = IONotebookError.corruptStore.localizedDescription
        }
    }

    private func sorted(_ values: [IONote]) -> [IONote] {
        values.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    private func commit(_ values: [IONote]) throws {
        guard loadIssue == nil else { throw IONotebookError.unavailable }
        guard values.count <= IONotebookIO.maximumNotes else { throw IONotebookError.capacity }
        for note in values { try IONotebookIO.validate(title: note.title, text: note.text) }
        let bytes = try JSONEncoder().encode(Envelope(version: 1, notes: values))
        guard bytes.count <= IONotebookIO.maximumStoreBytes else { throw IONotebookError.capacity }
        do { try write(bytes, fileURL) }
        catch {
            lastError = IONotebookError.writeFailed.localizedDescription
            throw IONotebookError.writeFailed
        }
        notes = sorted(values)
        lastError = nil
    }

    @discardableResult
    func create(title: String = "", text: String = "") throws -> UUID {
        let now = Date()
        let value = IONote(id: UUID(), title: title, text: text, createdAt: now, updatedAt: now)
        try commit(notes + [value])
        return value.id
    }

    func stageEdit(_ id: UUID, title: String, text: String) throws {
        guard loadIssue == nil else { throw IONotebookError.unavailable }
        guard let saved = note(id) else { throw IONotebookError.missing }
        try IONotebookIO.validate(title: title, text: text)
        let value = IONoteDraft(title: title, text: text)
        if saved.title == title && saved.text == text { drafts.removeValue(forKey: id) }
        else { drafts[id] = value }
    }

    func saveDraft(_ id: UUID) throws {
        guard let draft = drafts[id] else { return }
        guard let index = notes.firstIndex(where: { $0.id == id }) else { throw IONotebookError.missing }
        var values = notes
        values[index].title = draft.title; values[index].text = draft.text; values[index].updatedAt = Date()
        try commit(values)
        drafts.removeValue(forKey: id)
    }

    func saveAllDrafts() throws {
        guard !drafts.isEmpty else { return }
        let values = notes.map { note -> IONote in
            guard let draft = drafts[note.id] else { return note }
            var updated = note
            updated.title = draft.title; updated.text = draft.text; updated.updatedAt = Date()
            return updated
        }
        try commit(values)
        drafts.removeAll()
    }

    func delete(_ id: UUID) throws {
        guard note(id) != nil else { throw IONotebookError.missing }
        try commit(notes.filter { $0.id != id })
        drafts.removeValue(forKey: id)
    }

    @discardableResult
    func importTXT(_ url: URL) throws -> UUID {
        guard url.isFileURL, url.pathExtension.lowercased() == "txt" else { throw IONotebookError.invalidFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = try IONotebookIO.decodeTXT(IONotebookIO.read(url, limit: IONotebookIO.maximumTextBytes))
        let title = IONotebookIO.exportName(url.deletingPathExtension().lastPathComponent)
        return try create(title: title, text: text)
    }

    // Export the current draft even after a disk-write failure, without exposing any other store.
    func exportTXT(_ id: UUID) throws -> Data {
        guard let value = draft(id) else { throw IONotebookError.missing }
        try IONotebookIO.validate(title: value.title, text: value.text)
        return Data(value.text.utf8)
    }
}

struct IONoteTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw IONotebookError.invalidFile }
        data = Data(try IONotebookIO.decodeTXT(bytes).utf8)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
struct IONotebooksView: View {
    @EnvironmentObject private var notebook: IONotebookStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    @State private var query = ""
    @State private var importing = false
    @State private var deleting: UUID?
    @State private var error: String?
    private var filtered: [IONote] {
        notebook.notes.filter { note in
            let draft = notebook.draft(note.id)
            return query.isEmpty || (draft?.title ?? note.title).localizedStandardContains(query) || (draft?.text ?? note.text).localizedStandardContains(query)
        }
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let issue = notebook.loadIssue {
                    Section { Text(issue).foregroundStyle(.red); Button("重新读取") { notebook.retryLoad() } }
                }
                if let issue = notebook.lastError { Section { Text(issue).foregroundStyle(.red) } }
                if notebook.notes.isEmpty && notebook.loadIssue == nil {
                    Section { Text("把灵感和话术保存在这里，也可导入 TXT。需要提词时，再选择一篇转为提词稿。").foregroundStyle(.secondary) }
                }
                Section {
                    ForEach(filtered) { note in
                        NavigationLink(value: note.id) {
                            VStack(alignment: .leading, spacing: 6) {
                                let draft = notebook.draft(note.id)
                                Text((draft?.title.isEmpty == false ? draft?.title : nil) ?? note.displayTitle).font(.headline)
                                Text(draft?.text ?? note.text).lineLimit(2).foregroundStyle(.secondary)
                                HStack {
                                    Text(note.updatedAt, style: .date)
                                    if notebook.drafts[note.id] != nil { Text("有未保存修改").foregroundStyle(.orange) }
                                }.font(.caption)
                            }
                        }.swipeActions { Button("删除", role: .destructive) { deleting = note.id } }
                    }
                } footer: { Text("\(notebook.notes.count) / 100 篇 · 保存在本机") }
            }
            .navigationTitle("笔记")
            .searchable(text: $query, prompt: "搜索标题或正文")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { importing = true } label: { Label("导入 TXT", systemImage: "square.and.arrow.down") }
                        .disabled(notebook.loadIssue != nil)
                    Button {
                        do { path.append(try notebook.create()) } catch { self.error = error.localizedDescription }
                    } label: { Label("新建笔记", systemImage: "square.and.pencil") }
                        .disabled(notebook.loadIssue != nil)
                }
            }
            .navigationDestination(for: UUID.self) { IONoteEditorView(id: $0) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
                do { path.append(try notebook.importTXT(result.get())) }
                catch { if (error as NSError).code != NSUserCancelledError { self.error = error.localizedDescription } }
            }
            .confirmationDialog("删除这篇笔记及其草稿？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除笔记", role: .destructive) {
                    guard let id = deleting else { return }
                    do { try notebook.delete(id) } catch { self.error = error.localizedDescription }
                    deleting = nil
                }
            }
            .alert("未能完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                do { try notebook.saveAllDrafts() } catch { self.error = error.localizedDescription }
            }
        }
    }
}

@MainActor
private struct IONoteEditorView: View {
    let id: UUID
    @EnvironmentObject private var notebook: IONotebookStore
    @EnvironmentObject private var companion: CompanionStore
    @State private var autosave: Task<Void, Never>?
    @State private var error: String?
    @State private var document = IONoteTextDocument(data: Data())
    @State private var exporting = false
    @State private var confirmPrompter = false
    @State private var showPrompter = false
    private var value: IONoteDraft { notebook.draft(id) ?? IONoteDraft(title: "", text: "") }
    var body: some View {
        Form {
            Section {
                TextField("标题", text: Binding(get: { value.title }, set: { edit(title: $0, text: value.text) }))
                TextEditor(text: Binding(get: { value.text }, set: { edit(title: value.title, text: $0) }))
                    .frame(minHeight: 300)
            } footer: {
                Text("\(value.text.count) 字 · \(value.text.utf8.count) / 131072 字节 · \(notebook.drafts[id] == nil ? "已保存到本机" : (error == nil ? "正在保存草稿" : "有未保存修改"))")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("保存草稿") { save() }
                Button("导出这篇 TXT") {
                    do { document = IONoteTextDocument(data: try notebook.exportTXT(id)); exporting = true }
                    catch { self.error = error.localizedDescription }
                }
                Button("转为提词稿") { confirmPrompter = true }.disabled(value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: { Text("转为提词稿后进入提词器编辑页，由你决定何时发送到眼镜。") }
        }
        .navigationTitle("编辑笔记").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .preference(key: CompanionTabBarHiddenPreference.self, value: true)
        .fileExporter(isPresented: $exporting, document: document, contentType: .plainText, defaultFilename: IONotebookIO.exportName(value.title)) { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .confirmationDialog("用这篇正文替换当前本机提词稿？原笔记会保留。", isPresented: $confirmPrompter, titleVisibility: .visible) {
            Button("替换并打开提词器") {
                guard save() else { return }
                companion.savePrompter(value.text)
                showPrompter = true
            }
        }
        .navigationDestination(isPresented: $showPrompter) { PrompterView() }
        .onDisappear { autosave?.cancel(); save() }
    }

    private func edit(title: String, text: String) {
        do {
            try notebook.stageEdit(id, title: title, text: text)
            error = nil
            autosave?.cancel()
            autosave = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                save()
            }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    private func save() -> Bool {
        autosave?.cancel()
        do { try notebook.saveDraft(id); error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
