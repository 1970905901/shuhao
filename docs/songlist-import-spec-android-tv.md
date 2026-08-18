# 在线歌单导入实现方案 — Android TV

基于 iOS / Mac 已上线实现(`SonglistImporter.swift` + `SonglistImportSheet`)整理,移植到 Android TV 时按本方案一比一对齐。

> **范围**:用户粘贴一个分享链接(或裸 playlist ID + 平台选择) → 解析得到 `(平台, 歌单ID)` → 调对应平台的歌单详情接口拉所有曲目 → 在本地建一个用户歌单,把曲目灌进去。
>
> 不在范围:本地文件夹导入(见 `download-localimport-spec-android-tv.md`)、平台账号登录拉自己的歌单(没接,且很可能不接,平台风控严)。

---

## 1. 总体目标

1. **四个平台全覆盖**:网易云 / QQ / 酷狗 / 酷我。每家分享出来的 URL 形态都不一样,**用同一个解析入口识别** —— 用户不需要点平台 picker
2. **粘贴自动识别**:用户每输入一个字符就重新跑一遍正则,实时显示"已识别:酷我歌单 · 1234567"
3. **裸 ID 兜底**:用户没贴 URL 只贴了纯数字 ID → 让 TA 配合"来源平台"单选自己拼
4. **导入即去重**:同一首歌已经在本地歌单里(任何歌单都算)就不重复插入 —— 直接复用 `PlaylistStore.addTracks` 的去重逻辑
5. **进度可观察**:导入中显示 "正在拉取曲目…",完成后 "✓ 导入完成,共 N 首" 让用户看一眼再 dismiss
6. **失败可见**:接口报错(网络 / 平台风控 / 歌单空) → 用 Toast 或 inline 红字回报原文

---

## 2. 数据模型

复用 `discover-page-spec-android-tv.md` 里已经定义的 Track / SourceID / SonglistInfo / SonglistDetail / SonglistService 这一套。**本方案不引入任何新模型**,只新增一个解析中间产物:

```kotlin
/** URL/ID 解析结果。source + id 唯一定位一个平台歌单。 */
data class SonglistRef(val source: SourceID, val id: String)

sealed class ImportError(msg: String) : Throwable(msg) {
    object UnrecognizedURL : ImportError("无法识别歌单链接,请粘贴酷我 / 酷狗 / QQ / 网易云的歌单分享链接")
    class FetchFailed(detail: String) : ImportError("获取歌单失败:$detail")
    object EmptyPlaylist : ImportError("歌单为空或暂时无法读取")
}
```

---

## 3. URL 解析(`SonglistImporter.parse`)

用户粘贴的文本通常是 **"我用XX发现一个超棒的歌单 \"名字\" https://..." 这种分享文案**,夹杂中文、引号、链接。策略:

1. 先扫一次 URL —— 按各平台域名特征 + ID 抽取规则的正则数组逐一试
2. 全部失败再看是不是纯数字 ID —— 是的话返回 `null`,UI 层让用户选平台

### 3.1 各平台 URL 形态(必须全部覆盖)

| 平台 | URL 形态举例 | 抽取正则 |
|---|---|---|
| **网易云 (wy)** | `https://music.163.com/playlist?id=1234` <br/> `https://y.music.163.com/m/playlist?id=1234` <br/> `https://music.163.com/#/playlist?id=1234` | `music\.163\.com[^\s]*?[?#&]id=(\d+)` |
| **QQ (tx)** | `https://y.qq.com/n/ryqq/playlist/1234` <br/> `https://i.y.qq.com/n2/m/share/details/taoge.html?id=1234` <br/> `https://y.qq.com/n/yqq/playsquare/1234.html` | `y\.qq\.com/n/ryqq/playlist/(\d+)` <br/> `qq\.com[^\s]*?taoge\.html[^\s]*?[?&]id=(\d+)` <br/> `y\.qq\.com[^\s]*?/playsquare/(\d+)` |
| **酷狗 (kg)** | `https://www.kugou.com/songlist/1234/` <br/> `https://t1.kugou.com/share?listid=1234` <br/> `https://t1.kugou.com/share?global_collection_id=xxx` | `kugou\.com/songlist/(\d+)` <br/> `kugou\.com[^\s]*?[?&]listid=(\d+)` <br/> `kugou\.com[^\s]*?[?&]global_collection_id=(\d+)` |
| **酷我 (kw)** | `https://www.kuwo.cn/playlist_detail/1234` <br/> `http://m.kuwo.cn/newh5app/playlist_detail/1234` <br/> `https://www.kuwo.cn/playlists?pid=1234` | `kuwo\.cn[^\s]*?/playlist_detail/(\d+)` <br/> `kuwo\.cn[^\s]*?[?&]pid=(\d+)` |

