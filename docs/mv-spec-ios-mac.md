# MV (音乐视频) 播放方案 — iOS / Mac

本方案来自 Android TV 端已上线实现，覆盖 5 个音源（kw 酷我 / wy 网易云 / kg 酷狗 / tx QQ音乐 / mg 咪咕）的 MV 抓取、清晰度选优、UI 接入、降级。请 iOS / Mac 按以下规格实现一遍。

> 协议盲点提前打招呼：lx-music v4 用户脚本协议**不包**音乐视频，所有 MV 都是绕开脚本直接打各平台官方 / 半官方接口。每家平台的 API 都不一样，下面逐个列。

---

## 1. 总体目标

1. **元数据层**：搜索 / 排行榜 / 歌单返回曲目时，识别该曲是否带 MV，存进 `Track.extras["mvId"]`，UI 在歌曲行渲染一个「MV」徽章。
2. **解析层**：用户在播放器点 MV 按钮 → 调 `MvResolver.getMvUrl(track)` → 返回 `MusicVideoInfo`（含 url + 多档清晰度 + 平台跳转页 URL）。
3. **播放层**：复用音频播放器同一个 video pipeline 播 mp4 流。退出 MV 回到音乐播放。
4. **质量层**：永远尽可能拿到最高清晰度，多档时按平台规则排序，`bestUrl` 返回最高那档。
5. **降级层**：拿到的 URL 播放器拒绝播（Kuwo 经常返回加密 `.mgg`）→ 提示后端不可用、不要静默卡死。

---

## 2. 数据模型

```swift
struct MusicVideoInfo {
    let id: String?                  // 平台原始 MV id（kw rid / wy mvid / kg mvHash / tx vid / mg copyrightId）
    let name: String?                // 优先用接口返回的，没有就用 track.name
    let url: URL?                    // 直接可播的 mp4。多档时等于 qualities 首项
    let pageUrl: URL?                // 平台 H5 跳转页（备用 / debug）
    let qualities: [MvQuality]       // 排序：最高清晰度在前
    
    /// 最佳可播 URL：优先 url，其次第一条非空的 qualities.url
    var bestUrl: URL? { url ?? qualities.first { $0.url != nil }?.url }
}

struct MvQuality {
    let type: String                 // 平台原始档位字符串："uhd"/"hd"、"1080"、"1080p"、"mp4"…
    let url: URL?
    let size: String?                // 可选（部分平台返回 filesize）
}
```

`Track.extras` 用 `[String: String]` 即可，关键字段：

| key | 内容 | 由谁填 |
|---|---|---|
| `mvId` | 平台 MV 主键 | 搜索 / 排行榜 / 歌单的曲目解析器 |

`Track.hasMv` 是个 derived property：

```swift
extension Track { 
    var hasMv: Bool { !(extras["mvId"] ?? "").isEmpty } 
}
```

---

## 3. mvId 元数据捕获（搜索 / 排行榜 / 歌单）

每家平台的搜索 / 榜单 / 歌单接口返回里有不同的「这首歌带 MV」标志位。**每个曲目构造器都要解析、写进 extras["mvId"]**，否则播放器的 MV 按钮无法生效。

### 3.1 酷我 (kw)

- 字段：`MVFLAG`（字符串 `"1"` 表示有 MV）
- mvId 值：直接用歌曲 id（kw 的 mvId 等同 songmid 的 rid）

```swift
if json["MVFLAG"] == "1" { extras["mvId"] = id }
```

### 3.2 酷狗 (kg)

- **搜索接口**字段：`MvHash`（字符串）
- **排行榜接口**字段：`mvhash`（小写）
- **歌单接口**字段：`audio_info.mvhash` 或 `audio_info.mv_hash`（API 版本不一，两个都试）
- mvId 值：上述 hash 本体

```swift
let mv = json["MvHash"] ?? json["mvhash"] ?? audio?["mvhash"] ?? audio?["mv_hash"] ?? ""
if !mv.isEmpty { extras["mvId"] = mv }
```

### 3.3 网易云 (wy)

- 字段：`mvid`（数字；> 0 表示有 MV）
- mvId 值：mvid 转字符串

```swift
if let mvid = json["mvid"] as? Int64, mvid > 0 { extras["mvId"] = String(mvid) }
```

