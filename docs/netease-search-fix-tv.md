# TV 端网易云搜索/榜单/歌单音质 + MV 角标修复 patch

iOS 端已修，原因和验证细节见聊天记录。要点重复一遍：

1. `/api/search/get` 不返回 `hMusic / sqMusic / hrMusic` 字段，也不给真实 `mvid`(永远是 0)。
2. `/api/playlist/detail` 返回的 track 对象**带**这些字段 —— 这是榜单 / 歌单看起来"没问题"的原因。
3. 老映射 `hMusic → FLAC` 是**错的**:`hMusic` = 320k,FLAC 字段叫 `sqMusic`,Hi-Res 是 `hrMusic`。playlist/detail 路径上因为热门歌恰好两者都有,所以肉眼"对了",其实是误报。

## 改动 1:`SearchCatalog.kt` 的 `NetEaseSearch` —— 补 batch detail 请求

文件:`app/src/main/java/com/shuhao/tv/source/catalog/SearchCatalog.kt`

替换 `NetEaseSearch` 整个 class(约 180–220 行):

```kotlin
// MARK: - NetEase (music.163.com/api/search/get) ---------------------------------------------

private class NetEaseSearch(private val http: CatalogHttp) : SongCatalog {
    override val source = SourceID.WY

    override suspend fun search(keyword: String, page: Int): List<Track> {
        val offset = (page - 1) * 30
        val body = urlEncode("s=$keyword&type=1&offset=$offset&limit=30")
        val headers = mapOf("Referer" to "https://music.163.com/")
        val text = http.postForm("https://music.163.com/api/search/get", body, headers)
        val songs = JSONObject(text).optJSONObject("result")?.optJSONArray("songs") ?: return emptyList()
        val tracks = (0 until songs.length()).mapNotNull { build(songs.optJSONObject(it)) }
        return enrichFromDetail(tracks)
    }

    /**
     * /api/search/get 不返回音质字段、mvid 永远是 0、album.picUrl 也常缺。
     * 一次性 batch /api/song/detail 把 hMusic/sqMusic/hrMusic + 真实 mvid + 封面补齐。
     * 30 条一个请求,比之前每条单独打 /api/album/{id} 高效。
     */
    private suspend fun enrichFromDetail(tracks: List<Track>): List<Track> {
        if (tracks.isEmpty()) return tracks
        val idList = tracks.joinToString(",") { it.songmid }
        val ids = urlEncode("[$idList]")
        val headers = mapOf("Referer" to "https://music.163.com/")
        val text = runCatching {
            http.getText("https://music.163.com/api/song/detail/?ids=$ids", headers)
        }.getOrNull() ?: return tracks
        val songs = runCatching { JSONObject(text).optJSONArray("songs") }.getOrNull() ?: return tracks

        data class Detail(val picURL: String?, val qualities: List<Quality>, val mvId: String?)
        val lookup = HashMap<String, Detail>()
        for (i in 0 until songs.length()) {
            val s = songs.optJSONObject(i) ?: continue
            val id = s.opt("id")?.toString() ?: continue
            val qs = mutableListOf(Quality.K128)
            // hMusic = 320k, sqMusic = FLAC, hrMusic = Hi-Res。
            // mMusic 是 192k(我们 enum 没有这档),bMusic/lMusic 都是 128k(已经在 K128 兜底里)。
            if (s.optJSONObject("hMusic") != null) qs.add(Quality.K320)
            if (s.optJSONObject("sqMusic") != null) qs.add(Quality.FLAC)
            if (s.optJSONObject("hrMusic") != null) qs.add(Quality.HIRES)
            val pic = s.optJSONObject("album")?.optString("picUrl")?.ifEmpty { null }
            val mvId = s.optLong("mvid").takeIf { it > 0 }?.toString()
            lookup[id] = Detail(pic, qs, mvId)
        }
        return tracks.map { t ->
            val d = lookup[t.songmid] ?: return@map t
            t.copy(
                picURL = d.picURL ?: t.picURL,
                qualities = d.qualities,
                extras = if (d.mvId != null) t.extras + ("mvId" to d.mvId) else t.extras,
            )
        }
    }

    private fun build(d: JSONObject?): Track? {
        d ?: return null
        val id = d.opt("id")?.toString() ?: return null
        val artists = d.optJSONArray("artists")
        val singer = (0 until (artists?.length() ?: 0))
            .mapNotNull { artists?.optJSONObject(it)?.optString("name") }
            .filter { it.isNotEmpty() }.joinToString(" / ")
        val album = d.optJSONObject("album")
        // 搜索接口不带这些字段 —— enrichFromDetail 会覆盖。这里只给 K128 兜底,
        // 万一 detail 请求失败也能播。映射改对了:hMusic = 320k, sqMusic = FLAC, hrMusic = Hi-Res。
        val qs = mutableListOf(Quality.K128)
        if (d.optJSONObject("hMusic") != null) qs.add(Quality.K320)
        if (d.optJSONObject("sqMusic") != null) qs.add(Quality.FLAC)
        if (d.optJSONObject("hrMusic") != null) qs.add(Quality.HIRES)
        // mvid 在 /api/search/get 里永远是 0 —— 真正的 mvid 由 enrichFromDetail 填。
        val extras = mutableMapOf<String, String>()
        d.optLong("mvid").takeIf { it > 0 }?.toString()?.let { extras["mvId"] = it }
        return Track(
            id = Track.makeID(SourceID.WY, id),
            name = d.optString("name", "未知"),
            singer = singer.ifEmpty { "未知歌手" },
            albumName = album?.optString("name")?.ifEmpty { null },
            albumId = album?.opt("id")?.toString(),
            source = SourceID.WY,
            songmid = id,
            duration = d.optInt("duration").takeIf { it > 0 }?.div(1000),
            picURL = album?.optString("picUrl")?.ifEmpty { null },
            qualities = qs,
            extras = extras,
        )
    }
}
```

