import Testing
import Libavutil
@testable import PrismCore

@Suite("Source open options")
struct SourceOpenTuningTests {
    @Test("A silent origin times a read out instead of stalling it forever")
    func readsTimeOut() throws {
        var options = SourceOpenTuning.makeOptions(httpHeaders: [:])
        defer { av_dict_free(&options) }
        let entry = try #require(av_dict_get(options, "rw_timeout", nil, 0))
        #expect(String(cString: entry.pointee.value) == "15000000")
    }
}
