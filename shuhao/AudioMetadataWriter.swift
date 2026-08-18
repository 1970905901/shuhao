import Foundation
import UIKit

/// 把元数据(歌名 / 歌手 / 专辑 / 封面 / 歌词)写到刚下载好的音频文件里。
///
/// 设计原则:
/// - **单点入口** `AudioMetadataWriter.apply(...)` —— 调用方只关心 track + 封面 + 歌词,
///   不关心文件格式
/// - 内部根据扩展名分发到 `MP3TagWriter` (ID3v2.4 + UTF-8) 或 `FLACTagWriter`
///   (Vorbis Comment + PICTURE block)
/// - 失败兜底:写入异常吞掉 + 日志,不让 metadata 失败影响整次下载成功状态
///   (用户已经拿到能播的文件了,标签没写上是次要问题)
///
/// 实现走的是"读全文 → 在内存里重组 → 整体写回"的路子。音乐文件一般 <50 MB,
/// 一次性 load 进 Data 还在可接受范围。Hi-Res 24-bit FLAC 偶尔到 100MB+,
/// 真要省内存可以后续改成 stream 拼接,目前先求简单 + 正确。
///
/// 参考资料:
/// - ID3v2.4: https://id3.org/id3v2.4.0-structure & .../id3v2.4.0-frames
/// - FLAC format: https://xiph.org/flac/format.html
nonisolated enum AudioMetadataWriter {

    /// 写入元数据。`coverData` 为 nil 就不写封面;`lrcText` 为 nil/空就不写歌词。
    /// 抛错也不影响调用方,函数内部已经把所有异常吞掉 + 打 log。
    static func apply(
        to fileURL: URL,
        track: Track,
        details: TrackDetails? = nil,
        coverData: Data?,
        coverMIME: String?,   // "image/jpeg" / "image/png" 等;nil ⇒ 当成 jpeg
        lrcText: String?
    ) {
        let ext = fileURL.pathExtension.lowercased()
        do {
            switch ext {
            case "mp3":
                try MP3TagWriter.write(
                    fileURL: fileURL,
                    title: track.name,
                    artist: track.singer,
                    album: track.albumName,
                    details: details,
                    lyrics: lrcText,
                    coverData: coverData,
                    coverMIME: coverMIME ?? "image/jpeg"
                )
            case "flac":
                try FLACTagWriter.write(
                    fileURL: fileURL,
                    title: track.name,
                    artist: track.singer,
                    album: track.albumName,
                    details: details,
                    lyrics: lrcText,
                    coverData: coverData,
                    coverMIME: coverMIME ?? "image/jpeg"
                )
            default:
                print("[AudioMetadata] 未知格式 .\(ext),跳过写入")
            }
        } catch {
            print("[AudioMetadata] 写入失败 (\(fileURL.lastPathComponent)): \(error)")
        }
    }
}

// MARK: - ID3v2.4 (MP3)

