import Foundation

nonisolated protocol CatalogService: Sendable {
    var source: SourceID { get }
    func search(keyword: String, page: Int) async throws -> [Track]
}

nonisolated enum CatalogError: LocalizedError {
    case badResponse
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .badResponse: return "解析搜索结果失败"
        case .http(let c): return "HTTP \(c)"
        }
    }
}

nonisolated enum Catalogs {
    // Migu intentionally excluded: every public Migu URL endpoint requires a paid-account cookie,
    // the bundled v4 backend hangs on mg, and the user-provided fish_music backend
    // (m-api.ceseet.me) returns "此平台已停止服务" for mg.  Without a working URL resolver,
    // showing search results would just produce dead taps.
    static let all: [any CatalogService] = [
        KuwoCatalogService(),
        KugouCatalogService(),
        NetEaseCatalogService(),
        QQMusicCatalogService(),
    ]
    static func service(for source: SourceID) -> (any CatalogService)? {
        all.first { $0.source == source }
    }

    /// Aggregated search across every catalog. Results are interleaved per page so
    /// the user sees a mix from every platform that returned something.
    static func searchAll(keyword: String, page: Int = 1) async -> [Track] {
        let results = await withTaskGroup(of: (SourceID, [Track]).self) { group -> [SourceID: [Track]] in
            for svc in all {
                group.addTask {
                    do {
                        let tracks = try await svc.search(keyword: keyword, page: page)
                        return (svc.source, tracks)
                    } catch {
                        return (svc.source, [])
                    }
                }
            }
            var dict: [SourceID: [Track]] = [:]
            for await (src, tracks) in group { dict[src] = tracks }
            return dict
        }
        return interleave(results)
    }

    private static func interleave(_ groups: [SourceID: [Track]]) -> [Track] {
        let order: [SourceID] = [.kw, .wy, .kg, .tx]
        var iterators: [SourceID: IndexingIterator<[Track]>] = [:]
        for s in order { iterators[s] = groups[s]?.makeIterator() }
        var out: [Track] = []
        var keepGoing = true
        while keepGoing {
            keepGoing = false
            for s in order {
                if var it = iterators[s], let next = it.next() {
                    out.append(next)
                    iterators[s] = it
                    keepGoing = true
                }
            }
        }
        return out
    }
}

private let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

// MARK: - Kuwo

