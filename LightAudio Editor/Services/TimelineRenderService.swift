import Foundation

final class TimelineRenderService {
    func activeClips(in project: Project) -> [(Track, Clip, MediaAsset)] {
        let soloed = project.timeline.tracks.contains { $0.isSolo }
        var result: [(Track, Clip, MediaAsset)] = []
        for track in project.timeline.tracks {
            if track.isMuted { continue }
            if soloed && !track.isSolo { continue }
            for clip in track.clips {
                if let asset = project.asset(id: clip.sourceAssetID), !asset.isMissing {
                    result.append((track, clip, asset))
                }
            }
        }
        return result
    }
}
