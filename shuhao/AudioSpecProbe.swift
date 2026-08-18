import Foundation

/// 实测的音频规格 — 从文件头解析,不信任音源后端声称的档位。
/// FLAC 给位深/采样率,MP3 给码率;探测失败(未知容器/网络错误)整体为 nil,UI 不显示。
struct AudioSpec: Equatable, Sendable {
    let codec: String        // "FLAC" / "MP3"
    let sampleRate: Int      // Hz
    let bitsPerSample: Int?  // FLAC
    let bitrateKbps: Int?    // MP3

    var displayText: String {
        if let b = bitsPerSample {
            let khz = Double(sampleRate) / 1000
            let khzStr = khz.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(khz)) : String(format: "%.1f", khz)
            return "\(codec) \(b)bit/\(khzStr)kHz"
        }
        if let kbps = bitrateKbps { return "\(codec) \(kbps)kbps" }
        return codec
    }
}

nonisolated enum AudioSpecProbe {

    /// 远端 URL 用 Range 请求取头部字节,本地文件直接读。永不抛错,失败返回 nil。
    /// 只取 8KB:FLAC STREAMINFO 在前 26 字节,ID3 头 10 字节,裸 MP3 帧同步通常在
    /// 前几 KB。曾经取 64KB,慢 CDN 上要等一两秒才出结果。
    static func probe(url: URL) async -> AudioSpec? {
        guard let head = await fetchBytes(url: url, offset: 0, count: 8192), head.count >= 10 else {
            return nil
        }
        if head.prefix(4) == Data("fLaC".utf8) {
            return parseFLAC(head)
        }
        if head.prefix(3) == Data("ID3".utf8) {
            // ID3v2 size = 4 字节 syncsafe(每字节 7 位)。标签里常嵌封面,可能远超缓冲,
            // 超出就对标签结束位置再发一次 Range 请求。
            let size = (Int(head[6]) << 21) | (Int(head[7]) << 14) | (Int(head[8]) << 7) | Int(head[9])
            let tagEnd = 10 + size
            if tagEnd + 4 <= head.count {
                return parseMP3(head, from: tagEnd)
            }
            guard let frames = await fetchBytes(url: url, offset: tagEnd, count: 8192) else { return nil }
            return parseMP3(frames, from: 0)
        }
        // 裸 MP3(无 ID3)或其他 — 在头部里扫帧同步字。m4a 等未知容器自然失败。
        return parseMP3(head, from: 0)
    }

    // MARK: - FLAC

    /// STREAMINFO 永远是第一个 metadata block(规范保证),位于 "fLaC" 后 4 字节块头之后。
    private static func parseFLAC(_ data: Data) -> AudioSpec? {
        guard data.count >= 8 + 18 else { return nil }
        let d = [UInt8](data)
        guard d[4] & 0x7F == 0 else { return nil }  // block type 0 = STREAMINFO
        // STREAMINFO 第 10 字节起的 8 字节:20 位采样率 + 3 位声道 + 5 位位深 + 36 位总样本数
        var packed: UInt64 = 0
        for i in 0..<8 { packed = (packed << 8) | UInt64(d[8 + 10 + i]) }
        let sampleRate = Int(packed >> 44)
        let bps = Int((packed >> 36) & 0x1F) + 1
        guard sampleRate > 0 else { return nil }
        return AudioSpec(codec: "FLAC", sampleRate: sampleRate, bitsPerSample: bps, bitrateKbps: nil)
    }

    // MARK: - MP3

    private static let mpeg1L3Bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let mpeg2L3Bitrates = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
    private static let mpeg1Rates = [44100, 48000, 32000]
    private static let mpeg2Rates = [22050, 24000, 16000]
    private static let mpeg25Rates = [11025, 12000, 8000]

    private static func parseMP3(_ data: Data, from start: Int) -> AudioSpec? {
        let d = [UInt8](data)
        guard d.count > start + 4 else { return nil }
        // 扫描帧同步字(11 个置位比特),容忍标签和帧之间的填充垃圾。
        for i in start..<min(d.count - 4, start + 8192) {
            guard d[i] == 0xFF, d[i + 1] & 0xE0 == 0xE0 else { continue }
            let versionBits = (d[i + 1] >> 3) & 0x3   // 0=MPEG2.5, 2=MPEG2, 3=MPEG1
            let layerBits = (d[i + 1] >> 1) & 0x3     // 1=Layer3
            guard versionBits != 1, layerBits == 1 else { continue }
            let bitrateIdx = Int(d[i + 2] >> 4)
            let rateIdx = Int((d[i + 2] >> 2) & 0x3)
            guard bitrateIdx > 0, bitrateIdx < 15, rateIdx < 3 else { continue }
            let isV1 = versionBits == 3
            let kbps = (isV1 ? mpeg1L3Bitrates : mpeg2L3Bitrates)[bitrateIdx]
            let rates = isV1 ? mpeg1Rates : (versionBits == 2 ? mpeg2Rates : mpeg25Rates)
            return AudioSpec(codec: "MP3", sampleRate: rates[rateIdx], bitsPerSample: nil, bitrateKbps: kbps)
        }
        return nil
    }

    // MARK: - IO

    private static func fetchBytes(url: URL, offset: Int, count: Int) async -> Data? {
        if url.isFileURL {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(offset))
            return try? handle.read(upToCount: count)
        }
        var req = URLRequest(url: url)
        req.setValue("bytes=\(offset)-\(offset + count - 1)", forHTTPHeaderField: "Range")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        do {
            // bytes API + 手动截断:就算 CDN 不认 Range 返回整个文件,也只读前 count 字节。
            let (stream, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            var data = Data(capacity: count)
            for try await byte in stream {
                data.append(byte)
                if data.count >= count { break }
            }
            return data
        } catch {
            return nil
        }
    }
}
