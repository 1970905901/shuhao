import Foundation

/// Mirrors lx-music-mobile's `musicSdk/[source]/songList.js`:
///   - get recommended / tagged playlists (we keep it simple — hot/new recommended only)
///   - get tracks inside a specific playlist
nonisolated struct SonglistInfo: Identifiable, Hashable, Sendable {
    let id: String          // platform-side playlist id (e.g. Kuwo's pid)
    let source: SourceID
    let name: String
    let author: String
    let picURL: String?
    let trackCount: Int?
    let playCount: String?  // formatted "1.2万" etc
}

nonisolated struct SonglistDetail: Sendable {
    let info: SonglistInfo
    let tracks: [Track]
}

/// A platform-specific sort option. `id` is the value the platform's API expects
/// (e.g. "hot"/"new" for Kuwo, "5"/"6"/"7" for Kugou); `name` is the Chinese label.
nonisolated struct SonglistOrder: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
}

/// A single filter tag (歌单分类). `id` is what the platform's list API expects
/// (NetEase passes the Chinese category name; the others pass a numeric id).
/// `id == ""` means 全部 / no filter.
nonisolated struct SonglistTag: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    static let all = SonglistTag(id: "", name: "全部")
}

/// A named group of tags (热门/语种/风格/场景…). Groups and their contents differ per platform.
nonisolated struct SonglistTagGroup: Hashable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let tags: [SonglistTag]
}

nonisolated protocol SonglistService: Sendable {
    var source: SourceID { get }
    /// The sort tabs this platform supports (varies per source: 推荐/最热/最新/热藏/飙升…).
    var orders: [SonglistOrder] { get }
    /// Filter-tag groups for this platform. Empty ⇒ no filter UI is shown.
    func fetchTags() async throws -> [SonglistTagGroup]
    /// `tag == .all` (empty id) ⇒ recommended/unfiltered list.
    func fetchRecommended(order: SonglistOrder, tag: SonglistTag, page: Int) async throws -> [SonglistInfo]
    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail
    /// Search playlists by keyword. Empty result ⇒ no matches / unsupported.
    func search(keyword: String, page: Int) async throws -> [SonglistInfo]
}

// Default no-op filter/search so a platform can adopt the protocol incrementally.
nonisolated extension SonglistService {
    func fetchTags() async throws -> [SonglistTagGroup] { [] }
    func search(keyword: String, page: Int) async throws -> [SonglistInfo] { [] }
}

nonisolated enum Songlists {
    static let all: [any SonglistService] = [
        KuwoSonglistService(),
        NetEaseSonglistService(),
        KugouSonglistService(),
        QQSonglistService(),
    ]
    static func service(for source: SourceID) -> (any SonglistService)? {
        all.first { $0.source == source }
    }
}

// MARK: - Kuwo

