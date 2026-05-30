import Foundation

final class ProjectFileService {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let resolver = FileReferenceResolver()

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func save(_ project: Project, to url: URL) throws {
        var copy = project
        copy.lastSavedAt = Date()
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
    }

    func load(from url: URL) throws -> (Project, [MediaAsset]) {
        let data = try Data(contentsOf: url)
        var project = try decoder.decode(Project.self, from: data)
        let missing = resolver.markMissingAssets(in: &project, projectURL: url)
        return (project, missing)
    }

    func encodeRecovery(_ snapshot: ProjectRecoverySnapshot, to url: URL) throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    func decodeRecovery(from url: URL) throws -> ProjectRecoverySnapshot {
        let data = try Data(contentsOf: url)
        return try decoder.decode(ProjectRecoverySnapshot.self, from: data)
    }
}
