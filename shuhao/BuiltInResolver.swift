import Foundation

/// Direct platform endpoints used as a fallback when user-script `musicUrl` resolution fails.
/// These hit each platform's own open APIs — no third-party server dependency.
nonisolated enum BuiltInResolver {

    enum ResolveError: LocalizedError {
        case unsupported(SourceID)
        case http(Int)
        case noURL
        case vipOrUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupported(let s):
                switch s {
                case .mg: return "咪咕需要付费账号 cookie 才能解析 URL,默认 v4 脚本后端不支持咪咕,本地直连也无法绕过"
                case .kg: return "酷狗 URL 解析需要可用的 v4 脚本(本地直连酷狗需复杂签名,暂未实现)"
                case .tx: return "QQ 音乐 URL 解析需要可用的 v4 脚本(本地直连 QQ 音乐需复杂签名,暂未实现)"
                default: return "内置直连暂不支持 \(s.displayName)"
                }
            case .http(let c): return "HTTP \(c)"
            case .noURL: return "未返回播放地址"
            case .vipOrUnavailable: return "该曲目可能是 VIP 或受限歌曲"
            }
        }
    }

    struct ResolvedURL: Sendable {
        let url: URL
        let warning: String?  // surfaced to UI as a soft notice when the URL is e.g. a DRM placeholder
    }

    /// Kuwo serves a single DRM placeholder file (常见尾段：`588957081.mp3`)containing
    /// the announcement "当前歌曲仅在酷我音乐手机端播放" whenever the request lacks
    /// valid app-side authorization. Reject those so the user gets a real error instead
    /// of an audio recording telling them to download the Kuwo app.
    static let kuwoDRMPlaceholderFiles: Set<String> = ["588957081.mp3"]
    static func isKuwoDRMPlaceholder(_ url: URL) -> Bool {
        let last = url.lastPathComponent
        return kuwoDRMPlaceholderFiles.contains(last)
    }

    static func resolve(track: Track, quality: Quality) async throws -> ResolvedURL {
        switch track.source {
        case .kw:
            return try await resolveKuwo(songmid: track.songmid, quality: quality)
        case .wy:
            let url = try await resolveNetEase(songmid: track.songmid)
            return ResolvedURL(url: url, warning: nil)
        default:
            throw ResolveError.unsupported(track.source)
        }
    }

    // MARK: - Kuwo

    private static func kuwoBR(for quality: Quality) -> String {
        switch quality {
        case .k128: return "128kmp3"
        case .k320: return "320kmp3"
        case .flac: return "2000kflac"
        // The legacy antiserver endpoint has no atmos/master modes — hires is its ceiling.
        case .flac24, .hires, .atmos, .atmosPlus, .master: return "4000khires"
        }
    }

    /// Kuwo's `antiserver` endpoint has two modes:
    ///  - `convert_url3` returns JSON `{code, msg, url}` and prefers HTTPS CDN
    ///  - `convert_url` (legacy) returns plain text URL (often HTTP)
    /// We try convert_url3 first; if it returns code != 200 or empty url, we degrade
    /// the bitrate (high → low) and finally fall back to the legacy plaintext endpoint.
    private static func resolveKuwo(songmid: String, quality: Quality) async throws -> ResolvedURL {
        let preferred = kuwoBR(for: quality)
        let allBR = orderedKuwoBRs(starting: preferred)
        var lastError: Error?
        var lastDRMURL: URL?
        for br in allBR {
            do {
                if let u = try await kuwoConvertURL3(songmid: songmid, br: br) {
                    if Self.isKuwoDRMPlaceholder(u) {
                        // Remember it but keep trying other bitrates in case one returns a real URL.
                        lastDRMURL = u
                        continue
                    }
                    return ResolvedURL(url: u, warning: nil)
                }
            } catch {
                lastError = error
            }
        }
        if let u = try? await kuwoConvertURLLegacy(songmid: songmid, br: preferred) {
            if Self.isKuwoDRMPlaceholder(u) {
                lastDRMURL = u
            } else {
                return ResolvedURL(url: u, warning: nil)
            }
        }
        // No real URL anywhere — play the placeholder anyway so the user hears something
        // (and clearly knows what's going on via the warning banner).
        if let u = lastDRMURL {
            return ResolvedURL(
                url: u,
                warning: "酷我对未授权请求只返回 DRM 占位音频(「仅在酷我音乐手机端播放」)。需要一个能解析真实 URL 的 v4 脚本才能听到原曲。"
            )
        }
        if let lastError { throw lastError }
        throw ResolveError.vipOrUnavailable
    }

    private static func orderedKuwoBRs(starting br: String) -> [String] {
        let cascade = ["4000khires", "2000kflac", "320kmp3", "128kmp3"]
        guard let idx = cascade.firstIndex(of: br) else { return [br] + cascade }
        return Array(cascade[idx...]) + Array(cascade[..<idx])
    }

    private static func kuwoConvertURL3(songmid: String, br: String) async throws -> URL? {
        let urlStr = "http://antiserver.kuwo.cn/anti.s?type=convert_url3&format=mp3&response=url&rid=\(songmid)&br=\(br)"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ResolveError.http(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let code = json["code"] as? Int, code != 200 { return nil }
        guard let urlString = json["url"] as? String, !urlString.isEmpty, let resolved = URL(string: urlString) else {
            return nil
        }
        return resolved
    }

    private static func kuwoConvertURLLegacy(songmid: String, br: String) async throws -> URL {
        let urlStr = "http://antiserver.kuwo.cn/anti.s?format=mp3&rid=\(songmid)&type=convert_url&response=url&br=\(br)"
        guard let url = URL(string: urlStr) else { throw ResolveError.noURL }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("http"), let u = URL(string: text) else {
            throw ResolveError.noURL
        }
        return u
    }

    // MARK: - NetEase

    /// NetEase's `outer/url` endpoint 302-redirects to the real audio CDN or to `/404` for VIP / unavailable songs.
    /// We must NOT follow the redirect automatically — capture the Location header and decide.
    private static func resolveNetEase(songmid: String) async throws -> URL {
        guard let url = URL(string: "https://music.163.com/song/media/outer/url?id=\(songmid).mp3") else {
            throw ResolveError.noURL
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ResolveError.noURL }
        guard http.statusCode == 302 || http.statusCode == 301 || http.statusCode == 303 else {
            throw ResolveError.http(http.statusCode)
        }
        guard let location = http.value(forHTTPHeaderField: "Location"),
              let resolved = URL(string: location) else {
            throw ResolveError.noURL
        }
        if location.contains("/404") { throw ResolveError.vipOrUnavailable }
        return resolved
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)  // Stop on redirect — caller reads Location from response.
    }
}
