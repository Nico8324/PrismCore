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
    /// How long the dying read hangs before it throws. A real transport
    /// rarely fails instantly — it stalls and then gives up — and the stall
    /// is what lets a read budget expire *after* the host's own failure has
    /// been recorded, which is the ordering a caller has to get right.
    private let failureStall: Duration?
    /// The most this input answers in one call — see `defaultChunk`.
    private let chunk: Int
    private var delivered = 0
    private var storedReads = 0
    private var storedSeeks = 0
    private var storedSawEOF = false

    struct Broken: Error {}

    init(data: Data, reportsLength: Bool = true, failAfterBytes: Int? = nil,
         failureStall: Duration? = nil, chunk: Int = MemoryInput.defaultChunk) {
        self.chunk = chunk
        self.bytes = [UInt8](data)
        self.reportsLength = reportsLength
        self.failAfterBytes = failAfterBytes
        self.failureStall = failureStall
    }

    var length: Int64? { reportsLength ? Int64(bytes.count) : nil }
    var reads: Int { lock.withLock { storedReads } }
    /// Bytes handed over so far — how a test sizes a mid-playback failure.
    var deliveredBytes: Int { lock.withLock { delivered } }
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
    /// this fixture is 1.27 MB. A test that needs to die at a precise point
    /// of the *startup* sequence shrinks it further, because at 16 KiB the
    /// whole probe is one or two answers wide.
    static let defaultChunk = 16 * 1024

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        // Stalling outside the lock, like a real transport blocked on a
        // socket: the engine is free to time the read out while it hangs.
        if let failureStall, let failAfterBytes, deliveredBytes >= failAfterBytes {
            blockingSleep(failureStall)
        }
        return try lock.withLock {
            storedReads += 1
            if let failAfterBytes, delivered >= failAfterBytes { throw Broken() }
            var count = min(min(buffer.count, chunk), bytes.count - position)
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

/// Sleeps the calling thread — the host is called from libavformat's read
/// callback, which is not an async context.
private func blockingSleep(_ duration: Duration) {
    let seconds = Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1e18
    if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
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

    /// The gap 3.0.0 left: a host input that survives startup and dies LATER.
    /// The opening paths ask the guard what the host said; the produce loop
    /// used to report FFmpeg's `-EIO` instead, so an SMB mount that dropped
    /// or a debrid link that expired mid-film reached the host as
    /// "Input/output error" with nothing to act on.
    @Test func aHostInputThatDiesDuringProductionSurfacesTheHostError() async throws {
        let data = try fixtureData("h264_aac_30s", "mkv")
        // Measured on this fixture: startup (open, `find_stream_info`, the
        // Cues at the tail) costs ~164 KB of host answers and the whole
        // 1.27 MB container ~1.34 MB. 400 KB is therefore comfortably inside
        // the copy loop — production is already under way.
        let input = MemoryInput(data: data, failAfterBytes: 400_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreCustomInput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let remuxer = HLSRemuxer(
            sourceURL: absentURL("fixture.mkv"),
            outputDirectory: directory,
            segmentSeconds: 3,
            input: { input }
        )
        // A real thread, like the session's own: `run()` blocks in FFmpeg
        // reads and parks at EOF (#44).
        let producer = ProducerThread(name: "prismcore.tests.custom-input") { try remuxer.run() }
        defer { remuxer.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !producer.isFinished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(producer.isFinished, "the producer never returned")
        await producer.join()

        // Startup really did succeed — the failure under test is a
        // steady-state one, not another open.
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("seg00000.m4s").path
        ), "the host died before production started; the test proves nothing")

        let failure = try #require(producer.failureIfAny)
        guard case PrismCoreInputError.readFailed(let hostError) = failure else {
            Issue.record("Expected PrismCoreInputError.readFailed, got \(failure)")
            return
        }
        #expect(hostError is MemoryInput.Broken)
    }

    /// The probe's budget-exhausted exit had the same gap: a host that threw
    /// and then let the clock run out was reported as the expiry, not as the
    /// failure that caused it — and the expiry is the symptom.
    @Test func aProbeBudgetThatExpiresAfterAHostFailureNamesTheHostError() throws {
        let data = try fixtureData("h264_aac_30s", "mkv")
        // Tuned to land on that exit and nowhere else (swept, 2026-09-16):
        // in 2 KiB answers the open needs ~5, so failing after 4 KiB puts the
        // death inside `find_stream_info`, and the 600 ms stall means the
        // 200 ms budget is already spent when the host finally throws. The
        // read then comes back as the abort `find_stream_info` swallows, so
        // the probe's only visible symptom is an expired clock.
        let input = MemoryInput(data: data, failAfterBytes: 4096,
                                failureStall: .milliseconds(600), chunk: 2048)
        do {
            _ = try SourceProbe.open(url: absentURL("fixture.mkv"),
                                     budget: .milliseconds(200), input: { input })
            Issue.record("A probe whose host input died reported success")
        } catch {
            let underlying = (error as? SourceProbe.Failure).flatMap {
                if case .openFailed(let inner) = $0 { return inner } else { return nil }
            } ?? error
            guard case PrismCoreInputError.readFailed(let hostError) = underlying else {
                Issue.record("Expected PrismCoreInputError.readFailed, got \(underlying)")
                return
            }
            #expect(hostError is MemoryInput.Broken)
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
