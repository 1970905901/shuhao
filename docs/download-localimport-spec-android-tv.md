# 音乐下载 + 本地文件夹导入实现方案 — Android TV

基于 iOS / Mac 已上线实现整理,移植到 Android TV 时按本方案一比一对齐。两部分功能逻辑独立,**共用统一的封面缓存**和**统一的 Track 模型**,所以放在同一份方案里。

---

## 1. 总体目标

### 下载

1. **多档音质选择**:用户从弹窗选清晰度(STD / HQ / SQ / Hi-Res / Master 等),后端给的扩展档位也能下
2. **目录化组织**:文件按 `歌手/专辑/曲目号 - 歌名.ext` 命名落盘,既适合 Finder/资源管理器浏览,也适合扔进车载/外放设备直读
3. **多歌单分组**:用户可建多个"已下载子歌单",每首下载属于其中一个
4. **后台进度可观察**:UI 实时显示 0…1 进度,中途断网/取消能恢复或失败回报
5. **元数据写入**:下载完成后异步把 标题/歌手/专辑/封面/歌词 写进文件本体,**离线播放器也能正确识别**
6. **封面缓存**:从音频文件提取的 APIC/PICTURE 落 Caches,后续 UI 显示用本地高清封面,不走网络
7. **重名规避** + **同名歌手合并**:见 §3 文件命名约定
8. **持久化**:文件夹列表、下载记录全部 JSON 落盘,杀进程不丢失

### 本地导入

1. **文件夹粒度**:用户选一个目录,扫描所有音频文件(含子目录递归)生成歌单
2. **安全持久化路径**:Android 这边用 SAF (Storage Access Framework) 拿持久 `Uri`,等价 iOS 的 security-scoped bookmark
3. **标签提取**:标题/歌手/专辑/时长/内嵌封面/歌词 全部从文件本体读取,文件名只是兜底
4. **复用统一封面缓存**:同下载

---

## 2. 数据模型

跟之前发的 `discover-page-spec-android-tv.md` / `mv-spec` 用同一份 Track 模型,本方案新增的字段:

```kotlin
// 下载记录(完成 / 进行中 / 失败 都是这个类型)
data class DownloadRecord(
    val track: Track,
    val quality: Quality,
    var fileName: String,        // 相对路径:"歌手/专辑/01 - 歌名.flac"
    var status: DownloadStatus,  // downloading / completed / failed
    val folderID: String,        // UUID 字符串
    var errorMessage: String? = null,
)

enum class DownloadStatus { DOWNLOADING, COMPLETED, FAILED }

// 子歌单(一个"已下载"分类)
data class DownloadFolder(
    val id: String,              // UUID
    var name: String,
    val trackIDs: MutableList<String> = mutableListOf(),
)

// 下载前补抓的曲目详情(全部可选,拿不到不影响下载)
data class TrackDetails(
    val trackNumber: Int? = null,
    val trackTotal: Int? = null,
    val albumArtist: String? = null,
    val releaseDate: String? = null,     // "YYYY" 或 "YYYY-MM-DD"
    val genre: String? = null,
    val company: String? = null,
    val hiResCoverURL: String? = null,   // 比 track.picURL 更高清
)

// 本地文件夹记录(一个"已导入文件夹"对应一个用户歌单)
data class LocalFolderRecord(
    val id: String,              // UUID
    var name: String,
    val persistedUriString: String,  // Android: takePersistableUriPermission 拿到的 SAF uri
)
```

---

## 3. 下载主流程

### 3.1 触发入口

UI 上有"下载"按钮(歌曲行 ⋯ 菜单 + 播放器内菜单)。点击后弹下载弹窗,内容:

```
┌─────────────────────────────┐
│ 歌曲: <封面> <歌名> <歌手>     │
│ 音质: (单选)                  │
│   ○ STD 128k                 │
│   ● HQ  320k    ← 默认选最高  │
│   ○ SQ  FLAC                 │
│   ○ Hi-Res                   │
│ 下载到: [默认 ▾]   [+ 新建]    │
│ [开始下载]                    │
└─────────────────────────────┘
```