### 3.2 实现骨架

```kotlin
object SonglistImporter {

    fun parse(raw: String): SonglistRef? {
        val s = raw.trim()
        if (s.isEmpty()) return null

        // 顺序无所谓 —— 每个 pattern 只匹配自己平台的域名,不会跨平台误中
        val rules = listOf(
            SourceID.WY to listOf(
                "music\\.163\\.com[^\\s]*?[?#&]id=(\\d+)"
            ),
            SourceID.TX to listOf(
                "y\\.qq\\.com/n/ryqq/playlist/(\\d+)",
                "qq\\.com[^\\s]*?taoge\\.html[^\\s]*?[?&]id=(\\d+)",
                "y\\.qq\\.com[^\\s]*?/playsquare/(\\d+)"
            ),
            SourceID.KG to listOf(
                "kugou\\.com/songlist/(\\d+)",
                "kugou\\.com[^\\s]*?[?&]listid=(\\d+)",
                "kugou\\.com[^\\s]*?[?&]global_collection_id=(\\d+)"
            ),
            SourceID.KW to listOf(
                "kuwo\\.cn[^\\s]*?/playlist_detail/(\\d+)",
                "kuwo\\.cn[^\\s]*?[?&]pid=(\\d+)"
            )
        )
        for ((source, patterns) in rules) {
            for (pat in patterns) {
                val m = Regex(pat, RegexOption.IGNORE_CASE).find(s) ?: continue
                val id = m.groupValues.getOrNull(1)?.takeIf { it.isNotEmpty() } ?: continue
                return SonglistRef(source, id)
            }
        }
        return null  // 让 UI 层判断 pureID 走 manual source picker
    }

    /** UI 调:整段文本是纯数字 → 让用户配平台选择器自己拼。 */
    fun pureIdOrNull(raw: String): String? {
        val s = raw.trim()
        return if (s.isNotEmpty() && s.all { it.isDigit() }) s else null
    }
}
```

**关键**:四组规则之间**没有先后顺序**,因为每条都锚定域名。错配几乎不可能 —— 网易云的 `?id=1234` 只在 `music.163.com` 域名下,不会撞上其他家。

---

## 4. 拉歌单详情(`fetchDetail`)

每家平台一套 API。Android 端走 OkHttp + 协程,实现时 **直接对照 iOS `Songlists.swift` 里对应的 `SonglistService.fetchDetail` 函数**(已经踩过坑、跑通的版本)。下面按平台列接口和返回结构关键点 —— 完整字段映射写代码时回看 Songlists.swift。

> **共性约定**:
> - 所有请求都要带 mobile UA(默认 OkHttp UA 在酷狗等家会被风控直接 403):
>   `Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)`(QQ / 网易 / 酷我用这条)
>   酷狗例外:`Mozilla/5.0 (iPhone; CPU iPhone OS 9_1 ...) Mobile/13B143 Safari/601.1`
> - 超时 20s
> - 拉到详情后用 `info.name` (接口返回的标题)、`tracks` (曲目列表) 构 `SonglistDetail`
> - 每首歌都要走平台对应的 `buildTrack`(填好 `id` / `singer` / `albumName` / `qualities` 等),不要只塞个 songmid 上去 —— 播放、下载、Hi-Res 选档都依赖 `qualities`

### 4.1 网易云 (wy)

```
GET https://music.163.com/api/playlist/detail?id={pid}
Header: Referer: https://music.163.com/
```

返回 JSON:`result.tracks[]`,每首歌:
- `id` → track.songmid (字符串化)
- `name` → track.name
- `artists[].name` → 用 `" / "` 拼接成 singer
- `album.name` / `album.id` / `album.picUrl` → albumName / albumId / picURL
- `duration` (毫秒) / 1000 → track.duration
- 音质:`mMusic` 存在 → 加 .k320;`hMusic` 存在 → 加 .flac;默认有 .k128

### 4.2 QQ 音乐 (tx)