/// ID3v2.4 标准的最小可用子集:UTF-8 文本帧 + 同步歌词 + 嵌入封面。
/// 兼容性:iTunes / Music.app / Foobar2000 / VLC / 大多数 Android 播放器都吃。
nonisolated enum MP3TagWriter {

    enum WriterError: Error { case ioFailure }

    /// 写入流程:
    /// 1. 读完整原文件
    /// 2. 探测原有 ID3v2 tag 大小(MP3 可能开头本来就有一段 tag,要跳过)
    /// 3. 构造新 tag bytes
    /// 4. 输出 = 新 tag + (旧文件去掉头部旧 tag 的部分)
    /// 5. 原子写回
    static func write(
        fileURL: URL,
        title: String,
        artist: String,
        album: String?,
        details: TrackDetails? = nil,
        lyrics: String?,
        coverData: Data?,
        coverMIME: String
    ) throws {
        let original = try Data(contentsOf: fileURL)
        let existingTagSize = detectExistingID3Size(in: original)
        let audioStart = existingTagSize
        let audioData = original.subdata(in: audioStart..<original.count)

        let newTag = buildTag(
            title: title,
            artist: artist,
            album: album,
            details: details,
            lyrics: lyrics,
            coverData: coverData,
            coverMIME: coverMIME
        )

        var out = Data(capacity: newTag.count + audioData.count)
        out.append(newTag)
        out.append(audioData)

        try out.write(to: fileURL, options: .atomic)
    }

    /// 原文件开头有没有 ID3v2 tag?有的话返回它整段的字节数(含 10 字节 header + footer)。
    /// 没有就返回 0。
    private static func detectExistingID3Size(in data: Data) -> Int {
        guard data.count >= 10 else { return 0 }
        guard data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return 0 } // "ID3"
        let flags = data[5]
        let hasFooter = (flags & 0x10) != 0
        let size = synchsafeDecode(data[6], data[7], data[8], data[9])
        var total = 10 + size
        if hasFooter { total += 10 }
        return total
    }

    private static func buildTag(
        title: String,
        artist: String,
        album: String?,
        details: TrackDetails?,
        lyrics: String?,
        coverData: Data?,
        coverMIME: String
    ) -> Data {
        var frames = Data()
        frames.append(buildTextFrame(id: "TIT2", text: title))
        frames.append(buildTextFrame(id: "TPE1", text: artist))
        if let album = album, !album.isEmpty {
            frames.append(buildTextFrame(id: "TALB", text: album))
        }
        if let d = details {
            if let n = d.trackNumber, n > 0 {
                let trck = d.trackTotal.map { "\(n)/\($0)" } ?? "\(n)"
                frames.append(buildTextFrame(id: "TRCK", text: trck))
            }
            if let aa = d.albumArtist, !aa.isEmpty {
                frames.append(buildTextFrame(id: "TPE2", text: aa))
            }
            if let date = d.releaseDate, !date.isEmpty {
                frames.append(buildTextFrame(id: "TDRC", text: date))
            }
            if let genre = d.genre, !genre.isEmpty {
                frames.append(buildTextFrame(id: "TCON", text: genre))
            }
            if let company = d.company, !company.isEmpty {
                frames.append(buildTextFrame(id: "TPUB", text: company))
            }
        }
        if let lyrics = lyrics, !lyrics.isEmpty {
            frames.append(buildUSLTFrame(lyrics: lyrics))
        }
        if let coverData = coverData, !coverData.isEmpty {
            frames.append(buildAPICFrame(data: coverData, mime: coverMIME))
        }

        // padding 1024 字节 —— 留点空给后续重新写 tag 不必整文件再挪一次
        let padding = Data(count: 1024)
        let body = frames + padding

        var header = Data()
        header.append(contentsOf: [0x49, 0x44, 0x33])           // "ID3"
        header.append(contentsOf: [0x04, 0x00])                  // v2.4.0
        header.append(0x00)                                       // flags
        header.append(synchsafeEncode(body.count))                // size (4 bytes synchsafe)

        return header + body
    }

    /// 文本帧 TIT2 / TPE1 / TALB ——
    /// 帧头(10) + 编码字节(1) + UTF-8 text。size 字段在 v2.4 也是 synchsafe。
    private static func buildTextFrame(id: String, text: String) -> Data {
        var body = Data()
        body.append(0x03)                                          // UTF-8
        body.append(text.data(using: .utf8) ?? Data())
        return frameHeader(id: id, size: body.count) + body
    }

    /// USLT 同步歌词帧 ——
    /// 编码字节 + 三字节语言代码 + 内容描述(以 NUL 结尾) + 实际歌词。
    /// 把 LRC 整段当 lyrics 塞进去,大多数播放器都能识别。
    private static func buildUSLTFrame(lyrics: String) -> Data {
        var body = Data()
        body.append(0x03)                                          // UTF-8
        body.append(contentsOf: [0x63, 0x68, 0x69])               // "chi" (中文)
        body.append(0x00)                                          // 空描述符,直接 NUL 结尾
        body.append(lyrics.data(using: .utf8) ?? Data())
        return frameHeader(id: "USLT", size: body.count) + body
    }

    /// APIC 封面帧 ——
    /// 编码字节 + MIME 类型(NUL 结尾) + 封面类型(0x03 = 前封面) + 描述(NUL 结尾) + 图片二进制。
    private static func buildAPICFrame(data: Data, mime: String) -> Data {
        var body = Data()
        body.append(0x03)                                          // UTF-8 (描述用)
        body.append(mime.data(using: .ascii) ?? Data())
        body.append(0x00)                                          // MIME NUL
        body.append(0x03)                                          // 封面类型: front cover
        body.append(0x00)                                          // 描述为空,直接 NUL
        body.append(data)
        return frameHeader(id: "APIC", size: body.count) + body
    }

    /// 帧头 10 字节:4 字节 ID + 4 字节 synchsafe size + 2 字节 flags。
    private static func frameHeader(id: String, size: Int) -> Data {
        var h = Data()
        h.append(id.data(using: .ascii) ?? Data())
        h.append(synchsafeEncode(size))
        h.append(contentsOf: [0x00, 0x00])
        return h
    }

    /// 28 位整数打包到 4 字节,每字节只用低 7 位 —— 这是 ID3v2 防止跟 MP3 同步信号
    /// 冲突的常规手段。
    private static func synchsafeEncode(_ size: Int) -> Data {
        var d = Data(count: 4)
        d[0] = UInt8((size >> 21) & 0x7F)
        d[1] = UInt8((size >> 14) & 0x7F)
        d[2] = UInt8((size >> 7)  & 0x7F)
        d[3] = UInt8(size & 0x7F)
        return d
    }

    private static func synchsafeDecode(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Int {
        Int(b0 & 0x7F) << 21 | Int(b1 & 0x7F) << 14 | Int(b2 & 0x7F) << 7 | Int(b3 & 0x7F)
    }
}