nonisolated struct KuwoSonglistService: SonglistService {
    let source: SourceID = .kw
    let orders: [SonglistOrder] = [
        SonglistOrder(id: "new", name: "最新"),
        SonglistOrder(id: "hot", name: "最热"),
    ]

    func fetchRecommended(order: SonglistOrder, tag: SonglistTag, page: Int) async throws -> [SonglistInfo] {
        // No tag ⇒ recommended list (ordered); a tag ⇒ that tag's playlists.
        let urlStr = tag.id.isEmpty
            ? "http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?loginUid=0&loginSid=0&appUid=76039576&pn=\(page)&rn=36&order=\(order.id)"
            : "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagPlayList?loginUid=0&loginSid=0&appUid=76039576&pn=\(page)&id=\(tag.id)&rn=36"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 200,
              let outer = json["data"] as? [String: Any],
              let raw = outer["data"] as? [[String: Any]] else { return [] }
        return raw.compactMap(buildInfo)
    }

    // Tag groups via getTagList; numeric tag id feeds getTagPlayList above.
    func fetchTags() async throws -> [SonglistTagGroup] {
        let urlStr = "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagList?cmd=rcm_keyword_playlist&user=0&prod=kwplayer_pc_9.0.5.0&vipver=9.0.5.0&source=kwplayer_pc_9.0.5.0&loginUid=0&loginSid=0&appUid=76039576"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 200,
              let raw = json["data"] as? [[String: Any]] else { return [] }
        return raw.compactMap { type -> SonglistTagGroup? in
            guard let name = type["name"] as? String,
                  let items = type["data"] as? [[String: Any]] else { return nil }
            let tags = items.compactMap { item -> SonglistTag? in
                guard let n = item["name"] as? String else { return nil }
                // Only digest==10000 tags resolve via getTagPlayList; digest 43 ("专区") needs a
                // different endpoint/shape, so we skip those rather than ship dead filters.
                guard String(describing: item["digest"] ?? "") == "10000" else { return nil }
                let idVal = item["id"].map { String(describing: $0) } ?? ""
                return idVal.isEmpty ? nil : SonglistTag(id: idVal, name: n)
            }
            return tags.isEmpty ? nil : SonglistTagGroup(name: name, tags: tags)
        }
    }

    func search(keyword: String, page: Int) async throws -> [SonglistInfo] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        // client=kt returns strict JSON (the bare ver=mbox variant emits single-quoted pseudo-JSON).
        let urlStr = "http://search.kuwo.cn/r.s?client=kt&all=\(encoded)&pn=\(page - 1)&rn=30&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1&ft=playlist&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        // Kuwo's r.s returns JS-object-ish text (unquoted keys), like the music search endpoint.
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let abslist = KuwoTolerantJSON.array(text, key: "abslist")
        return abslist.compactMap { d -> SonglistInfo? in
            guard let id = (d["playlistid"].map { String(describing: $0) }), !id.isEmpty else { return nil }
            let plays = Int(d["playcnt"] as? String ?? "") ?? (d["playcnt"] as? Int) ?? 0
            return SonglistInfo(
                id: id,
                source: .kw,
                name: ((d["name"] as? String) ?? "未知歌单").decodingHTMLEntities(),
                author: ((d["nickname"] as? String) ?? "").decodingHTMLEntities(),
                picURL: d["pic"] as? String,
                trackCount: Int(d["songnum"] as? String ?? "") ?? (d["songnum"] as? Int),
                playCount: KuwoSonglistService.formatPlayCount(plays)
            )
        }
    }

    private func buildInfo(_ d: [String: Any]) -> SonglistInfo? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let total: Int? = (d["total"] as? Int) ?? Int(d["total"] as? String ?? "")
        let plays = d["listencnt"] as? Int ?? Int(d["listencnt"] as? String ?? "") ?? 0
        return SonglistInfo(
            id: id,
            source: .kw,
            name: ((d["name"] as? String) ?? "未知歌单").decodingHTMLEntities(),
            author: ((d["uname"] as? String) ?? "").decodingHTMLEntities(),
            picURL: d["img"] as? String,
            trackCount: total,
            playCount: KuwoSonglistService.formatPlayCount(plays)
        )
    }

    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail {
        let urlStr = "http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=\(list.id)&pn=0&rn=300&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1"
        guard let url = URL(string: urlStr) else { return SonglistDetail(info: list, tracks: []) }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["result"] as? String) == "ok",
              let musiclist = json["musiclist"] as? [[String: Any]] else {
            return SonglistDetail(info: list, tracks: [])
        }
        let rawTracks = musiclist.compactMap(buildTrack)
        // Resolve per-song covers via Kuwo's artistpicserver (reuses board helper).
        let tracks = await KuwoBoardService.fillKuwoCovers(rawTracks)
        let updated = SonglistInfo(
            id: list.id, source: list.source,
            name: (json["title"] as? String) ?? list.name,
            author: (json["uname"] as? String) ?? list.author,
            picURL: (json["pic"] as? String) ?? list.picURL,
            trackCount: (json["total"] as? Int) ?? tracks.count,
            playCount: list.playCount
        )
        return SonglistDetail(info: updated, tracks: tracks)
    }

    /// Same format codes as KuwoBoardService — extracted into helper later if needed.
    private func buildTrack(_ d: [String: Any]) -> Track? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let name = decode((d["name"] as? String) ?? "未知")
        let artist = decode((d["artist"] as? String) ?? "")
        let album = (d["album"] as? String).map(decode)
        let duration = Int((d["duration"] as? String) ?? "0") ?? 0

        var qs: [Quality] = []
        let codes = Set(((d["formats"] as? String) ?? "").split(separator: "|").map(String.init))
        if codes.contains("MP3128") { qs.append(.k128) }
        if codes.contains("MP3H") { qs.append(.k320) }
        if codes.contains("ALFLAC") { qs.append(.flac) }
        if codes.contains("HIRFLAC") || codes.contains("AC4256") { qs.append(.flac24) }
        if qs.isEmpty { qs = [.k128, .k320] }

        return Track(
            id: Track.makeID(source: .kw, songmid: id),
            name: name,
            singer: artist,
            albumName: album,
            albumId: d["albumid"] as? String,
            source: .kw,
            songmid: id,
            duration: duration > 0 ? duration : nil,
            picURL: nil,
            qualities: qs
        )
    }

    private func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func formatPlayCount(_ n: Int) -> String {
        if n > 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n > 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        return String(n)
    }
}