**关键**:音质列表 = `track.qualities ∪ (扩展档位 ∩ 脚本声明的能力)`。扩展档位(hires/atmos/master)在搜索元数据里几乎不报,只看脚本声明,跟选档逻辑(`audio-quality-spec-android-tv.md` §3)一致。默认选可选档位里最高的。

确定后调:

```kotlin
DownloadStore.download(track, quality, folderID)
```

### 3.2 download() 流程

```
download(track, quality, folderID):
  if records[track.id]?.status == DOWNLOADING: return  // 防重入

  // 重新下载已完成的歌(用户改了音质)→ 先把老文件清掉
  if records[track.id] != null: removeFile(track.id)

  // 占位记录 —— 文件名先空着,等详情接口给曲目号再回填
  record = DownloadRecord(track, quality, fileName="", DOWNLOADING, folderID)
  records[track.id] = record
  progress[track.id] = 0
  folders.find(folderID).trackIDs.addIfMissing(track.id)
  save()

  launch background runDownload(track, quality)
```

### 3.3 runDownload() 流程

```
runDownload(track, quality):
  // 详情(曲目号 + 高清封面) 和 解析播放 URL 并行
  details = async { TrackDetailFetcher.fetch(track) }
  url = try sources.resolveMusicURL(track, quality)  // 同播放,带降级级联
  details.await()

  // 扩展名:先信 URL pathExt(后端可能静默降级把 hires 实发 mp3),
  // 拿不到合法扩展名再按音质推断 —— flac 及以上(含 hires/atmos/master)都是 FLAC 容器
  urlExt = url.pathExtension.lowercase()
  ext = if (urlExt in {"mp3","flac","m4a","wav","ogg"}) urlExt
        else if (quality in {K128, K320}) "mp3"
        else "flac"

  // 拼最终文件名(三种形态):
  //   有专辑 + 曲目号: 歌手/专辑/NN - 歌名.ext
  //   有专辑无曲目号:  歌手/专辑 - 歌名.ext
  //   无专辑:          歌手 - 歌名.ext
  fileName = relativePath(track, ext, details?.trackNumber)
  fileName = uniquify(fileName, excluding=track.id)   // 重名时加 " (2)" / " (3)"
  records[track.id].fileName = fileName

  dest = primaryDir / fileName
  mkdir(dest.parentDir)

  // 下载,UI 实时拿进度
  FileDownloader.start(
    url, dest,
    onProgress = { p -> progress[track.id] = p },
    onFinish = { result ->
      progress[track.id] = null
      if (result is Success):
        records[track.id].status = COMPLETED
        embedMetadata(track, details, dest)   // fire-and-forget
      else:
        fail(track.id, result.error.message)
      save()
    }
  )
```

**关键参考**(已在 iOS 上踩过坑):
1. **`fileName` 先用空字符串占位**,详情接口给 trackNumber 后才能定名;这之前请求被取消,要靠 `fileName.isEmpty()` 防止 `appendingPathComponent("")` 删错根目录
2. **下载 HTTP 请求要带 mobile UA**,默认 OkHttp/URLSession UA 一些 CDN 直接拒
3. **元数据写入是 fire-and-forget**,失败只打日志,不回滚下载成功状态

### 3.4 文件命名

```kotlin
fun relativePath(track: Track, ext: String, trackNumber: Int?): String {
    val artist = sanitize(track.singer)
    val name = sanitize(track.name)
    val album = track.albumName?.takeIf { it.isNotEmpty() }
    return when {
        album != null && trackNumber != null && trackNumber > 0 ->
            "$artist/${sanitize(album)}/${"%02d".format(trackNumber)} - $name.$ext"
        album != null ->
            "$artist/${sanitize(album)} - $name.$ext"
        else ->
            "$artist - $name.$ext"
    }
}

/** 单组件消毒:`/` `:` 全角化,其它非法字符 `_`,首部点去掉。 */
fun sanitize(s: String): String {
    var t = s.replace('/', '／').replace(':', '：')
    for (ch in listOf('?', '*', '"', '<', '>', '|', '\\')) t = t.replace(ch.toString(), "_")
    t = t.trim()
    while (t.startsWith(".")) t = t.drop(1)
    return t.ifEmpty { "未知" }
}

/** 重名规避:已有同名文件 → 加 " (2)" / " (3)" 直到不撞 */
fun uniquify(fileName: String, excluding: String): String {
    fun taken(name: String): Boolean {
        if (records.any { it.key != excluding && it.value.fileName == name }) return true
        return File(primaryDir, name).exists()
    }
    if (!taken(fileName)) return fileName
    val ext = fileName.substringAfterLast('.', "")
    val base = fileName.substringBeforeLast('.', fileName)
    var n = 2
    while (taken("$base ($n).$ext")) n++
    return "$base ($n).$ext"
}
```

