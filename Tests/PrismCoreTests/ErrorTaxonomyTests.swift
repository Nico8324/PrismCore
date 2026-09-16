import Testing
import Foundation
@testable import PrismCore

/// Every case the engine claims to be able to prove is driven here by a real
/// failure — an origin that really refuses, a source that really has no video —
/// rather than by constructing the enum. A taxonomy assembled by hand tests
/// only that the author can spell the case names.
///
/// `.serialized` for the same reason `CoordinatedHTTPTests` is: the coordinated
/// reader shares one `HTTPOriginCoordinator`, and a backoff earned by one
/// test's origin would otherwise be waited out by another's.
@Suite("Error taxonomy", .serialized)
struct ErrorTaxonomyTests {

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    // MARK: - Origins that answer

    @Test func forbiddenOriginIsClassifiedAsRefusal() async throws {
        let server = try RangeFixtureServer(media: try Data(contentsOf: fixture("h264_aac", "mkv")),
                                            deniedStatus: 403)
        let url = try await server.start()
        defer { server.stop() }
        do {
            _ = try await SourceProbe.openDetached(url: url, budget: .seconds(5), coordinatedHTTP: true)
            Issue.record("A 403 origin produced a probe result")
        } catch {
            let classified = PrismCoreError.classify(error)
            guard case .originRefused(let status, let refusedURL) = classified else {
                Issue.record("403 classified as \(classified)")
                return
            }
            #expect(status == 403)
            #expect(refusedURL == url)
            // The whole point of separating this from a rate limit: retrying
            // an expired token just burns the origin's patience.
            #expect(classified.retryability == .permanent)
        }
    }

    @Test func rateLimitedOriginKeepsItsRetryAfter() async throws {
        let server = try RangeFixtureServer(media: try Data(contentsOf: fixture("h264_aac", "mkv")),
                                            deniedStatus: 429, retryAfter: "1")
        let url = try await server.start()
        defer { server.stop() }
        do {
            // A short budget on purpose: the reader retries a 429 up to eight
            // times, so what this proves is that the *budget expiry* does not
            // erase the reason — the latched 429 outranks the AVERROR_EXIT.
            _ = try await SourceProbe.openDetached(url: url, budget: .seconds(2), coordinatedHTTP: true)
            Issue.record("A 429 origin produced a probe result")
        } catch {
            let classified = PrismCoreError.classify(error)
            guard case .originRateLimited(let status, let retryAfter, _) = classified else {
                Issue.record("429 classified as \(classified)")
                return
            }
            #expect(status == 429)
            #expect(retryAfter == 1)
            #expect(classified.retryability == .retryable)
        }
    }

    @Test func droppedOriginIsUnreachableWithNoStatus() async throws {
        let server = try RangeFixtureServer(media: try Data(contentsOf: fixture("h264_aac", "mkv")),
                                            drops: 99)
        let url = try await server.start()
        defer { server.stop() }
        do {
            _ = try await SourceProbe.openDetached(url: url, budget: .seconds(2), coordinatedHTTP: true)
            Issue.record("An origin that drops every connection produced a probe result")
        } catch {
            let classified = PrismCoreError.classify(error)
            guard case .originUnreachable(let status, _, _) = classified else {
                Issue.record("a dropped connection classified as \(classified)")
                return
            }
            // No status is the honest answer — nothing was ever received.
            #expect(status == nil)
            #expect(classified.retryability == .retryable)
        }
    }

