import Foundation

struct ProjectDocument: Codable, Sendable {
    let version: Int
    var name: String
    var melody: MelodyProject

    init(name: String, melody: MelodyProject) {
        self.version = 3
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.melody = melody
    }

    static func decode(_ data: Data) throws -> ProjectDocument {
        guard !data.isEmpty, data.count <= ProjectLibrary.maximumFileSize else {
            throw ProjectLibraryError.fileTooLarge
        }
        let document: ProjectDocument
        do {
            document = try JSONDecoder().decode(ProjectDocument.self, from: data)
        } catch {
            throw ProjectLibraryError.invalidDocument
        }
        try document.validate()
        return document
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= ProjectLibrary.maximumFileSize else {
            throw ProjectLibraryError.fileTooLarge
        }
        return data
    }

    func validate() throws {
        guard version == 3, Self.validName(name), melody.isValid else {
            throw ProjectLibraryError.invalidDocument
        }
    }

    private static func validName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == trimmed && !name.isEmpty && name.count <= 64 &&
            !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private enum CodingKeys: String, CodingKey { case version, name, melody }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try container.decode(Int.self, forKey: .version)
        guard (1...3).contains(sourceVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported project version")
        }
        self.version = 3
        self.name = try container.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        self.melody = try container.decode(MelodyProject.self, forKey: .melody)
    }
}

struct LocalProject: Codable, Identifiable, Sendable {
    let id: UUID
    var updatedAt: Date
    var document: ProjectDocument
    var externalBookmark: Data?

    init(document: ProjectDocument, externalBookmark: Data? = nil, id: UUID = UUID()) {
        self.id = id
        self.updatedAt = Date()
        self.document = document
        self.externalBookmark = externalBookmark
    }
}

enum ProjectLibrary {
    static let maximumFileSize = 16 * 1_048_576
    private static let legacyRecordID = UUID(uuidString: "70FBBFB0-A2D8-4A04-8E83-F162B40026A2")!

    private static var directory: URL {
        StudioStorage.root.appendingPathComponent("Projects", isDirectory: true)
    }

    static func recent() throws -> [LocalProject] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= maximumFileSize,
                  let data = try? Data(contentsOf: url),
                  let local = try? JSONDecoder().decode(LocalProject.self, from: data),
                  url.deletingPathExtension().lastPathComponent.uppercased() == local.id.uuidString,
                  (try? local.document.validate()) != nil else {
                return nil
            }
            return local
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ local: LocalProject) throws {
        try local.document.validate()
        guard (local.externalBookmark?.count ?? 0) <= maximumFileSize else {
            throw ProjectLibraryError.invalidDocument
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(local)
        guard data.count <= maximumFileSize else { throw ProjectLibraryError.fileTooLarge }
        try data.write(to: recordURL(for: local.id), options: .atomic)
    }

    static func migrateLegacy() throws {
        guard !FileManager.default.fileExists(atPath: recordURL(for: legacyRecordID).path) else { return }
        let legacy = StudioStorage.root.appendingPathComponent("Project.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let values = try legacy.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= maximumFileSize else {
            throw ProjectLibraryError.fileTooLarge
        }
        let data = try Data(contentsOf: legacy)
        let melody: MelodyProject
        do {
            melody = try JSONDecoder().decode(MelodyProject.self, from: data)
        } catch {
            return
        }
        guard melody.isValid else { return }
        try save(LocalProject(document: ProjectDocument(name: "上次编辑的旋律", melody: melody), id: legacyRecordID))
    }

    static func open(_ url: URL) throws -> LocalProject {
        let data = try coordinatedRead(url)
        return LocalProject(document: try ProjectDocument.decode(data),
                            externalBookmark: bookmark(for: url))
    }

    static func bookmark(for url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func url(for bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale else {
            return nil
        }
        return url
    }

    static func write(_ document: ProjectDocument, to url: URL) throws {
        let data = try document.encoded()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var writeError: Error?
        var didWrite = false
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do {
                try data.write(to: destination, options: .atomic)
                didWrite = true
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        guard didWrite else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func recordURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    static func coordinatedRead(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var readError: Error?
        var result: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            do {
                let values = try source.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size > 0, size <= maximumFileSize else {
                    throw ProjectLibraryError.fileTooLarge
                }
                result = try Data(contentsOf: source)
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let result else { throw ProjectLibraryError.unreadableFile }
        return result
    }
}

private enum ProjectLibraryError: LocalizedError {
    case invalidDocument
    case fileTooLarge
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "项目文件格式无效，或旋律超出了支持范围。"
        case .fileTooLarge:
            return "项目文件为空或超过16MB限制。"
        case .unreadableFile:
            return "无法读取项目文件。"
        }
    }
}
