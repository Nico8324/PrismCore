import Foundation

/// Walks and rewrites the NAL units inside a length-prefixed HEVC packet — the
/// form libavformat's mov and matroska demuxers hand us (`hvcC`-style: each NAL
/// preceded by a 1/2/4-byte big-endian length, never Annex-B start codes).
///
/// Pure and allocation-conscious: the RPU rewrite this exists for runs on **every
/// video packet** of a Profile 7 source, so the no-change path must not copy the
/// packet, and the change path must copy it exactly once.
enum HEVCNALUnits {

    /// One NAL unit, as the rewriter sees it.
    struct Unit {
        /// `nal_unit_type`: 32 VPS, 33 SPS, 34 PPS, 39/40 SEI, 62 the
        /// unspecified type Dolby Vision carries its RPU in.
        let type: UInt8
        /// `nuh_layer_id`. Non-zero means a layered carriage, which no Apple
        /// decoder will take — but it is NOT how an interleaved Profile 7
        /// stream carries its enhancement layer: there the EL is `unspec63`
        /// (see `type`) and sits on layer 0 like everything else. Reading the
        /// dual layer off this field is the bug that shipped the EL inside a
        /// stream declared single-layer 8.1.
        let layerID: UInt8
        /// The whole NAL unit including its two-byte header, without the length
        /// prefix. A view into the caller's buffer: valid for the duration of
        /// the transform call only (or, for the array overloads, of the array).
        let bytes: UnsafeBufferPointer<UInt8>
    }

    /// `lengthSizeMinusOne + 1` out of an `hvcC` record: how many bytes each NAL
    /// length prefix occupies. Returns `nil` for a record too short to ask.
    static func lengthSize(fromHVCC data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count > 21, bytes[0] == 1 else { return nil }
        return Int(bytes[21] & 0x03) + 1
    }

    /// Every NAL unit in the packet, or `nil` if the lengths don't frame it
    /// exactly (a truncated packet, or Annex-B data misread as length-prefixed).
    ///
    /// Framing failure has to be `nil` rather than best-effort: a partially
    /// parsed packet rewritten back would splice garbage into the bitstream,
    /// where leaving the packet untouched merely leaves the RPU unconverted.
    static func units(in bytes: [UInt8], lengthSize: Int) -> [Unit]? {
        bytes.withUnsafeBufferPointer { units(in: $0, lengthSize: lengthSize) }
    }

    /// The pointer shape: the copy loop hands the packet's own buffer in, so
    /// a Profile 7 stream's per-packet walk allocates the `[Unit]` and
    /// nothing else. The units' `bytes` alias the buffer — valid only while
    /// it is.
    static func units(in bytes: UnsafeBufferPointer<UInt8>, lengthSize: Int) -> [Unit]? {
        guard (1...4).contains(lengthSize), let base = bytes.baseAddress else { return nil }
        var units: [Unit] = []
        var cursor = 0
        let count = bytes.count
        while cursor < count {
            guard cursor + lengthSize <= count else { return nil }
            var length = 0
            for offset in 0..<lengthSize {
                length = (length << 8) | Int(base[cursor + offset])
            }
            cursor += lengthSize
            // A zero-length NAL is not a thing, and treating one as valid would
            // spin this loop forever.
            guard length > 1, cursor + length <= count else { return nil }
            let header0 = base[cursor]
            let header1 = base[cursor + 1]
            units.append(
                Unit(
                    type: (header0 >> 1) & 0x3F,
                    layerID: ((header0 & 0x01) << 5) | (header1 >> 3),
                    bytes: UnsafeBufferPointer(start: base + cursor, count: length)
                )
            )
            cursor += length
        }
        return units.isEmpty ? nil : units
    }

    /// What the rewriter should do with one NAL unit.
    enum Disposition {
        case keep
        case drop
        case replace([UInt8])
    }

