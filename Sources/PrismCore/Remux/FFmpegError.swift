import Foundation
import Libavformat
import Libavutil

/// A failed libav* call, carrying the FFmpeg error string.
public struct FFmpegError: Error, CustomStringConvertible {
    public let code: Int32
    public let operation: String

    /// FFmpeg's own text for `code`, without the operation wrapped around it —
    /// what `PrismCoreError.ffmpeg` carries, so a host can log the engine's
    /// verdict and the library's wording separately.
    public var message: String {
        var buffer = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }

    public var description: String {
        "\(operation) failed: \(message) (\(code))"
    }

    /// Throw when `code` is a libav* failure (negative).
    @discardableResult
    static func check(_ code: Int32, _ operation: @autoclosure () -> String) throws -> Int32 {
        guard code >= 0 else { throw FFmpegError(code: code, operation: operation()) }
        return code
    }
}

/// `AVERROR(e)` for a POSIX errno — the macro Swift can't import. On Apple
/// platforms libav* negates errno directly, which is what the header does.
func swift_AVERROR(_ errno: Int32) -> Int32 {
    -errno
}

/// `AV_NOPTS_VALUE`, another unimportable macro: the smallest int64. Compared
/// against, never arithmetic'd.
func swift_AV_NOPTS_VALUE() -> Int64 {
    Int64.min
}

/// One value out of an `AVDictionary` (a stream's or format's metadata), or
/// `nil` when the key is absent — or present and empty, which containers do
/// write and which no caller wants to treat as a language tag or a title.
func avMetadataValue(_ dictionary: OpaquePointer?, _ key: String) -> String? {
    guard let dictionary,
          let entry = av_dict_get(dictionary, key, nil, 0),
          let value = entry.pointee.value
    else { return nil }
    let text = String(cString: value)
    return text.isEmpty ? nil : text
}

/// `AV_PROFILE_UNKNOWN`, likewise a macro (`-99`).
let swift_AV_PROFILE_UNKNOWN: Int32 = -99

/// `AVERROR_EOF` is a macro Swift can't import either; recompute it the way the
/// header does: `FFERRTAG('E','O','F',' ')` negated.
///
/// This file is the one home for the unimportable-macro shims — a second
/// file-scope copy of any of them is a redeclaration the moment two features
/// need it, which is exactly how the last wave collided.
func swift_AVERROR_EOF() -> Int32 {
    let tag = (Int32(UInt8(ascii: "E"))) | (Int32(UInt8(ascii: "O")) << 8)
        | (Int32(UInt8(ascii: "F")) << 16) | (Int32(UInt8(ascii: " ")) << 24)
    return -tag
}

/// `AVERROR_EXIT` — `FFERRTAG('E','X','I','T')` negated: what an interrupted
/// read returns, and what a bounded probe reports when its budget ran out.
func swift_AVERROR_EXIT() -> Int32 {
    let tag = (Int32(UInt8(ascii: "E"))) | (Int32(UInt8(ascii: "X")) << 8)
        | (Int32(UInt8(ascii: "I")) << 16) | (Int32(UInt8(ascii: "T")) << 24)
    return -tag
}

/// `FFERRTAG(a,b,c,d)` — `MKTAG` negated, the shape every named libav* error
/// code is built from. Computed rather than pasted as four magic negative
/// integers, whose bytes nobody can check by eye.
private func ffErrorTag(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int32 {
    -(Int32(a) | (Int32(b) << 8) | (Int32(c) << 16) | (Int32(d) << 24))
}

/// The `AVERROR_HTTP_*` family. These are the only libavformat codes that
/// report an origin's *status* rather than a symptom, which is what makes them
/// worth reconstructing: without them an expired token and a truncated file
/// both reach a host as "Input/output error".
func swift_AVERROR_HTTP_BAD_REQUEST() -> Int32 { ffErrorTag(0xF8, UInt8(ascii: "4"), UInt8(ascii: "0"), UInt8(ascii: "0")) }
func swift_AVERROR_HTTP_UNAUTHORIZED() -> Int32 { ffErrorTag(0xF8, UInt8(ascii: "4"), UInt8(ascii: "0"), UInt8(ascii: "1")) }
func swift_AVERROR_HTTP_FORBIDDEN() -> Int32 { ffErrorTag(0xF8, UInt8(ascii: "4"), UInt8(ascii: "0"), UInt8(ascii: "3")) }
func swift_AVERROR_HTTP_NOT_FOUND() -> Int32 { ffErrorTag(0xF8, UInt8(ascii: "4"), UInt8(ascii: "0"), UInt8(ascii: "4")) }
func swift_AVERROR_HTTP_TOO_MANY_REQUESTS() -> Int32 { ffErrorTag(0xF8, UInt8(ascii: "4"), UInt8(ascii: "2"), UInt8(ascii: "9")) }
func swift_AVERROR_HTTP_OTHER_4XX() -> Int32 { ffErrorTag(0xF8, UInt8(ascii: "4"), UInt8(ascii: "X"), UInt8(ascii: "X")) }
func swift_AVERROR_HTTP_SERVER_ERROR() -> Int32 { ffErrorTag(0xF8, UInt8(ascii: "5"), UInt8(ascii: "X"), UInt8(ascii: "X")) }
