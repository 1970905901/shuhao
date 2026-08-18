import Foundation

/// Lyric timing tweaks shared by the in-app lyric view and the CarPlay / lock-screen line.
nonisolated enum LyricSync {
    /// How far ahead of the vocal each line is shown. The now-playing info center and CarPlay
    /// add their own render latency, so we look ahead a bit to land the line on screen *as* the
    /// singer reaches it ("先出歌词") — kept small so a line never scrolls away before it's sung.
    static let leadSeconds: Double = 0.5
}

nonisolated struct LyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let time: Double
    let text: String
    let translation: String?
}

nonisolated enum LRCParser {
    /// Parse standard LRC text into time-sorted lines. Combines main lyrics with translation `tlyric` if present.
    static func parse(_ raw: String, translation: String? = nil) -> [LyricLine] {
        let main = parseLines(raw)
        let trans = translation.map { parseLines($0) } ?? []
        let transMap: [Int: String] = Dictionary(uniqueKeysWithValues: trans.map { (Int($0.time * 100), $0.text) })

        var lines: [LyricLine] = []
        var nextID = 0
        for l in main {
            let key = Int(l.time * 100)
            let tr = transMap[key]
            lines.append(LyricLine(id: nextID, time: l.time, text: l.text, translation: tr))
            nextID += 1
        }
        if lines.isEmpty {
            let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
                                .replacingOccurrences(of: "\r", with: "\n")
            for chunk in normalised.split(separator: "\n", omittingEmptySubsequences: true) {
                lines.append(LyricLine(id: nextID, time: -1, text: String(chunk).trimmingCharacters(in: .whitespaces), translation: nil))
                nextID += 1
            }
        }
        return lines
    }

    private struct ParsedLine { let time: Double; let text: String }

    private static let timeTagRegex = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:[\.:](\d{1,3}))?\]"#)

    private static func parseLines(_ raw: String) -> [ParsedLine] {
        var out: [ParsedLine] = []
        // CRITICAL: Swift treats `\r\n` as a single extended-grapheme `Character`, so
        // `raw.split(separator: "\n")` silently fails when the lyric has CRLF endings
        // (Kugou's LRC does). Normalise first.
        let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalised.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let ns = line as NSString
            let matches = timeTagRegex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            // Text is the remainder after the last timestamp tag.
            let last = matches.last!
            let textStart = last.range.location + last.range.length
            let text: String
            if textStart < ns.length {
                text = ns.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            } else {
                text = ""
            }
            for m in matches {
                let mins = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let secs = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var msStr = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : "0"
                if msStr.count == 2 { msStr += "0" }
                let ms = Double(msStr) ?? 0
                let time = mins * 60 + secs + ms / 1000
                out.append(ParsedLine(time: time, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Find the index of the active line at `time`. Returns nil if none yet.
    static func activeIndex(at time: Double, in lines: [LyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans >= 0 ? ans : nil
    }
}

/// Lyrics fetcher — uses a loaded JS source's `lyric` action when available; falls back to source-specific HTTP endpoints.
@MainActor
final class LyricsFetcher {
    static let shared = LyricsFetcher()
    private var cache: [String: [LyricLine]] = [:]

    /// 已下载歌曲的本地文件里嵌入了 LRC(下载时写入的)。AppServices 注入,
    /// 返回嵌入的原始 LRC 文本;非下载歌曲/读不到返回 nil。
    var localLyricsProvider: ((Track) async -> String?)?

    func fetch(for track: Track, sources: SourceManager) async -> [LyricLine] {
        if let hit = cache[track.id] {
            print("[Lyrics] cache hit for \(track.id) (\(hit.count) lines, first: \"\(hit.first?.text ?? "")\")")
            return hit
        }
        // 已下载的歌优先读文件内嵌歌词 —— 离线可用,而且就是下载时拉到的同一份。
        if let raw = await localLyricsProvider?(track), !raw.isEmpty {
            let lines = Self.mergeSameTimeTranslations(LRCParser.parse(raw))
            if !lines.isEmpty {
                print("[Lyrics] from embedded file: \(lines.count) lines for \(track.id)")
                cache[track.id] = lines
                return lines
            }
        }
        // Try user script first
        if let lines = await tryScript(track: track, sources: sources) {
            print("[Lyrics] from script: \(lines.count) lines, first 3: \(lines.prefix(3).map { $0.text })")
            cache[track.id] = lines
            return lines
        }
        // Fallback by source
        if let lines = await tryFallback(track: track) {
            print("[Lyrics] from fallback: \(lines.count) lines, first 3: \(lines.prefix(3).map { $0.text })")
            cache[track.id] = lines
            return lines
        }
        // Cross-source: borrow lyrics from the same song on another platform (same name+singer,
        // duration within 10s). Cached under the *original* track id so it sticks next time.
        if let lines = await tryOtherSources(track: track, sources: sources) {
            print("[Lyrics] from other-source: \(lines.count) lines, first 3: \(lines.prefix(3).map { $0.text })")
            cache[track.id] = lines
            return lines
        }
        print("[Lyrics] no lyric for \(track.id)")
        return []
    }

    private func tryScript(track: Track, sources: SourceManager) async -> [LyricLine]? {
        do {
            let result = try await sources.requestLyric(track: track)
            if let dict = result as? [String: Any] {
                let lyric = (dict["lyric"] as? String) ?? ""
                let tlyric = dict["tlyric"] as? String
                let parsed = LRCParser.parse(lyric, translation: tlyric)
                return parsed.isEmpty ? nil : parsed
            }
        } catch {
            print("[Lyrics] script lyric failed: \(error.localizedDescription)")
        }
        return nil
    }

    /// Find the same song on other platforms and borrow its lyrics. Tries each candidate's
    /// direct lyric API first (most reliable), then its script. Duration must be within 10s.
    private func tryOtherSources(track: Track, sources: SourceManager) async -> [LyricLine]? {
        let candidates = await OtherSourceFinder.findMatches(for: track, maxIntervalDiff: 10)
        for alt in candidates.prefix(4) {
            // findMatches already filters by interval, but double-check when both have durations.
            if let d1 = track.duration, let d2 = alt.duration, d1 > 0, d2 > 0, abs(d1 - d2) > 10 { continue }
            if let lines = await tryFallback(track: alt) {
                print("[Lyrics] cross-source hit \(alt.source.rawValue)/\(alt.songmid) (\(alt.name) - \(alt.singer))")
                return lines
            }
            if let lines = await tryScript(track: alt, sources: sources) {
                print("[Lyrics] cross-source hit (script) \(alt.source.rawValue)/\(alt.songmid)")
                return lines
            }
        }
        return nil
    }

    private func tryFallback(track: Track) async -> [LyricLine]? {
        switch track.source {
        case .kw: return await BuiltInLyricResolver.kuwo(songmid: track.songmid)
        case .tx: return await BuiltInLyricResolver.qq(songmid: track.songmid)
        case .wy: return await BuiltInLyricResolver.netease(songmid: track.songmid)
        case .kg:
            // Kugou wants (name, hash, durationMs) to find the right candidate.
            return await BuiltInLyricResolver.kugou(
                name: track.name,
                hash: track.extras["hash"] ?? track.songmid,
                durationMs: (track.duration ?? 0) * 1000
            )
        default: return nil
        }
    }

    /// LRCSerializer 写翻译时用的是"同一时间戳再写一行"。读回来时把同时间戳的
    /// 相邻两行合并回 原文 + translation,跟在线获取的结构保持一致。
    nonisolated static func mergeSameTimeTranslations(_ lines: [LyricLine]) -> [LyricLine] {
        var out: [LyricLine] = []
        var i = 0
        var nextID = 0
        while i < lines.count {
            let cur = lines[i]
            if cur.time >= 0, cur.translation == nil, i + 1 < lines.count,
               lines[i + 1].time == cur.time, !cur.text.isEmpty, !lines[i + 1].text.isEmpty {
                out.append(LyricLine(id: nextID, time: cur.time, text: cur.text, translation: lines[i + 1].text))
                i += 2
            } else {
                out.append(LyricLine(id: nextID, time: cur.time, text: cur.text, translation: cur.translation))
                i += 1
            }
            nextID += 1
        }
        return out
    }

    func clear() { cache.removeAll() }

    func injectCache(_ lines: [LyricLine], for trackID: String) {
        cache[trackID] = lines
    }
}