**关于同名歌手** —— 不做特殊处理,字符串精确匹配。同名歌手不同专辑会落到同一 `歌手/` 顶层但子专辑分隔;同名歌手同名专辑同名歌名才会触发 `uniquify`。中文歌曲库里同名歌手罕见,加平台后缀让文件名变丑得不偿失。

### 3.5 下载根目录

```
Android: 用 Environment.DIRECTORY_MUSIC + "/Shuhao/" (公共 Music 目录),
         需要权限就用 MediaStore Audio API 或 SAF 让用户授权
         (TV 上推荐 MediaStore,UX 简单)
TV 调试: Context.getExternalFilesDir(MUSIC) 不需要权限,但用户拔卡看不见
```

iOS 端:iPhone/iPad 用沙盒 `Documents/Downloads/`,Mac 用 `~/Music/Shuhao/`。

### 3.6 进度与失败

- `progress: Map<trackID, Double>`,UI 用 `@Published` / `StateFlow` 观察
- 下载失败:`status = FAILED`,`errorMessage` 存原文,UI 列表里给重试按钮
- App 重启时:JSON 里残留 `DOWNLOADING` 的记录 → 全部转 `FAILED("已中断")`,用户决定要不要重试

---

## 4. 元数据写入(下载后异步)

下载完文件落盘后,**异步** detached coroutine 跑:

```
embedMetadata(track, details, fileURL):
  // 1) 拉封面(优先详情给的高清,回落 track.picURL)
  coverData = fetch(details?.hiResCoverURL ?? track.picURL, mobileUA)
  coverMIME = http.Content-Type ?? guessFromExt(url)
  // 顺手丢进统一封面缓存
  if coverData not empty: coverCache.put(track.id, coverData)

  // 2) 歌词(用同一套 LyricsFetcher,跟播放复用)
  lyrics = lyricsResolver(track)
  lrcText = LRCSerializer.serialize(lyrics) if any

  // 3) 按扩展名分发写入
  switch fileURL.ext:
    case "mp3":  MP3TagWriter.write(...)    // ID3v2.4 + UTF-8
    case "flac": FLACTagWriter.write(...)   // Vorbis Comment + PICTURE block
    default: skip + log
```

### 4.1 MP3 (ID3v2.4)

写入帧:`TIT2`(title) / `TPE1`(artist) / `TALB`(album) / `TRCK`(NN/total) / `TYER`(year) / `TCON`(genre) / `TPUB`(publisher) / `TPE2`(album artist) / `USLT`(unsync lyrics) / `APIC`(picture)。

- 编码 byte = 3(UTF-8),不要用 16(UTF-16,iTunes 老版本兼容差)
- size 字段是 **syncsafe**(每字节 7 位),不是大端 32 位
- 写入流程:
  1. 读完整原文件
  2. 探测原有 ID3v2 头(`"ID3"` magic + syncsafe size),拿到要剥掉的旧 tag 长度
  3. 构造新 tag bytes(header + frames + padding)
  4. 输出 = 新 tag bytes + 原文件 [旧 tag 长度..end]
  5. 原子写回(写临时文件 → rename)

### 4.2 FLAC (Vorbis Comment + PICTURE)

写入字段:`TITLE` / `ARTIST` / `ALBUM` / `TRACKNUMBER` / `TRACKTOTAL` / `ALBUMARTIST` / `DATE` / `GENRE` / `ORGANIZATION` / `LYRICS`。封面单独走 PICTURE metadata block (type=4 即 STREAMINFO 之后)。

