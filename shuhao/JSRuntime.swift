import Foundation
import JavaScriptCore

/// Wraps a single lx-music v4 user script in a JSContext.
/// Implements the contract defined in Resources/user-api-preload.js.
final class JSScriptRuntime {
    let scriptID: String
    let metadata: ScriptMetadata
    private let context: JSContext
    private let key: String
    private let queue = DispatchQueue(label: "JSScriptRuntime.\(UUID().uuidString)")
    private var timeoutCallbacks: [Int: DispatchWorkItem] = [:]

    private var pendingRequests: [String: (Result<Any, Error>) -> Void] = [:]
    private var initContinuation: CheckedContinuation<ScriptCapabilities, Error>?
    private var inited: Bool = false
    private(set) var capabilities: ScriptCapabilities = ScriptCapabilities(sources: [:])

    struct ScriptMetadata {
        let id: String
        let name: String
        let description: String
        let version: String
        let author: String
        let homepage: String
    }

    enum RuntimeError: LocalizedError {
        case contextCreateFailed
        case preloadMissing
        case scriptThrew(String)
        case actionFailed(String)
        case notInited
        case unsupported(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .contextCreateFailed: return "无法创建 JS 上下文"
            case .preloadMissing: return "缺少用户脚本预加载文件"
            case .scriptThrew(let msg): return "脚本抛出异常: \(msg)"
            case .actionFailed(let msg): return "脚本调用失败: \(msg)"
            case .notInited: return "脚本尚未初始化"
            case .unsupported(let s): return "不支持: \(s)"
            case .timeout: return "脚本响应超时"
            }
        }
    }

    init(metadata: ScriptMetadata, rawScript: String) throws {
        guard let ctx = JSContext() else { throw RuntimeError.contextCreateFailed }
        self.context = ctx
        self.metadata = metadata
        self.scriptID = metadata.id
        self.key = UUID().uuidString

        ctx.exceptionHandler = { _, exc in
            print("[JSRuntime] exception: \(exc?.toString() ?? "?")")
        }
        // Console — receive all arguments (scripts often pass `console.log('label', value)`).
        // Joining all args mirrors web/Node's space-separated formatting.
        let makeConsole: (String) -> @convention(block) () -> Void = { level in
            return {
                let args = JSContext.currentArguments() ?? []
                let parts: [String] = args.compactMap { ($0 as? JSValue)?.toString() }
                print("[JS \(level)] \(parts.joined(separator: " "))")
            }
        }
        let console = JSValue(newObjectIn: ctx)!
        console.setObject(makeConsole("log"),   forKeyedSubscript: "log" as NSString)
        console.setObject(makeConsole("info"),  forKeyedSubscript: "info" as NSString)
        console.setObject(makeConsole("warn"),  forKeyedSubscript: "warn" as NSString)
        console.setObject(makeConsole("error"), forKeyedSubscript: "error" as NSString)
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)

        try installNativeCallbacks()

        guard let preloadURL = Bundle.main.url(forResource: "user-api-preload", withExtension: "js"),
              let preload = try? String(contentsOf: preloadURL, encoding: .utf8) else {
            throw RuntimeError.preloadMissing
        }
        ctx.evaluateScript(preload)
        if let exc = ctx.exception {
            throw RuntimeError.scriptThrew("preload: \(exc.toString() ?? "?")")
        }

        // Call lx_setup(key, id, name, description, version, author, homepage, rawScript)
        let setup = ctx.objectForKeyedSubscript("lx_setup")
        setup?.call(withArguments: [
            key, metadata.id, metadata.name, metadata.description,
            metadata.version, metadata.author, metadata.homepage, rawScript
        ])
        if let exc = ctx.exception {
            throw RuntimeError.scriptThrew("lx_setup: \(exc.toString() ?? "?")")
        }

        // Evaluate the user script directly — mirrors QuickJS.java loadScript() which calls
        // jsContext.evaluate(script) without any wrapping. The v4 source is itself an IIFE.
        ctx.evaluateScript(rawScript)
        if let exc = ctx.exception {
            throw RuntimeError.scriptThrew("user script: \(exc.toString() ?? "?")")
        }
    }

    /// Wait for the script to call `lx.send('inited', info)`. Times out after `timeout` seconds.
    func waitForInit(timeout: TimeInterval = 10) async throws -> ScriptCapabilities {
        if inited { return capabilities }
        return try await withThrowingTaskGroup(of: ScriptCapabilities.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScriptCapabilities, Error>) in
                    self.queue.sync { self.initContinuation = cont }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw RuntimeError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Ask the script to perform an action: musicUrl / lyric / pic.
    func requestAction(source: SourceID, action: String, info: [String: Any]) async throws -> Any {
        if !inited { throw RuntimeError.notInited }
        let requestKey = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            queue.sync { self.pendingRequests[requestKey] = { result in
                switch result {
                case .success(let v): cont.resume(returning: v)
                case .failure(let e): cont.resume(throwing: e)
                }
            }}
            let payload: [String: Any] = [
                "requestKey": requestKey,
                "data": ["source": source.rawValue, "action": action, "info": info]
            ]
            sendToScript(action: "request", payload: payload)
        }
    }

    private func sendToScript(action: String, payload: Any?) {
        let dataString: String
        if let payload {
            dataString = Self.safeJSONString(from: payload)
        } else {
            dataString = ""
        }
        let native = context.objectForKeyedSubscript("__lx_native__")
        if payload == nil {
            native?.call(withArguments: [key, action])
        } else {
            native?.call(withArguments: [key, action, dataString])
        }
    }

    /// 安全地把任意 payload 编码成 JSON 字符串。
    ///
    /// **不能直接 `try? JSONSerialization.data(...)`** —— `JSONSerialization` 遇到
    /// 无法编码的对象(NaN / Infinity 的 NSNumber、非 String 的字典 key、raw Data、
    /// JSValue 包装、循环引用等)会抛 Objective-C `NSException`,**Swift 的 `try?` 不接
    /// NSException**,直接 abort 进程。
    ///
    /// 同时:`isValidJSONObject(_:)` 对**顶层不是 array/dict 的"原子值"返回 false**
    /// (Int / String / NSNull 等),但这些值其实是合法的 JSON fragment,
    /// 脚本端拿到 `"5"` 就能 `JSON.parse` 出 Int。`sendToScript` 在
    /// `__set_timeout__` 通路上正是传的 `Int`,顶层原子值 —— 走 isValidJSONObject
    /// 会被误判,导致 setTimeout 回调 ID 丢失、脚本卡死。所以这里要分两条路。
    private static func safeJSONString(from payload: Any) -> String {
        // 路径 1:容器(dict / array)走标准 isValidJSONObject + serialize。
        if let s = serializeContainer(payload) { return s }
        // 路径 2:顶层原子值(Int / String / Bool / NSNull) —— 直接拼 JSON 字面量,
        // 绕过 isValidJSONObject 的"必须是容器"硬性要求。
        if let s = serializePrimitive(payload) { return s }
        // 路径 3:容器里夹了无法编码的值 —— 跑一遍 sanitizer 再试一次。
        let sanitized = sanitizeForJSON(payload)
        if let s = serializeContainer(sanitized) { return s }
        if let s = serializePrimitive(sanitized) { return s }
        print("[JSRuntime] payload not JSON-encodable even after sanitize, sending null")
        return "null"
    }

    /// 容器路径 —— 用 isValidJSONObject 把异常拦截在 ObjC 抛出之前。
    private static func serializeContainer(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 原子值路径 —— 自己拼 JSON literal,这样 `Int(5)` 输出 `"5"`,而不是
    /// 退化成 `"null"`(后者会让脚本的 `JSON.parse` 出 `null` → 查 callbacks[null] → 卡死)。
    private static func serializePrimitive(_ obj: Any) -> String? {
        if obj is NSNull { return "null" }
        // NSNumber 在 ObjC 桥下既可能是 Bool 也可能是 Int/Double —— 用 objCType 区分。
        // Swift Bool / NSNumber(value: true) 的 objCType 是 "c" 或 "B"。
        if let n = obj as? NSNumber {
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" {
                return n.boolValue ? "true" : "false"
            }
            let d = n.doubleValue
            if d.isNaN || d.isInfinite { return "null" }
            if let i = Int(exactly: n) { return String(i) }
            return String(d)
        }
        if let s = obj as? String {
            // 借 JSONSerialization 自己的 escape 逻辑(fragmentsAllowed 才接受原子值)。
            if let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }
        return nil
    }

    /// 递归把 Swift/ObjC 值清洗成 JSON-safe 形式。
    /// 策略:
    /// - dict:key 转 String,value 递归
    /// - array:每个元素递归
    /// - NSNumber:NaN / Infinity → NSNull
    /// - Data:base64 字符串(脚本想自己解码就解)
    /// - String / Bool / 普通 NSNumber / NSNull:原样
    /// - 其它(包括 JSValue、未知 ObjC 对象):`String(describing:)` 退化为可读字符串
    private static func sanitizeForJSON(_ obj: Any) -> Any {
        if let n = obj as? NSNumber {
            // NSNumber 涵盖了 Bool / Int / Double 等,先单独看 Double 的特殊值。
            // 用 CFGetTypeID 区分 Bool 和数值会更严谨,但 NaN/Inf 一律置 null 就够。
            let d = n.doubleValue
            if d.isNaN || d.isInfinite { return NSNull() }
            return n
        }
        if obj is NSNull { return obj }
        if let s = obj as? String { return s }
        if let dict = obj as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = sanitizeForJSON(v) }
            return out
        }
        if let dict = obj as? [AnyHashable: Any] {
            // 非 String key 的 dict:强转 key,丢掉转不了的。
            var out: [String: Any] = [:]
            for (k, v) in dict { out[String(describing: k)] = sanitizeForJSON(v) }
            return out
        }
        if let arr = obj as? [Any] {
            return arr.map { sanitizeForJSON($0) }
        }
        if let data = obj as? Data {
            return data.base64EncodedString()
        }
        // 兜底:脚本回包里 JSValue / 自定义类 / 函数等无法编码的东西,降级成可读字符串。
        return String(describing: obj)
    }

    // MARK: - Native callbacks installed before preload runs

    private func installNativeCallbacks() throws {
        // _nativeCall(key, action, dataString) — script => host
        let nativeCall: @convention(block) (String, String, String) -> Void = { [weak self] key, action, dataString in
            guard let self else { return }
            guard key == self.key else { return }
            self.handleScriptCall(action: action, rawData: dataString)
        }
        context.setObject(nativeCall, forKeyedSubscript: "__lx_native_call__" as NSString)

        // set_timeout
        let setTimeout: @convention(block) (NSNumber, NSNumber) -> Void = { [weak self] id, timeoutMS in
            guard let self else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.queue.sync { self?.timeoutCallbacks.removeValue(forKey: id.intValue) }
                self?.sendToScript(action: "__set_timeout__", payload: id.intValue)
            }
            self.queue.sync { self.timeoutCallbacks[id.intValue] = work }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMS.intValue), execute: work)
        }
        context.setObject(setTimeout, forKeyedSubscript: "__lx_native_call__set_timeout" as NSString)

        // utils_str2b64
        let str2b64: @convention(block) (String) -> String = { s in CryptoBridge.base64Encode(s) }
        context.setObject(str2b64, forKeyedSubscript: "__lx_native_call__utils_str2b64" as NSString)

        // utils_b642buf — returns JSON string of byte array (preload does JSON.parse)
        let b642buf: @convention(block) (String) -> String = { b64 in
            guard let bytes = CryptoBridge.base64DecodeToBytes(b64) else { return "[]" }
            // [UInt8] 理论上一定是合法 JSON array,但 isValidJSONObject 加上没坏处 ——
            // 同样防 NSException 把进程带走。
            return Self.safeJSONString(from: bytes)
        }
        context.setObject(b642buf, forKeyedSubscript: "__lx_native_call__utils_b642buf" as NSString)

        // utils_str2md5
        let str2md5: @convention(block) (String) -> String = { s in CryptoBridge.md5(s) }
        context.setObject(str2md5, forKeyedSubscript: "__lx_native_call__utils_str2md5" as NSString)

        // utils_aes_encrypt(b64data, b64key, b64iv, mode)
        let aesEnc: @convention(block) (String, String, String, String) -> String = { d, k, iv, mode in
            CryptoBridge.aesEncrypt(dataB64: d, keyB64: k, ivB64: iv, mode: mode) ?? ""
        }
        context.setObject(aesEnc, forKeyedSubscript: "__lx_native_call__utils_aes_encrypt" as NSString)

        // utils_rsa_encrypt(b64data, key, padding)
        let rsaEnc: @convention(block) (String, String, String) -> String = { d, k, p in
            CryptoBridge.rsaEncrypt(dataB64: d, pemBody: k, padding: p) ?? ""
        }
        context.setObject(rsaEnc, forKeyedSubscript: "__lx_native_call__utils_rsa_encrypt" as NSString)
    }

    private func handleScriptCall(action: String, rawData: String) {
        let parsed: Any? = {
            guard let data = rawData.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }()
        switch action {
        case "init":
            handleInit(parsed)
        case "showUpdateAlert":
            print("[JSRuntime] updateAlert: \(parsed ?? "nil")")
        case "request":
            handleHTTPRequest(parsed)
        case "cancelRequest":
            if let key = parsed as? String { ScriptHTTPClient.shared.cancel(requestKey: key) }
        case "response":
            handleScriptResponse(parsed)
        default:
            print("[JSRuntime] unknown script call: \(action)")
        }
    }

    private func handleInit(_ data: Any?) {
        guard let dict = data as? [String: Any] else {
            failInit(error: RuntimeError.actionFailed("init payload not a dict"))
            return
        }
        if let status = dict["status"] as? Bool, !status {
            let msg = dict["errorMessage"] as? String ?? "unknown"
            failInit(error: RuntimeError.actionFailed(msg))
            return
        }
        var caps = ScriptCapabilities(sources: [:])
        if let info = dict["info"] as? [String: Any],
           let sources = info["sources"] as? [String: Any] {
            for (key, val) in sources {
                guard let src = SourceID(rawValue: key),
                      let v = val as? [String: Any] else { continue }
                let actions = (v["actions"] as? [String]) ?? []
                let qstrs = (v["qualitys"] as? [String]) ?? []
                let qs = qstrs.compactMap { Quality(rawValue: $0) }
                caps.sources[src] = SourceCapability(
                    type: (v["type"] as? String) ?? "music",
                    actions: actions,
                    qualities: qs
                )
            }
        }
        capabilities = caps
        inited = true
        let cont = queue.sync { () -> CheckedContinuation<ScriptCapabilities, Error>? in
            let c = self.initContinuation; self.initContinuation = nil; return c
        }
        cont?.resume(returning: caps)
    }

    private func failInit(error: Error) {
        let cont = queue.sync { () -> CheckedContinuation<ScriptCapabilities, Error>? in
            let c = self.initContinuation; self.initContinuation = nil; return c
        }
        cont?.resume(throwing: error)
    }

    private func handleHTTPRequest(_ data: Any?) {
        guard let dict = data as? [String: Any],
              let requestKey = dict["requestKey"] as? String,
              let url = dict["url"] as? String else { return }
        let options = (dict["options"] as? [String: Any]) ?? [:]
        ScriptHTTPClient.shared.send(requestKey: requestKey, url: url, options: options) { [weak self] error, response in
            guard let self else { return }
            // Mirror lx-music-mobile's contract: always send both fields, one is NSNull. Scripts
            // that use `if (error == null)` rely on a present-but-null key.
            var payload: [String: Any] = ["requestKey": requestKey]
            if let error {
                payload["error"] = error.localizedDescription
                payload["response"] = NSNull()
            } else if let response {
                payload["error"] = NSNull()
                payload["response"] = [
                    "statusCode": response.statusCode,
                    "statusMessage": response.statusMessage,
                    "headers": response.headers,
                    "body": response.body,
                ]
            } else {
                payload["error"] = "no response"
                payload["response"] = NSNull()
            }
            self.sendToScript(action: "response", payload: payload)
        }
    }

    private func handleScriptResponse(_ data: Any?) {
        guard let dict = data as? [String: Any],
              let requestKey = dict["requestKey"] as? String else { return }
        let cb = queue.sync { () -> ((Result<Any, Error>) -> Void)? in
            let c = self.pendingRequests[requestKey]
            self.pendingRequests.removeValue(forKey: requestKey)
            return c
        }
        guard let cb else { return }
        if let status = dict["status"] as? Bool, status, let result = dict["result"] {
            cb(.success(result))
        } else {
            let msg = dict["errorMessage"] as? String ?? "unknown error"
            cb(.failure(RuntimeError.actionFailed(msg)))
        }
    }
}
