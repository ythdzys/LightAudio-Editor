import Foundation
import os

/// Caps expensive waveform/video jobs across service instances without blocking worker threads
/// while AVFoundation exports. A cancelled active job keeps its slot until teardown completes.
final class MediaPreparationScheduler {
    static let shared = MediaPreparationScheduler(limit: 2)
    static let log = OSLog(subsystem: "com.ythdzys.LightAudioEditor", category: .pointsOfInterest)
    final class Job {
        private let lock = NSLock()
        private var cancelled = false
        fileprivate var onCancel: (() -> Void)?
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            cancelled = true; let action = onCancel; lock.unlock()
            action?()
        }
        // Publication and cancellation are ordered: a cancelled job cannot publish a stale cache.
        func unlessCancelled<T>(_ body: () throws -> T) rethrows -> T? {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return nil }
            return try body()
        }
    }
    private struct Pending {
        let id: UUID
        let job: Job
        let work: (Job, @escaping () -> Void) -> Void
    }
    private let state = DispatchQueue(label: "com.lightaudio.preparation-budget")
    private let limit: Int
    private var pending: [Pending] = []
    private var active: Set<UUID> = []
    private var peak = 0
    var counts: (active: Int, pending: Int, peak: Int) {
        state.sync { (active.count, pending.count, peak) }
    }
    init(limit: Int) { self.limit = max(1, limit) }
    @discardableResult
    func submit(_ work: @escaping (Job, @escaping () -> Void) -> Void) -> Job {
        let id = UUID(), job = Job()
        job.onCancel = { [weak self] in self?.state.async { [weak self] in
            self?.pending.removeAll { $0.id == id }
        } }
        state.async {
            guard !job.isCancelled else { return }
            self.pending.append(Pending(id: id, job: job, work: work)); self.pump()
        }
        return job
    }
    private func pump() {
        while active.count < limit, !pending.isEmpty {
            let next = pending.removeFirst()
            guard !next.job.isCancelled else { continue }
            active.insert(next.id); peak = max(peak, active.count)
            os_signpost(.event, log: Self.log, name: "Preparation budget", "active=%d pending=%d", active.count, pending.count)
            let trace = OSSignpostID(log: Self.log)
            os_signpost(.begin, log: Self.log, name: "Media preparation", signpostID: trace)
            DispatchQueue.global(qos: .utility).async {
                next.work(next.job) { [weak self] in
                    self?.state.async { [weak self] in
                        guard let self, self.active.remove(next.id) != nil else { return }
                        os_signpost(.end, log: Self.log, name: "Media preparation", signpostID: trace)
                        self.pump()
                    }
                }
            }
        }
    }
}