### 3.4 QQ音乐 (tx)

- **搜索接口**：`mv.vid` 嵌套对象
- **排行榜接口**：`mv` 直接字符串
- mvId 值：vid 本体

```swift
let mv = (json["mv"] as? [String: Any])?["vid"] as? String
       ?? json["mv"] as? String
       ?? ""
if !mv.isEmpty { extras["mvId"] = mv }
```

### 3.5 咪咕 (mg)

- 字段：`mvCopyrightId`（字符串）
- mvId 值：copyrightId 本体

```swift
let mv = json["mvCopyrightId"] ?? ""
if !mv.isEmpty { extras["mvId"] = mv }
```

---

## 4. 解析器（MvResolver）

入口：

```swift
func getMvUrl(track: Track) async -> MusicVideoInfo? {
    switch track.source {
    case .kw: return await kuwo(track)
    case .wy: return await netease(track)
    case .kg: return await kugou(track)
    case .tx: return await qq(track)
    case .mg: return await migu(track)
    default:  return nil
    }
}
```

下面每家平台的实现细节。

---

### 4.1 酷我 (kw) ★ 最坑

**接口**：

```
GET http://antiserver.kuwo.cn/anti.s
    ?type=convert_url
    &rid=MV_<mvId>
    &format=mp4
    &response=url
Header: User-Agent: okhttp/3.10.0
```

返回是**纯文本** mp4 URL（不是 JSON）。

**坑 1 — DRM 占位文件**：未授权时 kw 会返回一个**固定的占位 mp3**，文件名常见为 `588957081.mp3` 或 `588957081.mp4`。播放器拿到这种 URL 解码出来是「仅在酷我音乐手机端播放」的语音提示。**必须拒绝**，否则用户体验是「点 MV 突然播一段广告语」。

判定规则：
1. URL 取末段（去掉 query），lowercase
2. 命中常量集 `{"588957081.mp3", "588957081.mp4"}` → reject
3. 以 `.mp3` 结尾 → reject（合法 MV 必然是 `.mp4`）

```swift
private func isKuwoMvPlaceholder(_ url: URL) -> Bool {
    let tail = url.lastPathComponent.lowercased()
    if tail == "588957081.mp3" || tail == "588957081.mp4" { return true }
    if tail.hasSuffix(".mp3") { return true }
    return false
}
```

**坑 2 — mvId fallback**：有时 search 没填 mvId 但歌曲又确实有 MV。fallback 是直接用 songmid（kw 的 mvId 和 songmid 数值一致）。

**返回结构**（单一档位）：

```swift
MusicVideoInfo(
    id: mvId, name: track.name, url: cleanedUrl,
    pageUrl: URL("http://www.kuwo.cn/mvplay/\(mvId)"),
    qualities: [MvQuality(type: "mp4", url: cleanedUrl, size: nil)]
)
```

---

### 4.2 网易云 (wy)

两步走：拿 mvid → 拉 detail。

**Step 1 — 确认 mvid**：

```swift
let mvid = track.extras["mvId"] != nil && track.extras["mvId"] != "0"
    ? track.extras["mvId"]!
    : await fetchMvidViaDetail(songmid)
```

`fetchMvidViaDetail` 通过：

```
GET https://music.163.com/api/song/detail?ids=[<songmid>]
Headers: Referer: https://music.163.com/, Origin: https://music.163.com
```

响应 `songs[0].mvid` 取出，`> 0` 才算有效。

**Step 2 — 拉详情 / 清晰度**：

```
GET https://music.163.com/api/mv/detail?id=<mvid>&type=mp4
Headers: Referer + Origin 同上
```

响应：

```json
{
  "code": 200,
  "data": {
    "name": "MV 名",
    "brs": {
      "240": "https://...mp4",
      "480": "https://...mp4",
      "720": "https://...mp4",
      "1080": "https://...mp4"   // 不一定有
    }
  }
}
```

`brs` 是个 map：**key 是码率（数字字符串），value 是直接 URL**。

**排序**：把 brs 的 key 转 Int 降序排，最大的就是最高清晰度。

```swift
let qualities = brs
    .compactMap { (k, v) -> MvQuality? in
        guard let url = URL(string: v as? String ?? "") else { return nil }
        return MvQuality(type: k, url: url, size: nil)
    }
    .sorted { (Int($0.type) ?? 0) > (Int($1.type) ?? 0) }
```

