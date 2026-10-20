import Foundation
import os
import AVFoundation

final class WaveformAnalysisService {
    private let cacheService = WaveformCacheService()
    private let scheduler: MediaPreparationScheduler
    init(scheduler: MediaPreparationScheduler = .shared) {
        self.scheduler = scheduler
        memoryCache.totalCostLimit = 24 * 1024 * 1024
    }
    private let memoryCache = NSCache<NSString, WaveformBox>()
    private let targetPeaksPerSecond = 180.0
    private let minimumPeakCount = 12000
    private let maximumPeakCount = 360000
    private let chunkFrameCount: AVAudioFrameCount = 16384

    /// Cache I/O and PCM analysis both run inside the shared preparation budget.
    /// Completion is always asynchronous on main; cancelled jobs cannot publish cache data.
    @discardableResult
    func loadOrGenerateWaveform(for asset: MediaAsset, completion: @escaping (Result<WaveformData, Error>) -> Void) -> MediaPreparationScheduler.Job {
        scheduler.submit { job, finished in
            defer { finished() }
            guard !job.isCancelled else { return }
            do {
                guard !asset.isMissing, let url = asset.audioSourceURL else {
                    throw self.waveformError(L10n.tr("Missing media."))
                }
                let cacheKey = self.cacheService.cacheKey(for: asset, fileURL: url)
                let waveform: WaveformData
                if let cached = self.memoryCache.object(forKey: cacheKey as NSString)?.data {
                    waveform = cached
                } else if let cached = self.cacheService.load(cacheKey: cacheKey) {
                    waveform = cached
                } else {
                    waveform = try self.generateWaveform(asset: asset, url: url, cacheKey: cacheKey, job: job)
                    do { try job.unlessCancelled { try self.cacheService.save(waveform) } }
                    catch { throw self.contextualError(error, message: L10n.format("Could not save waveform cache: %@", error.localizedDescription)) }
                }
                job.unlessCancelled {
                    self.memoryCache.setObject(WaveformBox(waveform), forKey: cacheKey as NSString,
                                               cost: waveform.peaks.count * MemoryLayout<WaveformPeak>.stride)
                }
                DispatchQueue.main.async { if !job.isCancelled { completion(.success(waveform)) } }
            } catch {
                DispatchQueue.main.async { if !job.isCancelled { completion(.failure(error)) } }
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

    private func generateWaveform(asset: MediaAsset, url: URL, cacheKey: String, job: MediaPreparationScheduler.Job) throws -> WaveformData {
        let trace = OSSignpostID(log: MediaPreparationScheduler.log)
        os_signpost(.begin, log: MediaPreparationScheduler.log, name: "Waveform analysis", signpostID: trace)
        defer { os_signpost(.end, log: MediaPreparationScheduler.log, name: "Waveform analysis", signpostID: trace) }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw contextualError(error, message: L10n.format("Could not open audio for waveform generation: %@", error.localizedDescription)) }
        let format = file.processingFormat
        var totalFrames = max(1, Int(file.length))
        var sampleRate = format.sampleRate > 0 ? format.sampleRate : asset.metadata.sampleRate
        var channelCount = Int(format.channelCount)
        // AVAudioFile on iPadOS 27 rejects the final partial block in some valid
        // FLAC streams. Decode FLAC independently; never silently discard its tail.
        #if os(iOS)
        let flac = file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatFLAC
            ? url.withUnsafeFileSystemRepresentation { la_flac_open($0) } : nil
        defer { if let flac { la_flac_close(flac) } }
        if file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatFLAC {
            guard let flac else { throw waveformError(L10n.tr("Could not open FLAC audio for waveform generation.")) }
            let count = la_flac_frame_count(flac)
            // A zero STREAMINFO count means unknown; use the system's length if available.
            totalFrames = count > 0 ? Int(count) : Int(file.length)
            sampleRate = Double(la_flac_sample_rate(flac))
            channelCount = Int(la_flac_channels(flac))
            guard totalFrames > 0, sampleRate > 0 else {
                throw waveformError(L10n.tr("Could not determine the FLAC audio length."))
            }
        }
        #endif
        let duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : asset.metadata.duration
        let targetPeakCount = peakCount(forDuration: duration, totalFrames: totalFrames)
        let framesPerPeak = max(1, Int(ceil(Double(totalFrames) / Double(targetPeakCount))))
        var peaks: [WaveformPeak] = []
        peaks.reserveCapacity(min(targetPeakCount + 1, totalFrames))
        var currentMin = Float.greatestFiniteMagnitude
        var currentMax = -Float.greatestFiniteMagnitude
        var framesInPeak = 0

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCount) else {
            throw waveformError(L10n.tr("Could not allocate waveform buffer."))
        }
        guard channelCount > 0 else {
            throw waveformError(L10n.tr("This audio file has no readable channels."))
        }

        var position = 0
        var samples = [Float](repeating: 0, count: Int(chunkFrameCount) * channelCount)
        while position < totalFrames {
            if job.isCancelled { throw CancellationError() }
            let requested = min(Int(chunkFrameCount), totalFrames - position)
            let framesRead: Int
            #if os(iOS)
            if let flac {
                framesRead = samples.withUnsafeMutableBufferPointer {
                    Int(la_flac_read(flac, UInt64(requested), $0.baseAddress))
                }
            } else {
                framesRead = try readNative(file, buffer: buffer, requested: requested, samples: &samples)
            }
            #else
            framesRead = try readNative(file, buffer: buffer, requested: requested, samples: &samples)
            #endif
            guard framesRead > 0 else {
                throw waveformError(L10n.tr("Audio ended before waveform generation was complete."))
            }
            position += framesRead
            for frame in 0..<framesRead {
                var frameMin = Float.greatestFiniteMagnitude
                var frameMax = -Float.greatestFiniteMagnitude
                for channel in 0..<channelCount {
                    let sample = sanitize(samples[frame * channelCount + channel])
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

    private func readNative(_ file: AVAudioFile, buffer: AVAudioPCMBuffer, requested: Int, samples: inout [Float]) throws -> Int {
        let position = file.framePosition
        do { try file.read(into: buffer, frameCount: AVAudioFrameCount(requested)) }
        catch {
            throw contextualError(error, message: L10n.format("Could not read audio for waveform generation at frame %lld of %lld: %@", position, file.length, error.localizedDescription))
        }
        guard let channels = buffer.floatChannelData else {
            throw waveformError(L10n.tr("Unsupported audio sample format."))
        }
        let channelCount = Int(buffer.format.channelCount)
        let framesRead = Int(buffer.frameLength)
        for frame in 0..<framesRead {
            for channel in 0..<channelCount { samples[frame * channelCount + channel] = channels[channel][frame] }
        }
        return framesRead
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
    private func contextualError(_ error: Error, message: String) -> NSError {
        NSError(domain: "LightAudioWaveform", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message, NSUnderlyingErrorKey: error])
    }
}

private final class WaveformBox {
    let data: WaveformData

    init(_ data: WaveformData) {
        self.data = data
    }
}
