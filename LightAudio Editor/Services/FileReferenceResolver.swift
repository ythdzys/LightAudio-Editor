import Foundation

final class FileReferenceResolver {
    func relativePath(for fileURL: URL, projectURL: URL?) -> String? {
        guard let projectURL = projectURL else { return nil }
        let base = projectURL.deletingLastPathComponent().standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(base) else { return nil }
        var relative = String(path.dropFirst(base.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? nil : relative
    }

    func resolvedURL(for asset: MediaAsset, projectURL: URL?) -> URL {
        if let relativePath = asset.relativePath, let projectURL = projectURL {
            let candidate = projectURL.deletingLastPathComponent().appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: asset.originalPath)
    }

    func markMissingAssets(in project: inout Project, projectURL: URL?) -> [MediaAsset] {
        var missing: [MediaAsset] = []
        for index in project.assets.indices {
            let url = resolvedURL(for: project.assets[index], projectURL: projectURL)
            let exists = FileManager.default.fileExists(atPath: url.path)
            project.assets[index].isMissing = !exists
            if !exists {
                project.assets[index].waveformStatus = .missing
                if project.assets[index].kind == .videoAudio {
                    project.assets[index].proxyStatus = .missing
                }
            } else if project.assets[index].waveformStatus == .missing {
                project.assets[index].waveformStatus = .notGenerated
                if project.assets[index].kind == .videoAudio && project.assets[index].proxyStatus == .missing {
                    project.assets[index].proxyStatus = .generating
                }
            }
            if !exists {
                missing.append(project.assets[index])
            }
        }
        return missing
    }
}
