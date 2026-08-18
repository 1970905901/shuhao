import Foundation

/// Resolves MV (music video) URLs per platform — Swift port of
/// `shuhao-tv/source/catalog/MvResolver.kt`. Each source has its own endpoint
/// shape; the Kotlin original itself was ported from RN
/// `src/utils/musicSdk/<src>/mv.js`.
///
/// Required `Track.extras` hints captured by the search catalogs:
///   - kw: "mvId" (Kuwo's MV id, same as songmid when MVFLAG=='1')
///   - wy: "mvId" (NetEase mvid; otherwise we look it up via song detail)
///   - kg: "mvId" (Kugou MvHash; otherwise we give up — no fallback search)
///   - tx: "mvId" (QQ Music mv.vid)
///   - mg: "mvId" (Migu mvCopyrightId)
enum MvResolver {

    /// Single entry point — dispatches to the per-source implementation.
    static func getMvUrl(for track: Track) async -> MusicVideoInfo? {
        let result: MusicVideoInfo?
        switch track.source {
        case .kw: result = await kuwo(track)
        case .wy: result = await netease(track)
        case .kg: result = await kugou(track)
        case .tx: result = await qq(track)
        case .mg: result = await migu(track)
        default:  return nil  // .local has no MV concept
        }
        // 日志专门给"显示有 MV 徽章却放不动"的反馈用 —— 看一眼控制台就知道是
        // 解析阶段拿不到 URL,还是拿到了但播放器拒绝。
        if let r = result {
            print("[MvResolver] \(track.source.rawValue) mvId=\(track.extras["mvId"] ?? "nil") qualities=\(r.qualities.count) best=\(r.bestUrl() ?? "nil")")
        } else {
            print("[MvResolver] \(track.source.rawValue) mvId=\(track.extras["mvId"] ?? "nil") → nil")
        }
        return result
    }

    // MARK: - Helpers

