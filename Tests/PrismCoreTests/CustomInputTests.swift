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
///
/// `class`, not `final class`, since 3.1.0: `CancellableMemoryInput` below is
/// the same transport with the interruption hook bolted on, and the tests that
/// matter are the ones comparing the two shapes on identical bytes.
private class MemoryInput: PrismCoreInput, @unchecked Sendable {
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
    /// Park the read — forever, until something releases it — once this many
    /// bytes have been handed over. A share whose server went away or a debrid
    /// link that stopped feeding: not an error, a call that does not return.
    /// This is the shape nothing in 3.0.0 could get out of.
    private let blockAfterBytes: Int?
    /// How a released read answers, which is the half of
    /// `CancellablePrismCoreInput`'s contract the engine has to tolerate both
    /// ways round.
    enum Release { case throwing, shortCount }
    private let releaseAnswer: Release
    /// The parked read's condition. Separate from `lock`: `cancelInFlightOperation`
    /// runs while a read holds nothing but this, which is exactly the
    /// concurrency the protocol requires a conformance to be safe for.
    fileprivate let gate = NSCondition()
    fileprivate var isReleased = false
    fileprivate var isParked = false
    private var delivered = 0
    private var storedReads = 0
    private var storedSeeks = 0
    private var storedSawEOF = false

    struct Broken: Error {}
    /// What a released read throws. Deliberately NOT `Broken`: a read the
    /// engine itself asked to let go of is not a transport failure, and a test
    /// that could not tell them apart would pass on the wrong one.
    struct Released: Error {}

    init(data: Data, reportsLength: Bool = true, failAfterBytes: Int? = nil,
         failureStall: Duration? = nil, chunk: Int = MemoryInput.defaultChunk,
         blockAfterBytes: Int? = nil, releaseAnswer: Release = .throwing) {
        self.chunk = chunk
        self.bytes = [UInt8](data)
        self.reportsLength = reportsLength
        self.failAfterBytes = failAfterBytes
        self.failureStall = failureStall
        self.blockAfterBytes = blockAfterBytes
        self.releaseAnswer = releaseAnswer
    }

    /// Let a parked read go without the engine's hook — how a test cleans up
    /// after a NON-conforming input, whose wedged thread would otherwise
    /// outlive the test and keep the work directory alive.
    func release() {
        gate.lock()
        isReleased = true
        gate.broadcast()
        gate.unlock()
    }

