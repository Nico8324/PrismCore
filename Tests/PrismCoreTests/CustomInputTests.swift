import Testing
import Foundation
import Libavformat
import Libavutil
@testable import PrismCore

/// A host-supplied input over bytes already in memory — the smallest honest
/// stand-in for an SMB client or a debrid session: a cursor, a length, and
/// failures the test can schedule.
///
/// A class rather than a struct because `PrismCoreInput`'s methods are
/// non-mutating (the engine holds one behind `any`), and `@unchecked Sendable`
/// with a lock because the engine reads it from the probe and producer
/// threads, never from the one that built it.
private final class MemoryInput: PrismCoreInput, @unchecked Sendable {
    private let bytes: [UInt8]
    private let lock = NSLock()
    private var position = 0
    private let reportsLength: Bool
    /// Throw from `read` once this many bytes have been handed out — the
    /// transport dying mid-playback.
    private let failAfterBytes: Int?
    private var delivered = 0
    private var storedReads = 0
    private var storedSeeks = 0
    private var storedSawEOF = false

    struct Broken: Error {}

    init(data: Data, reportsLength: Bool = true, failAfterBytes: Int? = nil) {
        self.bytes = [UInt8](data)
        self.reportsLength = reportsLength
        self.failAfterBytes = failAfterBytes
    }

    var length: Int64? { reportsLength ? Int64(bytes.count) : nil }
    var reads: Int { lock.withLock { storedReads } }
    var seeks: Int { lock.withLock { storedSeeks } }
    /// Whether a read ever answered 0 — the protocol's EOF.
    var sawEOF: Bool { lock.withLock { storedSawEOF } }

    func seek(to offset: Int64) throws {
        lock.withLock {
            storedSeeks += 1
            position = Int(max(0, min(offset, Int64(bytes.count))))
        }
    }

    /// Answers at most this much per call. Real transports do (a Range
    /// response, an SMB read), and a stand-in that hands over the whole file
    /// in one call never exercises EOF, a mid-file failure or a seek at all:
    /// libavformat's format probe asks for up to a megabyte in ONE read, and
    /// this fixture is 1.27 MB.
    private static let chunk = 16 * 1024

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try lock.withLock {
            storedReads += 1
            if let failAfterBytes, delivered >= failAfterBytes { throw Broken() }
            var count = min(min(buffer.count, Self.chunk), bytes.count - position)
            // Hand over exactly the scheduled budget, then fail on the NEXT
            // call — a transport that dies mid-file, not one that refuses to
            // start (which libavformat would simply report as an unopenable
            // source).
            if let failAfterBytes { count = min(count, failAfterBytes - delivered) }
            guard count > 0 else { storedSawEOF = true; return 0 }
            bytes.withUnsafeBytes { source in
                buffer.baseAddress!.copyMemory(
                    from: source.baseAddress!.advanced(by: position), byteCount: count
                )
            }
            position += count
            delivered += count
            return count
        }
    }
}

private func fixtureData(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

/// A URL that names nothing on disk. Every test here uses one, which is what
/// proves the bytes came from the host: native I/O would fail outright.
private func absentURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/prismcore-tests-no-such-directory/\(name)")
}

@Suite("Custom input")
struct CustomInputTests {

