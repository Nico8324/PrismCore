import Foundation

/// A completed video segment's source-time interval. This describes disk
/// residency, not AVPlayer's buffer or a guarantee of an instantaneous seek.
public struct ResidentRange: Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
}

/// Serializes snapshot LOOKUPS (and the opens) with retirement, so a preview
/// never borrows a file an eviction has already unlinked — the read itself
/// runs outside the lock on descriptors an unlink cannot invalidate.
final class ResidentSegmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int: ResidentRange] = [:]
    private var stopped = false
    /// Indexes whose file is on disk but must NOT be served: they were muxed
    /// with an audio offset that is no longer in force. The in-memory entry
    /// alone cannot carry this, because the serving path
    /// (`PlanSegmentProvider` → `DirectorySegmentProvider`) reads the
    /// FILESYSTEM, and the files outlive their entry by however long the
    /// unlink queue takes to get to them. That window is exactly when a host
    /// that watches `pendingAudioDelaySeconds` refreshes its player, so a
    /// fetch landing in it used to be answered with the old offset's bytes —
    /// and AVPlayer caches that answer for the rest of the session.
    private var supersededIndexes: Set<Int> = []
    /// Retired by eviction and not yet unlinked. Tracked only so that a later
    /// supersede can mark those files unservable too: their entry is already
    /// gone, so `entries.keys` would not name them.
    private var awaitingUnlink: Set<Int> = []

    func record(index: Int, start: Double, end: Double) {
        guard start.isFinite, end.isFinite, end > start else { return }
        lock.withLock {
            guard !stopped else { return }
            entries[index] = ResidentRange(startSeconds: start, endSeconds: end)
        }
    }

    func retire(_ indexes: [Int]) {
        lock.withLock {
            for index in indexes {
                entries.removeValue(forKey: index)
                awaitingUnlink.insert(index)
            }
        }
    }

    /// Retire everything AND mark it unservable in one lock acquisition, for
    /// the audio-delay re-anchor: the caller may declare the new offset in
    /// force the moment this returns, because from here no fetch can be
    /// answered off disk with bytes carrying the old one. The unlink still
    /// runs afterwards, off the producer's thread — the files are unservable
    /// long before they are gone.
    ///
    /// One step under the lock: a two-call read-then-retire could miss a
    /// segment published between them and leave its file behind.
    func supersedeAll() -> [Int] {
        lock.withLock {
            let indexes = Array(entries.keys)
            entries.removeAll()
            supersededIndexes.formUnion(indexes)
            supersededIndexes.formUnion(awaitingUnlink)
            return indexes
        }
    }

    /// Whether this index's files are stale output. Consulted by the serving
    /// path on every fetch, ahead of the disk read.
    func isSuperseded(index: Int) -> Bool {
        lock.withLock { supersededIndexes.contains(index) }
    }

    /// This index has been rewritten in full — variant segment and every
    /// rendition of the same cut — so serving it from disk is safe again.
    /// Deliberately not folded into `publish`: `publish` writes the variant
    /// segment, and the renditions of that index are cut after it, so
    /// clearing there would reopen the window on `audioN/segNNNNN.m4s`.
    func markProduced(index: Int) {
        lock.withLock { _ = supersededIndexes.remove(index) }
    }

    func publish(index: Int, start: Double, end: Double, data: Data, root: URL) throws {
        try lock.withLock {
            try data.write(to: root.appendingPathComponent(String(format: "seg%05d.m4s", index)), options: .atomic)
            awaitingUnlink.remove(index)
            if !stopped, start.isFinite, end.isFinite, end > start {
                entries[index] = ResidentRange(startSeconds: start, endSeconds: end)
            }
        }
    }

    func unlinkRetired(index: Int, directories: [URL]) {
        lock.withLock {
            // A queued unlink may outlive a re-production of this index.
            guard entries[index] == nil else { return }
            let name = String(format: "seg%05d.m4s", index)
            for directory in directories {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            awaitingUnlink.remove(index)
            // Nothing left on disk to serve, so the flag has done its job —
            // the next fetch misses honestly and re-anchors production.
            supersededIndexes.remove(index)
        }
    }

    func clear() {
        lock.withLock {
            stopped = true
            entries.removeAll()
            supersededIndexes.removeAll()
            awaitingUnlink.removeAll()
        }
    }

    var ranges: [ResidentRange] {
        lock.withLock {
            var result: [ResidentRange] = []
            for range in entries.values.sorted(by: { $0.startSeconds < $1.startSeconds }) {
                if let last = result.last, range.startSeconds <= last.endSeconds + 0.000_001 {
                    result[result.count - 1] = ResidentRange(
                        startSeconds: last.startSeconds,
                        endSeconds: max(last.endSeconds, range.endSeconds)
                    )
                } else { result.append(range) }
            }
            return result
        }
    }

    func snapshot(at seconds: Double, root: URL) -> (index: Int, data: Data)? {
        guard seconds.isFinite else { return nil }
        // Only the lookup and the opens happen under the lock: an open
        // descriptor survives a later unlink, so the (up to 64 MiB) read can
        // run outside it without stalling the producer's next `publish`.
        guard let opened: (index: Int, initial: FileHandle, media: FileHandle) = lock.withLock({
            guard !stopped, let entry = entries.first(where: {
                seconds >= $0.value.startSeconds && seconds < $0.value.endSeconds
            }) else { return nil }
            let mediaURL = root.appendingPathComponent(String(format: "seg%05d.m4s", entry.key))
            // A very long GOP can make one fragment enormous. Previewing it
            // must not allocate an unbounded second copy beside playback.
            guard let size = try? mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 64 << 20,
                  let initial = try? FileHandle(forReadingFrom: root.appendingPathComponent("init.mp4")),
                  let media = try? FileHandle(forReadingFrom: mediaURL)
            else { return nil }
            return (entry.key, initial, media)
        }) else { return nil }
        defer { try? opened.initial.close(); try? opened.media.close() }
        guard let initial = try? opened.initial.readToEnd(), let media = try? opened.media.readToEnd() else { return nil }
        return (opened.index, initial + media)
    }
}
