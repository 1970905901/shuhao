import Foundation

// MARK: - Embedded tag reader (FLAC / MP3)
//
// AudioMetadataWriter 在下载完成时把封面 + 歌词写进了音频文件本体,
// 这里负责把它们读回来 —— 已下载的歌离线时封面/歌词直接取自本地文件,
// 不再依赖网络。只读文件头部的标签区(FileHandle 按需 seek),
// 不会把几十 MB 的音频整个载入内存。
nonisolated enum EmbeddedTagReader {

    struct Tags: Sendable {
        var cover: Data?
        var lyrics: String?
        /// AVFoundation 对 FLAC 的 commonMetadata 支持参差不齐(Vorbis Comment 经常
        /// 读不到 ARTIST/TITLE/ALBUM),作为本地导入的兜底自己解析一遍。
        var title: String?
        var artist: String?
        var album: String?
    }

    static func read(at url: URL,
                     wantCover: Bool = true, wantLyrics: Bool = true,
                     wantFields: Bool = false) -> Tags {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return Tags() }
        defer { try? fh.close() }
        guard let magic = try? fh.read(upToCount: 4), magic.count == 4 else { return Tags() }
        if magic == Data("fLaC".utf8) {
            return readFLAC(fh, wantCover: wantCover, wantLyrics: wantLyrics, wantFields: wantFields)
        }
        if magic.prefix(3) == Data("ID3".utf8) {
            return readID3(fh, versionByte: magic[3], wantCover: wantCover, wantLyrics: wantLyrics, wantFields: wantFields)
        }
        return Tags()
    }

    // MARK: FLAC — metadata block 链

    private static func readFLAC(_ fh: FileHandle, wantCover: Bool, wantLyrics: Bool, wantFields: Bool) -> Tags {
        var tags = Tags()
        let wantVorbis = wantLyrics || wantFields
        while true {
            guard let header = try? fh.read(upToCount: 4), header.count == 4 else { break }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let size = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            switch type {
            case 4 where wantVorbis:   // VORBIS_COMMENT
                if let payload = try? fh.read(upToCount: size), payload.count == size {
                    parseVorbis(payload, into: &tags, wantLyrics: wantLyrics, wantFields: wantFields)
                } else { return tags }
            case 6 where wantCover && tags.cover == nil:   // PICTURE
                if let payload = try? fh.read(upToCount: size), payload.count == size {
                    tags.cover = picturePayload(payload)
                } else { return tags }
            default:
                guard (try? fh.seek(toOffset: fh.offsetInFile + UInt64(size))) != nil else { return tags }
            }
            if isLast { break }
            if doneReading(tags, wantCover: wantCover, wantLyrics: wantLyrics, wantFields: wantFields) { break }
        }
        return tags
    }

    /// Vorbis Comment 一次过遍历:LYRICS + TITLE/ARTIST/ALBUM 一起拿,避免反复解析。
    /// 多值的 ARTIST(协作艺术家)按出现顺序用 " / " 拼接 — 和 lx 习惯一致。
    private static func parseVorbis(_ d: Data, into tags: inout Tags,
                                    wantLyrics: Bool, wantFields: Bool) {
        var p = d.startIndex
        func readLE32() -> Int? {
            guard d.distance(from: p, to: d.endIndex) >= 4 else { return nil }
            let v = Int(d[p]) | Int(d[p + 1]) << 8 | Int(d[p + 2]) << 16 | Int(d[p + 3]) << 24
            p = d.index(p, offsetBy: 4)
            return v
        }
        guard let vendorLen = readLE32(),
              d.distance(from: p, to: d.endIndex) >= vendorLen else { return }
        p = d.index(p, offsetBy: vendorLen)
        guard let count = readLE32() else { return }
        var artists: [String] = []
        for _ in 0..<count {
            guard let len = readLE32(), len >= 0,
                  d.distance(from: p, to: d.endIndex) >= len else { return }
            let entry = d[p..<d.index(p, offsetBy: len)]
            p = d.index(p, offsetBy: len)
            guard let s = String(data: entry, encoding: .utf8),
                  let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].uppercased()
            let value = String(s[s.index(after: eq)...])
            if value.isEmpty { continue }
            switch key {
            case "LYRICS" where wantLyrics && tags.lyrics == nil:
                tags.lyrics = value
            case "TITLE" where wantFields && tags.title == nil:
                tags.title = value
            case "ARTIST" where wantFields:
                artists.append(value)
            case "ALBUM" where wantFields && tags.album == nil:
                tags.album = value
            default:
                continue
            }
        }
        if wantFields, !artists.isEmpty, tags.artist == nil {
            tags.artist = artists.joined(separator: " / ")
        }
    }

    private static func picturePayload(_ d: Data) -> Data? {
        var p = d.startIndex
        func readBE32() -> Int? {
            guard d.distance(from: p, to: d.endIndex) >= 4 else { return nil }
            let v = Int(d[p]) << 24 | Int(d[p + 1]) << 16 | Int(d[p + 2]) << 8 | Int(d[p + 3])
            p = d.index(p, offsetBy: 4)
            return v
        }
        func skip(_ n: Int) -> Bool {
            guard n >= 0, d.distance(from: p, to: d.endIndex) >= n else { return false }
            p = d.index(p, offsetBy: n)
            return true
        }
        guard readBE32() != nil,                                   // picture type
              let mimeLen = readBE32(), skip(mimeLen),
              let descLen = readBE32(), skip(descLen),
              readBE32() != nil, readBE32() != nil,                // width, height
              readBE32() != nil, readBE32() != nil,                // depth, colors
              let dataLen = readBE32(), dataLen > 0,
              d.distance(from: p, to: d.endIndex) >= dataLen else { return nil }
        return Data(d[p..<d.index(p, offsetBy: dataLen)])
    }

    // MARK: MP3 — ID3v2.3 / v2.4 帧

    private static func readID3(_ fh: FileHandle, versionByte: UInt8, wantCover: Bool, wantLyrics: Bool, wantFields: Bool) -> Tags {
        guard versionByte == 3 || versionByte == 4,
              let rest = try? fh.read(upToCount: 6), rest.count == 6 else { return Tags() }
        let flags = rest[1]
        let tagSize = synchsafe(Array(rest[rest.index(rest.startIndex, offsetBy: 2)...]))
        guard tagSize > 0, tagSize < 64 * 1024 * 1024,
              var d = try? fh.read(upToCount: tagSize), !d.isEmpty else { return Tags() }
        // 扩展头:跳过(我们自己不写,但别的工具写的文件可能带)。
        if flags & 0x40 != 0, d.count >= 4 {
            let extLen = versionByte == 4
                ? synchsafe([d[0], d[1], d[2], d[3]])
                : Int(d[0]) << 24 | Int(d[1]) << 16 | Int(d[2]) << 8 | Int(d[3])
            if extLen > 0, extLen <= d.count { d = d.dropFirst(extLen) }
        }
        var tags = Tags()
        var i = d.startIndex
        while d.distance(from: i, to: d.endIndex) >= 10 {
            let idData = d[i..<d.index(i, offsetBy: 4)]
            if idData.allSatisfy({ $0 == 0 }) { break }   // padding 区
            guard let id = String(data: idData, encoding: .isoLatin1) else { break }
            let sizeBytes = [d[d.index(i, offsetBy: 4)], d[d.index(i, offsetBy: 5)],
                             d[d.index(i, offsetBy: 6)], d[d.index(i, offsetBy: 7)]]
            let frameSize = versionByte == 4
                ? synchsafe(sizeBytes)
                : Int(sizeBytes[0]) << 24 | Int(sizeBytes[1]) << 16 | Int(sizeBytes[2]) << 8 | Int(sizeBytes[3])
            let bodyStart = d.index(i, offsetBy: 10)
            guard frameSize > 0, d.distance(from: bodyStart, to: d.endIndex) >= frameSize else { break }
            let body = d[bodyStart..<d.index(bodyStart, offsetBy: frameSize)]
            if id == "USLT", wantLyrics, tags.lyrics == nil {
                tags.lyrics = usltText(Data(body))
            } else if id == "APIC", wantCover, tags.cover == nil {
                tags.cover = apicData(Data(body))
            } else if wantFields {
                // T??? 文本帧:首字节是 encoding,后面是文本(可能含 null 分隔的多值,只取第一段)。
                switch id {
                case "TIT2" where tags.title == nil: tags.title = textFrame(Data(body))
                case "TPE1" where tags.artist == nil: tags.artist = textFrame(Data(body))
                case "TALB" where tags.album == nil: tags.album = textFrame(Data(body))
                default: break
                }
            }
            i = d.index(bodyStart, offsetBy: frameSize)
            if doneReading(tags, wantCover: wantCover, wantLyrics: wantLyrics, wantFields: wantFields) { break }
        }
        return tags
    }

    /// ID3v2 文本帧:encoding(1) + 文本。多值用 null 分隔(v2.4)或斜杠/分号(v2.3),取首段就够 UI 用。
    private static func textFrame(_ d: Data) -> String? {
        guard !d.isEmpty else { return nil }
        let encoding = d[d.startIndex]
        let body = d.dropFirst(1)
        guard let s = decodeText(Data(body), encoding: encoding) else { return nil }
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func synchsafe(_ b: [UInt8]) -> Int {
        Int(b[0] & 0x7F) << 21 | Int(b[1] & 0x7F) << 14 | Int(b[2] & 0x7F) << 7 | Int(b[3] & 0x7F)
    }

    /// USLT: encoding(1) + lang(3) + descriptor(null-terminated) + text
    private static func usltText(_ d: Data) -> String? {
        guard d.count > 4 else { return nil }
        let encoding = d[d.startIndex]
        let afterLang = d.dropFirst(4)
        guard let descEnd = terminatorEnd(in: afterLang, encoding: encoding) else { return nil }
        let text = afterLang[descEnd...]
        let s = decodeText(Data(text), encoding: encoding)
        return (s?.isEmpty == false) ? s : nil
    }

    /// APIC: encoding(1) + mime(latin1 null-terminated) + picType(1) + desc(null-terminated) + data
    private static func apicData(_ d: Data) -> Data? {
        guard d.count > 3 else { return nil }
        let encoding = d[d.startIndex]
        let afterEnc = d.dropFirst(1)
        guard let mimeEnd = terminatorEnd(in: afterEnc, encoding: 0) else { return nil }
        let afterMime = afterEnc[mimeEnd...]
        guard afterMime.count > 1 else { return nil }
        let afterType = afterMime.dropFirst(1)
        guard let descEnd = terminatorEnd(in: afterType, encoding: encoding) else { return nil }
        let pic = afterType[descEnd...]
        return pic.isEmpty ? nil : Data(pic)
    }

    /// 找到 null 终结符之后的位置(latin1/UTF-8 单字节 0x00,UTF-16 双字节 0x0000)。
    private static func terminatorEnd(in d: Data.SubSequence, encoding: UInt8) -> Data.Index? {
        if encoding == 1 || encoding == 2 {
            var i = d.startIndex
            while d.distance(from: i, to: d.endIndex) >= 2 {
                if d[i] == 0 && d[d.index(after: i)] == 0 { return d.index(i, offsetBy: 2) }
                i = d.index(i, offsetBy: 2)
            }
            return nil
        }
        guard let z = d.firstIndex(of: 0) else { return nil }
        return d.index(after: z)
    }

    private static func decodeText(_ d: Data, encoding: UInt8) -> String? {
        switch encoding {
        case 0: return String(data: d, encoding: .isoLatin1)
        case 1: return String(data: d, encoding: .utf16)     // 带 BOM
        case 2: return String(data: d, encoding: .utf16BigEndian)
        default: return String(data: d, encoding: .utf8)
        }
    }

    private static func doneReading(_ t: Tags, wantCover: Bool, wantLyrics: Bool, wantFields: Bool = false) -> Bool {
        (!wantCover || t.cover != nil)
        && (!wantLyrics || t.lyrics != nil)
        && (!wantFields || (t.title != nil && t.artist != nil && t.album != nil))
    }
}