- VORBIS_COMMENT 字段长度是 **小端** 32 位(跟 ID3 反着)
- PICTURE block 有完整 header(picture type + MIME + description + width + height + depth + colors + data length + data),按 spec 拼
- 流程同上:读全文件 → 重组 metadata 链 → 拼回 audio frames

### 4.3 为什么读全文件再整体写回

音乐文件一般 < 50MB,一次性 load 进内存可接受;Hi-Res 24-bit FLAC 偶尔到 100MB+ 也还行。流式拼接代码量翻倍,目前先选简单 + 正确,真要省内存后续再改。

---

## 5. 封面缓存(下载和导入共用)

```
位置: Caches/EmbeddedCovers/<trackID>.img
键:   trackID(已经是文件名安全的,如 "kw_665163" / "local_<hash>")
值:   原始 JPEG/PNG/WebP 字节(写什么就读什么,不重新编码)
```

**接口**:

```kotlin
class CoverCache {
    fun put(trackID: String, data: ByteArray): Unit   // 异步落盘
    fun get(trackID: String): File?                    // 文件存在返回,否则 null
    fun displayCoverURL(track: Track): String?
        = get(track.id)?.toURI()?.toString() ?: track.picURL
}
```

**关键**:全 App 显示封面的统一入口走 `displayCoverURL(track)`。已下载/已导入的歌**离线高清**,未下载的回落网络 URL。

**Backfill**:App 启动时扫一遍已完成的下载,如果 cache 里没有对应封面,后台 utility 优先级队列调 `EmbeddedTagReader.read(wantCover=true)` 把封面提出来补到 cache。系统清掉 Caches 也能自动恢复。

---

## 6. 本地文件夹导入

### 6.1 入口

UI: 资料库页 → "本地导入"按钮 → 弹窗:

```
┌─────────────────────────────┐
│ 歌单名称: [____________]      │
│ 文件夹: [选择文件夹]   ← SAF   │
│ (扫描该文件夹及全部子目录)     │
│ [    确定导入    ]            │
└─────────────────────────────┘
```

### 6.2 importFolder() 流程

```
importFolder(uri, playlistName):
  // Android: 拿持久 Uri 权限 (类似 iOS 的 security-scoped bookmark)
  context.contentResolver.takePersistableUriPermission(uri, READ|WRITE)
  folderID = UUID()

  // 后台扫描(主线程会卡)
  files = withContext(IO) { scanAudioFiles(uri) }   // 返回相对路径列表,自然排序
  if files.isEmpty: throw NoAudioFiles

  tracks = []
  files.forEachIndexed { idx, rel ->
    fileUri = uri.subUri(rel)
    val (track, cover) = readTrack(fileUri, rel, folderID)
    tracks.add(track)
    if (cover != null) coverCache.put(track.id, cover)
    progress(idx + 1, files.size)
  }

  localFolders.add(LocalFolderRecord(folderID, playlistName, uri.toString()))
  save()
  playlistStore.createPlaylist(playlistName).also { it.addTracks(tracks) }
```

### 6.3 scanAudioFiles

递归遍历 `uri` 下所有文件,匹配扩展名白名单:

```kotlin
val audioExtensions = setOf("mp3", "flac", "m4a", "aac", "wav", "aif", "aiff", "caf")
```

返回相对路径(用文件夹名 + `/`),按 `String.localeCompare` 自然排序(让 `"01"`、`"02"`、…、`"10"` 顺序正确)。

### 6.4 readTrack(fileUri, rel, folderID) — 核心标签提取

**优先级**:平台原生 API → 自己解析 ID3/Vorbis Comment 兜底 → 文件名兜底。