    /// Rebuild a packet, passing each NAL through `transform`.
    ///
    /// Returns `nil` when every unit was kept — the caller then leaves the
    /// packet's own buffer alone, which is the hot path for every packet that
    /// carries no RPU and no enhancement layer. `.keep` is deliberately a case
    /// rather than "return the same bytes": comparing a returned array against
    /// the slice would allocate once per NAL per packet to discover nothing
    /// happened.
    static func rewrite(
        _ bytes: [UInt8],
        lengthSize: Int,
        transform: (Unit) -> Disposition
    ) -> [UInt8]? {
        bytes.withUnsafeBufferPointer { buffer -> [UInt8]? in
            // The scratch buffer is owned here, not borrowed from an Array:
            // this used to hand back `output.withUnsafeMutableBufferPointer {
            // $0.baseAddress }`, a pointer that is only valid INSIDE that
            // closure — the copy loop then wrote through it after the closure
            // had returned. Undefined behaviour that happened to work.
            //
            // `max(size, 1)` because zero-length output is legitimate: a packet
            // that was nothing but enhancement layer and RPU leaves nothing
            // behind. An empty `Array`'s `baseAddress` may be nil, which the
            // copy loop would read as "could not allocate" and report as a
            // refusal — while the production allocator (`av_buffer_alloc` plus
            // padding) succeeds. The two shapes have to agree, because the
            // converter's stale accounting reads that refusal.
            var scratch: UnsafeMutablePointer<UInt8>?
            var writtenBytes = 0
            defer { scratch?.deallocate() }
            let didWrite = rewrite(buffer, lengthSize: lengthSize, transform: transform) { size in
                let allocation = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 1))
                scratch = allocation
                writtenBytes = size
                return allocation
            }
            guard didWrite, let scratch else { return nil }
            return [UInt8](UnsafeBufferPointer(start: scratch, count: writtenBytes))
        }
    }

    /// The pointer shape, writing the result into a buffer the caller
    /// provides: `allocate(size)` is called at most once, only when something
    /// changed, with the exact output size — the copy loop answers it with an
    /// `av_malloc`ed buffer that is then swapped into the packet, so the
    /// rewritten payload is written exactly once and never copied. Returns
    /// `false` (and never calls `allocate`) when every unit was kept, or the
    /// packet did not frame; `true` once the output has been written.
    ///
    /// `allocate` returning `nil` means "could not allocate": the packet is
    /// then left alone, exactly like a framing failure.
    static func rewrite(
        _ bytes: UnsafeBufferPointer<UInt8>,
        lengthSize: Int,
        transform: (Unit) -> Disposition,
        into allocate: (Int) -> UnsafeMutablePointer<UInt8>?
    ) -> Bool {
        guard let units = units(in: bytes, lengthSize: lengthSize) else { return false }

        var dispositions: [Disposition] = []
        dispositions.reserveCapacity(units.count)
        var changed = false
        var outputSize = 0
        for unit in units {
            let disposition = transform(unit)
            switch disposition {
            case .keep:
                outputSize += lengthSize + unit.bytes.count
            case .drop:
                changed = true
            case .replace(let replacement):
                changed = true
                if !replacement.isEmpty { outputSize += lengthSize + replacement.count }
            }
            dispositions.append(disposition)
        }
        guard changed, let output = allocate(outputSize) else { return false }

        var cursor = 0
        func append(length: Int) {
            for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) {
                output[cursor] = UInt8((length >> shift) & 0xFF)
                cursor += 1
            }
        }
        for (unit, disposition) in zip(units, dispositions) {
            switch disposition {
            case .keep:
                append(length: unit.bytes.count)
                if let base = unit.bytes.baseAddress {
                    (output + cursor).update(from: base, count: unit.bytes.count)
                }
                cursor += unit.bytes.count
            case .drop:
                continue
            case .replace(let replacement):
                guard !replacement.isEmpty else { continue }
                append(length: replacement.count)
                replacement.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress {
                        (output + cursor).update(from: base, count: source.count)
                    }
                }
                cursor += replacement.count
            }
        }
        return true
    }

    // MARK: - Read-only walks (H.264 framing, Annex-B carriage)

    /// Which codec's NAL header the walk should read. The *framing* is shared;
    /// only the header differs — H.264 spends one byte (`nal_unit_type` in the
    /// low 5 bits), HEVC two (type in bits 6…1 of the first).
    enum Codec {
        case h264
        case hevc

        /// Bytes of NAL header before the payload.
        var headerSize: Int { self == .h264 ? 1 : 2 }
    }

    /// How the units are delimited inside one packet.
    enum Framing: Equatable {
        /// `avcC` / `hvcC` carriage: a big-endian length before each unit.
        /// What the mov and matroska demuxers hand us.
        case lengthPrefixed(Int)
        /// Annex-B start codes (`00 00 01`, optionally with a leading `00`) —
        /// what the MPEG-TS demuxer hands us, and the form most captioned
        /// broadcast recordings arrive in. A video stream with no
        /// `avcC`/`hvcC` extradata is exactly this case, which is how the
        /// caller picks between the two.
        case annexB
    }

    /// Visit every NAL unit of a packet without allocating.
    ///
    /// Deliberately **best-effort**, unlike `units(in:lengthSize:)`: that one
    /// returns `nil` on a framing mismatch because its caller rewrites the
    /// packet, and a half-parsed rewrite splices garbage into the bitstream.
    /// This walk only reads — the worst a mis-framed packet can do is yield no
    /// captions for one frame — so it stops at the damage instead of
    /// discarding the units it had already framed correctly.
    ///
    /// `visit` receives the `nal_unit_type` and the payload **after** the NAL
    /// header, still carrying its emulation-prevention bytes.
    static func scan(
        _ bytes: UnsafeBufferPointer<UInt8>,
        framing: Framing,
        codec: Codec,
        visit: (UInt8, UnsafeBufferPointer<UInt8>) -> Void
    ) {
        guard let base = bytes.baseAddress else { return }
        let count = bytes.count
        let headerSize = codec.headerSize

        func emit(offset: Int, length: Int) {
            guard length > headerSize else { return }
            let type = codec == .h264 ? (base[offset] & 0x1F) : ((base[offset] >> 1) & 0x3F)
            visit(
                type,
                UnsafeBufferPointer(start: base + offset + headerSize, count: length - headerSize)
            )
        }

        switch framing {
        case .lengthPrefixed(let lengthSize):
            guard (1...4).contains(lengthSize) else { return }
            var cursor = 0
            while cursor + lengthSize <= count {
                var length = 0
                for offset in 0..<lengthSize {
                    length = (length << 8) | Int(base[cursor + offset])
                }
                cursor += lengthSize
                // A zero length would spin this loop forever; a length past the
                // end is a truncated packet, and the units before it stand.
                guard length > 0, cursor + length <= count else { return }
                emit(offset: cursor, length: length)
                cursor += length
            }

        case .annexB:
            var cursor = 0
            var unitStart: Int?
            while cursor + 2 < count {
                guard base[cursor] == 0, base[cursor + 1] == 0, base[cursor + 2] == 1 else {
                    cursor += 1
                    continue
                }
                if let start = unitStart {
                    // The leading zero of a four-byte start code belongs to the
                    // start code, not to the unit before it. Counting it in
                    // hands the SEI parser a trailing zero byte, which reads as
                    // another payload type and walks off the end of the message.
                    var end = cursor
                    while end > start, base[end - 1] == 0 { end -= 1 }
                    emit(offset: start, length: end - start)
                }
                cursor += 3
                unitStart = cursor
            }
            if let start = unitStart, start < count {
                emit(offset: start, length: count - start)
            }
        }
    }
}