**pageUrl**：`https://music.163.com/#/mv?id=<mvid>`

---

### 4.3 酷狗 (kg)

**接口**：

```
GET https://m.kugou.com/app/i/mv.php?cmd=100&hash=<mvHash>
```

**清晰度档位（高 → 低）**：

```
uhd  超高清
rq   高品
sq   标清+
hd   高清
sd   标清
lq   流畅
```

响应里这些档位每个是一个 JSON 对象，里面同时可能有 `downurl` 和 `url` 两个字段，**优先 `downurl`**：

```swift
let tiers = ["uhd", "rq", "sq", "hd", "sd", "lq"]
let data = body["mvdata"] ?? body["data"] ?? body  // 三种可能位置
let qualities: [MvQuality] = tiers.compactMap { tier in
    guard let q = data[tier] as? [String: Any] else { return nil }
    let urlStr = (q["downurl"] as? String).orNonEmpty ?? (q["url"] as? String)
    return urlStr.flatMap { URL(string: $0) }.map { MvQuality(type: tier, url: $0, size: nil) }
}
```

**Fallback**：某些 payload 是「单一 URL 直接放在 data 根」，没分档位：

```swift
if qualities.isEmpty {
    let candidates = ["downurl", "url", "mv_url", "playurl"]
    for key in candidates {
        if let url = (data[key] as? String).flatMap({ URL(string: $0) }) {
            qualities = [MvQuality(type: "default", url: url, size: nil)]
            break
        }
    }
}
```

**pageUrl**：`https://www.kugou.com/mvweb/html/mv_<mvHash>.html`

---

### 4.4 QQ音乐 (tx) ★ payload 复杂

**接口**：

```
POST https://u.y.qq.com/cgi-bin/musicu.fcg
Headers:
  Referer: https://y.qq.com/
  User-Agent: Mozilla/5.0
  Content-Type: application/x-www-form-urlencoded
Body: JSON 字符串（见下）
```

**Body 结构**（batch 拿 video info + URL 一次完成）：

```json
{
  "comm": {
    "ct": 6, "cv": 0, "g_tk": 1646675364, "uin": 0,
    "format": "json", "platform": "yqq"
  },
  "mvInfo": {
    "module": "music.video.VideoData",
    "method": "get_video_info_batch",
    "param": {
      "vidlist": ["<mvVid>"],
      "required": [
        "vid","type","sid","cover_pic","duration","singers","new_switch_str",
        "video_pay","hint","code","msg","name","desc","playcnt","pubdate","isfav",
        "fileid","filesize_v2","switch_pay_type","pay","pay_info","uploader_headurl",
        "uploader_nick","uploader_uin","uploader_encuin","play_forbid_reason"
      ]
    }
  },
  "mvUrl": {
    "module": "music.stream.MvUrlProxy",
    "method": "GetMvUrls",
    "param": {
      "vids": ["<mvVid>"],
      "request_type": 10003,
      "addrtype": 3,
      "format": 264,
      "maxFiletype": 60
    }
  }
}
```

**响应**：

```json
{
  "mvInfo": { "data": { "<mvVid>": { "name": "...", ... } } },
  "mvUrl":  { "data": { "<mvVid>": { "mp4": [ /* 档位数组 */ ] } } }
}
```

**`mp4[]` 元素**：

```json
{
  "code": 0,                        // ≠ 0 跳过
  "newFileType": 60,                // 数字越大清晰度越高（首选排序依据）
  "filetype": 50,                   // newFileType 是 0 时兜底用
  "format": 40,                     // 再兜底
  "freeflow_url": [                 // 优先：完整 URL 数组，取第一个非空
    "https://..."
  ],
  "url": ["https://prefix..."],     // freeflow_url 全空时走这个
  "vkey": "abcd1234",               // 配合 url[0] 拼接
  "cn": "video.mp4"                 // 同上
}
```

**URL 拼接**：

