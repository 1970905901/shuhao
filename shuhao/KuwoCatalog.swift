import Foundation

/// Built-in search via Kuwo's public mobile API.
/// Mirrors lx-music-mobile/src/utils/musicSdk/kw/musicSearch.js — same URL, same parsing.
nonisolated enum KuwoCatalog {

    enum CatalogError: LocalizedError {
        case badResponse
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "解析搜索结果失败"
            case .http(let c): return "HTTP \(c)"
            }
        }
    }

    static func search(keyword: String, page: Int = 1, pageSize: Int = 30) async throws -> [Track] {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        // URL copied verbatim from lx-music-mobile/src/utils/musicSdk/kw/musicSearch.js#L17
        let urlStr = "http://search.kuwo.cn/r.s?client=kt&all=\(encoded)&pn=\(page - 1)&rn=\(pageSize)&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1"
        guard let url = URL(string: urlStr) else { return [] }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CatalogError.badResponse }
        return parseResults(text)
    }

    private static func parseResults(_ text: String) -> [Track] {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let absList = json["abslist"] as? [[String: Any]] {
            return absList.compactMap(buildTrack)
        }
        return tolerantParse(text)
    }

    private static let mInfoRegex = try! NSRegularExpression(pattern: #"level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)"#)

    /// Mirrors lx-music-mobile kw/musicSearch.js#handleResult — parses N_MINFO into qualities.
    private static func buildTrack(_ d: [String: Any]) -> Track? {
        let mid = (d["MUSICRID"] as? String) ?? ""
        let songmid = mid.replacingOccurrences(of: "MUSIC_", with: "")
        guard !songmid.isEmpty else { return nil }
        let name = (d["SONGNAME"] as? String) ?? "未知"
        let artist = (d["ARTIST"] as? String) ?? ""
        let album = d["ALBUM"] as? String
        let durationStr = d["DURATION"] as? String ?? ""
        let duration = Int(durationStr)

        var qs: [Quality] = []
        if let nminfo = d["N_MINFO"] as? String {
            for chunk in nminfo.split(separator: ";") {
                let ns = String(chunk) as NSString
                guard let m = mInfoRegex.firstMatch(in: String(chunk), range: NSRange(location: 0, length: ns.length)) else { continue }
                let bitrate = ns.substring(with: m.range(at: 2))
                switch bitrate {
                case "4000": qs.append(.flac24)
                case "2000": qs.append(.flac)
                case "320":  qs.append(.k320)
                case "128":  qs.append(.k128)
                default: break
                }
            }
        }
        if qs.isEmpty { qs = [.k128] }

        let albumId = decodeName(d["ALBUMID"] as? String ?? "")
        // Kuwo: MVFLAG=="1" means the track has an MV; Kuwo's mvId is the rid
        // itself (same as songmid). Mirrors shuhao-tv's SearchCatalog behavior
        // — even though many tracks now return "0", the badge shows up for the
        // ones that still do, and MvResolver surfaces a "暂无可用 MV" toast
        // when antiserver.kuwo.cn refuses.
        var extras: [String: String] = [:]
        if (d["MVFLAG"] as? String) == "1" { extras["mvId"] = songmid }
        return Track(
            id: Track.makeID(source: .kw, songmid: songmid),
            name: decodeName(name),
            singer: formatSinger(decodeName(artist)),
            albumName: album.map(decodeName),
            albumId: albumId.isEmpty ? nil : albumId,
            source: .kw,
            songmid: songmid,
            duration: duration,
            picURL: nil,
            qualities: qs,
            extras: extras
        )
    }

    /// Lx-music's decodeName strips weird Kuwo-specific HTML entities. Kept simple here.
    private static func decodeName(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Kuwo returns "&" as singer separator sometimes; lx-music normalises to "、".
    private static func formatSinger(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "、")
    }

    private static func tolerantParse(_ text: String) -> [Track] {
        guard let range = text.range(of: "abslist:") else { return [] }
        let after = text[range.upperBound...]
        guard let start = after.firstIndex(of: "[") else { return [] }
        var depth = 0
        var end: String.Index?
        for i in after[start...].indices {
            let c = after[i]
            if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
        }
        guard let endIdx = end else { return [] }
        let body = String(after[start...endIdx])
        let strict = quoteKeys(body)
        guard let data = strict.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap(buildTrack)
    }

    private static func quoteKeys(_ raw: String) -> String {
        let pattern = #"([{,\s])([A-Za-z_][A-Za-z0-9_]*)\s*:"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return raw }
        let ns = raw as NSString
        let mutable = NSMutableString(string: raw)
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let prefix = ns.substring(with: m.range(at: 1))
            let keyName = ns.substring(with: m.range(at: 2))
            mutable.replaceCharacters(in: m.range, with: "\(prefix)\"\(keyName)\":")
        }
        return mutable as String
    }
}
