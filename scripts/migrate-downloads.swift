#!/usr/bin/env swift
// 存量下载迁移脚本(Mac only,手动执行):
//
//   swift scripts/migrate-downloads.swift          # 实际执行
//   swift scripts/migrate-downloads.swift --dry-run # 只打印计划,不动任何文件
//
// 做三件事:
// 1. 把已完成下载按新命名规则改名/挪目录:
//      有专辑+曲目号 → ~/Music/Shuhao/歌手/专辑/NN - 歌名.ext
//      有专辑无曲目号 → ~/Music/Shuhao/歌手/专辑 - 歌名.ext
//      无专辑        → ~/Music/Shuhao/歌手 - 歌名.ext
//    (旧文件在沙盒 Documents/Downloads 的也一并挪出来)
// 2. 补元数据:曲目号/总曲目/专辑艺术家/年份/流派/唱片公司 + 高清封面。
//    合并式写入 —— 已有的歌词/封面/标签全部保留,只补缺的。
// 3. 更新沙盒里的 downloadRecords.json(先备份)。
//
// 跑之前请退出随便听 app。脚本流程是"先拷贝到新位置 → 校验 → 再删旧文件",
// 中途失败不会丢文件。

import Foundation
import AppKit

// MARK: - 配置

let bundleID = "com.heartbeat.shuhao"
let dryRun = CommandLine.arguments.contains("--dry-run")

let home = FileManager.default.homeDirectoryForCurrentUser
let containerDocs = home.appendingPathComponent("Library/Containers/\(bundleID)/Data/Documents")
let recordsURL = containerDocs.appendingPathComponent("downloadRecords.json")
let legacyDir = containerDocs.appendingPathComponent("Downloads")
let musicDir = home.appendingPathComponent("Music/Shuhao")
let fm = FileManager.default

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("错误: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - 前置检查

let running = Process()
running.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
running.arguments = ["-x", "shuhao"]
running.standardOutput = Pipe()
try? running.run()
running.waitUntilExit()
if running.terminationStatus == 0 {
    die("随便听 app 还在运行,请先退出再跑迁移。")
}

guard fm.fileExists(atPath: recordsURL.path) else {
    die("找不到 \(recordsURL.path) —— 没有下载记录,无需迁移。")
}
guard let rawData = try? Data(contentsOf: recordsURL),
      var records = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: [String: Any]] else {
    die("downloadRecords.json 解析失败。")
}

try? fm.createDirectory(at: musicDir, withIntermediateDirectories: true)

// MARK: - 工具

func sanitize(_ s: String) -> String {
    var t = s
        .replacingOccurrences(of: "/", with: "／")
        .replacingOccurrences(of: ":", with: "：")
    for ch in ["?", "*", "\"", "<", ">", "|", "\\"] {
        t = t.replacingOccurrences(of: ch, with: "_")
    }
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    while t.hasPrefix(".") { t.removeFirst() }
    return t.isEmpty ? "未知" : t
}

func relativePath(singer: String, name: String, album: String?, ext: String, trackNumber: Int?) -> String {
    let artist = sanitize(singer)
    let song = sanitize(name)
    if let album, !album.isEmpty {
        let alb = sanitize(album)
        if let n = trackNumber, n > 0 {
            return "\(artist)/\(alb)/\(String(format: "%02d", n)) - \(song).\(ext)"
        }
        return "\(artist)/\(alb) - \(song).\(ext)"
    }
    return "\(artist) - \(song).\(ext)"
}

// MARK: - 同步 HTTP

let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"

func httpData(_ urlStr: String, referer: String? = nil, postJSON: [String: Any]? = nil) -> Data? {
    guard let url = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: url)
    req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
    if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
    if let postJSON {
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: postJSON)
    }
    req.timeoutInterval = 10
    var result: Data?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        result = data
        sem.signal()
    }.resume()
    sem.wait()
    return result
}