```swift
let baseURL: String? = {
    // 1) freeflow_url 优先
    if let arr = item["freeflow_url"] as? [String], let u = arr.first(where: { !$0.isEmpty }) {
        return u
    }
    // 2) url + vkey + cn 拼接
    let u0 = (item["url"] as? [String])?.first ?? ""
    let vkey = item["vkey"] as? String ?? ""
    let cn   = item["cn"]   as? String ?? ""
    if !u0.isEmpty && !vkey.isEmpty && !cn.isEmpty {
        return "\(u0)\(vkey)/\(cn)?fname=\(cn)"
    }
    return nil
}()
```

**排序**：

```swift
let order = (item["newFileType"] as? Int).nonZero
         ?? (item["filetype"] as? Int).nonZero
         ?? (item["format"] as? Int) ?? 0
```

按 order 降序排，order 大的清晰度高。

**name**：用 `mvInfo.data.<mvVid>.name`，没有就用 track.name。

**pageUrl**：`https://y.qq.com/n/ryqq/mv/<mvVid>`

---

### 4.5 咪咕 (mg)

**接口**：

```
GET https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do
    ?resourceType=D
    &resourceId=<mvCopyrightId>
Header: User-Agent: Mozilla/5.0
```

响应：

```json
{
  "resource": [
    {
      "songName": "...",
      "bluerayPath":    "/path1080.mp4",     // 1080P 蓝光
      "highscreenPath": "/path720.mp4",      // 720P 高清
      "widescreenPath": "/path480.mp4"       // 480P 标清
    }
  ]
}
```

**清晰度档位（高 → 低）**：

```
bluerayPath     → 1080p
highscreenPath  → 720p
widescreenPath  → 480p
```

**坑** —— ★ Android 端踩过的：原来按字段顺序排是 `widescreen → highscreen`，导致 `bestUrl` 永远拿 480P。**必须按 blueray → highscreen → widescreen 顺序枚举**，最高的在最前。

**URL 前缀**：返回的字段是**相对路径**，前面要拼 `https://freetyst.nf.migu.cn/public`：

```swift
private func buildMguUrl(_ path: String) -> URL? {
    let p = path.hasPrefix("/") ? path : "/\(path)"
    return URL(string: "https://freetyst.nf.migu.cn/public\(p)")
}
```

**去重**：有些 MV 三档返回同一个链接，要去重避免假装多档。

```swift
var qualities: [MvQuality] = []
var seenURLs = Set<URL>()
for (label, key) in [("1080p", "bluerayPath"), ("720p", "highscreenPath"), ("480p", "widescreenPath")] {
    guard let p = resource[key] as? String, !p.isEmpty,
          let url = buildMguUrl(p), seenURLs.insert(url).inserted else { continue }
    qualities.append(MvQuality(type: label, url: url, size: nil))
}
```

**name**：用 `resource.songName`，没有就 track.name。

**pageUrl**：咪咕没合适的公开 H5 详情页，可以不填。

---

## 5. UI 接入

### 5.1 曲目行 MV 徽章

歌曲行（TrackRow）在 `track.hasMv == true` 时渲染一个紧凑徽章：

```
[MV]  绿色背景 18% 透明度 + 绿色文字 + 10sp Bold + 4dp 圆角 + 5/1 内边距
```

放在音质徽章左边、源标签 chip 左边。

### 5.2 播放器 MV 按钮

全屏播放器 TransportBar 右组（紧挨着播放队列按钮）：

```
[ MV ]   普通 pill，常态可用
```

点击：

```swift
Task {
    toast("正在获取 MV…")                       // 用户反馈
    guard let info = await mvResolver.getMvUrl(track),
          let url  = info.bestUrl else {
        toast("暂无可用 MV")
        return
    }
    playbackEngine.playMvUrl(url)              // 同一个 AVPlayer / AVPlayerLayer，切到 video sink
}
```

**Toast 必须给** —— 解析有时 1-3 秒，没反馈用户会以为按钮坏了。

### 5.3 MV 模式状态

`PlaybackState.isMv: Bool`，进入 MV 模式后：

- 主 UI 隐藏黑胶 / 歌词
- 显示 `AVPlayerLayer` 全屏 / 大窗
- 返回键 / Back 退出 MV 回到音乐播放（**不要 stop 音乐**，只是切回音频可视化）

### 5.4 ExoPlayer / AVPlayer 格式拒绝兜底

