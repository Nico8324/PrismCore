import Testing
import Foundation
import AVFoundation
@testable import PrismCore

/// Issue #52: can AVPlayer be fed without a listening socket, so a sandboxed
/// macOS host does not need `com.apple.security.network.server`?
///
/// The issue settled two routes and left the third unasked.
/// `AVAssetResourceLoader`'s header forbids the delegate from loading **HLS**
/// media data; `FileHLSPlaybackTests` measured that AVPlayer will not evaluate
/// a `file://` playlist at all. What neither covered is that the header's ban
/// is about *HLS*: the issue itself notes a progressive asset through a
/// resource loader "is fine and unrelated", without connecting that to its own
/// question.
///
/// Measured here (macOS 26, 2026-09-08):
///
/// 1. Playlists served by the delegate work — master and every media playlist,
///    on a custom scheme, exactly the use the header sanctions.
/// 2. Segments that are not HTTP fail, `file://` and custom scheme alike, with
///    `CoreMediaErrorDomain -12881`. The delegate is *offered* segment
///    requests — including for the `file://` URLs a playlist names — so the
///    ban is enforced on the response, not by withholding the request.
/// 3. The same playlists with HTTP segments play. That control is what makes
///    (2) a statement about segments rather than about the delegate.
/// 4. **A progressive fragmented MP4 through the delegate plays, and seeks by
///    byte offset, with no socket anywhere.** The muxed shape's output already
///    is one fMP4 in pieces; concatenated, it is the asset.
///
/// So a listener-free mode exists for produced output — the scope the issue
/// wanted for its `file://` mode, on the route that actually works. What it
/// costs, and what is still unmeasured, is recorded on
/// `progressiveFMP4PlaysAndSeeks`.
@Suite("Playback without a listener", .serialized)
struct ListenerFreePlaybackTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    // MARK: - HLS: playlists yes, segments no

    /// Serves playlists off disk and rewrites what they point at.
    final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        enum Segments {
            /// Absolute `file://` — AVFoundation is left to load them itself.
            case file
            /// The custom scheme, so they come back here: the delegate loading
            /// media data, which the header forbids.
            case delegate
            /// The session's own loopback server — the control, where only the
            /// playlists are unusual.
            case http(URL)
        }

        let directory: URL
        let segments: Segments
        private let lock = NSLock()
        private var seen: [String] = []
        var requested: [String] { lock.withLock { seen } }

        init(directory: URL, segments: Segments) {
            self.directory = directory
            self.segments = segments
        }

        func resourceLoader(
            _ resourceLoader: AVAssetResourceLoader,
            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
        ) -> Bool {
            guard let url = loadingRequest.request.url else { return false }
            lock.withLock { seen.append(url.absoluteString) }
            // AVFoundation offers the delegate every URL a playlist names,
            // `file://` included. Answering those would *be* the delegate
            // loading media data — the thing under test — so decline them.
            guard url.scheme == "prism" else { return false }

            let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let onDisk = directory.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: onDisk) else {
                loadingRequest.finishLoading(with: URLError(.fileDoesNotExist))
                return true
            }
            let isPlaylist = url.pathExtension == "m3u8"
            let payload = isPlaylist
                ? Data(rewrite(String(decoding: data, as: UTF8.self), base: onDisk).utf8)
                : data
            loadingRequest.contentInformationRequest?.contentType =
                isPlaylist ? "public.m3u-playlist" : "public.mpeg-4"
            loadingRequest.contentInformationRequest?.contentLength = Int64(payload.count)
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true
            if let dataRequest = loadingRequest.dataRequest {
                let start = Int(dataRequest.requestedOffset)
                let end = min(payload.count, start + dataRequest.requestedLength)
                if start < end { dataRequest.respond(with: payload.subdata(in: start..<end)) }
            }
            loadingRequest.finishLoading()
            return true
        }

        /// Playlists keep pointing at the delegate; segments go where the
        /// variant says. `base` is the playlist's own location, so a nested
        /// rendition's relative URI resolves against the right directory.
        private func rewrite(_ text: String, base: URL) -> String {
            let parent = base.deletingLastPathComponent()
            func target(_ uri: String) -> String {
                guard !uri.hasPrefix("http"), !uri.hasPrefix("file:"), !uri.hasPrefix("prism:")
                else { return uri }
                let resolved = parent.appendingPathComponent(uri).standardizedFileURL
                let relative = resolved.path.replacingOccurrences(
                    of: directory.standardizedFileURL.path + "/", with: ""
                )
                if uri.hasSuffix(".m3u8") { return "prism://local/\(relative)" }
                switch segments {
                case .file: return resolved.absoluteString
                case .delegate: return "prism://local/\(relative)"
                case .http(let base): return base.appendingPathComponent(relative).absoluteString
                }
            }
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let entry = String(line)
                if entry.hasPrefix("#") {
                    guard let range = entry.range(of: #"URI="([^"]*)""#, options: .regularExpression)
                    else { return entry }
                    let uri = String(entry[range].dropFirst(5).dropLast())
                    return entry.replacingCharacters(in: range, with: "URI=\"\(target(uri))\"")
                }
                return entry.isEmpty ? entry : target(entry)
            }.joined(separator: "\n")
        }
    }

    @Test("HLS segments that are not HTTP are refused, delegate or file:// alike")
    func nonHTTPSegmentsAreRefused() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        _ = try await session.start()
        let workDirectory = await session.workDirectory
        try await waitForCompletedWorkDirectory(workDirectory)
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreRL-\(UUID().uuidString)", isDirectory: true)
        try copyOutput(workDirectory, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        await session.stop()

        for segments in [PlaylistLoader.Segments.file, .delegate] {
            let loader = PlaylistLoader(directory: copy, segments: segments)
            let asset = AVURLAsset(url: URL(string: "prism://local/master.m3u8")!)
            asset.resourceLoader.setDelegate(loader, queue: .global())
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            let status = await settledStatus(item, timeout: 10)

            #expect(
                status == .failed,
                """
                a non-HTTP HLS segment played (\(status.rawValue)) — if this \
                now works, #52's no-listener HLS mode just became possible.
                """
            )
            // The playlists were served: the refusal is about media data, and
            // the delegate got as far as being asked for segments.
            #expect(loader.requested.contains { $0.hasSuffix("master.m3u8") })
            #expect(loader.requested.contains { $0.hasSuffix(".m4s") || $0.hasSuffix("init.mp4") })
            _ = player
        }
    }

    @Test("Control: the same delegate playlists play with HTTP segments")
    func delegatePlaylistsWithHTTPSegmentsPlay() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let served = try await session.start()
        let workDirectory = await session.workDirectory
        let loader = PlaylistLoader(
            directory: workDirectory, segments: .http(served.deletingLastPathComponent())
        )
        let asset = AVURLAsset(url: URL(string: "prism://local/master.m3u8")!)
        asset.resourceLoader.setDelegate(loader, queue: .global())
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        let status = await settledStatus(item, timeout: 15)
        #expect(status == .readyToPlay, "delegate-served playlists failed (\(String(describing: item.error)))")
        player.play()
        try? await Task.sleep(for: .milliseconds(1200))
        #expect(CMTimeGetSeconds(player.currentTime()) > 0.3)
        player.pause()
        // Only the playlists reached the delegate; AVFoundation fetched the
        // segments itself, which is the whole shape of the sanctioned use.
        #expect(loader.requested.allSatisfy { $0.hasSuffix(".m3u8") })
        await session.stop()
    }

    // MARK: - Not HLS at all

    /// Answers byte ranges over one in-memory asset: no scheme AVFoundation
    /// knows, no socket, no entitlement.
    final class ByteRangeLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        let payload: Data
        /// Bytes per response, so a small fixture still exercises the ranged
        /// path a film would take. Without it AVFoundation asks for the whole
        /// asset once and the interesting behaviour never happens.
        let chunkSize: Int
        private let queue = DispatchQueue(label: "prismcore.tests.byterange")
        private let lock = NSLock()
        private var offsets: [Int] = []
        private var cancelled = Set<ObjectIdentifier>()
        /// Every request's starting offset, in order.
        var requestedOffsets: [Int] { lock.withLock { offsets } }

        init(payload: Data, chunkSize: Int = 32 << 10) {
            self.payload = payload
            self.chunkSize = chunkSize
        }

        func resourceLoader(
            _ resourceLoader: AVAssetResourceLoader,
            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
        ) -> Bool {
            if let information = loadingRequest.contentInformationRequest {
                information.contentType = "public.mpeg-4"
                information.contentLength = Int64(payload.count)
                information.isByteRangeAccessSupported = true
            }
            guard let dataRequest = loadingRequest.dataRequest else {
                loadingRequest.finishLoading()
                return true
            }
            let start = Int(dataRequest.requestedOffset)
            let length = dataRequest.requestsAllDataToEndOfResource
                ? payload.count - start
                : dataRequest.requestedLength
            lock.withLock { offsets.append(start) }

            let token = ObjectIdentifier(loadingRequest)
            queue.async { [self] in
                var offset = start
                let end = min(payload.count, start + max(0, length))
                while offset < end {
                    // A cancelled request must stop feeding: AVFoundation
                    // cancels the read it no longer wants on every seek.
                    if lock.withLock({ cancelled.contains(token) }) { return }
                    let chunk = min(chunkSize, end - offset)
                    dataRequest.respond(with: payload.subdata(in: offset..<(offset + chunk)))
                    offset += chunk
                    Thread.sleep(forTimeInterval: 0.03)
                }
                loadingRequest.finishLoading()
            }
            return true
        }

        func resourceLoader(
            _ resourceLoader: AVAssetResourceLoader,
            didCancel loadingRequest: AVAssetResourceLoadingRequest
        ) {
            lock.withLock { _ = cancelled.insert(ObjectIdentifier(loadingRequest)) }
        }
    }

    /// The finding: playback and seeking with nothing listening.
    ///
    /// What it costs, so nobody has to re-derive it: the muxed shape carries
    /// one audio track and no subtitle renditions — those live in a master
    /// playlist this route does not have (an fMP4 can carry both as tracks,
    /// but the muxer does not build it that way today). Unmeasured: Dolby
    /// Vision and Atmos signalling without the master's `SUPPLEMENTAL-CODECS`
    /// and `CHANNELS`, which would have to be read from the sample entries
    /// instead; and whether a demand-produced source can answer a seek at all,
    /// since a byte offset in unproduced output is a byte offset nothing can
    /// map. Produced output has no such problem — every fragment's size is
    /// known once it exists.
    @Test("A progressive fMP4 through the delegate plays and seeks, no socket",
          arguments: ["h264_aac_30s.mkv", "h264_ac3_51_20s.mkv"])
    func progressiveFMP4PlaysAndSeeks(_ name: String) async throws {
        let source = try PrismCoreSession(url: try fixture(name))
        // The muxed shape puts video and the best audio in one variant, so its
        // fragments concatenate into a single playable fMP4.
        let session = try await source.makeMuxedFallbackSession()
        let served = try await session.start()
        let base = served.deletingLastPathComponent()
        let workDirectory = await session.workDirectory
        let playlist = workDirectory.appendingPathComponent("index.m3u8")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if (try? String(contentsOf: playlist, encoding: .utf8))?
                .contains("#EXT-X-ENDLIST") == true { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        // Production is demand-driven — a segment exists once something asks
        // for it. Ask over the session's own server: that is production, not
        // playback, and the player below never sees a socket.
        var payload = Data()
        for piece in Self.pieces(inMediaPlaylist: try String(contentsOf: playlist, encoding: .utf8)) {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent(piece))
            payload.append(data)
        }
        await session.stop()
        await source.stop()
        try #require(payload.count > 0)

        let loader = ByteRangeLoader(payload: payload)
        let asset = AVURLAsset(url: URL(string: "prism://local/movie.mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: .global())
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        // The trickle never looks like a fast source, and the header quoted in
        // #52 is precisely about this flag: left on, the player waits for a
        // buffer it thinks will not stall and simply sits there.
        player.automaticallyWaitsToMinimizeStalling = false

        let status = await settledStatus(item, timeout: 15)
        try #require(
            status == .readyToPlay,
            "progressive fMP4 refused (\(status.rawValue), \(String(describing: item.error)))"
        )

        // Playback first, from the head: the clock moving is what "plays"
        // means, and it is the one thing no amount of range bookkeeping
        // proves.
        player.play()
        try? await Task.sleep(for: .milliseconds(1500))
        let played = CMTimeGetSeconds(player.currentTime())
        #expect(played > 0.3, "the clock never moved (at \(played))")

        // Then the seek. What is asserted is that it landed and that data
        // arrived at the destination — not that the clock ticks again within
        // some wall-clock window, which under a deliberately throttled feed
        // would be asserting the throttle's speed rather than the mechanism.
        let target = CMTime(seconds: 12, preferredTimescale: 600)
        let seeked = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(seeked)
        #expect(abs(CMTimeGetSeconds(player.currentTime()) - 12) < 0.5)
        try? await Task.sleep(for: .milliseconds(1500))
        let loadedPastTarget = item.loadedTimeRanges.contains {
            let range = $0.timeRangeValue
            return range.start <= target && CMTimeRangeGetEnd(range) > target
        }
        #expect(loadedPastTarget,
                "nothing was buffered at the seek target: \(item.loadedTimeRanges.map(\.timeRangeValue))")
        player.pause()

        // The point of the trickle: a seek must ask for bytes the delegate has
        // not delivered, and AVFoundation must answer that by *asking for an
        // offset* rather than reading everything in between. It does.
        #expect(
            loader.requestedOffsets.contains { $0 > 0 },
            "no mid-asset range was ever requested — offsets: \(loader.requestedOffsets)"
        )
    }

    /// Init segment plus fragments, in playlist order: that concatenation is
    /// the fMP4.
    private static func pieces(inMediaPlaylist text: String) -> [String] {
        var pieces: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let entry = String(line)
            if entry.hasPrefix("#EXT-X-MAP:"),
               let range = entry.range(of: #"URI="([^"]*)""#, options: .regularExpression) {
                pieces.append(String(entry[range].dropFirst(5).dropLast()))
            } else if !entry.hasPrefix("#"), !entry.isEmpty {
                pieces.append(entry)
            }
        }
        return pieces
    }

    // MARK: - Helpers

    /// Copy the produced output only: a whole-directory copy races the
    /// writer's temp-then-rename files, which are gone by the time copyfile
    /// reaches them.
    private func copyOutput(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let wanted: Set<String> = ["m3u8", "mp4", "m4s", "vtt"]
        // Resolved on both sides: the enumerator answers /private/var where
        // the work directory says /var, and that difference silently turns
        // every relative path into an absolute one.
        let root = source.resolvingSymlinksInPath().path
        guard let walk = manager.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for case let url as URL in walk {
            let relative = url.resolvingSymlinksInPath().path
                .replacingOccurrences(of: root + "/", with: "")
            let target = destination.appendingPathComponent(relative)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
            } else if wanted.contains(url.pathExtension) {
                try? manager.copyItem(at: url, to: target)
            }
        }
    }

    private func waitForCompletedWorkDirectory(
        _ directory: URL, timeout: Duration = .seconds(30)
    ) async throws {
        let master = directory.appendingPathComponent("master.m3u8")
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: master, encoding: .utf8) {
                let mediaPlaylists = PrismCoreSession.playlistURIs(inMaster: text)
                    .map { directory.appendingPathComponent($0) }
                let allEnded = !mediaPlaylists.isEmpty && mediaPlaylists.allSatisfy {
                    (try? String(contentsOf: $0, encoding: .utf8))?
                        .contains("#EXT-X-ENDLIST") == true
                }
                if allEnded { return }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw PrismCoreSession.SessionError.startupTimedOut(underlying: nil)
    }

    private func settledStatus(
        _ item: AVPlayerItem, timeout: TimeInterval
    ) async -> AVPlayerItem.Status {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                if item.status != .unknown {
                    once.run { continuation.resume(returning: item.status) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                _ = observation
                once.run { continuation.resume(returning: .unknown) }
            }
        }
    }
}