    /// Whether a read is parked right now.
    var isBlocked: Bool {
        gate.lock(); defer { gate.unlock() }
        return isParked
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
        if let blockAfterBytes, deliveredBytes >= blockAfterBytes {
            gate.lock()
            isParked = true
            while !isReleased { gate.wait() }
            isParked = false
            gate.unlock()
            // Both answers are legal once the engine has asked for the read
            // back; a short count is the one that used to read as EOF.
            switch releaseAnswer {
            case .throwing: throw Released()
            case .shortCount: return 0
            }
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

/// The same transport, conforming — the only difference between it and its
/// superclass is the one the engine is allowed to detect.
private final class CancellableMemoryInput: MemoryInput, CancellablePrismCoreInput {
    private let calls = NSLock()
    private var storedCancelCalls = 0
    private var storedIdleCancelCalls = 0

    var cancelCalls: Int { calls.withLock { storedCancelCalls } }
    /// Calls that found nothing parked. The protocol requires those to be
    /// no-ops, and the engine makes them: a deadline that expires between two
    /// reads reaches an input with nothing to release.
    var idleCancelCalls: Int { calls.withLock { storedIdleCancelCalls } }

    func cancelInFlightOperation() {
        // Takes the gate and nothing else — never the read lock. That lock is
        // held by the very call this exists to release, so reaching for it
        // would turn the rescue into a deadlock. This is the concurrency the
        // protocol warns conformances about, written out.
        gate.lock()
        let wasParked = isParked
        isReleased = true
        gate.broadcast()
        gate.unlock()
        calls.withLock {
            storedCancelCalls += 1
            if !wasParked { storedIdleCancelCalls += 1 }
        }
    }
}

/// `.serialized` because two of these count the engine's one-time notices,
/// and the notice sink is process-wide. This is the only suite that installs
/// custom inputs, so serializing it is enough to make the counts exact.
@Suite("Custom input", .serialized)
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

    // MARK: - Interruptible inputs (3.1.0)

    /// The half that does not depend on the host at all: a `stop()` whose
    /// producer is parked inside a read that will never return must still
    /// return. Before this, the join was unbounded and a host app leaving the
    /// player froze with it.
    @Test("stop() returns on its own budget when the host read never comes back")
    func stopReturnsWhenTheHostReadNeverDoes() async throws {
        let data = try fixtureData("h264_aac_30s", "mkv")
        // Past startup (~164 KB of host answers on this fixture) and inside
        // the copy loop, so the session is genuinely serving when the
        // transport goes silent.
        let input = MemoryInput(data: data, blockAfterBytes: 400_000)
        // Last defer to run: releases the thread this test deliberately
        // leaks, so the suite does not accumulate wedged producers.
        defer { input.release() }
        let session = try PrismCoreSession(url: absentURL("wedged.mkv"), input: { input })
        _ = try await session.start()
        #expect(try await reached(.seconds(20)) { input.isBlocked },
                "the producer never reached the parked read")

        let finished = Locked(false)
        let started = ContinuousClock.now
        // Abandoned, not awaited: a regression here does not fail, it HANGS,
        // and a task group would wait for the same uninterruptible join at
        // scope exit. The test owns the clock instead.
        let stopping = Task { await session.stop(); finished.withLock { $0 = true } }
        _ = try await reached(.seconds(15)) { finished.withLock { $0 } }
        let elapsed = started.duration(to: .now)
        stopping.cancel()

        #expect(finished.withLock { $0 },
                "stop() never returned — the producer join is unbounded again")
        #expect(elapsed < PrismCoreSession.producerStopGrace + .seconds(3),
                "stop() took \(elapsed) against a \(PrismCoreSession.producerStopGrace) grace")
    }

    /// The other half: a host that CAN be reached gets reached, so the
    /// producer exits and there is nothing to detach.
    @Test("A conforming input has its parked read released, so stop() joins")
    func stopReleasesAConformingHostRead() async throws {
        let data = try fixtureData("h264_aac_30s", "mkv")
        let input = CancellableMemoryInput(data: data, blockAfterBytes: 400_000)
        defer { input.release() }
        let notices = Locked<[String]>([])
        PrismCoreLog.observer = { message in notices.withLock { $0.append(message) } }
        defer { PrismCoreLog.observer = nil }

        let session = try PrismCoreSession(url: absentURL("released.mkv"), input: { input })
        _ = try await session.start()
        #expect(try await reached(.seconds(20)) { input.isBlocked },
                "the producer never reached the parked read")

        let started = ContinuousClock.now
        await session.stop()
        let elapsed = started.duration(to: .now)

        #expect(input.cancelCalls > 0, "the engine never asked the host to let go")
        #expect(elapsed < PrismCoreSession.producerStopGrace,
                "stop() took \(elapsed) — it waited the grace out instead of being released")
        let said = notices.withLock { $0 }
        #expect(!said.contains { $0.contains("detaching") },
                "the producer was detached, so the release never reached it: \(said)")
        #expect(!said.contains { $0.contains("does not conform") },
                "a conforming input was announced as unconformant: \(said)")
    }

    /// A read budget is the other place the guard becomes interrupted, and it
    /// is the one that notifies nobody on its own: `shouldInterrupt` is a
    /// poll, and the thread that would poll it is inside the host.
    @Test("A probe budget reaches a host read that has already parked")
    func probeBudgetReleasesAParkedConformingRead() async throws {
        let data = try fixtureData("h264_aac_30s", "mkv")
        // 2 KiB answers, parked after 4 KiB: the same tuning the failure test
        // above uses, which puts the park inside `find_stream_info` — after
        // the open, so the budget is bounding analysis, not a refusal.
        let input = CancellableMemoryInput(data: data, chunk: 2048, blockAfterBytes: 4096)
        defer { input.release() }

        let started = ContinuousClock.now
        // A real thread, never the cooperative pool: the probe blocks, and
        // before this change it blocks forever (#44's rule).
        let probe = ProducerThread(name: "prismcore.tests.parked-probe") {
            _ = try SourceProbe.open(
                url: absentURL("fixture.mkv"), budget: .milliseconds(300), input: { input }
            )
        }
        let returned = await probe.join(within: .seconds(15))
        let elapsed = started.duration(to: .now)

        #expect(returned, "the probe never returned — the budget did not reach the parked read")
        #expect(elapsed < .seconds(5), "the probe answered after \(elapsed) against a 0.3 s budget")
        #expect(input.cancelCalls > 0)
        #expect(probe.failureIfAny != nil, "a probe that could not read must not report success")
    }

    /// The short-count half of the contract. `read` returning 0 normally means
    /// end of stream; a read the engine itself released is allowed to answer
    /// that way, and reading it as EOF would hand the demuxer a truncated
    /// container as a complete one.
    @Test("A read released with a short count aborts rather than reporting EOF")
    func aReleasedShortCountIsNotEndOfStream() async throws {
        let data = try fixtureData("h264_aac", "mkv")
        // Parked on the very first read, so nothing else can be mistaken for
        // the abort under test.
        let input = CancellableMemoryInput(
            data: data, blockAfterBytes: 0, releaseAnswer: .shortCount
        )
        defer { input.release() }
        let readGuard = ReadInterruptGuard()
        let context = try #require(readGuard.makeContext())
        defer { avformat_free_context(context) }
        try readGuard.installCustomInput(on: context, factory: { input })
        #expect(readGuard.inputIsInterruptible)
        // `nonisolated(unsafe)`: the pointer crosses onto the reader thread,
        // which is the only thread that touches it — the same single-owner
        // shape every context in this engine already has.
        nonisolated(unsafe) let pb = try #require(context.pointee.pb)

        readGuard.arm(budget: .milliseconds(200))
        let outcome = Locked<Int32>(0)
        let reader = ProducerThread(name: "prismcore.tests.short-count") {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let result = avio_read(pb, &buffer, 4096)
            outcome.withLock { $0 = result }
        }
        let returned = await reader.join(within: .seconds(10))

        #expect(returned, "the parked read was never released")
        #expect(outcome.withLock { $0 } == swift_AVERROR_EXIT(),
                "a released read must come back as an abort, not as end of stream")
        withExtendedLifetime(readGuard) {}
    }

    /// The engine calls the hook whenever the guard becomes interrupted — it
    /// cannot see inside the host, so it never guesses whether anything is in
    /// flight. That makes "nothing in flight" the common case, and it has to
    /// cost nothing.
    @Test("cancelInFlightOperation with nothing in flight changes nothing")
    func cancellingWithNothingInFlightIsHarmless() throws {
        let data = try fixtureData("h264_aac", "mkv")
        let input = CancellableMemoryInput(data: data)
        input.cancelInFlightOperation()
        #expect(input.idleCancelCalls == 1)
        // …and the input still gives the engine a complete probe afterwards.
        let info = try SourceProbe.probe(url: absentURL("fixture.mkv"), input: { input })
        #expect(info.video?.codecName == "h264")
        #expect((info.duration ?? 0) > 0)

        // The same call made by the ENGINE, on an input that has not read a
        // byte: `cancel()` on a guard whose context nobody is using.
        let idle = CancellableMemoryInput(data: data)
        let readGuard = ReadInterruptGuard()
        let context = try #require(readGuard.makeContext())
        defer { avformat_free_context(context) }
        try readGuard.installCustomInput(on: context, factory: { idle })
        readGuard.cancel()
        #expect(idle.cancelCalls == 1)
        #expect(idle.idleCancelCalls == 1)
        withExtendedLifetime(readGuard) {}
    }

    /// Additive means additive: an input written against 3.0.0 behaves
    /// identically. What it gains is a breadcrumb — said once, at the only
    /// moment the engine can still tell the difference cheaply.
    @Test("A non-conforming input is unchanged, and is announced exactly once")
    func aNonConformingInputIsAnnouncedOnce() throws {
        let data = try fixtureData("h264_aac", "mkv")
        let notices = Locked<[String]>([])
        PrismCoreLog.observer = { message in notices.withLock { $0.append(message) } }
        defer { PrismCoreLog.observer = nil }

        let plainGuard = ReadInterruptGuard()
        let plainContext = try #require(plainGuard.makeContext())
        defer { avformat_free_context(plainContext) }
        try plainGuard.installCustomInput(on: plainContext, factory: { MemoryInput(data: data) })
        #expect(!plainGuard.inputIsInterruptible)
        let afterPlain = notices.withLock { $0 }
        #expect(afterPlain.count == 1, "expected exactly one notice, got \(afterPlain)")
        #expect(afterPlain.first?.contains("CancellablePrismCoreInput") == true,
                "the notice must name the protocol a host would have to adopt")

        // The conforming one says nothing. A breadcrumb dropped for the normal
        // case is noise, and noise is what stops the abnormal one being read.
        let sharpGuard = ReadInterruptGuard()
        let sharpContext = try #require(sharpGuard.makeContext())
        defer { avformat_free_context(sharpContext) }
        try sharpGuard.installCustomInput(
            on: sharpContext, factory: { CancellableMemoryInput(data: data) }
        )
        #expect(sharpGuard.inputIsInterruptible)
        #expect(notices.withLock { $0 }.count == 1)

        // And the old shape still reads: the notice is a note, not a refusal.
        let info = try SourceProbe.probe(
            url: absentURL("fixture.mkv"), input: { MemoryInput(data: data) }
        )
        #expect(info.video?.codecName == "h264")
        #expect(!info.audioTracks.isEmpty)
        withExtendedLifetime((plainGuard, sharpGuard)) {}
    }

    /// Poll `condition` until it holds or `limit` passes. Returns whether it
    /// held — a caller that cares turns that into the failure.
    private func reached(
        _ limit: Duration, _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
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
