import Foundation

/// Direct lyric fetchers per platform. We use the simplest endpoints from
/// lx-music-mobile/src/utils/musicSdk/*/lyric.js, skipping the ones that need
/// AES/RSA/krc decoding so we stay dependency-free.
nonisolated enum BuiltInLyricResolver {

    // MARK: - Kuwo
    /// `m.kuwo.cn/newh5/singles/songinfoandlrc` returns `{ data: { lrclist: [{time:'12.34', lineLyric:'...'}, ...] } }`.
    /// We rebuild a standard `[mm:ss.xx]` LRC string from that.
    static func kuwo(songmid: String) async -> [LyricLine]? {
        let urlStr = "http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=\(songmid)"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let lrclist = d["lrclist"] as? [[String: Any]] else { return nil }
        var rebuilt = ""
        for item in lrclist {
            guard let timeStr = item["time"] as? String,
                  let lineText = item["lineLyric"] as? String,
                  let secs = Double(timeStr) else { continue }
            let m = Int(secs) / 60
            let s = Int(secs) % 60
            let ms = Int((secs - floor(secs)) * 100)
            rebuilt += String(format: "[%02d:%02d.%02d]%@\n", m, s, ms, lineText)
        }
        let lines = LRCParser.parse(rebuilt)
        return lines.isEmpty ? nil : lines
    }

    // MARK: - QQ Music
    /// `c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=...` returns
    /// `{ code:0, lyric: <base64 LRC>, trans: <base64 translation> }`. Body is JSON.
    static func qq(songmid: String) async -> [LyricLine]? {
        let urlStr = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(songmid)&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&platform=yqq"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 0,
              let b64 = json["lyric"] as? String,
              let raw = Data(base64Encoded: b64),
              let lrcStr = String(data: raw, encoding: .utf8) else { return nil }
        var translation: String?
        if let tb64 = json["trans"] as? String, !tb64.isEmpty,
           let traw = Data(base64Encoded: tb64), let tstr = String(data: traw, encoding: .utf8) {
            translation = tstr
        }
        let lines = LRCParser.parse(lrcStr, translation: translation)
        return lines.isEmpty ? nil : lines
    }

    // MARK: - NetEase
    /// `music.163.com/api/song/lyric?id=...&lv=1&kv=1&tv=-1` returns `{ lrc: {lyric}, tlyric: {lyric} }`.
    static func netease(songmid: String) async -> [LyricLine]? {
        let urlStr = "https://music.163.com/api/song/lyric?id=\(songmid)&lv=1&kv=1&tv=-1"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let lyric = (json["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        let tlyric = (json["tlyric"] as? [String: Any])?["lyric"] as? String
        guard !lyric.isEmpty else { return nil }
        let lines = LRCParser.parse(lyric, translation: tlyric)
        return lines.isEmpty ? nil : lines
    }

    // MARK: - Kugou
    /// Two-step lookup mirroring kg/lyric.js#searchLyric + getLyricDownload:
    ///   1) `lyrics.kugou.com/search` returns candidates with id + accessKey
    ///   2) `lyrics.kugou.com/download?fmt=lrc` returns base64-encoded LRC
    /// We skip krc format (needs decryption) and always request lrc.
    static func kugou(name: String, hash: String, durationMs: Int) async -> [LyricLine]? {
        let headers: [String: String] = [
            "KG-RC": "1",
            "KG-THash": "expand_search_manager.cpp:852736169:451",
            "User-Agent": "KuGou2012-9020-ExpandSearchManager",
        ]
        guard let nameEnc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        let searchURL = "http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=\(nameEnc)&hash=\(hash)&timelength=\(durationMs)&lrctxt=1"
        guard let sURL = URL(string: searchURL) else { return nil }
        var sReq = URLRequest(url: sURL)
        for (k, v) in headers { sReq.setValue(v, forHTTPHeaderField: k) }
        sReq.timeoutInterval = 8
        guard let (sData, _) = try? await URLSession.shared.data(for: sReq),
              let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
              let candidates = sJson["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let id = first["id"] as? String ?? (first["id"] as? Int).map(String.init),
              let accessKey = first["accesskey"] as? String else { return nil }

        let dlURL = "http://lyrics.kugou.com/download?ver=1&client=pc&id=\(id)&accesskey=\(accessKey)&fmt=lrc&charset=utf8"
        guard let dURL = URL(string: dlURL) else { return nil }
        var dReq = URLRequest(url: dURL)
        for (k, v) in headers { dReq.setValue(v, forHTTPHeaderField: k) }
        dReq.timeoutInterval = 8
        guard let (dData, _) = try? await URLSession.shared.data(for: dReq),
              let dJson = try? JSONSerialization.jsonObject(with: dData) as? [String: Any] else { return nil }
        print("[Lyric KG] download response status=\(dJson["status"] ?? "?") fmt=\(dJson["fmt"] ?? "?")")
        guard (dJson["status"] as? Int) == 200,
              let fmt = dJson["fmt"] as? String,
              let b64 = dJson["content"] as? String,
              let raw = Data(base64Encoded: b64),
              let lrcStr = String(data: raw, encoding: .utf8) else { return nil }
        print("[Lyric KG] fmt=\(fmt) preview: \(lrcStr.prefix(300))")
        // Kugou may return fmt=krc (encrypted) when contenttype != 1. We skip those since we
        // can't decrypt and parser would produce garbage. The caller will fall through to no-lyric.
        guard fmt == "lrc" else {
            print("[Lyric KG] skipping non-lrc format")
            return nil
        }
        let lines = LRCParser.parse(lrcStr)
        return lines.isEmpty ? nil : lines
    }
}