// MARK: - NetEase

nonisolated struct NetEaseSonglistService: SonglistService {
    let source: SourceID = .wy
    let orders: [SonglistOrder] = [
        SonglistOrder(id: "hot", name: "最热"),
    ]

    func fetchRecommended(order: SonglistOrder, tag: SonglistTag, page: Int) async throws -> [SonglistInfo] {
        let limit = 36
        let offset = (page - 1) * limit
        // NetEase's `cat` param is the category's Chinese name itself.
        let catName = tag.id.isEmpty ? "全部" : tag.name
        let cat = catName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "全部"
        let urlStr = "https://music.163.com/api/playlist/list?cat=\(cat)&order=\(order.id)&limit=\(limit)&offset=\(offset)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["playlists"] as? [[String: Any]] else { return [] }
        return arr.compactMap(buildInfo)
    }

    // NetEase's catalogue is effectively static; the `cat` value is the name, so id == name.
    func fetchTags() async throws -> [SonglistTagGroup] { NetEaseSonglistService.staticTags }
    private static func group(_ name: String, _ names: [String]) -> SonglistTagGroup {
        SonglistTagGroup(name: name, tags: names.map { SonglistTag(id: $0, name: $0) })
    }
    static let staticTags: [SonglistTagGroup] = [
        group("语种", ["华语", "欧美", "日语", "韩语", "粤语", "小语种"]),
        group("风格", ["流行", "摇滚", "民谣", "电子", "舞曲", "说唱", "轻音乐", "爵士", "乡村", "R&B/Soul", "古典", "民族", "英伦", "金属", "朋克", "蓝调", "雷鬼", "世界音乐", "拉丁", "另类/独立", "New Age", "古风", "后摇", "Bossa Nova"]),
        group("场景", ["清晨", "夜晚", "学习", "工作", "午休", "下午茶", "地铁", "驾车", "运动", "旅行", "散步", "酒吧"]),
        group("情感", ["怀旧", "清新", "浪漫", "性感", "伤感", "治愈", "放松", "孤独", "感动", "兴奋", "快乐", "安静", "思念"]),
        group("主题", ["影视原声", "ACG", "儿童", "校园", "游戏", "70后", "80后", "90后", "网络歌曲", "KTV", "经典", "翻唱", "吉他", "钢琴", "器乐", "榜单", "00后"]),
    ]

    func search(keyword: String, page: Int) async throws -> [SonglistInfo] {
        let limit = 30
        let offset = (page - 1) * limit
        let s = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        // type=1000 ⇒ playlists. The plain web search API avoids eapi crypto.
        let urlStr = "https://music.163.com/api/search/get?s=\(s)&type=1000&limit=\(limit)&offset=\(offset)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let arr = result["playlists"] as? [[String: Any]] else { return [] }
        return arr.compactMap(buildInfo)
    }

    private func buildInfo(_ d: [String: Any]) -> SonglistInfo? {
        guard let idAny = d["id"] else { return nil }
        let id = String(describing: idAny)
        let creator = d["creator"] as? [String: Any]
        let plays = (d["playCount"] as? Int) ?? 0
        return SonglistInfo(
            id: id,
            source: .wy,
            name: ((d["name"] as? String) ?? "未知歌单").decodingHTMLEntities(),
            author: ((creator?["nickname"] as? String) ?? "").decodingHTMLEntities(),
            picURL: d["coverImgUrl"] as? String,
            trackCount: d["trackCount"] as? Int,
            playCount: KuwoSonglistService.formatPlayCount(plays)
        )
    }

    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail {
        // 匿名调用没有任何接口能一次拿到全部曲目详情,必须两步走:
        // 1) POST v6 接口 → 歌单元信息 + 完整 trackIds(tracks 字段匿名只回前 10 首)
        // 2) 老批量详情接口 /api/song/detail?ids=[...] 按 100 个一组并行拉,
        //    返回的还是 buildTrack 认识的旧字段格式(artists/album/hMusic...)。
        guard let url = URL(string: "https://music.163.com/api/v6/playlist/detail") else {
            return SonglistDetail(info: list, tracks: [])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = "id=\(list.id)&n=100000&s=8".data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playlist = json["playlist"] as? [String: Any] else {
            // v6 挂了退回老接口 —— 至少能导前 10 首,不至于整单失败
            return try await fetchDetailLegacy(list)
        }
        let ids = ((playlist["trackIds"] as? [[String: Any]]) ?? [])
            .compactMap { d in d["id"].map { String(describing: $0) } }
        let updated = SonglistInfo(
            id: list.id, source: list.source,
            name: (playlist["name"] as? String) ?? list.name,
            author: ((playlist["creator"] as? [String: Any])?["nickname"] as? String) ?? list.author,
            picURL: (playlist["coverImgUrl"] as? String) ?? list.picURL,
            trackCount: (playlist["trackCount"] as? Int) ?? ids.count,
            playCount: list.playCount
        )
        // v6 自带的 tracks 匿名只有前 10 首;短歌单已全覆盖时不用再拉第二步
        let inline = ((playlist["tracks"] as? [[String: Any]]) ?? []).compactMap(buildTrack)
        if !ids.isEmpty && inline.count >= ids.count {
            return SonglistDetail(info: updated, tracks: inline)
        }
        // 100 个一组并行拉详情(最多 6 路并发,超大歌单别瞬间打出上百个请求),
        // 单组失败只丢那一组;最后按 trackIds 原始顺序重排。
        let chunks = stride(from: 0, to: ids.count, by: 100)
            .map { Array(ids[$0..<min($0 + 100, ids.count)]) }
        var byID: [String: Track] = [:]
        await withTaskGroup(of: [Track].self) { group in
            var pending = chunks.makeIterator()
            for _ in 0..<6 {
                guard let c = pending.next() else { break }
                group.addTask { await self.fetchSongDetails(c) }
            }
            for await tracks in group {
                for t in tracks { byID[t.songmid] = t }
                if let c = pending.next() {
                    group.addTask { await self.fetchSongDetails(c) }
                }
            }
        }
        let tracks = ids.compactMap { byID[$0] }
        return SonglistDetail(info: updated, tracks: tracks.isEmpty ? inline : tracks)
    }

    /// 老接口:GET /api/playlist/detail,匿名只回前 10 首详情。仅作 v6 失败时的兜底。
    private func fetchDetailLegacy(_ list: SonglistInfo) async throws -> SonglistDetail {
        let urlStr = "https://music.163.com/api/playlist/detail?id=\(list.id)"
        guard let url = URL(string: urlStr) else { return SonglistDetail(info: list, tracks: []) }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return SonglistDetail(info: list, tracks: [])
        }
        let trackArr = (result["tracks"] as? [[String: Any]]) ?? []
        let tracks = trackArr.compactMap(buildTrack)
        let updated = SonglistInfo(
            id: list.id, source: list.source,
            name: (result["name"] as? String) ?? list.name,
            author: ((result["creator"] as? [String: Any])?["nickname"] as? String) ?? list.author,
            picURL: (result["coverImgUrl"] as? String) ?? list.picURL,
            trackCount: (result["trackCount"] as? Int) ?? tracks.count,
            playCount: list.playCount
        )
        return SonglistDetail(info: updated, tracks: tracks)
    }

    /// 批量曲目详情:/api/song/detail?ids=[id,…],一组最多 100 个。
    /// 失败返回空数组而不是抛错 —— 调用方按组容错。
    private func fetchSongDetails(_ ids: [String]) async -> [Track] {
        let idsParam = "[" + ids.joined(separator: ",") + "]"
        guard let enc = idsParam.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://music.163.com/api/song/detail?ids=\(enc)") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = json["songs"] as? [[String: Any]] else { return [] }
        return songs.compactMap(buildTrack)
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
        var qs: [Quality] = [.k128]
        if (d["mMusic"] as? [String: Any]) != nil { qs.append(.k320) }
        if (d["hMusic"] as? [String: Any]) != nil { qs.append(.flac) }
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
            qualities: qs
        )
    }
}

