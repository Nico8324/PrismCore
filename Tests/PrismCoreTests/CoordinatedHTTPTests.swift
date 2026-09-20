import Testing
import Foundation
@testable import PrismCore
import Libavformat

@Suite("Coordinated HTTP", .serialized)
struct CoordinatedHTTPTests {
    @Test func interruptedHTTPReadHonorsProbeDeadline() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"))
        let server = try RangeFixtureServer(media: Data(contentsOf: fixture), firstByteDelay: 3)
        let url = try await server.start()
        defer { server.stop() }
        let start = ContinuousClock.now
        do {
            _ = try await SourceProbe.openDetached(url: url, budget: .milliseconds(150), coordinatedHTTP: true)
            Issue.record("A starving origin exceeded the probe budget without throwing")
        } catch {
            #expect(start.duration(to: .now) < .seconds(2))
        }
    }

    @Test func droppedConnectionCanBeRetried() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "h264_aac", withExtension: "mkv", subdirectory: "Fixtures"))
        let server = try RangeFixtureServer(media: Data(contentsOf: fixture), drops: 1)
        let url = try await server.start()
        defer { server.stop() }
        let probed = try await SourceProbe.openDetached(url: url, coordinatedHTTP: true)
        #expect(!probed.info.audioTracks.isEmpty)
        #expect(server.requests.count >= 2)
    }
    @Test func rangeValidationAndRetryDates() {
        #expect(HTTPRangeInput.contentRange("bytes 20-39/40")?.start == 20)
        #expect(HTTPRangeInput.contentRange("bytes 20-40/40") == nil)
        #expect(HTTPRangeInput.contentRange("bytes -2-4/10") == nil)
        #expect(HTTPRangeInput.contentRange("bytes 5-2/10") == nil)
        #expect(HTTPOriginCoordinator.retryDelay("3") == 3)
        #expect(HTTPOriginCoordinator.retryDelay("NaN") == nil)
        #expect(HTTPOriginCoordinator.retryDelay("Thu, 01 Jan 1970 00:00:10 GMT", now: Date(timeIntervalSince1970: 0)) == 10)
        #expect(HTTPOriginCoordinator.origin(URL(string: "https://EXAMPLE.com/movie?token=secret")!) == "https://example.com:443")
    }

    @Test func refusedOriginWaitsAndThenPlays() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "h264_aac_30s", withExtension: "mkv", subdirectory: "Fixtures"))
        let server = try RangeFixtureServer(media: Data(contentsOf: fixture), refusals: 1)
        let url = try await server.start()
        defer { server.stop() }
        let session = try PrismCoreSession(url: url, coordinatedHTTP: true)
        do {
            _ = try await session.start()
            #expect(!session.residentRanges.isEmpty)
            #expect(session.audioDelivery == .streamCopy)
            let requests = server.requests
            #expect(requests.count >= 2)
            #expect(requests[1] - requests[0] >= 0.95)
        } catch { await session.stop(); throw error }
        await session.stop()
    }


    /// Startup reads head → tail → head (open, the index-load nudge, the
    /// producer's start), and the last of those used to refetch bytes this
    /// reader already had — the whole point of retaining more than one block.
    @Test func aBlockSurvivesAnExcursionToTheTail() async throws {
        // Bigger than one 1 MB block, so head and tail are genuinely
        // different blocks. Contents are irrelevant: nothing demuxes here.
        var media = Data(count: 3 << 20)
        media.withUnsafeMutableBytes { $0.copyBytes(from: (0..<(3 << 20)).map { UInt8($0 % 251) }) }
        let server = try RangeFixtureServer(media: media)
        let url = try await server.start()
        defer { server.stop() }

        let guardian = ReadInterruptGuard()
        let context = try #require(guardian.makeContext())
        defer { var closing: UnsafeMutablePointer<AVFormatContext>? = context; avformat_close_input(&closing) }
        try guardian.installHTTPInput(on: context, url: url, headers: [:])
        let io = try #require(context.pointee.pb)

        var scratch = [UInt8](repeating: 0, count: 16)
        #expect(avio_read(io, &scratch, 16) == 16)
        let afterHead = server.requests.count

        // The tail, far enough that neither avio's own buffer nor the head
        // block can answer it.
        #expect(avio_seek(io, Int64(media.count - 4096), SEEK_SET) >= 0)
        #expect(avio_read(io, &scratch, 16) == 16)
        #expect(server.requests.count > afterHead, "the tail read should have cost a request")
        let afterTail = server.requests.count

        // Back to the head: the block is still here, so this costs nothing.
        #expect(avio_seek(io, 0, SEEK_SET) >= 0)
        #expect(avio_read(io, &scratch, 16) == 16)
        #expect(scratch.prefix(4) == [0, 1, 2, 3], "the retained block served the wrong bytes")
        #expect(server.requests.count == afterTail, "the rewind refetched a block the reader still had")
    }

    @Test func originAdmissionDoesNotOccupySlotsWhileCancelled() {
        let coordinator = HTTPOriginCoordinator()
        #expect(coordinator.acquire("test", cancelled: { false }))
        #expect(coordinator.acquire("test", cancelled: { false }))
        #expect(!coordinator.acquire("test", cancelled: { true }))
        coordinator.release("test")
        #expect(coordinator.acquire("test", cancelled: { false }))
        coordinator.release("test")
        coordinator.release("test")
    }
}