```
readTrack(fileUri, rel, folderID):
  title = fileBaseName(rel)  // 去扩展名的文件名
  artist = ""
  album = null
  duration = null
  cover = null

  // 1) 平台原生 metadata 提取
  //    Android: MediaMetadataRetriever
  //    - 设置 setDataSource(context, fileUri)
  //    - extractMetadata(METADATA_KEY_TITLE/ARTIST/ALBUM/DURATION)
  //    - getEmbeddedPicture() 拿封面
  try { mmr.use { ... } } catch { /* 忽略,fallback 处理 */ }

  // 2) AVF/MMR 对 FLAC 的 Vorbis Comment 读取经常失败 —— 自己解析一遍兜底
  needFields = artist.isEmpty || album.isNullOrEmpty || title == fileBaseName(rel)
  if (cover == null || needFields):
    tags = EmbeddedTagReader.read(fileUri, wantCover=cover==null, wantFields=needFields)
    cover = cover ?: tags.cover
    if (artist.isEmpty && tags.artist != null) artist = tags.artist
    if ((album.isNullOrEmpty) && tags.album != null) album = tags.album
    if (tags.title != null && title == fileBaseName(rel)) title = tags.title

  // 3) 文件名兜底("歌手 - 歌名"),但要小心 "01 - 歌名" 那种 track-number 前缀
  if (artist.isEmpty):
    parts = title.split(" - ", limit=2)
    if (parts.size == 2):
      head = parts[0].trim()
      isAllDigits = head.isNotEmpty() && head.all { it.isDigit() }
      if (!isAllDigits):
        artist = head
        title = parts[1].trim()
      else:
        // track-number 前缀剥掉让 UI 干净,但不写回 trackNumber 字段
        title = parts[1].trim()

  if (artist.isEmpty) artist = "未知歌手"

  // 4) trackID 用 SHA256(folderID + "|" + rel)[:24],稳定且文件名安全
  hash = sha256("$folderID|$rel").hex().take(24)
  ext = rel.substringAfterLast('.').lowercase()
  lossless = ext in setOf("flac", "wav", "aif", "aiff", "caf")
  track = Track(
    id = "local_$hash",
    name = title,
    singer = artist,
    albumName = album,
    source = LOCAL,
    songmid = "lf://$folderID/$rel",   // 注意:存"协议+folderID+相对路径"
    duration = duration,
    qualities = listOf(if (lossless) FLAC else K320),
  )
  return (track, cover)
```

**踩过的坑**(必看):

1. **AVFoundation / MediaMetadataRetriever 对 FLAC 的 Vorbis Comment 几乎读不到** —— 标题/歌手/专辑全是 null。**必须**自己解析 Vorbis Comment 兜底,见 §7。
2. **`01 - 歌名.flac` 这种文件名**前半是 track number,不是歌手。文件名拆分时必须检查"前半全是数字"就拒绝当 artist。这个 bug iOS 上踩过,修了。
3. **trackID 用稳定哈希**(folderID + 相对路径),不要用 UUID() —— 重新扫描同一文件夹时要能匹配回老的播放记录/收藏状态。
4. **持久 Uri 权限**:Android 走 SAF 拿 `Uri` 后必须 `takePersistableUriPermission`,不然下次启动 app 就读不出来了。iOS 走 security-scoped bookmark,同样道理。

### 6.5 播放时解析

`songmid` 存的是 `lf://<folderID>/<rel>`,播放器拿到这个 string 后:

```kotlin
fun fileURI(track: Track): Uri? {
    if (!track.songmid.startsWith("lf://")) return null
    val body = track.songmid.removePrefix("lf://")
    val slash = body.indexOf('/')
    if (slash < 0) return null
    val folderID = body.substring(0, slash)
    val rel = body.substring(slash + 1)
    val root = resolveRootUri(folderID) ?: return null
    return root.appendPath(rel).takeIf { it.exists() }
}
```

`resolveRootUri(folderID)` 从 `LocalFolderRecord.persistedUriString` 解析回 `Uri`。Android 上是 `DocumentFile.fromTreeUri(context, Uri.parse(...))` + `findFile(rel)`。

---

## 7. EmbeddedTagReader(FLAC / MP3 标签解析)

平台原生 metadata API 不可靠时的兜底,纯字节级解析。一次调用同时拿封面 + 歌词 + 标题/歌手/专辑。

