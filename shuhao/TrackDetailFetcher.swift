import Foundation

/// 下载前补抓的曲目详情 —— 全部字段可选,接口拿不到就跳过,不影响下载本身。
nonisolated struct TrackDetails: Sendable {
    var trackNumber: Int?
    var trackTotal: Int?
    var albumArtist: String?
    var releaseDate: String?    // "YYYY" 或 "YYYY-MM-DD"
    var genre: String?
    var company: String?
    /// 比 track.picURL 更高清的封面地址(没有就为 nil,调用方回落 picURL)。
    var hiResCoverURL: String?
}

/// 按源拉曲目详情。所有请求 fail-soft:超时 / 解析失败一律返回部分数据或 nil,
/// 绝不抛错 —— 详情只是锦上添花,拿不到照样下载。
nonisolated enum TrackDetailFetcher {

    static func fetch(_ track: Track) async -> TrackDetails? {
        switch track.source {
        case .wy: return await fetchWY(track)
        case .tx: return await fetchTX(track)
        case .kg: return await fetchKG(track)
        case .kw: return await fetchKW(track)
        case .mg, .local: return nil
        }
    }

    private static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"

    private static func getJSON(_ urlStr: String, referer: String? = nil) async -> [String: Any]? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - 网易云

    /// song/detail 一个接口给齐:曲目号(no)、专辑曲目总数(album.size)、
    /// 发行时间(album.publishTime, ms epoch)、专辑艺术家、唱片公司、原图封面。
    private static func fetchWY(_ track: Track) async -> TrackDetails? {
        let id = track.songmid
        guard let json = await getJSON(
            "https://music.163.com/api/song/detail/?id=\(id)&ids=%5B\(id)%5D",
            referer: "https://music.163.com/"
        ), let song = (json["songs"] as? [[String: Any]])?.first else { return nil }

        var d = TrackDetails()
        if let no = song["no"] as? Int, no > 0 { d.trackNumber = no }
        if let album = song["album"] as? [String: Any] {
            if let size = album["size"] as? Int, size > 0 { d.trackTotal = size }
            if let company = album["company"] as? String, !company.isEmpty { d.company = company }
            if let pic = album["picUrl"] as? String, !pic.isEmpty { d.hiResCoverURL = pic }
            if let artist = album["artist"] as? [String: Any],
               let name = artist["name"] as? String, !name.isEmpty {
                d.albumArtist = name
            }
            if let ms = album["publishTime"] as? Double, ms > 0 {
                d.releaseDate = formatDate(Date(timeIntervalSince1970: ms / 1000))
            }
        }
        return d
    }

    // MARK: - QQ 音乐

    /// get_song_detail_yqq:track_info.index_album 是曲目号,time_public 是发行日期,
    /// info 区块里有流派 / 唱片公司。高清封面直接按 albumMid 拼 800x800。
    private static func fetchTX(_ track: Track) async -> TrackDetails? {
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        let body: [String: Any] = [
            "req": [
                "module": "music.pf_song_detail_svr",
                "method": "get_song_detail_yqq",
                "param": ["song_mid": track.songmid],
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var d = TrackDetails()
        if let albumMid = track.extras["albumMid"], !albumMid.isEmpty {
            d.hiResCoverURL = "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"
        }

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let reqResp = json["req"] as? [String: Any],
              let respData = reqResp["data"] as? [String: Any] else {
            return d.hiResCoverURL == nil ? nil : d
        }
        if let trackInfo = respData["track_info"] as? [String: Any] {
            if let idx = trackInfo["index_album"] as? Int, idx > 0 { d.trackNumber = idx }
            if let pub = trackInfo["time_public"] as? String, !pub.isEmpty { d.releaseDate = pub }
        }
        // info 区块形如 { genre: { content: [{value: "流行"}] }, company: {...} }
        if let info = respData["info"] as? [String: Any] {
            d.genre = infoValue(info, key: "genre")
            d.company = infoValue(info, key: "company")
        }
        return d
    }

    private static func infoValue(_ info: [String: Any], key: String) -> String? {
        guard let section = info[key] as? [String: Any],
              let content = section["content"] as? [[String: Any]],
              let value = content.first?["value"] as? String,
              !value.isEmpty else { return nil }
        return value
    }

    // MARK: - 酷狗

    /// 两个接口:album/info 给发行时间 + 专辑艺术家;album/song 列出专辑全部曲目,
    /// 按 hash 找到位置就是曲目号。没有 albumId 的歌(单曲)直接放弃。
    private static func fetchKG(_ track: Track) async -> TrackDetails? {
        var d = TrackDetails()
        // 搜索结果封面是 {size}=240 模板;去掉尺寸段就是原图。
        if let pic = track.picURL, pic.contains("/240/") {
            d.hiResCoverURL = pic.replacingOccurrences(of: "/240/", with: "/")
        }
        guard let albumId = track.extras["albumId"] ?? track.albumId, !albumId.isEmpty else {
            return d.hiResCoverURL == nil ? nil : d
        }

        if let json = await getJSON("http://mobilecdn.kugou.com/api/v3/album/info?albumid=\(albumId)"),
           let data = json["data"] as? [String: Any] {
            if let singer = data["singername"] as? String, !singer.isEmpty { d.albumArtist = singer }
            if let pub = data["publishtime"] as? String, !pub.isEmpty {
                d.releaseDate = String(pub.prefix(10))   // "2008-01-01 00:00:00" → 前 10 位
            }
        }

        if let hash = track.extras["hash"]?.lowercased(), !hash.isEmpty,
           let json = await getJSON("http://mobilecdn.kugou.com/api/v3/album/song?albumid=\(albumId)&page=1&pagesize=100"),
           let data = json["data"] as? [String: Any],
           let songs = data["info"] as? [[String: Any]] {
            if let idx = songs.firstIndex(where: { ($0["hash"] as? String)?.lowercased() == hash }) {
                d.trackNumber = idx + 1
            }
            let total = (data["total"] as? Int) ?? songs.count
            if total > 0 { d.trackTotal = total }
        }
        return d
    }

    // MARK: - 酷我

    /// songinfoandlrc 只可靠给一个 releaseDate,其它字段没有。
    private static func fetchKW(_ track: Track) async -> TrackDetails? {
        guard let json = await getJSON("http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=\(track.songmid)"),
              let data = json["data"] as? [String: Any],
              let info = data["songinfo"] as? [String: Any] else { return nil }
        var d = TrackDetails()
        if let date = info["releaseDate"] as? String, !date.isEmpty { d.releaseDate = date }
        return d.releaseDate == nil ? nil : d
    }

    private static func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return fmt.string(from: date)
    }
}