// MARK: - FLAC (Vorbis Comment + PICTURE)

/// FLAC 标签写入 —— 解析现有 metadata block 链,把 VORBIS_COMMENT 和 PICTURE
/// 替换/插入,保留 STREAMINFO / SEEKTABLE 等其它块,最后拼回完整文件。
///
/// FLAC 结构:
/// ```
/// "fLaC" (4 bytes)
/// [metadata block]*  (第一个一定是 STREAMINFO,最后一个有 last-block flag = 1)
/// [audio frames]
/// ```
///
/// 每个 metadata block:
/// ```
/// 4 bytes header:
///   1 bit  last-block flag
///   7 bits block type (0=STREAMINFO, 1=PADDING, 4=VORBIS_COMMENT, 6=PICTURE, ...)
///   24 bits data length (big-endian)
/// data...
/// ```
nonisolated enum FLACTagWriter {

    enum WriterError: Error {
        case notFLAC
        case parseFailed
    }

    static let blockTypeVorbisComment: UInt8 = 4
    static let blockTypePicture: UInt8 = 6
    static let blockTypePadding: UInt8 = 1
    static let blockTypeStreaminfo: UInt8 = 0

    static func write(
        fileURL: URL,
        title: String,
        artist: String,
        album: String?,
        details: TrackDetails? = nil,
        lyrics: String?,
        coverData: Data?,
        coverMIME: String
    ) throws {
        let original = try Data(contentsOf: fileURL)
        // 4 字节签名 + 至少一个 STREAMINFO block (4 + 34 字节) = 42 字节起步
        guard original.count >= 42 else { throw WriterError.parseFailed }
        guard original[0] == 0x66, original[1] == 0x4C,
              original[2] == 0x61, original[3] == 0x43 else { throw WriterError.notFLAC }

        // 解析所有 metadata block,记录每块的范围
        struct Block { let type: UInt8; let range: Range<Int>; let dataRange: Range<Int> }
        var blocks: [Block] = []
        var cursor = 4
        var lastSeen = false
        while !lastSeen && cursor + 4 <= original.count {
            let header0 = original[cursor]
            let isLast = (header0 & 0x80) != 0
            let type = header0 & 0x7F
            let length = Int(original[cursor + 1]) << 16
                       | Int(original[cursor + 2]) << 8
                       | Int(original[cursor + 3])
            let blockEnd = cursor + 4 + length
            guard blockEnd <= original.count else { throw WriterError.parseFailed }
            blocks.append(Block(type: type,
                                range: cursor..<blockEnd,
                                dataRange: (cursor + 4)..<blockEnd))
            cursor = blockEnd
            lastSeen = isLast
        }
        let audioStart = cursor
        guard audioStart <= original.count else { throw WriterError.parseFailed }

        // 重组:STREAMINFO + 其它老块(去掉旧 VORBIS_COMMENT/PICTURE/PADDING)
        //       + 新 VORBIS_COMMENT + 新 PICTURE(如果有) + 一个 PADDING block 收尾。
        var output = Data()
        output.append(contentsOf: [0x66, 0x4C, 0x61, 0x43])  // "fLaC"

        // 1) STREAMINFO 必须留(放第一个)
        guard let streamInfo = blocks.first, streamInfo.type == blockTypeStreaminfo else {
            throw WriterError.parseFailed
        }
        // 2) 收集除 VORBIS_COMMENT / PICTURE / PADDING 之外的其它块(SEEKTABLE / CUESHEET / APPLICATION 等)
        let keepers = blocks.dropFirst().filter {
            $0.type != blockTypeVorbisComment
                && $0.type != blockTypePicture
                && $0.type != blockTypePadding
        }
        // 3) 构造新的 VORBIS_COMMENT data
        let vcData = buildVorbisCommentData(title: title, artist: artist, album: album, details: details, lyrics: lyrics)
        // 4) 构造新的 PICTURE data(可选)
        let picData: Data? = coverData.flatMap { d in
            buildPictureData(coverData: d, mime: coverMIME)
        }
        // 5) PADDING block(4096 字节) —— 留出空间下次重写不一定要整文件挪
        let paddingData = Data(count: 4096)

        // 把所有新块按 [STREAMINFO][keepers...][VC][PIC?][PADDING] 顺序拼接,
        // 最后一块标记 last-block。
        var newBlocks: [(type: UInt8, data: Data)] = []
        newBlocks.append((blockTypeStreaminfo, original.subdata(in: streamInfo.dataRange)))
        for k in keepers {
            newBlocks.append((k.type, original.subdata(in: k.dataRange)))
        }
        newBlocks.append((blockTypeVorbisComment, vcData))
        if let pic = picData { newBlocks.append((blockTypePicture, pic)) }
        newBlocks.append((blockTypePadding, paddingData))

        for (idx, blk) in newBlocks.enumerated() {
            let isLast = (idx == newBlocks.count - 1)
            output.append(encodeBlockHeader(type: blk.type, length: blk.data.count, isLast: isLast))
            output.append(blk.data)
        }

        // 6) 拼上音频帧(原文件从 audioStart 开始的所有字节)
        output.append(original.subdata(in: audioStart..<original.count))

        try output.write(to: fileURL, options: .atomic)
    }

    /// VORBIS_COMMENT 块内容(不含 4 字节 block header):
    /// ```
    ///   4 bytes LE: vendor length
    ///   vendor (UTF-8)
    ///   4 bytes LE: comment count
    ///   for each:
    ///     4 bytes LE: comment length
    ///     "KEY=VALUE" UTF-8
    /// ```
    private static func buildVorbisCommentData(
        title: String,
        artist: String,
        album: String?,
        details: TrackDetails?,
        lyrics: String?
    ) -> Data {
        let vendor = "shuhao"
        var comments: [String] = []
        comments.append("TITLE=\(title)")
        comments.append("ARTIST=\(artist)")
        if let album = album, !album.isEmpty {
            comments.append("ALBUM=\(album)")
        }
        if let d = details {
            if let n = d.trackNumber, n > 0 { comments.append("TRACKNUMBER=\(n)") }
            if let total = d.trackTotal, total > 0 { comments.append("TRACKTOTAL=\(total)") }
            if let aa = d.albumArtist, !aa.isEmpty { comments.append("ALBUMARTIST=\(aa)") }
            if let date = d.releaseDate, !date.isEmpty { comments.append("DATE=\(date)") }
            if let genre = d.genre, !genre.isEmpty { comments.append("GENRE=\(genre)") }
            if let company = d.company, !company.isEmpty { comments.append("ORGANIZATION=\(company)") }
        }
        if let lyrics = lyrics, !lyrics.isEmpty {
            comments.append("LYRICS=\(lyrics)")
        }

        var out = Data()
        let vendorBytes = vendor.data(using: .utf8) ?? Data()
        out.append(uint32LE(vendorBytes.count))
        out.append(vendorBytes)
        out.append(uint32LE(comments.count))
        for c in comments {
            let bytes = c.data(using: .utf8) ?? Data()
            out.append(uint32LE(bytes.count))
            out.append(bytes)
        }
        return out
    }

    /// PICTURE 块(不含 4 字节 block header):全部字段都是 big-endian。
    private static func buildPictureData(coverData: Data, mime: String) -> Data {
        // 用 UIImage 测一下尺寸 + 位深,FLAC 规范这几项必须填。
        let img = UIImage(data: coverData)
        let width = Int(img?.size.width ?? 0)
        let height = Int(img?.size.height ?? 0)
        // 8 bits per channel × 3 channels = 24 bits per pixel,JPEG/PNG 多数走这个。
        let depth = 24

        var out = Data()
        out.append(uint32BE(3))                                    // picture type: front cover
        let mimeBytes = mime.data(using: .ascii) ?? Data()
        out.append(uint32BE(mimeBytes.count))
        out.append(mimeBytes)
        out.append(uint32BE(0))                                    // description length = 0
        out.append(uint32BE(width))
        out.append(uint32BE(height))
        out.append(uint32BE(depth))
        out.append(uint32BE(0))                                    // # of indexed colors (0 = non-indexed)
        out.append(uint32BE(coverData.count))
        out.append(coverData)
        return out
    }

    /// 4 字节 block header:1 bit last-block flag + 7 bits type + 24 bits length。
    private static func encodeBlockHeader(type: UInt8, length: Int, isLast: Bool) -> Data {
        var h = Data(count: 4)
        h[0] = (isLast ? 0x80 : 0x00) | (type & 0x7F)
        h[1] = UInt8((length >> 16) & 0xFF)
        h[2] = UInt8((length >> 8) & 0xFF)
        h[3] = UInt8(length & 0xFF)
        return h
    }

    private static func uint32LE(_ value: Int) -> Data {
        var d = Data(count: 4)
        d[0] = UInt8(value & 0xFF)
        d[1] = UInt8((value >> 8) & 0xFF)
        d[2] = UInt8((value >> 16) & 0xFF)
        d[3] = UInt8((value >> 24) & 0xFF)
        return d
    }

    private static func uint32BE(_ value: Int) -> Data {
        var d = Data(count: 4)
        d[0] = UInt8((value >> 24) & 0xFF)
        d[1] = UInt8((value >> 16) & 0xFF)
        d[2] = UInt8((value >> 8) & 0xFF)
        d[3] = UInt8(value & 0xFF)
        return d
    }
}

// MARK: - LRC serialization helper

/// 把 shuhao 解析后的 [LyricLine] 重新打包成标准 LRC 文本 ——
/// 嵌入 MP3/FLAC 后其它播放器拿到也能识别。
nonisolated enum LRCSerializer {
    static func serialize(_ lines: [LyricLine]) -> String {
        var out = ""
        for line in lines {
            // shuhao 用 time == -1 表示纯文本(没时间戳的歌词),写时也按一行文本输出。
            if line.time < 0 {
                out += line.text + "\n"
                continue
            }
            let totalCentis = Int((line.time * 100).rounded())
            let mins = totalCentis / 6000
            let secs = (totalCentis / 100) % 60
            let centis = totalCentis % 100
            let prefix = String(format: "[%02d:%02d.%02d]", mins, secs, centis)
            out += prefix + line.text + "\n"
            if let trans = line.translation, !trans.isEmpty {
                // 翻译也插一行,用同一时间戳 —— 大多数播放器会识别为同时显示。
                out += prefix + trans + "\n"
            }
        }
        return out
    }
}
