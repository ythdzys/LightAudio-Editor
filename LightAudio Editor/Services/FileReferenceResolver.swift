import Foundation

final class FileReferenceResolver {
    private let sourceTimestampTolerance: TimeInterval = 0.001

    func relativePath(for fileURL: URL, projectURL: URL?) -> String? {
        guard let projectURL = projectURL else { return nil }
        let base = projectURL.deletingLastPathComponent().standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : "\(base)/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    func resolvedURL(for asset: MediaAsset, projectURL: URL?) -> URL {
        if let resolvedPath = asset.resolvedPath {
            let resolvedURL = URL(fileURLWithPath: resolvedPath)
            if FileManager.default.fileExists(atPath: resolvedURL.path) {
                return resolvedURL
            }
        }
        if let relativePath = asset.relativePath, let projectURL = projectURL {
            let candidate = projectURL.deletingLastPathComponent().appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: asset.resolvedPath ?? asset.originalPath)
    }

    func sourceModificationTimestamp(for fileURL: URL) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return modificationDate.timeIntervalSince1970
    }

    func markMissingAssets(in project: inout Project, projectURL: URL?) -> [MediaAsset] {
        var missing: [MediaAsset] = []
        for index in project.assets.indices {
            let url = resolvedURL(for: project.assets[index], projectURL: projectURL)
            let exists = FileManager.default.fileExists(atPath: url.path)
            let attributes = exists ? try? FileManager.default.attributesOfItem(atPath: url.path) : nil
            let currentTimestamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
            let currentSize = (attributes?[.size] as? NSNumber)?.int64Value
            let timestampChanged: Bool
            if let expectedTimestamp = project.assets[index].sourceModificationTimestamp,
               let currentTimestamp {
                timestampChanged = abs(expectedTimestamp - currentTimestamp) > sourceTimestampTolerance
            } else {
                timestampChanged = false
            }
            let sizeChanged: Bool
            if let expectedSize = project.assets[index].metadata.fileSize,
               let currentSize {
                sizeChanged = expectedSize != currentSize
            } else {
                sizeChanged = false
            }
            let sourceChanged = exists && (timestampChanged || sizeChanged)
            let unavailable = !exists || sourceChanged

            if !unavailable {
                // Rebase only after a real source is found. Keeping the old relative reference on
                // failure lets a collected project recover if its Media folder appears later.
                project.assets[index].originalPath = url.path
                project.assets[index].resolvedPath = url.path
                if project.assets[index].sourceModificationTimestamp == nil {
                    // Older projects did not persist a fingerprint. Adopt the current source without blocking them.
                    project.assets[index].sourceModificationTimestamp = currentTimestamp
                }
            }
            project.assets[index].isMissing = unavailable
            if unavailable {
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
            if unavailable {
                missing.append(project.assets[index])
            }
        }
        return missing
    }
}