    @Test func aRefusalRiddenOutLeavesNoFailureBehind() async throws {
        let server = try RangeFixtureServer(media: try Data(contentsOf: fixture("h264_aac_30s", "mkv")),
                                            refusals: 1, retryAfter: "0")
        let url = try await server.start()
        defer { server.stop() }
        let session = try PrismCoreSession(url: url, coordinatedHTTP: true)
        do {
            _ = try await session.start()
            // The latch must not outlive the retry that succeeded: a session
            // throttled once at the start and healthy afterwards is not a
            // rate-limited session.
            #expect(await session.remuxFailure == nil)
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }

    // MARK: - Sources

    @Test func audioOnlySourceIsNoVideoStream() async throws {
        let session = try PrismCoreSession(url: try fixture("audio_only_multi", "mka"))
        defer { Task { await session.stop() } }
        do {
            _ = try await session.start(startupTimeout: .seconds(10))
            Issue.record("An audio-only source produced a playlist")
        } catch {
            let classified = PrismCoreError.classify(error)
            guard case .noVideoStream = classified else {
                Issue.record("an audio-only source classified as \(classified)")
                return
            }
            #expect(classified.retryability == .permanent)
        }
    }

    @Test func vp9SourceIsNotRemuxableAndSaysWhichStream() async throws {
        let session = try PrismCoreSession(url: try fixture("vp9", "webm"))
        defer { Task { await session.stop() } }
        do {
            _ = try await session.start(startupTimeout: .seconds(10))
            Issue.record("A VP9 source produced an fMP4 playlist")
        } catch {
            let classified = PrismCoreError.classify(error)
            guard case .videoCodecNotRemuxable(let codecName, let streamIndex) = classified else {
                Issue.record("VP9 classified as \(classified)")
                return
            }
            #expect(codecName == "vp9")
            #expect(streamIndex >= 0)
            #expect(classified.retryability == .permanent)
        }
    }

    // MARK: - Budgets

    @Test func starvedStartupIsTheBudget() async throws {
        let server = try RangeFixtureServer(media: try Data(contentsOf: fixture("h264_aac", "mkv")),
                                            firstByteDelay: 3)
        let url = try await server.start()
        defer { server.stop() }
        let session = try PrismCoreSession(url: url)
        do {
            _ = try await session.start(startupTimeout: .milliseconds(300))
            Issue.record("A starving origin produced a playlist inside 300 ms")
        } catch {
            let classified = PrismCoreError.classify(error)
            guard case .startupBudgetExpired = classified else {
                Issue.record("a starved startup classified as \(classified)")
                await session.stop()
                return
            }
            // Deliberately not `.retryable`: a budget expires for a slow
            // network and for a source that will never produce, and the
            // failure site cannot tell those apart.
            #expect(classified.retryability == .unknown)
        }
        await session.stop()
    }

    // MARK: - Failures that arrive from outside the engine

    @Test func masterRejectionFoldsIntoTheTaxonomy() {
        for code in MasterRejection.errorCodes {
            let error = NSError(domain: "AVFoundationErrorDomain", code: code)
            let classified = PrismCoreError.classify(error)
            guard case .masterRejectedByPlayer = classified else {
                Issue.record("\(code) classified as \(classified)")
                continue
            }
            #expect(classified.retryability == .permanent)
        }
        // Nested, which is how `AVPlayerItem.error` actually arrives.
        let nested = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "NSURLErrorDomain", code: -1002)
        ])
        guard case .masterRejectedByPlayer = PrismCoreError.classify(nested) else {
            Issue.record("a nested -1002 was not recognized as a master rejection")
            return
        }
    }

    @Test func outOfSpaceIsRecognizedInBothSpellings() {
        for error in [NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
                      NSError(domain: NSCocoaErrorDomain, code: 640)] {
            guard case .workDirectoryOutOfSpace = PrismCoreError.classify(error) else {
                Issue.record("\(error.domain)/\(error.code) was not read as a full volume")
                continue
            }
        }
        // libav*'s spelling of the same thing, from a failed segment write.
        let ffmpeg = FFmpegError(code: swift_AVERROR(ENOSPC), operation: "av_interleaved_write_frame")
        guard case .workDirectoryOutOfSpace = PrismCoreError.classify(ffmpeg) else {
            Issue.record("AVERROR(ENOSPC) was not read as a full volume")
            return
        }
    }

    // MARK: - The FFmpeg codes

    /// The `AVERROR_HTTP_*` shims are reconstructed macros, so they are checked
    /// against **libavformat's own message table** rather than against the
    /// arithmetic that produced them — `av_strerror` only names a code it
    /// recognizes, so a wrong tag shows up here as "Error number … occurred".
    @Test func httpErrorTagsMatchTheLibraryTable() {
        #expect(FFmpegError(code: swift_AVERROR_HTTP_UNAUTHORIZED(), operation: "x").message.contains("401"))
        #expect(FFmpegError(code: swift_AVERROR_HTTP_FORBIDDEN(), operation: "x").message.contains("403"))
        #expect(FFmpegError(code: swift_AVERROR_HTTP_NOT_FOUND(), operation: "x").message.contains("404"))
        #expect(FFmpegError(code: swift_AVERROR_HTTP_BAD_REQUEST(), operation: "x").message.contains("400"))
        #expect(FFmpegError(code: swift_AVERROR_HTTP_SERVER_ERROR(), operation: "x").message.contains("5XX"))
    }

    @Test func ffmpegHTTPCodesCarryTheirStatus() {
        guard case .originRefused(let forbidden, _) =
            PrismCoreError.classify(FFmpegError(code: swift_AVERROR_HTTP_FORBIDDEN(), operation: "open")) else {
            Issue.record("AVERROR_HTTP_FORBIDDEN was not read as a refusal")
            return
        }
        #expect(forbidden == 403)

        let serverError = PrismCoreError.classify(
            FFmpegError(code: swift_AVERROR_HTTP_SERVER_ERROR(), operation: "open"))
        guard case .originUnreachable(let status, _, _) = serverError else {
            Issue.record("AVERROR_HTTP_SERVER_ERROR classified as \(serverError)")
            return
        }
        #expect(status == 500)
        // 5xx is the origin talking about itself, which time can fix; a 4xx is
        // it talking about our request, which time cannot.
        #expect(serverError.retryability == .retryable)
        #expect(PrismCoreError.classify(
            FFmpegError(code: swift_AVERROR_HTTP_NOT_FOUND(), operation: "open")).retryability == .permanent)
    }

    @Test func unmappedFFmpegCodesKeepTheirCodeAndMessage() {
        let classified = PrismCoreError.classify(
            FFmpegError(code: swift_AVERROR(EINVAL), operation: "av_interleaved_write_frame"))
        guard case .ffmpeg(let code, let operation, let message) = classified else {
            Issue.record("EINVAL was given a classification it has not earned: \(classified)")
            return
        }
        #expect(code == swift_AVERROR(EINVAL))
        #expect(operation == "av_interleaved_write_frame")
        #expect(!message.isEmpty)
        // Not a guess in either direction: nothing about -22 says whether a
        // retry would help.
        #expect(classified.retryability == .unknown)
    }

    // MARK: - What the engine refuses to claim

    @Test func unprovableSituationsStayUnknown() {
        // A successful open that handed back no context is not an audio-only
        // source: no stream list was ever walked. Reporting `.noVideoStream`
        // here would be the exact misclassification this taxonomy exists to
        // avoid.
        guard case .unknown = PrismCoreError.classify(SourceProbe.Failure.noStreams) else {
            Issue.record("a missing context was reported as a verdict about the source")
            return
        }
        // Calling order is a programming mistake, not a playback failure.
        guard case .unknown = PrismCoreError.classify(PrismCoreSession.SessionError.alreadyStarted) else {
            Issue.record("an API misuse was given a playback classification")
            return
        }
    }

    @Test func wrappersAreUnwrappedToTheRealCause() {
        // The shape a host actually catches out of `start()`.
        let wrapped = PrismCoreSession.SessionError.startupTimedOut(
            underlying: SourceProbe.Failure.openFailed(
                FFmpegError(code: swift_AVERROR_HTTP_FORBIDDEN(), operation: "avformat_open_input")))
        guard case .originRefused(let status, _) = PrismCoreError.classify(wrapped) else {
            Issue.record("a 403 two wrappers deep was reported as a timeout")
            return
        }
        #expect(status == 403)
        // And with nothing underneath, the timeout is the answer.
        guard case .startupBudgetExpired = PrismCoreError.classify(
            PrismCoreSession.SessionError.startupTimedOut(underlying: nil)) else {
            Issue.record("a bare startup timeout lost its meaning")
            return
        }
    }

    @Test func urlErrorsAreSeparatedIntoRefusalAndUnreachable() {
        guard case .originRefused(let status, _) = PrismCoreError.classify(
            URLError(.userAuthenticationRequired)) else {
            Issue.record("an authentication failure was not read as a refusal")
            return
        }
        // Honest: URLSession collapsed the response, so there is no number.
        #expect(status == nil)
        guard case .originUnreachable = PrismCoreError.classify(URLError(.networkConnectionLost)) else {
            Issue.record("a lost connection was not read as an unreachable origin")
            return
        }
    }
}
