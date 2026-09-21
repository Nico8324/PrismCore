import Testing
import Foundation
@testable import PrismCore

@Suite("LoopbackHTTPServer")
struct LoopbackHTTPServerTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Serves a file with the right type, length, and bytes")
    func servesFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("#EXTM3U\n#EXT-X-VERSION:7\n".utf8)
        try payload.write(to: root.appendingPathComponent("index.m3u8"))

        let server = LoopbackHTTPServer(root: root)
        let base = try await server.start()
        defer { Task { await server.stop() } }

        let (data, response) = try await URLSession.uncached.data(
            from: base.appendingPathComponent("index.m3u8")
        )
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(data == payload)
    }

    @Test("Missing files 404; traversal is refused")
    func missingAndTraversal() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let server = LoopbackHTTPServer(root: root)
        let base = try await server.start()
        defer { Task { await server.stop() } }

        let (_, missing) = try await URLSession.uncached.data(from: base.appendingPathComponent("nope.m4s"))
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)

        var traversal = URLRequest(url: base)
        traversal.url = URL(string: "http://127.0.0.1:\(await server.port)/../secret")
        let (_, escaped) = try await URLSession.uncached.data(for: traversal)
        #expect((escaped as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("Segment content types map by extension")
    func contentTypes() {
        #expect(LoopbackHTTPServer.contentType(for: URL(fileURLWithPath: "/x/seg1.m4s")) == "video/mp4")
        #expect(LoopbackHTTPServer.contentType(for: URL(fileURLWithPath: "/x/init.mp4")) == "video/mp4")
        #expect(LoopbackHTTPServer.contentType(for: URL(fileURLWithPath: "/x/a.vtt")) == "text/vtt")
        #expect(LoopbackHTTPServer.contentType(for: URL(fileURLWithPath: "/x/other.bin")) == "application/octet-stream")
    }
}

@Suite("FFmpeg plumbing")
struct FFmpegPlumbingTests {

    @Test("AVERROR_EOF reconstruction matches FFERRTAG('E','O','F',' ')")
    func eofTag() {
        // -0x20464F45 little-endian 'EOF ' — the value ffmpeg's error.h defines.
        #expect(swift_AVERROR_EOF() == -0x20464F45)
    }

    @Test("FFmpegError describes the failed operation")
    func errorDescription() {
        let error = FFmpegError(code: swift_AVERROR_EOF(), operation: "av_read_frame")
        #expect(error.description.contains("av_read_frame"))
        #expect(error.description.lowercased().contains("end of file"))
    }
}