nonisolated struct KuwoCatalogService: CatalogService {
    let source: SourceID = .kw
    func search(keyword: String, page: Int) async throws -> [Track] {
        let tracks = try await KuwoCatalog.search(keyword: keyword, page: page)
        // Resolve covers in parallel — kuwo's artistpicserver returns the cover URL as plain text body.
        return await Self.fillCovers(tracks)
    }

    private static func fillCovers(_ tracks: [Track]) async -> [Track] {
        await withTaskGroup(of: (Int, String?).self) { group -> [Track] in
            for (idx, t) in tracks.enumerated() where t.picURL == nil {
                group.addTask {
                    let urlStr = "http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=\(t.songmid)"
                    guard let u = URL(string: urlStr) else { return (idx, nil) }
                    var req = URLRequest(url: u)
                    req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
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
}

// MARK: - Kugou — mirrors lx-music-mobile/src/utils/musicSdk/kg/musicSearch.js

nonisolated struct KugouCatalogService: CatalogService {
    let source: SourceID = .kg

    func search(keyword: String, page: Int) async throws -> [Track] {
        guard let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        let urlStr = "https://songsearch.kugou.com/song_search_v2?keyword=\(enc)&page=\(page)&pagesize=30&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let items = d["lists"] as? [[String: Any]] else { return [] }
        // 去重必须用 Track.id(= Audioid,兜底 FileHash):同一录音在不同专辑里
        // FileHash 不同但 Audioid 相同,按 FileHash 去重会放进一堆相同 id 的行,
        // ForEach 身份冲突 → 列表空行、序号错乱。保留搜索排序里的第一个。
        var seen = Set<String>()
        var out: [Track] = []
        func append(_ d: [String: Any]) {
            guard let t = build(d), seen.insert(t.id).inserted else { return }
            out.append(t)
        }
        for item in items {
            append(item)
            for sub in (item["Grp"] as? [[String: Any]]) ?? [] { append(sub) }
        }
        return out
    }

    private func build(_ d: [String: Any]) -> Track? {
        let hash = (d["FileHash"] as? String) ?? ""
        guard !hash.isEmpty else { return nil }
        let song = decodeKugou((d["SongName"] as? String) ?? "未知")
        let singer = decodeKugou((d["SingerName"] as? String) ?? "")
        let album = (d["AlbumName"] as? String).map(decodeKugou)
        let albumId = (d["AlbumID"] as? String) ?? ((d["AlbumID"] as? Int).map(String.init))
        let duration = d["Duration"] as? Int
        var qs: [Quality] = []
        if (d["FileSize"] as? Int).map({ $0 != 0 }) ?? false { qs.append(.k128) }
        if (d["HQFileSize"] as? Int).map({ $0 != 0 }) ?? false { qs.append(.k320) }
        if (d["SQFileSize"] as? Int).map({ $0 != 0 }) ?? false { qs.append(.flac) }
        if (d["ResFileSize"] as? Int).map({ $0 != 0 }) ?? false { qs.append(.flac24) }
        if qs.isEmpty { qs = [.k128] }
        let songmid: String
        if let audioid = d["Audioid"] as? Int { songmid = String(audioid) }
        else if let s = d["Audioid"] as? String { songmid = s }
        else { songmid = hash }
        var extras: [String: String] = ["hash": hash]
        if let id = albumId { extras["albumId"] = id }
        // Kugou: MvHash → MV resolver hits m.kugou.com/app/i/mv.php?cmd=100.
        // Mirrors shuhao-tv's SearchCatalog. The cmd=100 endpoint frequently
        // returns "data not found" for newer uploads, in which case
        // MvPlayerView's "暂无可用 MV" toast surfaces the failure (parity
        // with the TV version's behavior).
        if let mh = d["MvHash"] as? String, !mh.isEmpty { extras["mvId"] = mh }
        // Cover URL: Kugou search returns the Image template with a {size} placeholder.
        let pic: String? = (d["Image"] as? String).flatMap { tmpl in
            tmpl.isEmpty ? nil : tmpl.replacingOccurrences(of: "{size}", with: "240")
        }
        return Track(
            id: Track.makeID(source: .kg, songmid: songmid),
            name: song,
            singer: singer,
            albumName: album,
            albumId: albumId,
            source: .kg,
            songmid: songmid,
            duration: duration,
            picURL: pic,
            qualities: qs,
            extras: extras
        )
    }

    private func decodeKugou(_ s: String) -> String {
        // Kugou wraps highlighted text in <em>...</em>; strip those tags.
        s.replacingOccurrences(of: "<em>", with: "")
            .replacingOccurrences(of: "</em>", with: "")
    }
}

// MARK: - NetEase Cloud Music

nonisolated struct NetEaseCatalogService: CatalogService {
    let source: SourceID = .wy

    func search(keyword: String, page: Int) async throws -> [Track] {
        guard let url = URL(string: "https://music.163.com/api/search/get") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let offset = (page - 1) * 30
        let body = "s=\(keyword)&type=1&offset=\(offset)&limit=30"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        req.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return [] }
        let tracks = songs.compactMap(build)
        return await Self.enrichFromDetail(tracks)
    }

    /// 老接口 /api/search/get 不带音质字段、`mvid` 永远是 0、`album.picUrl` 也常常缺,
    /// 用一次 /api/song/detail 批量补齐:hMusic/sqMusic/hrMusic 直读音质,真实 mvid
    /// 用来打 MV 角标,顺便拿封面。30 条 ID 一次请求,比之前每条歌一个 /api/album/{id}
    /// 高效得多。
    private static func enrichFromDetail(_ tracks: [Track]) async -> [Track] {
        guard !tracks.isEmpty else { return tracks }
        let idList = tracks.map(\.songmid).joined(separator: ",")
        guard let encoded = "[\(idList)]".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let u = URL(string: "https://music.163.com/api/song/detail/?ids=\(encoded)") else { return tracks }
        var req = URLRequest(url: u)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = json["songs"] as? [[String: Any]] else { return tracks }

        struct Detail { var picURL: String?; var qualities: [Quality]; var mvId: String? }
        var lookup: [String: Detail] = [:]
        for s in songs {
            guard let idAny = s["id"] else { continue }
            let id = String(describing: idAny)
            var qs: [Quality] = [.k128]
            // hMusic = 320k, sqMusic = FLAC, hrMusic = Hi-Res。mMusic 是 192k 在
            // 我们的 enum 里没有(直接归入 k128 不必要,不计),bMusic/lMusic 都是 128k。
            if (s["hMusic"] as? [String: Any]) != nil { qs.append(.k320) }
            if (s["sqMusic"] as? [String: Any]) != nil { qs.append(.flac) }
            if (s["hrMusic"] as? [String: Any]) != nil { qs.append(.hires) }
            let picURL = (s["album"] as? [String: Any])?["picUrl"] as? String
            var mvId: String?
            if let n = s["mvid"] as? Int, n > 0 { mvId = String(n) }
            lookup[id] = Detail(picURL: picURL, qualities: qs, mvId: mvId)
        }
        return tracks.map { t in
            guard let d = lookup[t.songmid] else { return t }
            var nt = t
            if let pic = d.picURL, !pic.isEmpty { nt.picURL = pic }
            nt.qualities = d.qualities
            if let m = d.mvId { nt.extras["mvId"] = m }
            return nt
        }
    }

    private func build(_ d: [String: Any]) -> Track? {
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
        // /api/search/get 不返回 hMusic/sqMusic/hrMusic 这些音质字段,enrichFromDetail
        // 会用 /api/song/detail 覆盖。这里只给一个 k128 兜底,保证万一 detail 失败也能播。
        // 之前老代码把 hMusic 错映射成 flac (hMusic 其实是 320k,sqMusic 才是 FLAC),
        // 那段误导代码已经搬到 detail enrichment 里改对了。
        var qs: [Quality] = [.k128]
        if (d["hMusic"] as? [String: Any]) != nil { qs.append(.k320) }
        if (d["sqMusic"] as? [String: Any]) != nil { qs.append(.flac) }
        if (d["hrMusic"] as? [String: Any]) != nil { qs.append(.hires) }
        // mvid 在 /api/search/get 里永远是 0 —— 真正的 mvid 由 enrichFromDetail 填。
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

// MARK: - QQ Music — uses u.y.qq.com/cgi-bin/musicu.fcg DoSearchForQQMusicLite
// (the legacy c.y.qq.com/soso public endpoint now returns empty lists; this newer
// JSON-RPC style endpoint still works without signing).

nonisolated struct QQMusicCatalogService: CatalogService {
    let source: SourceID = .tx

    func search(keyword: String, page: Int) async throws -> [Track] {
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let body: [String: Any] = [
            "req": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicLite",
                "param": [
                    "query": keyword,
                    "num_per_page": 30,
                    "page_num": page,
                    "search_type": 0,
                    "grp": 0,
                    "nqc_flag": 0,
                ],
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reqResp = json["req"] as? [String: Any],
              let respData = reqResp["data"] as? [String: Any],
              let respBody = respData["body"] as? [String: Any],
              let songs = respBody["item_song"] as? [[String: Any]] else { return [] }
        return songs.compactMap(build)
    }

    private func build(_ d: [String: Any]) -> Track? {
        let mid = (d["mid"] as? String) ?? ""
        guard !mid.isEmpty else { return nil }
        let name = (d["name"] as? String) ?? "未知"
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
        // QQ Music: `mv.vid` is the MV identifier consumed by MvUrlProxy.
        if let mv = d["mv"] as? [String: Any], let vid = mv["vid"] as? String, !vid.isEmpty {
            extras["mvId"] = vid
        }
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

// MARK: - Migu

nonisolated struct MiguCatalogService: CatalogService {
    let source: SourceID = .mg

    func search(keyword: String, page: Int) async throws -> [Track] {
        guard let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        let urlStr = "https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do?isCopyright=1&isCorrect=1&pageNo=\(page)&pageSize=30&searchSwitch=%7B%22song%22%3A1%7D&sort=0&text=\(enc)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Android_migu", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["songResultData"] as? [String: Any],
              let nested = result["resultList"] as? [Any] else { return [] }
        var out: [Track] = []
        for entry in nested {
            // Migu wraps each song record inside an inner array; flatten both shapes.
            if let arr = entry as? [[String: Any]] {
                for item in arr { if let t = build(item) { out.append(t) } }
            } else if let item = entry as? [String: Any] {
                if let t = build(item) { out.append(t) }
            }
        }
        return out
    }

    private func build(_ d: [String: Any]) -> Track? {
        let copyrightId = (d["copyrightId"] as? String) ?? ""
        let id = (d["id"] as? String) ?? ""
        guard !copyrightId.isEmpty || !id.isEmpty else { return nil }
        let songmid = id.isEmpty ? copyrightId : id
        let name = (d["name"] as? String) ?? "未知"
        let singers = (d["singers"] as? [[String: Any]]) ?? []
        let singer = singers.compactMap { $0["name"] as? String }.joined(separator: " / ")
        let albums = (d["albums"] as? [[String: Any]]) ?? []
        let albumName = albums.first?["name"] as? String
        let albumId = albums.first?["id"] as? String
        var pic: String?
        if let imgs = d["imgItems"] as? [[String: Any]] {
            pic = imgs.first(where: { ($0["imgSizeType"] as? String) == "03" })?["img"] as? String
                ?? imgs.first?["img"] as? String
        }
        var extras: [String: String] = ["copyrightId": copyrightId]
        if let lrcURL = d["lyricUrl"] as? String { extras["lrcUrl"] = lrcURL }
        // Migu: mvCopyrightId is the resourceId fed to /resourceinfo.do?resourceType=D.
        if let mv = d["mvCopyrightId"] as? String, !mv.isEmpty { extras["mvId"] = mv }
        return Track(
            id: Track.makeID(source: .mg, songmid: songmid),
            name: name,
            singer: singer.isEmpty ? "未知" : singer,
            albumName: albumName,
            albumId: albumId,
            source: .mg,
            songmid: songmid,
            duration: nil,
            picURL: pic,
            qualities: [.k128, .k320],
            extras: extras
        )
    }
}
