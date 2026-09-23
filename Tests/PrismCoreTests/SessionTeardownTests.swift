import Testing
import Foundation
@testable import PrismCore

@Suite("Session teardown outside the happy path")
struct SessionTeardownTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("A session stopped before it started refuses to start")
    func stopBeforeStart() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        let directory = await session.workDirectory
        await session.stop()
        await #expect(throws: CancellationError.self) { try await session.start() }
        // Nothing came up behind the refusal to write into it.
        #expect(await eventually { !FileManager.default.fileExists(atPath: directory.path) })
    }

    @Test("A started session released without stop() removes its segments")
    func releasedWithoutStop() async throws {
        var session: PrismCoreSession? = try PrismCoreSession(url: try fixture("h264_aac.mkv"))
        _ = try await session!.start()
        let directory = await session!.workDirectory
        #expect(FileManager.default.fileExists(atPath: directory.path))
        session = nil
        #expect(await eventually { !FileManager.default.fileExists(atPath: directory.path) })
    }
}
