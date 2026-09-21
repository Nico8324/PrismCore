import Foundation
import Libavformat
import Libavutil

/// Bytes supplied by the **host** instead of by libavformat's own protocols.
///
/// The engine can natively open whatever libavformat can (`file:`, `http:`,
/// …), which leaves out every source whose bytes only the host can reach: an
/// SMB share mounted through the host's own client, a debrid or torrent
/// session, an encrypted local store, a file inside a disc image. Those hosts
/// used to have no way in at all; this is it.
///
/// Implementations are read-only and position-based. `read` fills as much of
/// `buffer` as it can and returns how many bytes it wrote — **`0` means end of
/// stream**, never "nothing available right now": libavformat treats a zero
/// return as EOF, so an implementation that would otherwise return 0 has to
/// block until it has a byte or throw.
///
/// Errors thrown from either method reach FFmpeg as a negative return code and
/// are re-surfaced to the caller as `PrismCoreInputError.readFailed` /
/// `.seekFailed`, wrapping the host's own error — a failing transport must
/// come back as a typed failure, not as a session that hangs waiting for a
/// playlist that will never be written.
///
/// `Sendable` because the engine reads on whichever thread owns the context
/// that open produced (a probe thread, the producer thread, the preview
/// actor's). Each open gets its **own** instance from the factory, so an
/// implementation never has to be safe for *concurrent* use — only for use
/// from a thread that is not the one that created it.
public protocol PrismCoreInput: Sendable {

    /// Fill `buffer` from the current position, advancing it by the number of
    /// bytes written. Returns `0` at end of stream.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int

    /// Move the read position. `offset` is always absolute and non-negative,
    /// and may legitimately be at or past `length` (the demuxer probes the
    /// tail); the next `read` from there returns `0`.
    func seek(to offset: Int64) throws

    /// Total byte count, or `nil` for a stream whose size is unknown.
    ///
    /// `nil` also means **not seekable**: a size is what the demuxer's index
    /// load, the segment plan and every scrub need, and an input that cannot
    /// say how long it is cannot answer a seek either. See
    /// `PrismCoreInputError.notSeekable` for what the engine does with one.
    var length: Int64? { get }
}

/// A `PrismCoreInput` whose in-flight `read` or `seek` can be released from
/// another thread.
///
/// The plain protocol has no way out of a blocked call. `ReadInterruptGuard`
/// bounds blocking operations with FFmpeg's `interrupt_callback`, which FFmpeg
/// polls *between* reads — so it reaches libavformat's own I/O and stops dead
/// at the edge of a host's synchronous `read(into:)`. An SMB share whose
/// server went away, or a debrid link that stopped feeding, therefore parks the
/// calling thread for as long as the host's own transport takes to give up:
/// minutes, or never. That thread is the probe's, or the producer's — and a
/// parked producer is what used to make `PrismCoreSession.stop()` hang, which
/// in a host app is a frozen UI.
///
/// Conforming is what gives the engine a way in.
///
/// **The contract, both halves.** The engine promises to call
/// `cancelInFlightOperation()` whenever the read guard on this input's context
/// becomes interrupted — an expired probe/index-load budget, or an explicit
/// cancellation such as `stop()`. The host promises that the `read` or `seek`
/// blocked at that moment then *returns*, promptly, in one of two ways the
/// engine accepts equally:
///
/// - **throwing** — the usual shape, and the one that carries a reason. What
///   is thrown is recorded as `PrismCoreInputError.readFailed` /
///   `.seekFailed`, but on an interrupted context it is the abort, not the
///   error, that decides the outcome, so a plain "cancelled" error is fine;
/// - **a short count**, `0` included. Zero normally means end of stream —
///   `read(into:)` says so — but a read released by a cancellation is read
///   back as the abort it is and never as EOF, because the engine knows it
///   asked. A short positive count is simply the bytes that did arrive.
///
/// Both are honoured only while the guard is interrupted. A host that returns
/// `0` at any *other* moment is still declaring EOF.
///
/// Two requirements on the implementation:
///
/// - **it may be called concurrently with `read` or `seek`** — that is the
///   whole point — so it must not take a lock those hold, and must not touch
///   state they mutate without its own synchronization. Waking a socket,
///   cancelling a `URLSessionTask`, setting an atomic flag: all fine;
/// - **it may be called when nothing is in flight**, and must then do nothing.
///   The engine cannot see inside the host, so it never guesses; a deadline
///   that expires between two reads calls this against an idle input.
///
/// An input that does *not* conform keeps working exactly as before. The
/// engine checks for this conformance once, when it installs the input, and
/// leaves a notice in the unified log when it is absent — so a thread wedged
/// an hour later has a breadcrumb instead of being a mystery.
public protocol CancellablePrismCoreInput: PrismCoreInput {

