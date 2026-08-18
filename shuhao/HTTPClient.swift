import Foundation

/// HTTP requests issued by JS user scripts via `lx.request`.
/// Mirrors lx-music-mobile/src/core/init/userApi/request.js — same default UA,
/// same JSON-parsing-on-response behavior, same Content-Type handling.
final class ScriptHTTPClient {
    static let shared = ScriptHTTPClient()

    // Match the default UA in lx-music-mobile's request.js (Windows Chrome). Some
    // backends, including the bundled v4 script's API server, are picky about UA.
    private static let defaultUA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36"

    private let session: URLSession
    private var tasks: [String: URLSessionDataTask] = [:]
    private let queue = DispatchQueue(label: "ScriptHTTPClient.queue")

    init() {
        let config = URLSessionConfiguration.default
        // Compromise: the lxmusic API server can take 5–10s for legitimate URL resolution,
        // but hangs forever on unsupported platforms (e.g. mg). 25s lets slow requests
        // succeed while bounding the worst case.
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 35
        self.session = URLSession(configuration: config)
    }

    struct ScriptResponse {
        let statusCode: Int
        let statusMessage: String
        let headers: [String: String]
        /// Already JSON-decoded if the body parsed as JSON, otherwise the raw UTF-8 string,
        /// otherwise an array of bytes. Matches the contract in lx-music-mobile's `fetchData`.
        let body: Any
    }

    func send(requestKey: String, url: String, options: [String: Any], completion: @escaping (Error?, ScriptResponse?) -> Void) {
        guard let u = URL(string: url) else {
            completion(NSError(domain: "ScriptHTTPClient", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]), nil)
            return
        }
        var req = URLRequest(url: u)
        let method = ((options["method"] as? String) ?? "GET").uppercased()
        req.httpMethod = method
        if let timeout = options["timeout"] as? Double { req.timeoutInterval = timeout / 1000.0 }

        // Caller-supplied headers
        var callerHeaders: [String: String] = [:]
        if let headers = options["headers"] as? [String: Any] {
            for (k, v) in headers {
                let value = String(describing: v)
                callerHeaders[k] = value
                req.setValue(value, forHTTPHeaderField: k)
            }
        }

        // Body shape: body | form | formData (mirrors handleRequestData in request.js)
        if method == "POST", let form = options["form"] as? [String: Any] {
            req.httpBody = encodeForm(form).data(using: .utf8)
            if hasHeaderCI(callerHeaders, "Content-Type") == nil {
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        } else if method == "POST", let formData = options["formData"] as? [String: Any] {
            req.httpBody = try? JSONSerialization.data(withJSONObject: formData)
            if hasHeaderCI(callerHeaders, "Content-Type") == nil {
                req.setValue("multipart/form-data", forHTTPHeaderField: "Content-Type")
            }
        } else if let body = options["body"] {
            if hasHeaderCI(callerHeaders, "Content-Type") == nil, method == "POST" {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let ct = (hasHeaderCI(callerHeaders, "Content-Type") ?? "").lowercased()
            if ct.contains("application/json"), let dict = body as? [String: Any] {
                req.httpBody = try? JSONSerialization.data(withJSONObject: dict)
            } else {
                req.httpBody = bodyToData(body)
            }
        }

        // Default headers (only if not set by caller). Matches request.js defaultHeaders + Accept.
        if hasHeaderCI(callerHeaders, "User-Agent") == nil {
            req.setValue(Self.defaultUA, forHTTPHeaderField: "User-Agent")
        }
        if hasHeaderCI(callerHeaders, "Accept") == nil {
            req.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        let binary = (options["binary"] as? Bool) ?? false

        if UserDefaults.standard.bool(forKey: "debug.logScriptHTTP") {
            let hdrs = req.allHTTPHeaderFields ?? [:]
            print("[ScriptHTTP] → \(method) \(url)\n  headers=\(hdrs)")
        }
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            self?.queue.sync { self?.tasks.removeValue(forKey: requestKey) }
            if UserDefaults.standard.bool(forKey: "debug.logScriptHTTP"), let error {
                print("[ScriptHTTP] ✗ \(url): \(error.localizedDescription)")
            }
            if let error {
                completion(error, nil); return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(NSError(domain: "ScriptHTTPClient", code: -2,
                                   userInfo: [NSLocalizedDescriptionKey: "No HTTP response"]), nil)
                return
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let key = k as? String { headers[key.lowercased()] = String(describing: v) }
            }
            let bodyValue = Self.decodeBody(data: data, binary: binary)
            // Debug: surface raw response so we can see exactly what the script gets.
            if UserDefaults.standard.bool(forKey: "debug.logScriptHTTP") {
                let preview = String(data: (data ?? Data()).prefix(800), encoding: .utf8) ?? "<binary>"
                print("[ScriptHTTP] ← \(http.statusCode) \(url)\n  bytes=\(data?.count ?? 0) parsed=\(type(of: bodyValue))\n  raw: \(preview)")
            }
            let resp = ScriptResponse(
                statusCode: http.statusCode,
                statusMessage: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                headers: headers,
                body: bodyValue
            )
            completion(nil, resp)
        }
        queue.sync { tasks[requestKey] = task }
        task.resume()
    }

    /// Mirrors request.js: try JSON.parse(body); on failure pass the raw text; for binary requests
    /// return the byte array. The key fix is the JSON parse — without it, scripts that do
    /// `resp.body.code` / `resp.body.data.url` get undefined.
    static func decodeBody(data: Data?, binary: Bool) -> Any {
        guard let data, !data.isEmpty else { return "" }
        if binary { return [UInt8](data) }
        // Try JSON first (objects, arrays, primitives)
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return json
        }
        // Fallback: utf8 string
        if let txt = String(data: data, encoding: .utf8) { return txt }
        // Last resort: raw bytes
        return [UInt8](data)
    }

    private func hasHeaderCI(_ headers: [String: String], _ name: String) -> String? {
        let target = name.lowercased()
        for (k, v) in headers where k.lowercased() == target { return v }
        return nil
    }

    func cancel(requestKey: String) {
        queue.sync {
            tasks[requestKey]?.cancel()
            tasks.removeValue(forKey: requestKey)
        }
    }

    private func bodyToData(_ body: Any) -> Data? {
        if let s = body as? String { return s.data(using: .utf8) }
        if let arr = body as? [Any] {
            let bytes = arr.compactMap { ($0 as? NSNumber)?.uint8Value }
            return Data(bytes)
        }
        if let dict = body as? [String: Any] {
            return try? JSONSerialization.data(withJSONObject: dict)
        }
        return nil
    }

    private func encodeForm(_ form: [String: Any]) -> String {
        form.map { k, v in
            let key = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let val = String(describing: v).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return "\(key)=\(val)"
        }.joined(separator: "&")
    }
}
