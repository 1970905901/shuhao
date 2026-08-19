import Foundation

/// Mirrors lx-music-mobile's `musicSdk/[source]/leaderboard.js`. Each source exposes a static
/// list of boards (酷我飙升榜, 抖音热歌榜, ...) and a per-board song-fetch endpoint.
nonisolated struct BoardInfo: Identifiable, Hashable, Sendable {
    let id: String       // "kw__93"
    let source: SourceID
    let bangid: String   // platform-side id
    let name: String
    var picURL: String?  // filled by service either statically or on-demand
}

nonisolated protocol BoardService: Sendable {
    var source: SourceID { get }
    var list: [BoardInfo] { get }
    /// Optionally fetch a fresh list (with covers) from the platform.
    /// Default impl returns the static `list`.
    func fetchBoards() async -> [BoardInfo]
    func fetchTracks(bangid: String, page: Int) async throws -> [Track]
}

extension BoardService {
    func fetchBoards() async -> [BoardInfo] { list }
}

nonisolated enum Boards {
    static let all: [any BoardService] = [
        KuwoBoardService(),
        NetEaseBoardService(),
        KugouBoardService(),
        QQBoardService(),
    ]
    static func service(for source: SourceID) -> (any BoardService)? {
        all.first { $0.source == source }
    }
    static var allBoards: [BoardInfo] {
        all.flatMap { $0.list }
    }
}

// MARK: - Kuwo