    /// Release whatever `read` or `seek` is blocked right now, if any.
    ///
    /// Called from a thread that is **not** the one inside `read`/`seek`, and
    /// possibly when neither is running — in which case it must be a no-op.
    /// It must return promptly: the engine calls it from a deadline timer and
    /// from `stop()`, neither of which can afford to block.
    func cancelInFlightOperation()
}

/// How a host hands its bytes over: **one call per open**.
///
/// Deliberately a factory rather than an instance. A session opens the source
/// more than once — the routing probe, the remuxer (when it did not adopt the
/// probe's context), a `SeekPreviewService` running alongside playback — and
/// those contexts read from completely different positions at the same time.
/// One shared instance would have them fighting over a single cursor: the
/// producer's sequential read and a scrub preview's seek would interleave into
/// garbage, intermittently, on exactly the sources hardest to debug. A factory
/// makes a shared cursor impossible to express by accident.
public typealias PrismCoreInputFactory = @Sendable () throws -> any PrismCoreInput

public enum PrismCoreInputError: Error {
    /// The input reported `length == nil`. Every path that takes a custom
    /// input needs to seek, so this is refused at open time rather than
    /// half-working — see `CustomInput` for what was measured.
    case notSeekable
    /// `avio_alloc_context` (or its buffer) could not be allocated.
    case allocation
    /// The host's `read` threw; the host's own error is attached.
    case readFailed(any Error)
    /// The host's `seek` threw; the host's own error is attached.
    case seekFailed(any Error)
}

/// Adapts a `PrismCoreInput` onto an `AVIOContext` and hangs it on an
/// `AVFormatContext`, which is what makes libavformat read through the host.
///
/// The shape is the one `HTTPRangeInput` already proved: allocate the context
/// with `avio_alloc_context`, pass an unretained pointer to `self` as the
/// opaque, set `AVFMT_FLAG_CUSTOM_IO` so the format context does not try to
/// free an AVIO it does not own, and free both here.
///
/// **Non-seekable inputs, and why they are refused rather than tolerated.**
/// The avio context is created with `seekable = 0` and the seek callback
/// answers `AVERROR(ESPIPE)`, which is the honest contract — a wrong
/// `seekable = 1` would have libavformat trust seeks that do nothing. What it
/// does *not* buy is a usable session, and the failure is the quiet kind.
/// Measured on `h264_aac_30s.mkv` fed through a length-less input (gate
/// temporarily removed, 2026-09-16): the open succeeds, `find_stream_info`
/// returns the full 30.023 s duration from the Matroska header, and
/// `SegmentPlan.build` produces a six-entry `keyframeIndex` plan — so the
/// session starts and publishes a **complete VOD playlist** promising all six
/// segments. Fetching the last of them then blocked for **45.4 s** and ended
/// with the loopback connection dropped, with `residentRanges` still empty;
/// the same bytes behind a seekable input served that segment in **2 ms**
/// (HTTP 200, 123 253 bytes) with the whole 0–29.96 s range resident. A
/// promise the producer cannot keep is worse than a refusal, so the engine
/// rejects a length-less input at open with `PrismCoreInputError.notSeekable`.
final class CustomInput {

    /// A read buffer big enough to cover libavformat's probe reads without
    /// making the host's first call enormous. The same 32 KiB
    /// `HTTPRangeInput` uses; nothing here is sensitive to the exact size.
    private static let bufferSize = 32768

    private let input: any PrismCoreInput
    private let interrupted: () -> Bool
    private let length: Int64?
    /// Where FFmpeg believes the cursor is.
    private var position: Int64 = 0
    /// Where the HOST's cursor actually is. The two drift on purpose: the
    /// seek callback only records the target, and the host is moved lazily by
    /// the next read. libavformat seeks far more often than it reads from the
    /// new position (probing a tail and coming back, `avio_seek` to the
    /// current position), and on a transport where a seek is a round trip —
    /// which is the whole reason a host supplies its own bytes — each of
    /// those would otherwise be paid for nothing.
    private var hostPosition: Int64 = 0
    private var io: UnsafeMutablePointer<AVIOContext>?
    /// The host error behind the last negative return code. FFmpeg reduces
    /// every failure to an `int`, so without this the caller gets `-EIO` and
    /// no idea which mount, token or socket actually gave up.
    ///
    /// Locked because the reader and whoever asks are not guaranteed to be
    /// the same thread — the preview actor and the producer both hand their
    /// context's guard around.
    private let failureLock = NSLock()
    private var storedFailure: (any Error)?

