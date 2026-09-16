import Foundation

/// Tolerant matching of a host's preferred language against the language tags
/// a container actually carries.
///
/// Containers are a mess about this. The same language reaches us as ISO
/// 639-2/B (`cze`), 639-2/T (`ces`), 639-1 (`cs`), with a region (`pt-BR`),
/// with a script (`zh-Hant`), uppercased, underscored (`pt_BR`), empty, or
/// `und`. A host that asks for "cs" means all of the first three.
///
/// **Foundation can answer this honestly, so there is no table here.**
/// `Locale.canonicalLanguageIdentifier(from:)` folds every case above —
/// verified by probe on this toolchain (macOS 27, Swift 6):
/// `cze`/`CZE`/`Cze` → `cs`, `ger` → `de`, `alb` → `sq`, `dut` → `nl`,
/// `pt_BR`/`PT-br` → `pt-BR`, `cs-cz` → `cs-CZ`, `zh-cmn-Hant` → `zh-Hant`,
/// and it leaves `und` and unknown tags alone instead of guessing.
///
/// The trap that made this comment worth writing: the *obvious* route,
/// `Locale.Language(identifier: "cze").languageCode?.identifier(.alpha2)`,
/// returns **nil** — `Locale.Language` does not fold bibliographic codes at
/// all, so a matcher built on it silently fails to match exactly the tags
/// (`cze`, `ger`, `fre`, `dut`) that made tolerant matching necessary.
public enum LanguageMatch {

    /// The canonical form of a container tag, or `nil` when the tag names no
    /// language.
    ///
    /// `und` — the container saying it does not know — is deliberately not a
    /// language: matching it would let a host's preference land on a track
    /// whose language nobody ever claimed.
    public static func canonical(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let canonical = Locale.canonicalLanguageIdentifier(from: trimmed)
        guard !canonical.isEmpty, canonical.lowercased() != "und" else { return nil }
        return canonical
    }

    /// How well `candidate` answers `preferred`: `2` for an exact match
    /// (including region and script), `1` for the bare language alone, `0` for
    /// no match at all.
    ///
    /// Two levels rather than one because `pt-BR` and `pt` are both answers to
    /// "Portuguese" and only one of them is the right one — the caller takes
    /// the highest score, so an exact region match wins whenever it exists and
    /// a bare `pt` is still better than nothing.
    public static func score(preferred: String?, candidate: String?) -> Int {
        guard let want = canonical(preferred), let have = canonical(candidate) else { return 0 }
        if want.caseInsensitiveCompare(have) == .orderedSame { return 2 }
        return primarySubtag(want) == primarySubtag(have) ? 1 : 0
    }

    /// Index of the element that best answers `preferred`, or `nil` when
    /// nothing does — which is the whole no-match contract: the caller then
    /// changes nothing and the source's own default stands.
    ///
    /// `bonus` breaks ties between equally good language matches (higher
    /// wins). It can never rescue an element the language rejected, so a
    /// preference can only ever reorder within the language it asked for.
    /// Stable: among equals the first element wins, which keeps the source's
    /// own ordering as the final tie-break.
    static func bestIndex<Element>(
        in elements: [Element],
        preferred: String?,
        language: (Element) -> String?,
        bonus: (Element) -> Int = { _ in 0 }
    ) -> Int? {
        guard canonical(preferred) != nil else { return nil }
        var best: (index: Int, score: Int, bonus: Int)?
        for (index, element) in elements.enumerated() {
            let score = score(preferred: preferred, candidate: language(element))
            guard score > 0 else { continue }
            let extra = bonus(element)
            if let current = best, (score, extra) <= (current.score, current.bonus) { continue }
            best = (index, score, extra)
        }
        return best?.index
    }

    private static func primarySubtag(_ canonical: String) -> String {
        String(canonical.split(separator: "-").first ?? "").lowercased()
    }
}