/// Uses Kuwo's legacy `kbangserver.kuwo.cn/ksong.s` endpoint (the modern `wbd.kuwo.cn`
/// route in lx-music-mobile needs a private signing routine we don't have).
nonisolated struct KuwoBoardService: BoardService {
    let source: SourceID = .kw

    // Trimmed subset of `boardList` from musicSdk/kw/leaderboard.js — top picks first.
    let list: [BoardInfo] = [
        BoardInfo(id: "kw__93",  source: .kw, bangid: "93",  name: "飙升榜"),
        BoardInfo(id: "kw__16",  source: .kw, bangid: "16",  name: "热歌榜"),
        BoardInfo(id: "kw__17",  source: .kw, bangid: "17",  name: "新歌榜"),
        BoardInfo(id: "kw__158", source: .kw, bangid: "158", name: "抖音热歌榜"),
        BoardInfo(id: "kw__187", source: .kw, bangid: "187", name: "流行趋势榜"),
        BoardInfo(id: "kw__104", source: .kw, bangid: "104", name: "华语榜"),
        BoardInfo(id: "kw__182", source: .kw, bangid: "182", name: "粤语榜"),
        BoardInfo(id: "kw__22",  source: .kw, bangid: "22",  name: "欧美榜"),
        BoardInfo(id: "kw__184", source: .kw, bangid: "184", name: "韩语榜"),
        BoardInfo(id: "kw__183", source: .kw, bangid: "183", name: "日语榜"),
        BoardInfo(id: "kw__26",  source: .kw, bangid: "26",  name: "经典怀旧榜"),
        BoardInfo(id: "kw__278", source: .kw, bangid: "278", name: "古风音乐榜"),
        BoardInfo(id: "kw__242", source: .kw, bangid: "242", name: "电音榜"),
        BoardInfo(id: "kw__186", source: .kw, bangid: "186", name: "ACG神曲榜"),
        BoardInfo(id: "kw__185", source: .kw, bangid: "185", name: "最强翻唱榜"),
        BoardInfo(id: "kw__284", source: .kw, bangid: "284", name: "热评榜"),
        BoardInfo(id: "kw__283", source: .kw, bangid: "283", name: "枕边轻音乐榜"),
        BoardInfo(id: "kw__280", source: .kw, bangid: "280", name: "家务进行曲榜"),
        BoardInfo(id: "kw__64",  source: .kw, bangid: "64",  name: "影视金曲榜"),
        BoardInfo(id: "kw__12",  source: .kw, bangid: "12",  name: "Billboard榜"),
    ]

    func fetchBoards() async -> [BoardInfo] {
        // `qukudata.kuwo.cn` returns the full board tree with `sourceid` + `pic` per board.
        // We merge those covers into our static list (so users see real icons, not text badges).
        let urlStr = "http://qukudata.kuwo.cn/q.k?op=query&cont=tree&node=2&pn=0&rn=200&fmt=json&level=2"
        guard let url = URL(string: urlStr) else { return list }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let children = json["child"] as? [[String: Any]] else { return list }
        var picByBangid: [String: String] = [:]
        for c in children {
            let bangid = (c["sourceid"] as? String) ?? ""
            let pic = (c["pic"] as? String) ?? ""
            if !bangid.isEmpty, !pic.isEmpty { picByBangid[bangid] = pic }
        }
        return list.map { board in
            var b = board
            b.picURL = picByBangid[board.bangid] ?? board.picURL
            return b
        }
    }

    func fetchTracks(bangid: String, page: Int) async throws -> [Track] {
        let pn = max(0, page - 1)
        let urlStr = "http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&pn=\(pn)&rn=100&type=bang&data=content&id=\(bangid)&show_copyright_off=0&pcmp4=1&isbang=1"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["musiclist"] as? [[String: Any]] else { return [] }
        let tracks = list.compactMap(buildTrack)
        // Fill cover for each — search results already do this via artistpicserver.
        return await KuwoBoardService.fillKuwoCovers(tracks)
    }

    /// Resolve per-song cover URLs via Kuwo's artistpicserver in parallel (matches Catalogs.swift).
    static func fillKuwoCovers(_ tracks: [Track]) async -> [Track] {
        await withTaskGroup(of: (Int, String?).self) { group -> [Track] in
            for (idx, t) in tracks.enumerated() where t.picURL == nil {
                group.addTask {
                    let urlStr = "http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=\(t.songmid)"
                    guard let u = URL(string: urlStr) else { return (idx, nil) }
                    var req = URLRequest(url: u)
                    req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
                    req.timeoutInterval = 6
                    if let (data, _) = try? await URLSession.shared.data(for: req),
                       let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       s.hasPrefix("http") {
                        return (idx, s)
                    }
                    return (idx, nil)
                }
            }
            var out = tracks
            for await (idx, pic) in group {
                if let pic, idx < out.count { out[idx].picURL = pic }
            }
            return out
        }
    }

    /// `formats` is a pipe-separated codename list. We only care about audio quality codes here.
    private func buildTrack(_ d: [String: Any]) -> Track? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let rawName = (d["name"] as? String) ?? "未知"
        let artist = (d["artist"] as? String) ?? ""
        let album = d["album"] as? String
        // Kuwo ksong.s returns BOTH `duration` and `song_duration`. The former is some short
        // ranking metric (typically 1~20, looks like a "days on chart" counter) — definitely
        // not playback length. `song_duration` is the real seconds (e.g. 210, 243, 264).
        // Previously we preferred `duration`, so rows showed "0:01" / "0:14" for tracks that
        // actually play for 3+ minutes. Read `song_duration` first; keep `duration` as a
        // last-ditch fallback only if the real field is missing.
        let durationStr = (d["song_duration"] as? String) ?? (d["duration"] as? String) ?? "0"
        let duration = Int(durationStr) ?? 0

        var qualities: [Quality] = []
        let formats = (d["formats"] as? String) ?? ""
        let codes = Set(formats.split(separator: "|").map(String.init))
        if codes.contains("MP3128") { qualities.append(.k128) }
        if codes.contains("MP3H")  { qualities.append(.k320) }
        if codes.contains("ALFLAC") { qualities.append(.flac) }
        if codes.contains("HIRFLAC") || codes.contains("AC4256") || codes.contains("DDJOC768") { qualities.append(.flac24) }
        if codes.contains("HIRFLAC") { qualities.append(.hires) }
        // AC4256 / DDJOC768 are Dolby codecs (AC-4 / DD+ JOC) — i.e. 全景声.
        if codes.contains("AC4256") || codes.contains("DDJOC768") { qualities.append(.atmos) }
        if qualities.isEmpty { qualities = [.k128, .k320] }

        return Track(
            id: Track.makeID(source: .kw, songmid: id),
            name: decodeKuwo(rawName),
            singer: decodeKuwo(artist),
            albumName: album.map(decodeKuwo),
            albumId: d["albumid"] as? String,
            source: .kw,
            songmid: id,
            duration: duration > 0 ? duration : nil,
            picURL: nil,
            qualities: qualities
        )
    }

    private func decodeKuwo(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - NetEase

/// `music.163.com/api/toplist` returns the full board list with covers.
/// `music.163.com/api/playlist/detail?id=X` returns songs.
nonisolated struct NetEaseBoardService: BoardService {
    let source: SourceID = .wy

    /// Static fallback — the API call below replaces this with the live list.
    let list: [BoardInfo] = [
        BoardInfo(id: "wy__19723756", source: .wy, bangid: "19723756", name: "飙升榜", picURL: nil),
        BoardInfo(id: "wy__3779629",  source: .wy, bangid: "3779629",  name: "新歌榜", picURL: nil),
        BoardInfo(id: "wy__3778678",  source: .wy, bangid: "3778678",  name: "热歌榜", picURL: nil),
        BoardInfo(id: "wy__2884035",  source: .wy, bangid: "2884035",  name: "原创榜", picURL: nil),
    ]

    func fetchBoards() async -> [BoardInfo] {
        guard let url = URL(string: "https://music.163.com/api/toplist") else { return list }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["list"] as? [[String: Any]] else { return list }
        return arr.compactMap { item -> BoardInfo? in
            guard let idAny = item["id"] else { return nil }
            let id = String(describing: idAny)
            let name = (item["name"] as? String) ?? "未知"
            let cover = item["coverImgUrl"] as? String
            return BoardInfo(id: "wy__\(id)", source: .wy, bangid: id, name: name, picURL: cover)
        }
    }

    func fetchTracks(bangid: String, page: Int) async throws -> [Track] {
        // NetEase top lists are playlists themselves — `playlist/detail` works.
        let urlStr = "https://music.163.com/api/playlist/detail?id=\(bangid)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let tracks = result["tracks"] as? [[String: Any]] else { return [] }
        return tracks.compactMap(buildTrack)
    }

    private func buildTrack(_ d: [String: Any]) -> Track? {
        guard let idAny = d["id"] else { return nil }
        let id = String(describing: idAny)
        let name = (d["name"] as? String) ?? "未知"
        let artists = (d["artists"] as? [[String: Any]]) ?? []
        let singer = artists.compactMap { $0["name"] as? String }.joined(separator: " / ")
        let albumD = d["album"] as? [String: Any]
        let albumName = albumD?["name"] as? String
        let albumId = albumD.flatMap { $0["id"].map { String(describing: $0) } }
        let pic = albumD?["picUrl"] as? String
        let duration = (d["duration"] as? Int).map { $0 / 1000 }
        // 音质映射修正:hMusic = 320k,sqMusic = FLAC,hrMusic = Hi-Res。
        // 老的 hMusic → .flac 是错的(那是 320k 被误标成无损)。
        // mMusic 是 192k,本 App 无此档,不映射;128k 已由 k128 兜底。
        var qs: [Quality] = [.k128]
        if (d["hMusic"] as? [String: Any]) != nil { qs.append(.k320) }
        if (d["sqMusic"] as? [String: Any]) != nil { qs.append(.flac) }
        if (d["hrMusic"] as? [String: Any]) != nil { qs.append(.hires) }
        // mvid > 0 表示该曲有 MV(排行榜来自 playlist/detail,会返回真实 mvid)。
        var extras: [String: String] = [:]
        if let mvid = d["mvid"] as? Int, mvid > 0 { extras["mvId"] = String(mvid) }
        return Track(
            id: Track.makeID(source: .wy, songmid: id),
            name: name,
            singer: singer.isEmpty ? "未知歌手" : singer,
            albumName: albumName,
            albumId: albumId,
            source: .wy,
            songmid: id,
            duration: duration,
            picURL: pic,
            qualities: qs,
            extras: extras
        )
    }
}

// MARK: - Kugou

/// Mirrors musicSdk/kg/leaderboard.js. Songs via `mobilecdnbj.kugou.com/api/v3/rank/song`.
nonisolated struct KugouBoardService: BoardService {
    let source: SourceID = .kg

    let list: [BoardInfo] = [
        BoardInfo(id: "kg__8888",  source: .kg, bangid: "8888",  name: "TOP500"),
        BoardInfo(id: "kg__6666",  source: .kg, bangid: "6666",  name: "飙升榜"),
        BoardInfo(id: "kg__23784", source: .kg, bangid: "23784", name: "网络红歌榜"),
        BoardInfo(id: "kg__52144", source: .kg, bangid: "52144", name: "抖音热歌榜"),
        BoardInfo(id: "kg__52767", source: .kg, bangid: "52767", name: "快手热歌榜"),
        BoardInfo(id: "kg__24971", source: .kg, bangid: "24971", name: "DJ热歌榜"),
        BoardInfo(id: "kg__44412", source: .kg, bangid: "44412", name: "说唱先锋榜"),
        BoardInfo(id: "kg__31308", source: .kg, bangid: "31308", name: "内地榜"),
        BoardInfo(id: "kg__33160", source: .kg, bangid: "33160", name: "电音榜"),
        BoardInfo(id: "kg__33161", source: .kg, bangid: "33161", name: "古风新歌榜"),
        BoardInfo(id: "kg__33165", source: .kg, bangid: "33165", name: "粤语金曲榜"),
        BoardInfo(id: "kg__33166", source: .kg, bangid: "33166", name: "欧美金曲榜"),
        BoardInfo(id: "kg__33163", source: .kg, bangid: "33163", name: "影视金曲榜"),
        BoardInfo(id: "kg__31311", source: .kg, bangid: "31311", name: "韩国榜"),
        BoardInfo(id: "kg__31312", source: .kg, bangid: "31312", name: "日本榜"),
    ]

    func fetchBoards() async -> [BoardInfo] {
        // `v5/rank/list` returns every board with an `imgurl` ({size} template). Merge covers
        // into our curated list by bangid.
        let urlStr = "http://mobilecdnbj.kugou.com/api/v5/rank/list?version=9108&plat=0&showtype=2&parentid=0&apiver=6&area_code=1&withsong=1"
        guard let url = URL(string: urlStr) else { return list }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let info = d["info"] as? [[String: Any]] else { return list }
        var picByBangid: [String: String] = [:]
        for b in info {
            let bangid = (b["rankid"] as? Int).map(String.init) ?? (b["rankid"] as? String) ?? ""
            let raw = (b["imgurl"] as? String) ?? (b["img_cover"] as? String) ?? ""
            if !bangid.isEmpty, !raw.isEmpty {
                picByBangid[bangid] = raw.replacingOccurrences(of: "{size}", with: "240")
            }
        }
        return list.map { board in
            var b = board
            b.picURL = picByBangid[board.bangid] ?? board.picURL
            return b
        }
    }

    func fetchTracks(bangid: String, page: Int) async throws -> [Track] {
        let urlStr = "http://mobilecdnbj.kugou.com/api/v3/rank/song?version=9108&ranktype=1&plat=0&pagesize=100&area_code=1&page=\(page)&rankid=\(bangid)&with_res_tag=0&show_portrait_mv=1"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let info = d["info"] as? [[String: Any]] else { return [] }
        return info.compactMap(buildTrack)
    }

    private func buildTrack(_ d: [String: Any]) -> Track? {
        let hash = (d["hash"] as? String) ?? ""
        guard !hash.isEmpty else { return nil }
        let audioId: String
        if let i = d["audio_id"] as? Int { audioId = String(i) }
        else if let s = d["audio_id"] as? String, !s.isEmpty { audioId = s }
        else { audioId = hash }
        let name = decode((d["songname"] as? String) ?? "未知")
        let authors = (d["authors"] as? [[String: Any]]) ?? []
        let singer = authors.compactMap { $0["author_name"] as? String }.joined(separator: "、")
        let album = (d["remark"] as? String).map(decode)
        let albumId = (d["album_id"] as? String) ?? (d["album_id"] as? Int).map(String.init)
        let duration = (d["duration"] as? Int) ?? Int((d["duration"] as? String) ?? "0")

        var qs: [Quality] = []
        if (d["filesize"] as? Int).map({ $0 != 0 }) ?? false { qs.append(.k128) }
        if (d["320filesize"] as? Int).map({ $0 != 0 }) ?? false { qs.append(.k320) }
        if (d["sqfilesize"] as? Int).map({ $0 != 0 }) ?? false { qs.append(.flac) }
        if (d["filesize_high"] as? Int).map({ $0 != 0 }) ?? false { qs.append(.flac24) }
        if qs.isEmpty { qs = [.k128] }

        var extras: [String: String] = ["hash": hash]
        if let albumId { extras["albumId"] = albumId }
        // Cover: use the first author's sizable avatar ({size} template).
        let pic: String? = (authors.first?["sizable_avatar"] as? String).flatMap {
            $0.isEmpty ? nil : $0.replacingOccurrences(of: "{size}", with: "150")
        }
        return Track(
            id: Track.makeID(source: .kg, songmid: audioId),
            name: name,
            singer: singer,
            albumName: album,
            albumId: albumId,
            source: .kg,
            songmid: audioId,
            duration: (duration ?? 0) > 0 ? duration : nil,
            picURL: pic,
            qualities: qs,
            extras: extras
        )
    }

    private func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - QQ Music

/// Mirrors musicSdk/tx/leaderboard.js. Songs via `u.y.qq.com/cgi-bin/musicu.fcg` toplist GetDetail.
nonisolated struct QQBoardService: BoardService {
    let source: SourceID = .tx

    let list: [BoardInfo] = [
        BoardInfo(id: "tx__4",  source: .tx, bangid: "4",  name: "流行指数榜"),
        BoardInfo(id: "tx__26", source: .tx, bangid: "26", name: "热歌榜"),
        BoardInfo(id: "tx__27", source: .tx, bangid: "27", name: "新歌榜"),
        BoardInfo(id: "tx__62", source: .tx, bangid: "62", name: "飙升榜"),
        BoardInfo(id: "tx__28", source: .tx, bangid: "28", name: "网络歌曲榜"),
        BoardInfo(id: "tx__60", source: .tx, bangid: "60", name: "抖快榜"),
        BoardInfo(id: "tx__5",  source: .tx, bangid: "5",  name: "内地榜"),
        BoardInfo(id: "tx__3",  source: .tx, bangid: "3",  name: "欧美榜"),
        BoardInfo(id: "tx__59", source: .tx, bangid: "59", name: "香港地区榜"),
        BoardInfo(id: "tx__16", source: .tx, bangid: "16", name: "韩国榜"),
        BoardInfo(id: "tx__17", source: .tx, bangid: "17", name: "日本榜"),
        BoardInfo(id: "tx__65", source: .tx, bangid: "65", name: "国风热歌榜"),
        BoardInfo(id: "tx__58", source: .tx, bangid: "58", name: "说唱榜"),
        BoardInfo(id: "tx__29", source: .tx, bangid: "29", name: "影视金曲榜"),
        BoardInfo(id: "tx__63", source: .tx, bangid: "63", name: "DJ舞曲榜"),
    ]

    func fetchBoards() async -> [BoardInfo] {
        // `fcg_myqq_toplist.fcg` returns topList[] with `id` + `picUrl`. Merge covers by bangid.
        let urlStr = "https://c.y.qq.com/v8/fcg-bin/fcg_myqq_toplist.fcg?g_tk=1928093487&inCharset=utf-8&outCharset=utf-8&notice=0&format=json&uin=0&needNewCode=1&platform=h5"
        guard let url = URL(string: urlStr) else { return list }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let topList = d["topList"] as? [[String: Any]] else { return list }
        var picByBangid: [String: String] = [:]
        for b in topList {
            let bangid = (b["id"] as? Int).map(String.init) ?? (b["id"] as? String) ?? ""
            let pic = (b["picUrl"] as? String) ?? ""
            if !bangid.isEmpty, !pic.isEmpty { picByBangid[bangid] = pic }
        }
        return list.map { board in
            var b = board
            b.picURL = picByBangid[board.bangid] ?? board.picURL
            return b
        }
    }

    func fetchTracks(bangid: String, page: Int) async throws -> [Track] {
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let body: [String: Any] = [
            "toplist": [
                "module": "musicToplist.ToplistInfoServer",
                "method": "GetDetail",
                "param": ["topid": Int(bangid) ?? 0, "num": 100],
            ],
            "comm": ["uin": 0, "format": "json", "ct": 20, "cv": 1859],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toplist = json["toplist"] as? [String: Any],
              let tdata = toplist["data"] as? [String: Any],
              let songs = tdata["songInfoList"] as? [[String: Any]] else { return [] }
        return songs.compactMap(QQTrackBuilder.build)
    }
}

/// Shared QQ track builder for boards + songlists (mirrors QQMusicCatalogService.build).
nonisolated enum QQTrackBuilder {
    static func build(_ d: [String: Any]) -> Track? {
        let mid = (d["mid"] as? String) ?? ""
        guard !mid.isEmpty else { return nil }
        let name = (d["name"] as? String) ?? (d["title"] as? String) ?? "未知"
        let singers = (d["singer"] as? [[String: Any]]) ?? []
        let singer = singers.compactMap { $0["name"] as? String }.joined(separator: " / ")
        let album = d["album"] as? [String: Any]
        let albumName = album?["name"] as? String
        let albumMid = album?["mid"] as? String
        let albumId = album?["id"].map { String(describing: $0) }
        let interval = d["interval"] as? Int
        let file = d["file"] as? [String: Any] ?? [:]
        var qs: [Quality] = []
        if (file["size_128mp3"] as? Int).map({ $0 > 0 }) ?? false { qs.append(.k128) }
        if (file["size_320mp3"] as? Int).map({ $0 > 0 }) ?? false { qs.append(.k320) }
        if (file["size_flac"] as? Int).map({ $0 > 0 }) ?? false { qs.append(.flac) }
        if (file["size_hires"] as? Int).map({ $0 > 0 }) ?? false { qs.append(.flac24) }
        if qs.isEmpty { qs = [.k128] }
        var extras: [String: String] = [:]
        if let m = albumMid, !m.isEmpty { extras["albumMid"] = m }
        if let smm = file["media_mid"] as? String, !smm.isEmpty { extras["strMediaMid"] = smm }
        if let sid = d["id"].map({ String(describing: $0) }) { extras["songId"] = sid }
        let picURL: String? = (albumMid?.isEmpty == false)
            ? "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid!).jpg"
            : nil
        return Track(
            id: Track.makeID(source: .tx, songmid: mid),
            name: name,
            singer: singer.isEmpty ? "未知" : singer,
            albumName: albumName?.isEmpty == false ? albumName : nil,
            albumId: albumId,
            source: .tx,
            songmid: mid,
            duration: interval,
            picURL: picURL,
            qualities: qs,
            extras: extras
        )
    }
}
