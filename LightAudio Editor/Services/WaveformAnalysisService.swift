import Foundation
import AVFoundation

final class WaveformAnalysisService {
    private let cacheService = WaveformCacheService()
    private let memoryCache = NSCache<NSString, WaveformBox>()
    private let targetPeaksPerSecond = 180.0
    private let minimumPeakCount = 12000
    private let maximumPeakCount = 360000
    private let chunkFrameCount: AVAudioFrameCount = 16384

    func loadOrGenerateWaveform(for asset: MediaAsset, completion: @escaping (Result<WaveformData, Error>) -> Void) {
        guard !asset.isMissing, let url = asset.audioSourceURL else {
            completion(.failure(waveformError("Missing media.")))
            return
        }
        let cacheKey = cacheService.cacheKey(for: asset, fileURL: url)
        if let cached = memoryCache.object(forKey: cacheKey as NSString)?.data {
            completion(.success(cached))
            return
        }
        if let cached = cacheService.load(cacheKey: cacheKey) {
            memoryCache.setObject(WaveformBox(cached), forKey: cacheKey as NSString)
            completion(.success(cached))
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let waveform = try self.generateWaveform(asset: asset, url: url, cacheKey: cacheKey)
                try self.cacheService.save(waveform)
                self.memoryCache.setObject(WaveformBox(waveform), forKey: cacheKey as NSString)
                DispatchQueue.main.async { completion(.success(waveform)) }
            } catch {
                let detail = "Could not generate a waveform for \(asset.metadata.fileName): \(error.localizedDescription)"
                let contextualError = NSError(
                    domain: "LightAudioWaveform",
                    code: (error as NSError).code,
                    userInfo: [
                        NSLocalizedDescriptionKey: detail,
                        NSUnderlyingErrorKey: error
                    ]
                )
                DispatchQueue.main.async { completion(.failure(contextualError)) }
            }
        }
    }

    func cacheKey(for asset: MediaAsset) -> String? {
        guard let url = asset.audioSourceURL, !asset.isMissing else { return nil }
        return cacheService.cacheKey(for: asset, fileURL: url)
    }

    func invalidateCache(for asset: MediaAsset) {
        guard let url = asset.audioSourceURL, !asset.isMissing else { return }
        let key = cacheService.cacheKey(for: asset, fileURL: url)
        memoryCache.removeObject(forKey: key as NSString)
        try? cacheService.delete(cacheKey: key)
    }

    private func generateWaveform(asset: MediaAsset, url: URL, cacheKey: String) throws -> WaveformData {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = max(1, Int(file.length))
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : asset.metadata.sampleRate
        let duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : asset.metadata.duration
        let targetPeakCount = peakCount(forDuration: duration, totalFrames: totalFrames)
        let framesPerPeak = max(1, Int(ceil(Double(totalFrames) / Double(targetPeakCount))))
        var peaks: [WaveformPeak] = []
        peaks.reserveCapacity(min(targetPeakCount + 1, totalFrames))
        var currentMin = Float.greatestFiniteMagnitude
        var currentMax = -Float.greatestFiniteMagnitude
        var framesInPeak = 0

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCount) else {
            throw waveformError("Could not allocate waveform buffer.")
        }
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else {
            throw waveformError("This audio file has no readable channels.")
        }

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrameCount)
            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw waveformError("Unsupported audio sample format.")
            }
            for frame in 0..<framesRead {
                var frameMin = Float.greatestFiniteMagnitude
                var frameMax = -Float.greatestFiniteMagnitude
                for channel in 0..<channelCount {
                    let sample = sanitize(channels[channel][frame])
                    frameMin = min(frameMin, sample)
                    frameMax = max(frameMax, sample)
                }
                currentMin = min(currentMin, frameMin)
                currentMax = max(currentMax, frameMax)
                framesInPeak += 1
                if framesInPeak >= framesPerPeak {
                    peaks.append(normalizedPeak(min: currentMin, max: currentMax))
                    currentMin = Float.greatestFiniteMagnitude
                    currentMax = -Float.greatestFiniteMagnitude
                    framesInPeak = 0
                }
            }
        }

        if framesInPeak > 0 || peaks.isEmpty {
            peaks.append(normalizedPeak(min: currentMin, max: currentMax))
        }

        return WaveformData(
            cacheKey: cacheKey,
            duration: duration,
            sampleRate: sampleRate,
            channelCount: channelCount,
            peaks: peaks,
            createdAt: Date()
        )
    }

    private func peakCount(forDuration duration: TimeInterval, totalFrames: Int) -> Int {
        guard duration.isFinite, duration > 0 else {
            return min(totalFrames, min(maximumPeakCount, minimumPeakCount))
        }
        let durationBasedCount = Int(ceil(duration * targetPeaksPerSecond))
        return min(totalFrames, min(maximumPeakCount, max(minimumPeakCount, durationBasedCount)))
    }

    private func sanitize(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        return max(-1, min(1, sample))
    }

    private func normalizedPeak(min minPeak: Float, max maxPeak: Float) -> WaveformPeak {
        guard minPeak.isFinite, maxPeak.isFinite else {
            return WaveformPeak(min: 0, max: 0)
        }
        return WaveformPeak(min: max(-1, minPeak), max: min(1, maxPeak))
    }

    private func waveformError(_ message: String) -> NSError {
        NSError(domain: "LightAudioWaveform", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class WaveformBox {
    let data: WaveformData

    init(_ data: WaveformData) {
        self.data = data
    }
}
