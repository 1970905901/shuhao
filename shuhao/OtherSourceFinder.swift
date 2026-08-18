import Foundation

/// Implements lx-music-mobile's "换源播放" (cross-source fallback) mechanism.
/// Mirrors `findMusic` + `getOnlineOtherSourceMusicUrl` in lx-music-mobile:
///   src/utils/musicSdk/index.js
///   src/core/music/utils.ts
///
/// When the script can't resolve a song on its native source (e.g. mg has no backend support,
/// or kg has a song not in the API server), we search the same name+singer on every OTHER
/// platform and try to resolve there. First playable URL wins.
nonisolated enum OtherSourceFinder {

    /// Searches all platforms (except the original source) for songs matching `track`'s
    /// name + singer, ranks them via the same algorithm as official `findMusic`.
    /// `maxIntervalDiff` is the allowed duration gap (seconds) for two tracks to count as the same
    /// song — 5s for playback fallback, looser (e.g. 10s) when borrowing lyrics.
    static func findMatches(for track: Track, maxIntervalDiff: Int = 5) async -> [Track] {
        let query = "\(track.name) \(track.singer)".trimmingCharacters(in: .whitespaces)
        var groups: [SourceID: [Track]] = [:]
        await withTaskGroup(of: (SourceID, [Track]).self) { group in
            for svc in Catalogs.all where svc.source != track.source {
                group.addTask {
                    let result = (try? await svc.search(keyword: query, page: 1)) ?? []
                    return (svc.source, result)
                }
            }
            for await (src, tracks) in group { groups[src] = tracks }
        }
        return rank(groups: groups, against: track, maxIntervalDiff: maxIntervalDiff)
    }

    // MARK: - Matching / ranking — mirrors `findMusic` in musicSdk/index.js#L73-167

    private static let singersRxp = try! NSRegularExpression(pattern: "[、&;；/,，|]")
    private static let dropCharsRxp = try! NSRegularExpression(pattern: #"[\s'.,，&"、()（）`~\-<>|/\[\]!！]"#)

    private static func sortSingle(_ singer: String) -> String {
        let range = NSRange(location: 0, length: (singer as NSString).length)
        let hasMulti = singersRxp.firstMatch(in: singer, range: range) != nil
        if !hasMulti { return singer }
        let parts = singersRxp.stringByReplacingMatches(in: singer, range: range, withTemplate: "、")
            .split(separator: "、").map(String.init)
        return parts.sorted().joined(separator: "、")
    }
    private static func filterStr(_ s: String) -> String {
        let ns = s as NSString
        return dropCharsRxp.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
    private static func getInterval(_ secs: Int?) -> Int { secs ?? 0 }

    /// Ranks candidates by similarity to target. Returns flat list, best matches first.
    private static func rank(groups: [SourceID: [Track]], against target: Track, maxIntervalDiff: Int) -> [Track] {
        let fName = filterStr(target.name).lowercased()
        let fSinger = filterStr(sortSingle(target.singer)).lowercased()
        let fAlbum = filterStr(target.albumName ?? "").lowercased()
        let fInterval = getInterval(target.duration)
        let isEqualsInterval: (Int) -> Bool = { intv in
            abs((fInterval == 0 ? intv : fInterval) - (intv == 0 ? fInterval : intv)) <= maxIntervalDiff
        }
        let isIncludesName: (String) -> Bool = { name in
            fName.contains(name) || name.contains(fName)
        }
        let isIncludesSinger: (String) -> Bool = { singer in
            fSinger.isEmpty ? true : (fSinger.contains(singer) || singer.contains(fSinger))
        }
        let isEqualsAlbum: (String) -> Bool = { album in
            fAlbum.isEmpty ? true : fAlbum == album
        }

        // Phase 1: per-source pick — first item satisfying various criteria.
        struct Annotated {
            var track: Track
            var fName: String
            var fSinger: String
            var fAlbum: String
            var fInterval: Int
        }
        var picked: [Annotated] = []
        for (_, list) in groups {
            let annotated: [Annotated] = list.map { t in
                Annotated(
                    track: t,
                    fName: filterStr(t.name).lowercased(),
                    fSinger: filterStr(sortSingle(t.singer)).lowercased(),
                    fAlbum: filterStr(t.albumName ?? "").lowercased(),
                    fInterval: getInterval(t.duration)
                )
            }
            // Drop items whose interval is too far off (matches official `item.name = null`).
            let intervalOk = annotated.filter { isEqualsInterval($0.fInterval) }

            // 1) exact name + singer-includes match (interval-filtered)
            if let hit = intervalOk.first(where: { $0.fName == fName && isIncludesSinger($0.fSinger) }) {
                picked.append(hit); continue
            }
            // 2) exact singer + name-includes match
            if let hit = intervalOk.first(where: { $0.fSinger == fSinger && isIncludesName($0.fName) }) {
                picked.append(hit); continue
            }
            // 3) album equal + singer-includes + name-includes
            if let hit = intervalOk.first(where: { isEqualsAlbum($0.fAlbum) && isIncludesSinger($0.fSinger) && isIncludesName($0.fName) }) {
                picked.append(hit); continue
            }
        }
        if picked.isEmpty { return [] }

        // Phase 2: cascade-rank the picked set into buckets, best first.
        let predicates: [(Annotated) -> Bool] = [
            { $0.fSinger == fSinger && $0.fName == fName && isEqualsInterval($0.fInterval) },
            { $0.fName == fName && $0.fSinger == fSinger && $0.fAlbum == fAlbum },
            { $0.fSinger == fSinger && $0.fName == fName },
            { $0.fName == fName && isEqualsInterval($0.fInterval) },
            { $0.fSinger == fSinger && isEqualsInterval($0.fInterval) },
            { isEqualsInterval($0.fInterval) },
            { $0.fName == fName },
            { $0.fSinger == fSinger },
            { $0.fAlbum == fAlbum },
        ]

        var remaining = picked
        var out: [Track] = []
        for pred in predicates {
            let matched = remaining.filter(pred)
            out.append(contentsOf: matched.map { $0.track })
            remaining.removeAll { item in matched.contains { $0.track.id == item.track.id } }
        }
        // Append leftovers
        out.append(contentsOf: remaining.map { $0.track })
        return out
    }
}