```kotlin
data class Tags(
    var cover: ByteArray? = null,
    var lyrics: String? = null,
    var title: String? = null,
    var artist: String? = null,
    var album: String? = null,
)

fun read(uri: Uri,
         wantCover: Boolean = true,
         wantLyrics: Boolean = true,
         wantFields: Boolean = false): Tags
```

### 7.1 FLAC

Magic 前 4 字节 = `"fLaC"`。后面是一串 metadata block,每块 4 字节 header(`isLast` bit + `type` 7 bits + `size` 24 bits),需要的块:

- **type 4 = VORBIS_COMMENT**:含 LYRICS / TITLE / ARTIST / ALBUM 字段(`KEY=value` 形式,UTF-8)
- **type 6 = PICTURE**:含封面(图片数据)

```
VORBIS_COMMENT payload 解析:
  vendorLen = readLE32(); skip(vendorLen)
  count = readLE32()
  artists = []
  repeat count {
    len = readLE32()
    entry = readString(len, UTF-8)
    parts = entry.split('=', limit=2)
    when (parts[0].uppercase()) {
      "LYRICS" -> tags.lyrics = parts[1]
      "TITLE" -> tags.title = parts[1]
      "ARTIST" -> artists.add(parts[1])  // 协作艺人多值,出现多次
      "ALBUM" -> tags.album = parts[1]
    }
  }
  if (artists.isNotEmpty()) tags.artist = artists.joinToString(" / ")

PICTURE payload 解析:
  readBE32()  // picture type
  mimeLen = readBE32(); skip(mimeLen)
  descLen = readBE32(); skip(descLen)
  readBE32() * 4  // width / height / depth / colors
  dataLen = readBE32()
  tags.cover = readBytes(dataLen)
```

注意:**Vorbis Comment 字段长度是 LE32,PICTURE block 内部是 BE32**。不一致,别看错。

### 7.2 MP3 (ID3v2.3 / v2.4)

Magic 前 3 字节 = `"ID3"`,第 4 字节 = version(3 或 4)。后面是 6 字节(flags 1 + tagSize 4)。

- `tagSize` 是 **syncsafe**(每字节 7 位)
- 帧 header 10 字节:id(4) + size(4) + flags(2)
- v2.4 的帧 size 是 syncsafe,v2.3 是大端 32 位 —— 必须看 version 选解码

需要的帧:`USLT`(歌词)、`APIC`(封面)、`TIT2`(标题)、`TPE1`(歌手)、`TALB`(专辑)。

```
T??? 文本帧 (TIT2/TPE1/TALB):
  encoding = readByte()  // 0=ISO-8859-1, 1=UTF-16, 2=UTF-16BE, 3=UTF-8
  text = readString(rest, encoding).trimEnd('\0', ' ')
  // 多值用 null 分隔 (v2.4) 或斜杠 (v2.3),取首段够用

USLT (歌词):
  encoding = readByte()
  lang = readBytes(3)
  descriptor = readNullTerminated(encoding)
  text = readString(rest, encoding)

APIC (封面):
  encoding = readByte()
  mime = readNullTerminatedLatin1()
  picType = readByte()
  desc = readNullTerminated(encoding)
  data = rest
```

**关键细节**:UTF-16 终结符是 **2 字节** `0x00 0x00`,不是 1 字节。`apicData` 解析很容易在这里栽。

---

## 8. 持久化

### 8.1 下载相关

```
documents/downloadFolders.json   ← List<DownloadFolder>
documents/downloadRecords.json   ← Map<trackID, DownloadRecord>
```

- 启动时 load,任何 `DOWNLOADING` 状态全部强转 `FAILED("已中断")`
- 每次增删改一次性 dump

### 8.2 本地导入相关

```
documents/localFolders.json      ← List<LocalFolderRecord>
```

- `persistedUriString` 存 SAF Uri 字符串
- 启动时不 eagerly 解析,等具体歌曲被播放时才 `resolveRootUri` (lazy,节省启动时间)

### 8.3 封面缓存

- 路径:`Caches/EmbeddedCovers/<sanitize(trackID)>.img`
- 启动时扫一遍目录拿 `cachedCoverIDs: Set<String>`,UI 知道哪些 track 有本地封面
- 后台 backfill:已完成下载里没有缓存封面的,逐个调 EmbeddedTagReader 提取