// MARK: - QQ Music

/// Mirrors musicSdk/tx/songList.js. Recommended via `get_playlist_by_tag`,
/// detail via `fcg_ucc_getcdinfo_byids_cp.fcg`.
nonisolated struct QQSonglistService: SonglistService {
    let source: SourceID = .tx
    let orders: [SonglistOrder] = [
        SonglistOrder(id: "5", name: "最热"),
        SonglistOrder(id: "2", name: "最新"),
    ]
    private let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"

    func fetchRecommended(order: SonglistOrder, tag: SonglistTag, page: Int) async throws -> [SonglistInfo] {
        let size = 36
        let inner: [String: Any]
        if tag.id.isEmpty {
            let orderId = Int(order.id) ?? 5
            inner = [
                "comm": ["cv": 1602, "ct": 20],
                "playlist": [
                    "method": "get_playlist_by_tag",
                    "param": ["id": 10000000, "sin": size * (page - 1), "size": size, "order": orderId, "cur_page": page],
                    "module": "playlist.PlayListPlazaServer",
                ],
            ]
        } else {
            let cid = Int(tag.id) ?? 0
            inner = [
                "comm": ["cv": 1602, "ct": 20],
                "playlist": [
                    "method": "get_category_content",
                    "param": ["titleid": cid, "caller": "0", "category_id": cid, "size": size, "page": page - 1, "use_page": 1],
                    "module": "playlist.PlayListCategoryServer",
                ],
            ]
        }
        guard let innerData = try? JSONSerialization.data(withJSONObject: inner),
              let dataStr = String(data: innerData, encoding: .utf8),
              let enc = dataStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg?format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json&needNewCode=0&data=\(enc)")
        else { return [] }
        var req = URLRequest(url: url)
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playlist = json["playlist"] as? [String: Any],
              let pdata = playlist["data"] as? [String: Any] else { return [] }
        if tag.id.isEmpty {
            let arr = (pdata["v_playlist"] as? [[String: Any]]) ?? []
            return arr.compactMap(Self.buildInfo)
        } else {
            // get_category_content nests each playlist under `content.v_item[].basic`.
            let items = ((pdata["content"] as? [String: Any])?["v_item"] as? [[String: Any]]) ?? []
            return items.compactMap { ($0["basic"] as? [String: Any]).flatMap(Self.buildInfo) }
        }
    }

    /// Handles both the `get_playlist_by_tag` (cover_url_medium / access_num / creator_info)
    /// and `get_category_content` (cover.medium_url / play_cnt / creator) item shapes.
    private static func buildInfo(_ d: [String: Any]) -> SonglistInfo? {
        guard let tidAny = d["tid"] else { return nil }
        let id = String(describing: tidAny)
        let creator = (d["creator_info"] as? [String: Any]) ?? (d["creator"] as? [String: Any])
        let cover = d["cover"] as? [String: Any]
        var pic = (d["cover_url_medium"] as? String) ?? (d["cover_url_big"] as? String)
            ?? (cover?["medium_url"] as? String) ?? (cover?["default_url"] as? String)
        // 没有自定义封面的歌单 QQ 会返回官方默认图(绿底音符 cover_playlist.png),
        // 当成无封面处理,让 UI 显示 App 自己的占位图,风格更统一。
        if pic?.contains("mediastyle/global/img/cover_playlist") == true { pic = nil }
        let plays = (d["access_num"] as? Int) ?? (d["play_cnt"] as? Int) ?? 0
        return SonglistInfo(
            id: id, source: .tx,
            name: ((d["title"] as? String) ?? "未知歌单").decodingHTMLEntities(),
            author: ((creator?["nick"] as? String) ?? "").decodingHTMLEntities(),
            picURL: pic,
            trackCount: (d["song_ids"] as? [Any])?.count,
            playCount: KuwoSonglistService.formatPlayCount(plays)
        )
    }

    func fetchTags() async throws -> [SonglistTagGroup] {
        let urlStr = "https://u.y.qq.com/cgi-bin/musicu.fcg?loginUin=0&hostUin=0&format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json&needNewCode=0&data=%7B%22tags%22%3A%7B%22method%22%3A%22get_all_categories%22%2C%22param%22%3A%7B%22qq%22%3A%22%22%7D%2C%22module%22%3A%22playlist.PlaylistAllCategoriesServer%22%7D%7D"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tags = json["tags"] as? [String: Any],
              let tdata = tags["data"] as? [String: Any],
              let groups = tdata["v_group"] as? [[String: Any]] else { return [] }
        return groups.compactMap { g -> SonglistTagGroup? in
            guard let name = g["group_name"] as? String,
                  let items = g["v_item"] as? [[String: Any]] else { return nil }
            let tagList = items.compactMap { item -> SonglistTag? in
                guard let n = item["name"] as? String, let idAny = item["id"] else { return nil }
                return SonglistTag(id: String(describing: idAny), name: n)
            }
            return tagList.isEmpty ? nil : SonglistTagGroup(name: name, tags: tagList)
        }
    }

    func search(keyword: String, page: Int) async throws -> [SonglistInfo] {
        let limit = 30
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let urlStr = "http://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist?page_no=\(page - 1)&num_per_page=\(limit)&format=json&query=\(q)&remoteplace=txt.yqq.playlist&inCharset=utf8&outCharset=utf-8"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)", forHTTPHeaderField: "User-Agent")
        req.setValue("http://y.qq.com/portal/search.html", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        // QQ's playlist search marks the payload utf-8 but emits a few invalid bytes inside
        // user-authored titles, so strict JSON parsing fails — re-decode lossily and retry.
        let obj = (try? JSONSerialization.jsonObject(with: data))
            ?? (try? JSONSerialization.jsonObject(with: Data(String(decoding: data, as: UTF8.self).utf8)))
        guard let json = obj as? [String: Any],
              let d = json["data"] as? [String: Any],
              let list = d["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> SonglistInfo? in
            guard let idAny = item["dissid"] else { return nil }
            let creator = item["creator"] as? [String: Any]
            return SonglistInfo(
                id: String(describing: idAny), source: .tx,
                name: ((item["dissname"] as? String) ?? "未知歌单").decodingHTMLEntities(),
                author: ((creator?["name"] as? String) ?? "").decodingHTMLEntities(),
                picURL: item["imgurl"] as? String,
                trackCount: item["song_count"] as? Int,
                playCount: KuwoSonglistService.formatPlayCount(item["listennum"] as? Int ?? 0)
            )
        }
    }

    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail {
        let urlStr = "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=\(list.id)&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"
        guard let url = URL(string: urlStr) else { return SonglistDetail(info: list, tracks: []) }
        var req = URLRequest(url: url)
        req.setValue("https://y.qq.com", forHTTPHeaderField: "Origin")
        req.setValue("https://y.qq.com/n/yqq/playsquare/\(list.id).html", forHTTPHeaderField: "Referer")
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cdlist = json["cdlist"] as? [[String: Any]],
              let cd = cdlist.first,
              let songlist = cd["songlist"] as? [[String: Any]] else {
            return SonglistDetail(info: list, tracks: [])
        }
        let tracks = songlist.compactMap(QQTrackBuilder.build)
        let updated = SonglistInfo(
            id: list.id, source: list.source,
            name: (cd["dissname"] as? String) ?? list.name,
            author: (cd["nickname"] as? String) ?? list.author,
            picURL: (cd["logo"] as? String) ?? list.picURL,
            trackCount: tracks.count,
            playCount: list.playCount
        )
        return SonglistDetail(info: updated, tracks: tracks)
    }
}