```
GET https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg
    ?type=1&json=1&utf8=1&onlysong=0&new_format=1
    &disstid={pid}&format=json&inCharset=utf8&outCharset=utf-8
    &notice=0&platform=yqq.json&needNewCode=0
Header:
  Origin:  https://y.qq.com
  Referer: https://y.qq.com/n/yqq/playsquare/{pid}.html
```

返回 JSON:`cdlist[0].songlist[]`。曲目构造**复用 QQTrackBuilder**(也就是搜索/排行榜共用的那个),不要在导入这里重写一遍。

### 4.3 酷狗 (kg)

酷狗最绕,**两步**:

1. **抓 HTML 拿 hash 列表**
   ```
   GET http://www2.kugou.kugou.com/yueku/v9/special/single/{specialid}-5-9999.html
   ```
   正文里找 `global.data = [ ... ];`,JSON 解析后每项的 `.hash` 字段(转大写)就是要的。

2. **批量解析 hash → 完整 song info**(每 100 一批,**并发**跑、按 chunk index 排序拼回):
   ```
   POST http://gateway.kugou.com/v2/album_audio/audio
   Headers:
     Content-Type: application/json
     KG-THash: 13a3164
     KG-RC:    1
     KG-Fake:  0
     KG-RF:    00869891
     User-Agent: Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi
     x-router:  kmr.service.kugou.com
   Body: {
     "area_code":"1","show_privilege":1,"show_album_info":"1","is_publish":"",
     "appid":1005,"clientver":11451,"mid":"1","dfid":"-",
     "clienttime":1586163263991,"key":"OIlwieks28dk2k092lksi2UIkp",
     "fields":"album_info,author_name,audio_info,ori_audio_name,base,songname",
     "data": [{"hash":"<HASH1>"}, {"hash":"<HASH2>"}, ...]
   }
   ```

   返回 `data[]`,**注意每行可能是 `[obj]` 也可能直接是 `obj` 也可能是失败标记**,不能直接 cast 整个 `data` 当 `[[obj]]`,要逐行解。

   音质:`audio_info.filesize` / `filesize_320` / `filesize_flac` / `filesize_high` 非 0 即对应支持 .k128 / .k320 / .flac / .flac24。

   `audio_info.timelength` (毫秒) / 1000 → duration。

   **上限保护**:`hashes.take(500)`,防止用户导一个 5000 首的离谱歌单把内存打爆。

### 4.4 酷我 (kw)

```
GET http://nplserver.kuwo.cn/pl.svc?op=getlistinfo
    &pid={pid}&pn=0&rn=300&encode=utf8&keyset=pl2012&identity=kuwo
    &pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1
```

返回 JSON:`result == "ok"` 且 `musiclist[]` 有内容。每首歌:
- `id` → track.songmid
- `name` / `artist` / `album` / `albumid` → 标量字段(注意 `&nbsp;` / `&amp;` 要解一下)
- `duration`(字符串秒)
- 音质 `formats` 是用 `|` 分隔的码:`MP3128` / `MP3H` / `ALFLAC` / `HIRFLAC` / `AC4256` 对应 k128/k320/flac/flac24

**额外一步**:酷我曲目的 `picURL` 接口不返回,要走 `artistpicserver` 异步补封面 —— 这部分跟排行榜走的是同一个 helper `KuwoBoardService.fillKuwoCovers`,Android 上把它做成 `KuwoCoverFiller.fill(tracks)` 同样的 fan-out 即可。**没填到也不影响导入**,UI 上回落默认封面。

---

## 5. 导入主流程

```kotlin
suspend fun importPlaylist(
    ref: SonglistRef,
    customName: String?,
    playlists: PlaylistStore
): ImportResult {
    val svc = Songlists.service(ref.source) ?: throw ImportError.UnrecognizedURL

    // stub:fetchDetail 只看 .id / .source,其它字段填空即可
    val stub = SonglistInfo(id = ref.id, source = ref.source,
        name = "", author = "", picURL = null, trackCount = null, playCount = null)

    val detail = try {
        svc.fetchDetail(stub)
    } catch (e: Exception) {
        throw ImportError.FetchFailed(e.localizedMessage ?: e.toString())
    }
    if (detail.tracks.isEmpty()) throw ImportError.EmptyPlaylist

    // 歌单名优先级:用户指定 > 接口返回的名字 > 兜底 "导入的歌单"
    val trimmed = customName?.trim().orEmpty()
    val name = when {
        trimmed.isNotEmpty() -> trimmed
        detail.info.name.isNotEmpty() -> detail.info.name
        else -> "导入的歌单"
    }
    val playlist = playlists.createPlaylist(name)
    playlists.addTracks(detail.tracks, playlist.id)
    return ImportResult(playlistId = playlist.id, count = detail.tracks.size)
}

data class ImportResult(val playlistId: String, val count: Int)
```