    @Test func hostSuppliedBytesProbeAndProduceASegment() async throws {
        let data = try fixtureData("h264_aac_30s", "mkv")
        let input = MemoryInput(data: data)
        let session = try PrismCoreSession(
            url: absentURL("fixture.mkv"),
            input: { input }
        )
        do {
            let playlist = try await session.start()
            #expect(playlist.isFileURL == false)
            // Produced from bytes the engine could not have opened itself.
            #expect(!session.residentRanges.isEmpty)
            // The producer ran the whole 1.27 MB container through the host
            // in 16 KiB answers — many reads and, for the tail, real seeks.
            #expect(input.reads > 10)
            #expect(input.seeks > 0)
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }

    @Test func probeReadsTheWholeContainerThroughTheHost() throws {
        let data = try fixtureData("h264_aac_30s", "mkv")
        let input = MemoryInput(data: data)
        let info = try SourceProbe.probe(url: absentURL("fixture.mkv"), input: { input })
        #expect(info.video?.codecName == "h264")
        #expect(!info.audioTracks.isEmpty)
        // The full duration proves the demuxer got all the way through the
        // container on host-supplied bytes alone.
        #expect((info.duration ?? 0) > 25)
    }

    /// Each open takes its OWN instance: two contexts reading one cursor is
    /// the concurrency bug the factory exists to make unexpressible.
    @Test func eachOpenTakesItsOwnInputInstance() throws {
        let data = try fixtureData("h264_aac", "mkv")
        let made = Locked(0)
        let factory: PrismCoreInputFactory = {
            made.withLock { $0 += 1 }
            return MemoryInput(data: data)
        }
        _ = try SourceProbe.probe(url: absentURL("a.mkv"), input: factory)
        _ = try SourceProbe.probe(url: absentURL("a.mkv"), input: factory)
        #expect(made.withLock { $0 } == 2)
    }

    @Test func endOfStreamAndSizeAreAnsweredThroughTheAVIOContext() throws {
        let data = try fixtureData("h264_aac", "mkv")
        let input = MemoryInput(data: data)
        let readGuard = ReadInterruptGuard()
        let context = try #require(readGuard.makeContext())
        defer { avformat_free_context(context) }
        try readGuard.installCustomInput(on: context, factory: { input })
        let pb = try #require(context.pointee.pb)

        // AVSEEK_SIZE: the length the host reported, without a read.
        #expect(avio_size(pb) == Int64(data.count))
        #expect(pb.pointee.seekable != 0)

        // Reading from the very end is EOF, not an error — the distinction
        // libavformat's demuxers branch on at every container tail.
        #expect(avio_seek(pb, Int64(data.count), SEEK_SET) == Int64(data.count))
        var byte: UInt8 = 0
        #expect(avio_read(pb, &byte, 1) == swift_AVERROR_EOF())
        #expect(input.sawEOF || avio_feof(pb) != 0)
    }

    @Test func aFailingHostReadSurfacesAsATypedFailureQuickly() throws {
        let data = try fixtureData("h264_aac_30s", "mkv")
        // Small on purpose: the probe is remarkably tolerant of a truncated
        // container (it warns about `probesize` and answers anyway), so the
        // budget has to die before the format probe is satisfied for the
        // failure to be about the TRANSPORT rather than about the bytes.
        let input = MemoryInput(data: data, failAfterBytes: 512)
        let started = ContinuousClock.now
        do {
            _ = try SourceProbe.open(url: absentURL("fixture.mkv"), input: { input })
            Issue.record("A source whose host input died opened successfully")
        } catch {
            let underlying = (error as? SourceProbe.Failure).flatMap {
                if case .openFailed(let inner) = $0 { return inner } else { return nil }
            } ?? error
            guard case PrismCoreInputError.readFailed(let hostError) = underlying else {
                Issue.record("Expected PrismCoreInputError.readFailed, got \(underlying)")
                return
            }
            #expect(hostError is MemoryInput.Broken)
            // The point of the typed failure: the caller gets an answer
            // instead of a session waiting on a playlist nobody will write.
            #expect(started.duration(to: .now) < .seconds(10))
        }
    }

    /// A length-less input is refused at open rather than producing a session
    /// with no duration, no plan and no scrub — see `CustomInput`.
    @Test func lengthlessInputIsRefusedWithAClearError() throws {
        let data = try fixtureData("h264_aac", "mkv")
        let input = MemoryInput(data: data, reportsLength: false)
        let readGuard = ReadInterruptGuard()
        let context = try #require(readGuard.makeContext())
        defer { avformat_free_context(context) }
        #expect(throws: PrismCoreInputError.self) {
            try readGuard.installCustomInput(on: context, factory: { input })
        }
        #expect(throws: (any Error).self) {
            _ = try SourceProbe.open(url: absentURL("fixture.mkv"), input: { input })
        }
    }

    /// The non-seekable contract itself, on the avio layer that implements it:
    /// `seekable = 0`, no size, and a seek that fails instead of silently
    /// doing nothing.
    @Test func nonSeekableInputReportsItselfHonestlyToFFmpeg() throws {
        let data = try fixtureData("h264_aac", "mkv")
        let adapter = CustomInput(
            input: MemoryInput(data: data, reportsLength: false), interrupted: { false }
        )
        let readGuard = ReadInterruptGuard()
        let context = try #require(readGuard.makeContext())
        defer { avformat_free_context(context) }
        try adapter.install(on: context)
        let pb = try #require(context.pointee.pb)
        #expect(pb.pointee.seekable == 0)
        #expect(avio_size(pb) < 0)
        // Forward is not the interesting direction: libavformat skips ahead
        // on an unseekable stream by reading and discarding. Backwards is the
        // one that has to FAIL rather than silently land somewhere else.
        // Far enough forward to leave the avio buffer behind, so the seek
        // back is a real one and not a rewind inside bytes already held.
        #expect(avio_seek(pb, 200_000, SEEK_SET) == 200_000)
        #expect(avio_seek(pb, 0, SEEK_SET) < 0)
        // The adapter frees its AVIO in deinit, so it has to outlive the
        // context it is installed on.
        withExtendedLifetime(adapter) {}
    }
}

/// A one-value lock, so the factory counter is safe to touch from wherever
/// the probe thread runs.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