func httpJSON(_ urlStr: String, referer: String? = nil, postJSON: [String: Any]? = nil) -> [String: Any]? {
    guard let data = httpData(urlStr, referer: referer, postJSON: postJSON) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// MARK: - 曲目详情(对应 app 里的 TrackDetailFetcher)

struct Details {
    var trackNumber: Int?
    var trackTotal: Int?
    var albumArtist: String?
    var releaseDate: String?
    var genre: String?
    var company: String?
    var hiResCoverURL: String?
}

func fetchDetails(source: String, songmid: String, extras: [String: String],
                  albumId: String?, picURL: String?) -> Details {
    var d = Details()
    switch source {
    case "wy":
        guard let json = httpJSON(
            "https://music.163.com/api/song/detail/?id=\(songmid)&ids=%5B\(songmid)%5D",
            referer: "https://music.163.com/"
        ), let song = (json["songs"] as? [[String: Any]])?.first else { break }
        if let no = song["no"] as? Int, no > 0 { d.trackNumber = no }
        if let album = song["album"] as? [String: Any] {
            if let size = album["size"] as? Int, size > 0 { d.trackTotal = size }
            if let company = album["company"] as? String, !company.isEmpty { d.company = company }
            if let pic = album["picUrl"] as? String, !pic.isEmpty { d.hiResCoverURL = pic }
            if let artist = album["artist"] as? [String: Any],
               let name = artist["name"] as? String, !name.isEmpty { d.albumArtist = name }
            if let ms = album["publishTime"] as? Double, ms > 0 {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
                d.releaseDate = fmt.string(from: Date(timeIntervalSince1970: ms / 1000))
            }
        }
    case "tx":
        if let albumMid = extras["albumMid"], !albumMid.isEmpty {
            d.hiResCoverURL = "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"
        }
        let body: [String: Any] = [
            "req": [
                "module": "music.pf_song_detail_svr",
                "method": "get_song_detail_yqq",
                "param": ["song_mid": songmid],
            ]
        ]
        guard let json = httpJSON("https://u.y.qq.com/cgi-bin/musicu.fcg",
                                  referer: "https://y.qq.com/", postJSON: body),
              let reqResp = json["req"] as? [String: Any],
              let respData = reqResp["data"] as? [String: Any] else { break }
        if let trackInfo = respData["track_info"] as? [String: Any] {
            if let idx = trackInfo["index_album"] as? Int, idx > 0 { d.trackNumber = idx }
            if let pub = trackInfo["time_public"] as? String, !pub.isEmpty { d.releaseDate = pub }
        }
        if let info = respData["info"] as? [String: Any] {
            func infoValue(_ key: String) -> String? {
                guard let section = info[key] as? [String: Any],
                      let content = section["content"] as? [[String: Any]],
                      let value = content.first?["value"] as? String, !value.isEmpty else { return nil }
                return value
            }
            d.genre = infoValue("genre")
            d.company = infoValue("company")
        }
    case "kg":
        if let pic = picURL, pic.contains("/240/") {
            d.hiResCoverURL = pic.replacingOccurrences(of: "/240/", with: "/")
        }
        guard let aid = extras["albumId"] ?? albumId, !aid.isEmpty else { break }
        if let json = httpJSON("http://mobilecdn.kugou.com/api/v3/album/info?albumid=\(aid)"),
           let data = json["data"] as? [String: Any] {
            if let singer = data["singername"] as? String, !singer.isEmpty { d.albumArtist = singer }
            if let pub = data["publishtime"] as? String, !pub.isEmpty {
                d.releaseDate = String(pub.prefix(10))
            }
        }
        if let hash = extras["hash"]?.lowercased(), !hash.isEmpty,
           let json = httpJSON("http://mobilecdn.kugou.com/api/v3/album/song?albumid=\(aid)&page=1&pagesize=100"),
           let data = json["data"] as? [String: Any],
           let songs = data["info"] as? [[String: Any]] {
            if let idx = songs.firstIndex(where: { ($0["hash"] as? String)?.lowercased() == hash }) {
                d.trackNumber = idx + 1
            }
            let total = (data["total"] as? Int) ?? songs.count
            if total > 0 { d.trackTotal = total }
        }
    case "kw":
        if let json = httpJSON("http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=\(songmid)"),
           let data = json["data"] as? [String: Any],
           let info = data["songinfo"] as? [String: Any],
           let date = info["releaseDate"] as? String, !date.isEmpty {
            d.releaseDate = date
        }
    default:
        break
    }
    return d
}

// MARK: - FLAC 标签合并

func uint32LE(_ v: Int) -> Data {
    Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
}
func uint32BE(_ v: Int) -> Data {
    Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
}
func readUInt32LE(_ data: Data, _ offset: Int) -> Int {
    Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
}

func buildFLACPicture(coverData: Data, mime: String) -> Data {
    var width = 0, height = 0
    if let rep = NSBitmapImageRep(data: coverData) {
        width = rep.pixelsWide
        height = rep.pixelsHigh
    }
    var out = Data()
    out.append(uint32BE(3))
    let mimeBytes = mime.data(using: .ascii) ?? Data()
    out.append(uint32BE(mimeBytes.count)); out.append(mimeBytes)
    out.append(uint32BE(0))
    out.append(uint32BE(width)); out.append(uint32BE(height))
    out.append(uint32BE(24)); out.append(uint32BE(0))
    out.append(uint32BE(coverData.count)); out.append(coverData)
    return out
}

/// 合并式重写 FLAC:已有 comment / PICTURE 全保留,只追加缺失的字段。
/// 返回 (是否改动, 是否已有封面)。
func mergeFLACTags(at url: URL, details: Details, title: String, artist: String,
                   album: String?, fetchCover: () -> (Data, String)?) -> Bool {
    guard var original = try? Data(contentsOf: url), original.count >= 42,
          original[0] == 0x66, original[1] == 0x4C, original[2] == 0x61, original[3] == 0x43 else {
        return false
    }
    original = Data(original)   // 重新基底,保证下标从 0 开始

    struct Block { let type: UInt8; let dataRange: Range<Int> }
    var blocks: [Block] = []
    var cursor = 4
    var lastSeen = false
    while !lastSeen && cursor + 4 <= original.count {
        let header0 = original[cursor]
        lastSeen = (header0 & 0x80) != 0
        let type = header0 & 0x7F
        let length = Int(original[cursor + 1]) << 16 | Int(original[cursor + 2]) << 8 | Int(original[cursor + 3])
        let end = cursor + 4 + length
        guard end <= original.count else { return false }
        blocks.append(Block(type: type, dataRange: (cursor + 4)..<end))
        cursor = end
    }
    let audioStart = cursor
    guard let streamInfo = blocks.first, streamInfo.type == 0 else { return false }

    // 现有 comments
    var comments: [String] = []
    if let vc = blocks.first(where: { $0.type == 4 }) {
        let data = original.subdata(in: vc.dataRange)
        if data.count >= 8 {
            var p = 0
            let vendorLen = readUInt32LE(data, p); p += 4 + vendorLen
            if p + 4 <= data.count {
                let count = readUInt32LE(data, p); p += 4
                for _ in 0..<count {
                    guard p + 4 <= data.count else { break }
                    let len = readUInt32LE(data, p); p += 4
                    guard p + len <= data.count else { break }
                    if let s = String(data: data.subdata(in: p..<(p + len)), encoding: .utf8) {
                        comments.append(s)
                    }
                    p += len
                }
            }
        }
    }
    func hasKey(_ key: String) -> Bool {
        comments.contains { $0.uppercased().hasPrefix(key.uppercased() + "=") }
    }
    var changed = false
    func addIfMissing(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty, !hasKey(key) else { return }
        comments.append("\(key)=\(value)")
        changed = true
    }
    addIfMissing("TITLE", title)
    addIfMissing("ARTIST", artist)
    addIfMissing("ALBUM", album)
    addIfMissing("TRACKNUMBER", details.trackNumber.map(String.init))
    addIfMissing("TRACKTOTAL", details.trackTotal.map(String.init))
    addIfMissing("ALBUMARTIST", details.albumArtist)
    addIfMissing("DATE", details.releaseDate)
    addIfMissing("GENRE", details.genre)
    addIfMissing("ORGANIZATION", details.company)

    let hadPicture = blocks.contains { $0.type == 6 }
    var newPicture: Data?
    if !hadPicture, let (cover, mime) = fetchCover() {
        newPicture = buildFLACPicture(coverData: cover, mime: mime)
        changed = true
    }
    guard changed else { return false }

    var vcData = Data()
    let vendor = "shuhao".data(using: .utf8)!
    vcData.append(uint32LE(vendor.count)); vcData.append(vendor)
    vcData.append(uint32LE(comments.count))
    for c in comments {
        let bytes = c.data(using: .utf8) ?? Data()
        vcData.append(uint32LE(bytes.count)); vcData.append(bytes)
    }

    var newBlocks: [(UInt8, Data)] = [(0, original.subdata(in: streamInfo.dataRange))]
    for b in blocks.dropFirst() where b.type != 4 && b.type != 1 {
        newBlocks.append((b.type, original.subdata(in: b.dataRange)))
    }
    newBlocks.append((4, vcData))
    if let pic = newPicture { newBlocks.append((6, pic)) }
    newBlocks.append((1, Data(count: 4096)))

    var out = Data([0x66, 0x4C, 0x61, 0x43])
    for (idx, blk) in newBlocks.enumerated() {
        let isLast = idx == newBlocks.count - 1
        var h = Data(count: 4)
        h[0] = (isLast ? 0x80 : 0x00) | (blk.0 & 0x7F)
        h[1] = UInt8((blk.1.count >> 16) & 0xFF)
        h[2] = UInt8((blk.1.count >> 8) & 0xFF)
        h[3] = UInt8(blk.1.count & 0xFF)
        out.append(h); out.append(blk.1)
    }
    out.append(original.subdata(in: audioStart..<original.count))
    do { try out.write(to: url, options: .atomic) } catch { return false }
    return true
}

// MARK: - MP3 (ID3v2) 标签合并

func synchsafeEncode(_ size: Int) -> Data {
    Data([UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
}

/// 合并式重写 MP3:解析现有 ID3v2.3/2.4 帧全部保留,追加缺失的文本帧/封面,统一写回 v2.4。
func mergeMP3Tags(at url: URL, details: Details, title: String, artist: String,
                  album: String?, fetchCover: () -> (Data, String)?) -> Bool {
    guard var original = try? Data(contentsOf: url) else { return false }
    original = Data(original)

    var frames: [(id: String, body: Data)] = []
    var audioStart = 0
    if original.count >= 10, original[0] == 0x49, original[1] == 0x44, original[2] == 0x33 {
        let version = original[3]            // 3 = v2.3, 4 = v2.4
        let flags = original[5]
        let tagSize = Int(original[6] & 0x7F) << 21 | Int(original[7] & 0x7F) << 14
                    | Int(original[8] & 0x7F) << 7 | Int(original[9] & 0x7F)
        audioStart = 10 + tagSize + ((flags & 0x10) != 0 ? 10 : 0)
        var p = 10
        // 跳过 extended header
        if (flags & 0x40) != 0, p + 4 <= original.count {
            let extSize: Int
            if version == 4 {
                extSize = Int(original[p] & 0x7F) << 21 | Int(original[p+1] & 0x7F) << 14
                        | Int(original[p+2] & 0x7F) << 7 | Int(original[p+3] & 0x7F)
            } else {
                extSize = Int(original[p]) << 24 | Int(original[p+1]) << 16
                        | Int(original[p+2]) << 8 | Int(original[p+3]) + 4
            }
            p += extSize
        }
        let tagEnd = min(10 + tagSize, original.count)
        while p + 10 <= tagEnd {
            if original[p] == 0 { break }    // padding
            guard let id = String(data: original.subdata(in: p..<(p + 4)), encoding: .ascii),
                  id.allSatisfy({ $0.isUppercase || $0.isNumber }) else { break }
            let size: Int
            if version == 4 {
                size = Int(original[p+4] & 0x7F) << 21 | Int(original[p+5] & 0x7F) << 14
                     | Int(original[p+6] & 0x7F) << 7 | Int(original[p+7] & 0x7F)
            } else {
                size = Int(original[p+4]) << 24 | Int(original[p+5]) << 16
                     | Int(original[p+6]) << 8 | Int(original[p+7])
            }
            guard size > 0, p + 10 + size <= tagEnd else { break }
            frames.append((id, original.subdata(in: (p + 10)..<(p + 10 + size))))
            p += 10 + size
        }
    }
    audioStart = min(audioStart, original.count)

    func hasFrame(_ id: String) -> Bool { frames.contains { $0.id == id } }
    var changed = false
    func textBody(_ text: String) -> Data {
        var b = Data([0x03]); b.append(text.data(using: .utf8) ?? Data()); return b
    }
    func addIfMissing(_ id: String, _ value: String?) {
        guard let value, !value.isEmpty, !hasFrame(id) else { return }
        // v2.3 的年份帧叫 TYER —— 有它就不再补 TDRC,避免双份。
        if id == "TDRC", hasFrame("TYER") { return }
        frames.append((id, textBody(value)))
        changed = true
    }
    addIfMissing("TIT2", title)
    addIfMissing("TPE1", artist)
    addIfMissing("TALB", album)
    if let n = details.trackNumber, n > 0 {
        addIfMissing("TRCK", details.trackTotal.map { "\(n)/\($0)" } ?? "\(n)")
    }
    addIfMissing("TPE2", details.albumArtist)
    addIfMissing("TDRC", details.releaseDate)
    addIfMissing("TCON", details.genre)
    addIfMissing("TPUB", details.company)
    if !hasFrame("APIC"), let (cover, mime) = fetchCover() {
        var b = Data([0x03])
        b.append(mime.data(using: .ascii) ?? Data()); b.append(0x00)
        b.append(0x03); b.append(0x00)
        b.append(cover)
        frames.append(("APIC", b))
        changed = true
    }
    guard changed else { return false }

    var framesData = Data()
    for f in frames {
        framesData.append(f.id.data(using: .ascii)!)
        framesData.append(synchsafeEncode(f.body.count))
        framesData.append(Data([0x00, 0x00]))
        framesData.append(f.body)
    }
    let body = framesData + Data(count: 1024)
    var out = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00])
    out.append(synchsafeEncode(body.count))
    out.append(body)
    out.append(original.subdata(in: audioStart..<original.count))
    do { try out.write(to: url, options: .atomic) } catch { return false }
    return true
}

// MARK: - 封面下载

func fetchCover(hiRes: String?, fallback: String?) -> (Data, String)? {
    for urlStr in [hiRes, fallback].compactMap({ $0 }) {
        guard let data = httpData(urlStr), data.count > 1000 else { continue }
        let mime: String
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { mime = "image/png" }
        else { mime = "image/jpeg" }
        return (data, mime)
    }
    return nil
}

// MARK: - 主流程

print(dryRun ? "== DRY RUN,不会改任何文件 ==" : "== 开始迁移 ==")
print("音乐目录: \(musicDir.path)")
print("记录文件: \(recordsURL.path)")

if !dryRun {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let backup = recordsURL.appendingPathExtension("bak-\(stamp)")
    try? fm.copyItem(at: recordsURL, to: backup)
    print("已备份记录 → \(backup.lastPathComponent)")
}

var migrated = 0, skipped = 0, missing = 0, failed = 0
var assignedNames = Set(records.values.compactMap { $0["fileName"] as? String })

for (trackID, var rec) in records.sorted(by: { $0.key < $1.key }) {
    guard (rec["status"] as? String) == "completed",
          let fileName = rec["fileName"] as? String, !fileName.isEmpty,
          let track = rec["track"] as? [String: Any],
          let name = track["name"] as? String,
          let singer = track["singer"] as? String else { skipped += 1; continue }

    let album = track["albumName"] as? String
    let source = (track["source"] as? String) ?? ""
    let songmid = (track["songmid"] as? String) ?? ""
    let extras = (track["extras"] as? [String: String]) ?? [:]
    let albumId = track["albumId"] as? String
    let picURL = track["picURL"] as? String

    // 找旧文件
    let oldURL: URL
    let inMusic = musicDir.appendingPathComponent(fileName)
    let inLegacy = legacyDir.appendingPathComponent(fileName)
    if fm.fileExists(atPath: inMusic.path) { oldURL = inMusic }
    else if fm.fileExists(atPath: inLegacy.path) { oldURL = inLegacy }
    else {
        print("[缺文件] \(singer) - \(name) (\(fileName))")
        missing += 1
        continue
    }
    let ext = oldURL.pathExtension.lowercased()

    print("处理: \(singer) - \(name) [\(source)]")
    let details = fetchDetails(source: source, songmid: songmid, extras: extras,
                               albumId: albumId, picURL: picURL)

    // 新相对路径 + 撞名规避
    var newRel = relativePath(singer: singer, name: name, album: album,
                              ext: ext, trackNumber: details.trackNumber)
    if newRel != fileName {
        var n = 2
        while (assignedNames.contains(newRel) && newRel != fileName)
                || fm.fileExists(atPath: musicDir.appendingPathComponent(newRel).path) {
            let base = (newRel as NSString).deletingPathExtension
                .replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
            newRel = "\(base) (\(n)).\(ext)"
            n += 1
        }
    }
    let newURL = musicDir.appendingPathComponent(newRel)

    if dryRun {
        let tags = [
            details.trackNumber.map { "曲目\($0)" + (details.trackTotal.map { "/\($0)" } ?? "") },
            details.releaseDate, details.albumArtist, details.genre, details.company,
        ].compactMap { $0 }.joined(separator: ", ")
        print("  → \(newRel)" + (tags.isEmpty ? "" : "  [\(tags)]"))
        migrated += 1
        continue
    }

    // 先拷贝到新位置(同路径就免拷),在新文件上补标签,成功后再删旧文件。
    do {
        if newURL.path != oldURL.path {
            try fm.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: newURL.path) { try fm.removeItem(at: newURL) }
            try fm.copyItem(at: oldURL, to: newURL)
        }
    } catch {
        print("  [失败] 拷贝出错: \(error.localizedDescription)")
        failed += 1
        continue
    }

    let coverProvider = { fetchCover(hiRes: details.hiResCoverURL, fallback: picURL) }
    let tagged: Bool
    switch ext {
    case "flac":
        tagged = mergeFLACTags(at: newURL, details: details, title: name, artist: singer,
                               album: album, fetchCover: coverProvider)
    case "mp3":
        tagged = mergeMP3Tags(at: newURL, details: details, title: name, artist: singer,
                              album: album, fetchCover: coverProvider)
    default:
        tagged = false
    }

    if newURL.path != oldURL.path {
        // 校验新文件落盘后再删旧的
        let newSize = ((try? fm.attributesOfItem(atPath: newURL.path))?[.size] as? Int) ?? 0
        if newSize > 0 {
            try? fm.removeItem(at: oldURL)
            // 清掉腾空的旧目录(不动根目录)
            var dir = oldURL.deletingLastPathComponent()
            while dir.path != musicDir.path && dir.path != legacyDir.path
                    && (dir.path.hasPrefix(musicDir.path) || dir.path.hasPrefix(legacyDir.path)) {
                let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                guard contents.allSatisfy({ $0 == ".DS_Store" }) else { break }
                try? fm.removeItem(at: dir)
                dir = dir.deletingLastPathComponent()
            }
        } else {
            print("  [失败] 新文件校验不通过,保留旧文件")
            failed += 1
            continue
        }
    }

    assignedNames.remove(fileName)
    assignedNames.insert(newRel)
    rec["fileName"] = newRel
    records[trackID] = rec
    migrated += 1
    print("  → \(newRel)" + (tagged ? "  [标签已补]" : ""))
}

if !dryRun {
    let out = try! JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
    try! out.write(to: recordsURL, options: .atomic)
    print("已写回 downloadRecords.json")
}

print("\n完成: 迁移 \(migrated) 首,跳过 \(skipped),缺文件 \(missing),失败 \(failed)")
if dryRun { print("(dry-run 模式,以上只是计划)") }