Kuwo 即使过了 `isKuwoMvPlaceholder` 检测，URL 还是可能是被 DRM 包过的 `.mgg`。AVPlayer 加载会失败，`AVPlayerItem.error` 触发。

```swift
playerItem.statusObserver = ... {
    if case .failed(let err) = $0.status {
        toast("MV 格式不支持，可能是音源限制")
        playbackEngine.exitMv()
    }
}
```

不要静默卡死。

---

## 6. 整体流程

```
用户点歌曲行 → 看到 [MV] 徽章 → 知道有视频可看
用户点全屏播放器 → 看到 [MV] 按钮 → 点
  ↓
toast("正在获取 MV…")
  ↓
MvResolver.getMvUrl(track) 异步执行
  ↓ (1-3 秒)
  ├─ 成功 → playMvUrl(bestUrl) → 切到视频层
  ├─ 失败 (nil) → toast("暂无可用 MV") → 留在音频播放
  └─ AVPlayer 加载报错 → toast("MV 格式不支持") → exitMv()
```

---

## 7. 已知现实情况

- **kw**：DRM 拒绝率高（特别是不付费账号），placeholder 占位文件常见。fallback：mvId 用 songmid 兜底。
- **wy**：付费 MV 也能拿到 URL，但播放可能 403。Master MV 都能拿，质量好。
- **kg**：质量档位最完整（6 档），返回稳定。`mvHash` 是搜索 / 榜单都能拿到的，可靠。
- **tx**：响应结构最复杂，payload 模板别改任何字段，`g_tk` 和 `addrtype` 都是必填且不能动。
- **mg**：返回简单，但要记得 blueray > highscreen > widescreen 的顺序。新版 SDK 可能加 4K 字段，留意 `4kPath` 之类的新 key。

---

## 8. 关键校验点（实现完拿这些自查）

1. 搜索一首带 MV 的 wy 歌（比如周杰伦的歌），TrackRow 看到 `[MV]` 徽章。
2. 进全屏播放器，点 MV → toast → 1-2 秒后出视频。
3. 用一首明显无 MV 的歌（搜「环境音」之类）→ TrackRow 不应该有徽章。
4. 故意搜个 kw 老歌（更可能 DRM）→ 点 MV → 不应该播出占位语音「仅在酷我...」，应该弹「暂无可用 MV」。
5. tx 一首热歌 → 返回的 `qualities` 至少有 2-3 档，`bestUrl` 是 `newFileType` 数值最大的那条。
6. mg 蓝光 MV → `bestUrl` 是 1080P 那条不是 480P。
7. 排行榜 / 歌单页打开后 TrackRow 也能看到 MV 徽章（说明非搜索路径也填了 extras）。

---

## 9. 复用代码段（参考实现）

下面这些是 Android 端 `MvResolver.kt` 里实测可用的常量 / 校验逻辑，iOS / Mac 直接抄过去即可。

```swift
// 酷我 DRM 占位文件名（小写比对）
let KUWO_PLACEHOLDER_FILES: Set<String> = ["588957081.mp3", "588957081.mp4"]

// 咪咕 URL 前缀
let MIGU_RESOURCE_PREFIX = "https://freetyst.nf.migu.cn/public"

// QQ MV payload comm（固定）
let QQ_COMM: [String: Any] = [
    "ct": 6, "cv": 0, "g_tk": 1_646_675_364, "uin": 0,
    "format": "json", "platform": "yqq"
]

// QQ MV required 字段列表（必须完整）
let QQ_MV_REQUIRED: [String] = [
    "vid","type","sid","cover_pic","duration","singers","new_switch_str",
    "video_pay","hint","code","msg","name","desc","playcnt","pubdate","isfav",
    "fileid","filesize_v2","switch_pay_type","pay","pay_info","uploader_headurl",
    "uploader_nick","uploader_uin","uploader_encuin","play_forbid_reason"
]
```

---

## 10. 不做的事

- ❌ **MV 收藏**：spec 不含；按音乐曲目收藏即可，MV 跟 track 1:1 绑定
- ❌ **MV 下载 / 缓存**：spec 不含；点播一次性流
- ❌ **MV 弹幕**：spec 不含
- ❌ **MV 评论**：spec 不含
- ❌ **跨源 MV 兜底**：原平台无 MV → 不要去其他平台找同名 MV（容易匹配错）