---

## 9. UI 关键点

### 9.1 下载列表(资料库 → 已下载)

- 顶层是 `DownloadFolder` 列表(子歌单),进入某个子歌单看里面的歌
- 进行中的下载单独一栏置顶:歌名 + 进度条(0…100%) + 取消按钮
- 失败的歌:红色文字 + "重试" 按钮
- 长按/⋯ 菜单:删除单首、改音质重下、移动到其他子歌单

### 9.2 本地导入弹窗

- 文件夹选择按钮 → 调系统 SAF picker(Android: `ACTION_OPEN_DOCUMENT_TREE`)
- 选定后自动填默认歌单名(用文件夹名)
- 导入中:`ProgressView(value: progress) { Text("读取歌曲信息 N%") }`
- 完成后:`✓ 导入完成,共 N 首` 让用户看一眼再 dismiss

### 9.3 焦点导航(TV 专属)

- 下载弹窗的音质 picker、子歌单 picker 都要 D-pad 友好
- 默认焦点在"开始下载"按钮,音质 / 子歌单切换用左右键
- 本地导入弹窗:默认焦点"选择文件夹"

---

## 10. 已下载查询接口

为 UI 准备的最小查询面:

```kotlin
class DownloadStore {
    fun isDownloaded(trackID: String): Boolean
    fun localURL(trackID: String): URI?           // 拿到本地文件 URI
    fun quality(trackID: String): Quality?
    fun tracks(folder: DownloadFolder): List<Track>
    val activeDownloads: List<DownloadRecord>     // 进行中
    val completedCount: Int
    
    fun download(track: Track, quality: Quality, folderID: String)
    fun retry(trackID: String)
    fun removeDownload(trackID: String)
    fun createFolder(name: String): DownloadFolder
    fun renameFolder(id: String, name: String)
    fun deleteFolder(id: String)                   // 连同里面所有歌一起删
}
```

**播放层**:`PlaybackEngine.setURLResolver` 注入一个回调,优先用 `downloadStore.localURL(track.id)`,没有再走在线 `sources.resolveMusicURL`。本地导入的歌通过 `LocalMusicStore.fileURI(track)` 同样优先于在线源。

---

## 11. 自查清单

- [ ] 下载 320k 一首 QQ 音乐的歌 → 资源管理器里能看到 `歌手/专辑/01 - 歌名.mp3`,标签里歌名/歌手/专辑/封面/歌词都写上了
- [ ] 下载 Hi-Res FLAC → 同上,扩展名 `.flac`,封面是 800×800 高清
- [ ] 同一歌手下载多张专辑 → 同一 `歌手/` 顶层下两个 `专辑/` 子文件夹
- [ ] 同一首歌点两次下载(改音质) → 老文件先删,只剩新文件,文件名没尾巴 `(2)`
- [ ] 下载途中杀进程 → 重启后状态变成"失败(已中断)",列表里能看到重试按钮
- [ ] 已下载列表里删除一首 → 文件 + 缓存封面 + 记录都没了,空专辑目录连带删
- [ ] 本地导入一个文件夹(里面有 `01 - 歌名.flac` 这种命名)→ 歌手名不是 "01",是文件标签里的真实歌手(或"未知歌手")
- [ ] 离线播放本地导入的歌 → 封面、歌词、歌名/歌手/专辑都正确显示
- [ ] App 重启 → 本地导入的歌还能播(SAF 持久权限有效)
- [ ] 已下载/已导入的歌的封面是高清的,不再走网络

---

## 12. 不做的事

- ❌ **iCloud / Google Drive 同步**:不在本方案范围
- ❌ **下载断点续传**:简化,失败了就重头来
- ❌ **下载到 SD 卡(老 Android)**:用 MediaStore 就行,不挑磁盘
- ❌ **加密下载文件**:平台音乐本身不带 DRM(走 lx-music 协议),下载就是裸 mp3/flac,加密反而麻烦
- ❌ **歌手 ID 维度分目录**:同名歌手罕见,字符串精确匹配就够