    var failure: (any Error)? { failureLock.withLock { storedFailure } }

    private func record(_ failure: any Error) {
        failureLock.withLock { storedFailure = failure }
    }

    init(input: any PrismCoreInput, interrupted: @escaping () -> Bool) {
        self.input = input
        self.interrupted = interrupted
        self.length = input.length
    }

    func install(on context: UnsafeMutablePointer<AVFormatContext>) throws {
        guard let allocation = av_malloc(Self.bufferSize) else { throw PrismCoreInputError.allocation }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        io = avio_alloc_context(
            allocation.assumingMemoryBound(to: UInt8.self), Int32(Self.bufferSize), 0, opaque,
            { opaque, bytes, count in
                guard let opaque, let bytes else { return swift_AVERROR(EIO) }
                return Unmanaged<CustomInput>.fromOpaque(opaque).takeUnretainedValue()
                    .read(into: bytes, count: count)
            }, nil,
            { opaque, offset, whence in
                guard let opaque else { return Int64(swift_AVERROR(EIO)) }
                return Unmanaged<CustomInput>.fromOpaque(opaque).takeUnretainedValue()
                    .seek(offset: offset, whence: whence)
            })
        guard let io else { av_free(allocation); throw PrismCoreInputError.allocation }
        // A length-less input gets an honest 0: libavformat then never issues
        // a seek it would have trusted to work.
        io.pointee.seekable = length == nil ? 0 : Int32(AVIO_SEEKABLE_NORMAL)
        context.pointee.pb = io
        context.pointee.flags |= 0x0080 // AVFMT_FLAG_CUSTOM_IO: this owner frees AVIO.
    }

    deinit {
        if let io { av_free(io.pointee.buffer); avio_context_free(&self.io) }
    }

    private func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & 0x10000 != 0 { // AVSEEK_SIZE: answer the size, do not move.
            guard let length else { return Int64(swift_AVERROR(ENOSYS)) }
            return length
        }
        guard length != nil else { return Int64(swift_AVERROR(ESPIPE)) }
        let base: Int64
        // AVSEEK_FORCE (0x20000) is advisory — it says "seek even if it looks
        // expensive", not that the position means something different.
        switch whence & ~0x20000 {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = position
        case SEEK_END: base = length ?? 0
        default: return Int64(swift_AVERROR(EINVAL))
        }
        let (target, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, target >= 0 else { return Int64(swift_AVERROR(EINVAL)) }
        position = target
        return target
    }

    private func read(into destination: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
        guard count > 0 else { return 0 }
        // Checked here as well as in the interrupt callback: a host whose read
        // blocks for minutes is exactly the shape the guard exists for, and
        // this is the one place the engine gets control back between reads.
        if interrupted() { return swift_AVERROR_EXIT() }
        if let length, position >= length { return swift_AVERROR_EOF() }
        do {
            if position != hostPosition {
                try input.seek(to: position)
                hostPosition = position
            }
        } catch {
            record(PrismCoreInputError.seekFailed(error))
            return interrupted() ? swift_AVERROR_EXIT() : swift_AVERROR(EIO)
        }
        do {
            let written = try input.read(
                into: UnsafeMutableRawBufferPointer(start: destination, count: Int(count))
            )
            // A host that over-reports would have libavformat read past the
            // buffer it just handed out; clamp rather than trust.
            //
            // The interrupted branch is the short-count half of
            // `CancellablePrismCoreInput`'s contract: a read we released from
            // another thread is allowed to come back empty, and reporting that
            // as EOF would tell the demuxer the file ended — a truncated
            // container analysed as a complete one, which is a wrong answer
            // rather than an aborted one. The guard asked for this, so it is
            // read back as the abort it is.
            guard written > 0 else {
                return interrupted() ? swift_AVERROR_EXIT() : swift_AVERROR_EOF()
            }
            let accepted = min(written, Int(count))
            position += Int64(accepted)
            hostPosition = position
            return Int32(accepted)
        } catch {
            record(PrismCoreInputError.readFailed(error))
            return interrupted() ? swift_AVERROR_EXIT() : swift_AVERROR(EIO)
        }
    }
}