// MARK: - Kugou

/// Mirrors musicSdk/kg/songList.js. Recommended via `getSpecial`; detail scrapes the playlist
/// HTML for song hashes, then resolves them through Kugou's gateway audio API.
nonisolated struct KugouSonglistService: SonglistService {
    let source: SourceID = .kg
    let orders: [SonglistOrder] = [
        SonglistOrder(id: "5", name: "推荐"),
        SonglistOrder(id: "6", name: "最热"),
        SonglistOrder(id: "7", name: "最新"),
        SonglistOrder(id: "3", name: "热藏"),
        SonglistOrder(id: "8", name: "飙升"),
    ]
    private let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 9_1 like Mac OS X) AppleWebKit/601.1.46 (KHTML, like Gecko) Version/9.0 Mobile/13B143 Safari/601.1"

    func fetchRecommended(order: SonglistOrder, tag: SonglistTag, page: Int) async throws -> [SonglistInfo] {
        // `c` is the category id; empty ⇒ all categories (recommended).
        let urlStr = "http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_ajax=1&cdn=cdn&t=\(order.id)&c=\(tag.id)&p=\(page)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["special_db"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let sidAny = d["specialid"] else { return nil }
            let id = String(describing: sidAny)
            let plays = (d["total_play_count"] as? String) ?? KuwoSonglistService.formatPlayCount(d["play_count"] as? Int ?? 0)
            let img = (d["img"] as? String) ?? (d["imgurl"] as? String)
            return SonglistInfo(
                id: id, source: .kg,
                name: ((d["specialname"] as? String) ?? "未知歌单").decodingHTMLEntities(),
                author: ((d["nickname"] as? String) ?? "").decodingHTMLEntities(),
                picURL: img?.replacingOccurrences(of: "{size}", with: "240"),
                trackCount: d["songcount"] as? Int,
                playCount: plays
            )
        }
    }

    func fetchTags() async throws -> [SonglistTagGroup] {
        let urlStr = "http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_smarty=1&"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["status"] as? Int) == 1,
              let d = json["data"] as? [String: Any],
              let tagids = d["tagids"] as? [String: Any] else { return [] }
        // `tagids` is keyed by category name; each value has a `.data` array of {id, name}.
        // (Group order is not guaranteed since JSON objects are unordered in Swift.)
        return tagids.compactMap { name, value -> SonglistTagGroup? in
            guard let obj = value as? [String: Any],
                  let items = obj["data"] as? [[String: Any]] else { return nil }
            let tags = items.compactMap { item -> SonglistTag? in
                guard let n = item["name"] as? String, let idAny = item["id"] else { return nil }
                return SonglistTag(id: String(describing: idAny), name: n)
            }
            return tags.isEmpty ? nil : SonglistTagGroup(name: name, tags: tags)
        }
    }

    func search(keyword: String, page: Int) async throws -> [SonglistInfo] {
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let urlStr = "http://msearchretry.kugou.com/api/v3/search/special?keyword=\(q)&page=\(page)&pagesize=30&showtype=10&filter=0&version=7910&sver=2"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any],
              let info = d["info"] as? [[String: Any]] else { return [] }
        return info.compactMap { item -> SonglistInfo? in
            guard let sidAny = item["specialid"] else { return nil }
            let img = (item["imgurl"] as? String) ?? (item["img"] as? String)
            return SonglistInfo(
                id: String(describing: sidAny), source: .kg,
                name: ((item["specialname"] as? String) ?? "未知歌单").decodingHTMLEntities(),
                author: ((item["nickname"] as? String) ?? "").decodingHTMLEntities(),
                picURL: img?.replacingOccurrences(of: "{size}", with: "240"),
                trackCount: item["songcount"] as? Int,
                playCount: KuwoSonglistService.formatPlayCount(item["playcount"] as? Int ?? 0)
            )
        }
    }

    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail {
        // 1) Scrape the playlist HTML for the song hash list (`global.data = [...]`).
        let htmlURLStr = "http://www2.kugou.kugou.com/yueku/v9/special/single/\(list.id)-5-9999.html"
        guard let htmlURL = URL(string: htmlURLStr) else { return SonglistDetail(info: list, tracks: []) }
        var htmlReq = URLRequest(url: htmlURL)
        htmlReq.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        htmlReq.timeoutInterval = 20
        let (htmlData, _) = try await URLSession.shared.data(for: htmlReq)
        guard let html = String(data: htmlData, encoding: .utf8) else { return SonglistDetail(info: list, tracks: []) }
        let hashes = Self.extractHashes(from: html)
        guard !hashes.isEmpty else { return SonglistDetail(info: list, tracks: []) }
        // 2) Resolve hashes to full song info via the gateway audio API.
        let tracks = try await resolveHashes(hashes)
        return SonglistDetail(info: list, tracks: tracks)
    }

    /// Parse `global.data = [ ... ];` and pull each item's `hash`.
    private static func extractHashes(from html: String) -> [String] {
        guard let r = html.range(of: "global.data = ") else { return [] }
        let after = html[r.upperBound...]
        guard let end = after.range(of: "];") else { return [] }
        let arrayLiteral = String(after[after.startIndex...end.lowerBound]) // up to and incl ']'
        guard let data = arrayLiteral.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { ($0["hash"] as? String)?.uppercased() }
    }

    /// Resolve all hashes (chunked by 100, like android's createTask) to full song info.
    /// Chunks run concurrently; results are re-ordered to preserve playlist order.
    private func resolveHashes(_ hashes: [String]) async throws -> [Track] {
        let capped = Array(hashes.prefix(500))   // guard against absurdly large playlists
        let chunks = stride(from: 0, to: capped.count, by: 100).map { Array(capped[$0..<min($0 + 100, capped.count)]) }
        let indexed = await withTaskGroup(of: (Int, [Track]).self) { group -> [(Int, [Track])] in
            for (i, chunk) in chunks.enumerated() {
                group.addTask { (i, (try? await Self.resolveChunk(chunk)) ?? []) }
            }
            var acc: [(Int, [Track])] = []
            for await r in group { acc.append(r) }
            return acc
        }
        return indexed.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }

    private static func resolveChunk(_ hashes: [String]) async throws -> [Track] {
        guard !hashes.isEmpty, let url = URL(string: "http://gateway.kugou.com/v2/album_audio/audio") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("13a3164", forHTTPHeaderField: "KG-THash")
        req.setValue("1", forHTTPHeaderField: "KG-RC")
        req.setValue("0", forHTTPHeaderField: "KG-Fake")
        req.setValue("00869891", forHTTPHeaderField: "KG-RF")
        req.setValue("Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi", forHTTPHeaderField: "User-Agent")
        req.setValue("kmr.service.kugou.com", forHTTPHeaderField: "x-router")
        req.timeoutInterval = 20
        let body: [String: Any] = [
            "area_code": "1", "show_privilege": 1, "show_album_info": "1", "is_publish": "",
            "appid": 1005, "clientver": 11451, "mid": "1", "dfid": "-",
            "clienttime": 1586163263991, "key": "OIlwieks28dk2k092lksi2UIkp",
            "fields": "album_info,author_name,audio_info,ori_audio_name,base,songname",
            "data": hashes.map { ["hash": $0] },
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outer = json["data"] as? [Any] else { return [] }
        // Loosely typed: a failed hash can come back as something other than an array, so we
        // must NOT cast the whole thing to [[Any]] (that fails wholesale). Handle each row.
        return outer.compactMap { row -> Track? in
            if let arr = row as? [Any], let d = arr.first as? [String: Any] { return buildTrack(d) }
            if let d = row as? [String: Any] { return buildTrack(d) }
            return nil
        }
    }

    private static func buildTrack(_ d: [String: Any]) -> Track? {
        let audio = d["audio_info"] as? [String: Any] ?? [:]
        let hash = (audio["hash"] as? String) ?? ""
        guard !hash.isEmpty else { return nil }
        let audioId = (audio["audio_id"] as? String) ?? (audio["audio_id"] as? Int).map(String.init) ?? hash
        let name = decode((d["songname"] as? String) ?? (d["ori_audio_name"] as? String) ?? "未知")
        let singer = decode((d["author_name"] as? String) ?? "")
        let albumInfo = d["album_info"] as? [String: Any]
        let albumName = (albumInfo?["album_name"] as? String).map(decode)
        let albumId = (albumInfo?["album_id"] as? String) ?? (albumInfo?["album_id"] as? Int).map(String.init)
        let durMs = Int((audio["timelength"] as? String) ?? "0") ?? (audio["timelength"] as? Int) ?? 0

        let nonZero: (Any?) -> Bool = { v in
            if let s = v as? String { return s != "0" && !s.isEmpty }
            if let i = v as? Int { return i != 0 }
            return false
        }
        var qs: [Quality] = []
        if nonZero(audio["filesize"]) { qs.append(.k128) }
        if nonZero(audio["filesize_320"]) { qs.append(.k320) }
        if nonZero(audio["filesize_flac"]) { qs.append(.flac) }
        if nonZero(audio["filesize_high"]) { qs.append(.flac24) }
        if qs.isEmpty { qs = [.k128] }

        var extras: [String: String] = ["hash": hash]
        if let albumId { extras["albumId"] = albumId }
        let pic: String? = (albumInfo?["sizable_cover"] as? String).flatMap {
            $0.isEmpty ? nil : $0.replacingOccurrences(of: "{size}", with: "240")
        }
        return Track(
            id: Track.makeID(source: .kg, songmid: audioId),
            name: name,
            singer: singer,
            albumName: albumName,
            albumId: albumId,
            source: .kg,
            songmid: audioId,
            duration: durMs > 0 ? durMs / 1000 : nil,
            picURL: pic,
            qualities: qs,
            extras: extras
        )
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Kuwo tolerant JSON

/// Kuwo's `search.kuwo.cn/r.s` endpoint returns JS-object-ish text with unquoted keys even when
/// `rformat=json` is requested. This mirrors KuwoCatalog's private parser, but pulls out an
/// arbitrary top-level array (e.g. `abslist`) instead of building tracks.
fileprivate enum KuwoTolerantJSON {
    static func array(_ text: String, key: String) -> [[String: Any]] {
        // Fast path: some responses are already valid JSON.
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj[key] as? [[String: Any]] { return arr }
        guard let r = text.range(of: "\(key):") else { return [] }
        let after = text[r.upperBound...]
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
        let body = quoteKeys(String(after[start...endIdx]))
        guard let data = body.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    /// Wrap bare identifier keys in double quotes so JSONSerialization accepts the payload.
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

// MARK: - HTML entity decoding

nonisolated extension String {
    /// Decode HTML entities found in platform-supplied titles (e.g. QQ playlist names contain
    /// `&#32;`/`&#124;`). Mirrors lx-music's `decodeName` (which uses the `he` library) for the
    /// named + numeric (decimal & hex) entities that actually show up. Cheap no-op without `&`.
    func decodingHTMLEntities() -> String {
        guard contains("&") else { return self }
        var s = self
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&nbsp;": " ", "&middot;": "·", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…",
        ]
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v) }
        s = Self.decodeNumeric(s, pattern: #"&#(\d+);"#, radix: 10)
        s = Self.decodeNumeric(s, pattern: #"&#[xX]([0-9A-Fa-f]+);"#, radix: 16)
        return s
    }

    private static func decodeNumeric(_ input: String, pattern: String, radix: Int) -> String {
        guard input.contains("&#"), let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        let mutable = NSMutableString(string: input)
        for m in re.matches(in: input, range: NSRange(location: 0, length: ns.length)).reversed() {
            let digits = ns.substring(with: m.range(at: 1))
            if let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code) {
                mutable.replaceCharacters(in: m.range, with: String(scalar))
            }
        }
        return mutable as String
    }
}