## 改动 2:`BoardCatalog.kt` 的 `buildNetEaseTrack` —— 修映射

文件:`app/src/main/java/com/shuhao/tv/source/catalog/BoardCatalog.kt`,大约 150-177 行。

替换:

```kotlin
internal fun buildNetEaseTrack(d: JSONObject?): Track? {
    d ?: return null
    val id = d.opt("id")?.toString() ?: return null
    val artists = d.optJSONArray("artists")
    val singer = (0 until (artists?.length() ?: 0))
        .mapNotNull { artists?.optJSONObject(it)?.optString("name") }
        .filter { it.isNotEmpty() }.joinToString(" / ")
    val album = d.optJSONObject("album")
    // 映射改对:hMusic = 320k, sqMusic = FLAC, hrMusic = Hi-Res。
    // /api/playlist/detail 返回的 track 一般这些字段都齐,所以排行榜/歌单
    // 直接读不用再批量补一次 detail。
    val qs = mutableListOf(Quality.K128)
    if (d.optJSONObject("hMusic") != null) qs.add(Quality.K320)
    if (d.optJSONObject("sqMusic") != null) qs.add(Quality.FLAC)
    if (d.optJSONObject("hrMusic") != null) qs.add(Quality.HIRES)
    // NetEase MV: 'mvid' > 0 means an MV exists. Same field name in board / songlist / search.
    val extras = mutableMapOf<String, String>()
    d.optLong("mvid").takeIf { it > 0 }?.toString()?.let { extras["mvId"] = it }
    return Track(
        id = Track.makeID(SourceID.WY, id),
        name = d.optString("name", "未知"),
        singer = singer.ifEmpty { "未知歌手" },
        albumName = album?.optString("name")?.ifEmpty { null },
        albumId = album?.opt("id")?.toString(),
        source = SourceID.WY,
        songmid = id,
        duration = d.optInt("duration").takeIf { it > 0 }?.div(1000),
        picURL = album?.optString("picUrl")?.ifEmpty { null },
        qualities = qs,
        extras = extras,
    )
}
```

`SonglistCatalog.kt` 里走的也是 `buildNetEaseTrack`(line 210 处调用),所以改完这一个,排行榜 + 歌单详情两条路一起好了。

## 验证

实测命令(任何机器跑都行,直接 curl):

```bash
# /api/search/get 返回字段(确认没有 hMusic/sqMusic/mvid)
curl -s -X POST 'https://music.163.com/api/search/get' \
  -H 'Referer: https://music.163.com/' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 's=晴天' --data-urlencode 'type=1' --data-urlencode 'limit=1' \
  | jq '.result.songs[0] | {hMusic, sqMusic, mvid}'

# /api/song/detail 返回字段(应有 hMusic/sqMusic/hrMusic/mvid)
curl -s 'https://music.163.com/api/song/detail/?ids=%5B186016%5D' \
  -H 'Referer: https://music.163.com/' \
  | jq '.songs[0] | {hMusic: (.hMusic!=null), sqMusic: (.sqMusic!=null), hrMusic: (.hrMusic!=null), mvid}'
```

预期:第一条 hMusic/sqMusic 为 null、mvid 为 0;第二条 hMusic/sqMusic 都 true、mvid 为 504177。

## 自查清单

- [ ] 搜"周杰伦" → 网易云结果应该有 SQ / Hi-Res 角标,热门歌应该带 MV 标
- [ ] 搜"陈奕迅" → 同上
- [ ] 飞行榜/热歌榜的网易云榜 → 角标应该比之前**更精确**(以前是 hMusic 一存在就贴 FLAC,现在要 sqMusic 才贴)
- [ ] 一首明显没 FLAC 的歌(网络歌手 cover) → 应该只显示 HQ 不再误标 FLAC