**关键**:`createPlaylist` + `addTracks` 是 `PlaylistStore` 已有的两个公开 API,内部含去重和持久化。导入功能本身**不写 IO** —— 全靠 store 把整件事落盘。

---

## 6. UI 弹窗(`SonglistImportSheet`)

### 6.1 字段

```
┌──────────────────────────────────────────────────┐
│ 导入歌单                                          │
│                                                   │
│ 歌单链接                                          │
│ ┌──────────────────────────────────────────────┐ │
│ │ 粘贴酷我/酷狗/QQ/网易云的歌单分享链接或 ID    │ │
│ └──────────────────────────────────────────────┘ │
│ ✓ 已识别:网易云歌单 · 1234567                  │
│                                                   │
│ (识别失败但纯数字 ID 时显示)                       │
│ 来源平台: [网易云] [QQ音乐] [酷狗] [酷我]         │
│                                                   │
│ 支持的链接形式举例:                               │
│  • music.163.com/playlist?id=…                   │
│  • y.qq.com/n/ryqq/playlist/…                    │
│  • kugou.com/songlist/…                          │
│  • kuwo.cn/playlist_detail/…                     │
│                                                   │
│ 歌单名(可选)                                     │
│ ┌──────────────────────────────────────────────┐ │
│ │ 留空则用原歌单名                              │ │
│ └──────────────────────────────────────────────┘ │
│                                                   │
│ [正在拉取曲目…]  ← importing                      │
│ ✓ 导入完成,共 42 首  ← done                      │
│                                                   │
│ ┌────────┐  ┌──────────┐                         │
│ │  取消  │  │ 确定导入 │                         │
│ └────────┘  └──────────┘                         │
└──────────────────────────────────────────────────┘
```

### 6.2 状态机

```
状态: idle  → typing → recognized | pureId | unrecognized
                              ↓ (点击导入)
                          importing
                              ↓
                          done(count) → dismiss(900ms 延迟)
                              ↓
                          error(msg) → 红字 inline 显示,回到 typing 重试
```

- **typing**:每次 `onValueChange` 都跑一遍 `parse(raw)` / `pureIdOrNull(raw)`,Recompose 显示绿色 ✓ 标签或来源平台 picker
- **importing**:`确定导入` 变 disabled + 文字改 "导入中…",同时 ProgressView 显示在表单底部,interactiveDismissDisabled
- **done**:用 `delay(900ms)` 让用户看一眼绿色 "✓ 导入完成,共 N 首" 再 dismiss
- **error**:inline 红字一行 + 不 dismiss,用户改 URL 重试

### 6.3 `canImport` 计算

```kotlin
val canImport = !importing && doneCount == null
              && (parsedRef != null || pureID != null)
```

URL 模式下 `parsedRef` 已含 source;纯 ID 模式用 `pureID` + `manualSource` 拼一个 `SonglistRef`。

### 6.4 触发入口

资料库页 (`LibraryView`) 顶部菜单,跟"创建歌单"、"本地导入"并列三项:

```
[+] 添加
   ├─ ➕ 创建歌单
   ├─ 🔗 导入歌单   ← 本方案
   └─ 📁 本地导入
```

---

## 7. 焦点导航(TV 专属,与 iOS / Mac 不同)

TV 没有触屏 / 鼠标,弹窗里所有可交互元素必须能用 D-pad 走通:

- 默认焦点落 **URL 输入框**(用户上来就要粘贴,贴完才有别的事可干)
- D-pad 下 → 来源平台 picker(如果可见) → 歌单名输入框 → `确定导入` 按钮
- `确定导入` 在 disabled 状态下也要能聚焦(让用户看到光圈,知道按了为啥不响应);Compose 里用 `Modifier.focusable(enabled = true).clickable(enabled = canImport)`
- 弹窗本身在 TV 上用全屏 Dialog,不要 partial sheet(Android TV 焦点框架对底部 sheet 支持差)

剪贴板贴粘:TV 上系统级粘贴依赖蓝牙键盘,默认遥控器没法粘;**遥控器场景下用户多半是用手机扫码 + 推送 ID**,这条路下次再做。当下规格仍按"用户能粘贴" 设计,但**为遥控器留一个兜底**:

```
左下小按钮: [📷 显示二维码]  ← Phase 2
            扫码进配对页,手机端把 URL 推给 TV → 通过本地局域网回调直接填进输入框
```

Phase 1 不做二维码,只保留 UI 占位让后续好加。

---

## 8. 持久化

**不需要额外的持久化**。整个导入产物就是一个普通用户歌单,落 `PlaylistStore` 已有的:

```
documents/playlists.json   ← List<PlaylistMeta>
documents/trackBank.json   ← Map<trackID, Track>
```

导入来源(从哪个平台、哪个 pid 来的)**故意不记录**:用户的"我的歌单"就是用户的,不带"导入痕迹",改名 / 加歌 / 删歌都跟其他歌单完全一致。

---

## 9. 自查清单

- [ ] 粘贴 `https://music.163.com/playlist?id=2034742057` → 识别成"网易云歌单 · 2034742057",导入后曲目数和接口返回一致
- [ ] 粘贴 `https://y.qq.com/n/ryqq/playlist/4055609000` → 识别成"QQ 音乐歌单",导入后曲目能播
- [ ] 粘贴 `https://www.kugou.com/songlist/3036247/` → 识别成"酷狗歌单 · 3036247",hash 解析没掉首歌
- [ ] 粘贴 `https://www.kuwo.cn/playlist_detail/2914582147` → 识别成"酷我歌单",曲目有封面(异步补)
- [ ] 粘贴纯数字 `2034742057` → 出现来源平台 segmented control,选网易云能正常导入
- [ ] 粘贴乱七八糟的字 → 识别失败,`确定导入` 保持 disabled
- [ ] 粘贴一个空歌单的 URL → 报错 "歌单为空或暂时无法读取",不创建空歌单
- [ ] 接口超时 → 报错文案是原始 error message,不是"未知错误"
- [ ] 导入过程中遥控器 BACK → 不能关弹窗(防止 partial state)
- [ ] 导入完成自动 dismiss 后,资料库里能看到这个新歌单,曲目数对得上
- [ ] 同一个 URL 导入两次 → 生成两个**独立**的本地歌单(导入不去重,这是 by design;用户要去重自己手动删)
- [ ] 酷狗 500 首大歌单 → 不卡 UI,进度提示一直 spin 着,最终能完成

---

## 10. 不做的事

- ❌ **平台账号登录后拉自己创建的歌单**:平台风控严,等价 OAuth 接,工作量过大
- ❌ **分享文案智能识别**(从一段微信分享文本里把链接拎出来):上面正则已经能扫散落 URL,做更花的 NLP 性价比低
- ❌ **导入时分音质 / 选音质**:导入只解析曲目列表,真正下载某首歌的音质走下载弹窗(见 `download-localimport-spec-android-tv.md`)
- ❌ **导入后自动下载全部**:歌单导入和批量下载是两件事,合并会模糊用户意图(导入完直接放到首页"导入歌单"页给用户,他可以再点全选下载)
- ❌ **持久化"导入来源" / 双向同步**:平台歌单更新了不会回流到本地导入歌单。想要新内容就再导一次

---

## 11. 实现顺序建议

1. **DAY 1**:`SonglistImporter.parse` + 测试用例(粘各种 URL 形态,断言正确解析)。**先写测试** —— URL 形态花样多,回归靠 unit test 兜底
2. **DAY 1-2**:把 iOS `Songlists.swift` 里四家的 `fetchDetail` 一比一翻译成 Kotlin。**网易云最简单先做,验证整链路通**;接着 QQ → 酷我 → 酷狗(酷狗最绕,放最后)
3. **DAY 2**:`importPlaylist` + UI 弹窗(用 Compose `AlertDialog` + Form 字段),手动跑 self-check 清单
4. **DAY 3**:TV 焦点导航打磨,接资料库菜单入口

---

## 参考

- `shuhao/SonglistImporter.swift` — 主逻辑 + UI
- `shuhao/Songlists.swift` — 每家 fetchDetail 实现细节
- `docs/discover-page-spec-android-tv.md` — Track / SonglistInfo / SonglistService 已经在那里定义,本方案是它的下游
- `docs/download-localimport-spec-android-tv.md` — `导入的歌单`里的曲目要支持下载就走那份方案的 DownloadStore