    /// Tiny GET → String helper. Returns nil on network error / non-2xx.
    private static func getText(_ url: String, headers: [String: String] = [:]) async -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 12
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    /// Tiny GET → JSON helper.
    private static func getJSON(_ url: String, headers: [String: String] = [:]) async -> [String: Any]? {
        guard let text = await getText(url, headers: headers),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    // ===================================================================== Kuwo

    /// Kuwo's `anti.s?type=convert_url&rid=MV_<mvId>` returns either a real mp4
    /// URL or the DRM placeholder mp3 ("仅在酷我音乐手机端播放"). Reject the
    /// latter — there's no auth-free way around it (RN/Kotlin sources hit the
    /// same wall).
    private static func kuwo(_ track: Track) async -> MusicVideoInfo? {
        let mvId = track.extras["mvId"].flatMap { $0.isEmpty || $0 == "0" ? nil : $0 } ?? track.songmid
        let raw = await getText(
            "http://antiserver.kuwo.cn/anti.s?type=convert_url&rid=MV_\(mvId)&format=mp4&response=url",
            headers: ["User-Agent": "okhttp/3.10.0"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = raw, url.hasPrefix("http"), !isKuwoMvPlaceholder(url) else { return nil }
        return MusicVideoInfo(
            id: mvId, name: track.name, url: url,
            pageUrl: "http://www.kuwo.cn/mvplay/\(mvId)",
            qualities: [MvQuality(type: "mp4", url: url)]
        )
    }

    private static func isKuwoMvPlaceholder(_ url: String) -> Bool {
        let tail = url.split(separator: "/").last.map(String.init)?.split(separator: "?").first.map(String.init)?.lowercased() ?? ""
        if Self.kuwoPlaceholderFiles.contains(tail) { return true }
        // 合法 MV 必须是 mp4。kw 后端无授权时除了 588957081 占位外,还会回 .mp3 / .mgg /
        // .aac 等音频包装(都是 DRM 加密残骸,AVPlayer 拿到也只是黑屏卡死)。
        if let dot = tail.lastIndex(of: ".") {
            let ext = String(tail[tail.index(after: dot)...])
            if !ext.isEmpty && ext != "mp4" && ext != "m4v" && ext != "mov" { return true }
        }
        return false
    }
    private static let kuwoPlaceholderFiles: Set<String> = ["588957081.mp3", "588957081.mp4"]

    // ===================================================================== NetEase

    /// NetEase: derive mvid (from extras or song-detail), then /api/mv/detail.
    private static func netease(_ track: Track) async -> MusicVideoInfo? {
        let headers = ["Referer": "https://music.163.com/", "Origin": "https://music.163.com"]
        var mvId = track.extras["mvId"].flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
        if mvId == nil {
            if let detail = await getJSON("https://music.163.com/api/song/detail?ids=[\(track.songmid)]", headers: headers),
               let songs = detail["songs"] as? [[String: Any]],
               let first = songs.first,
               let mvNum = first["mvid"] as? Int, mvNum > 0 {
                mvId = String(mvNum)
            }
        }
        guard let mvId else { return nil }

        var info = MusicVideoInfo(
            id: mvId, name: track.name, pageUrl: "https://music.163.com/#/mv?id=\(mvId)"
        )
        guard let body = await getJSON("https://music.163.com/api/mv/detail?id=\(mvId)&type=mp4", headers: headers),
              (body["code"] as? Int) == 200,
              let data = body["data"] as? [String: Any]
        else { return info }
        let brs = (data["brs"] as? [String: Any]) ?? [:]
        var qualities: [MvQuality] = []
        for (k, v) in brs {
            // wy 偶尔会在最高码率档塞 .flv,过滤掉防止 AVPlayer 黑屏。
            if let u = v as? String, !u.isEmpty, Self.isPlayableMvExt(u) {
                qualities.append(MvQuality(type: k, url: u))
            }
        }
        qualities.sort { (Int($0.type) ?? 0) > (Int($1.type) ?? 0) }
        info.name = (data["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? info.name
        info.url = qualities.first?.url
        info.qualities = qualities
        return info
    }

    // ===================================================================== Kugou

    /// Kugou: `m.kugou.com/app/i/mv.php?cmd=100&hash=<MvHash>`. Qualities under
    /// `mvdata` (or top-level `data`): uhd > rq > sq > hd > sd > lq, each
    /// `{downurl, url}`.
    private static func kugou(_ track: Track) async -> MusicVideoInfo? {
        guard let mvHash = track.extras["mvId"], !mvHash.isEmpty else { return nil }
        guard let body = await getJSON("https://m.kugou.com/app/i/mv.php?cmd=100&hash=\(mvHash)") else { return nil }
        let data = (body["mvdata"] as? [String: Any]) ?? (body["data"] as? [String: Any]) ?? body
        var qualities: [MvQuality] = []
        for tier in ["uhd", "rq", "sq", "hd", "sd", "lq"] {
            guard let q = data[tier] as? [String: Any] else { continue }
            // kg 每档常常 downurl 是 mkv (Matroska 母版),url 是 mp4 流。AVPlayer 不
            // 支持 mkv,必须挑 mp4 那条;两条都是 mkv 这档跳过,落到下一档。Android 的
            // ExoPlayer 自带 mkv 解码所以 spec 偏好 downurl,iOS/Catalyst 反着来。
            let candidates = [q["url"] as? String, q["downurl"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }
            guard let chosen = candidates.first(where: isPlayableMvExt) else { continue }
            qualities.append(MvQuality(type: tier, url: chosen))
        }
        // Fallback: some payloads put a single URL at the data root.
        if qualities.isEmpty {
            let candidates = ["downurl", "url", "mv_url", "playurl"]
            let u = candidates.compactMap { data[$0] as? String }
                .first(where: { !$0.isEmpty && isPlayableMvExt($0) }) ?? ""
            if !u.isEmpty { qualities.append(MvQuality(type: "default", url: u)) }
        }
        guard !qualities.isEmpty else { return nil }
        return MusicVideoInfo(
            id: mvHash, name: track.name,
            url: qualities.first?.url,
            pageUrl: "https://www.kugou.com/mvweb/html/mv_\(mvHash).html",
            qualities: qualities
        )
    }

    /// AVPlayer 支持的容器:mp4 / m4v / mov / HLS。kg/wy 高画质可能给 .mkv (Matroska)
    /// 或 .flv,iOS 拿到就 -11828 黑屏。无扩展名(纯路径的 CDN)放行让播放器自己试。
    private static func isPlayableMvExt(_ urlStr: String) -> Bool {
        let lower = urlStr.lowercased()
        let path = lower.split(separator: "?").first.map(String.init) ?? lower
        guard let dot = path.lastIndex(of: ".") else { return true }
        let ext = String(path[path.index(after: dot)...])
        if ext.isEmpty { return true }
        return ["mp4", "m4v", "mov", "m3u8"].contains(ext)
    }

    // ===================================================================== QQ Music

    /// QQ Music: `musicu.fcg` with the `MvUrlProxy` batch payload. Response has
    /// `mvUrl.data[<vid>].mp4[]` — each entry carries `freeflow_url[]` or
    /// `url[] + vkey + cn` to be glued together.
    private static func qq(_ track: Track) async -> MusicVideoInfo? {
        guard let mvVid = track.extras["mvId"], !mvVid.isEmpty else { return nil }
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        req.httpBody = qqPayload(mvVid: mvVid).data(using: .utf8)

        let body: [String: Any]?
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }

        guard let body else { return nil }
        let urlInfo = ((body["mvUrl"] as? [String: Any])?["data"] as? [String: Any])?[mvVid] as? [String: Any]
        let videoInfo = ((body["mvInfo"] as? [String: Any])?["data"] as? [String: Any])?[mvVid] as? [String: Any]
        let qualities = qqQualities(urlInfo)
        guard !qualities.isEmpty else { return nil }
        let name = (videoInfo?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? track.name
        return MusicVideoInfo(
            id: mvVid, name: name,
            url: qualities.first?.url,
            pageUrl: "https://y.qq.com/n/ryqq/mv/\(mvVid)",
            qualities: qualities
        )
    }

    private static func qqPayload(mvVid: String) -> String {
        // Same field list the RN/Kotlin sources use; keep parity for forward-compat.
        let required: [String] = [
            "vid", "type", "sid", "cover_pic", "duration", "singers", "new_switch_str",
            "video_pay", "hint", "code", "msg", "name", "desc", "playcnt", "pubdate", "isfav",
            "fileid", "filesize_v2", "switch_pay_type", "pay", "pay_info", "uploader_headurl",
            "uploader_nick", "uploader_uin", "uploader_encuin", "play_forbid_reason",
        ]
        let payload: [String: Any] = [
            "comm": [
                "ct": 6, "cv": 0, "g_tk": 1646675364, "uin": 0,
                "format": "json", "platform": "yqq",
            ],
            "mvInfo": [
                "module": "music.video.VideoData",
                "method": "get_video_info_batch",
                "param": ["vidlist": [mvVid], "required": required],
            ],
            "mvUrl": [
                "module": "music.stream.MvUrlProxy",
                "method": "GetMvUrls",
                "param": [
                    "vids": [mvVid],
                    "request_type": 10003,
                    "addrtype": 3,
                    "format": 264,
                    "maxFiletype": 60,
                ],
            ],
        ]
        return (try? String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)) ?? ""
    }

    private static func qqQualities(_ urlInfo: [String: Any]?) -> [MvQuality] {
        guard let mp4 = urlInfo?["mp4"] as? [[String: Any]] else { return [] }
        var entries: [(Int, MvQuality)] = []
        for item in mp4 {
            if (item["code"] as? Int) != 0 { continue }
            let freeflow = (item["freeflow_url"] as? [String]) ?? []
            var base: String? = freeflow.first(where: { !$0.isEmpty })
            if base == nil {
                let urls = (item["url"] as? [String]) ?? []
                let u0 = urls.first ?? ""
                let vkey = (item["vkey"] as? String) ?? ""
                let cn = (item["cn"] as? String) ?? ""
                if !u0.isEmpty, !vkey.isEmpty, !cn.isEmpty {
                    base = "\(u0)\(vkey)/\(cn)?fname=\(cn)"
                }
            }
            guard let url = base, !url.isEmpty else { continue }
            let order = (item["newFileType"] as? Int).flatMap { $0 == 0 ? nil : $0 }
                ?? (item["filetype"] as? Int).flatMap { $0 == 0 ? nil : $0 }
                ?? (item["format"] as? Int) ?? 0
            entries.append((order, MvQuality(type: qqQualityLabel(order), url: url)))
        }
        return entries.sorted(by: { $0.0 > $1.0 }).map { $0.1 }
    }

    /// QQ newFileType 数字 → 人类可读画质名。映射来自 QQ 音乐 web 实测:
    /// 60 = 1080p, 50 = 720p, 40 = 480p, 30 = 360p, 20 = 240p。
    private static func qqQualityLabel(_ order: Int) -> String {
        switch order {
        case 80...: return "4K"
        case 60..<80: return "1080P"
        case 50..<60: return "720P"
        case 40..<50: return "480P"
        case 30..<40: return "360P"
        case 1..<30: return "240P"
        default: return "MP4"
        }
    }

    // ===================================================================== Migu

    /// Migu: `c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=D&resourceId=<mvCopyrightId>`.
    /// `resource[0]` has up to three path fields ordered highest first:
    ///   - bluerayPath    -> 1080P (蓝光 when an FHD master exists)
    ///   - highscreenPath -> 720P  (高清)
    ///   - widescreenPath -> 480P  (标清, the lowest)
    private static func migu(_ track: Track) async -> MusicVideoInfo? {
        guard let mvId = track.extras["mvId"], !mvId.isEmpty else { return nil }
        guard let body = await getJSON(
            "https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=D&resourceId=\(mvId)",
            headers: ["User-Agent": "Mozilla/5.0"]
        ) else { return nil }
        guard let resource = (body["resource"] as? [[String: Any]])?.first else { return nil }
        let tiers: [(String, String)] = [
            ("1080p", "bluerayPath"),
            ("720p",  "highscreenPath"),
            ("480p",  "widescreenPath"),
        ]
        var qualities: [MvQuality] = []
        var seen = Set<String>()
        for (label, key) in tiers {
            let path = (resource[key] as? String) ?? ""
            guard !path.isEmpty else { continue }
            let url = buildMguUrl(path: path)
            if seen.insert(url).inserted {
                qualities.append(MvQuality(type: label, url: url))
            }
        }
        guard !qualities.isEmpty else { return nil }
        let name = (resource["songName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? track.name
        return MusicVideoInfo(
            id: mvId, name: name,
            url: qualities.first?.url,
            qualities: qualities
        )
    }

    private static func buildMguUrl(path: String) -> String {
        let p = path.hasPrefix("/") ? path : "/\(path)"
        return "https://freetyst.nf.migu.cn/public\(p)"
    }
}
