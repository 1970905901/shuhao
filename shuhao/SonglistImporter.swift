import SwiftUI

// MARK: - 在线歌单导入(QQ / 酷狗 / 酷我 / 网易云)
//
// 用户粘贴一个分享链接(或纯 playlist ID + 平台选择)→ 解析得到 (源, 歌单ID) →
// 调对应平台的 `SonglistService.fetchDetail` 拉所有曲目 → 创建一个本地用户歌单
// 把曲目灌进去。重复用 PlaylistStore.addTracks 的去重逻辑,同一首歌不会重复。

nonisolated enum SonglistImporter {

    enum ImportError: LocalizedError {
        case unrecognizedURL
        case fetchFailed(String)
        case emptyPlaylist
        var errorDescription: String? {
            switch self {
            case .unrecognizedURL: return "无法识别歌单链接,请粘贴酷我 / 酷狗 / QQ / 网易云的歌单分享链接"
            case .fetchFailed(let msg): return "获取歌单失败:\(msg)"
            case .emptyPlaylist: return "歌单为空或暂时无法读取"
            }
        }
    }

    // MARK: - URL parsing

    /// 解析结果:平台 + 该平台 API 需要的歌单 ID。
    struct ParsedRef: Equatable {
        let source: SourceID
        let id: String
    }

    /// 从用户粘贴的任意文本里识别出歌单引用 —— 支持各平台分享文案 + 裸 URL。
    /// 通常分享文案是"我用XX发现一个超棒的歌单 \"名字\" https://...id=12345",
    /// 所以先扫一次链接再扫散落的 ID 关键词。
    static func parse(_ raw: String) -> ParsedRef? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 1) 优先按 URL 匹配 —— 每家平台有自己的歌单 URL 形态
        if let ref = matchURL(in: s) { return ref }

        // 2) 退而求其次 —— 纯数字串当作 playlist id(用户没贴链接,需要 UI 再问平台)
        //    这里返回 nil,UI 层会让用户配合平台 picker 自行构造 ParsedRef。
        return nil
    }

    private static func matchURL(in text: String) -> ParsedRef? {
        // 各家域名特征 + ID 抽取规则。顺序无所谓 —— 每个 pattern 只匹配自己平台的域名。
        let patterns: [(SourceID, [String])] = [
            // 网易云:music.163.com / y.music.163.com,?id= 或 #/playlist?id=
            (.wy, [
                #"music\.163\.com[^\s]*?[?#&]id=(\d+)"#,
            ]),
            // QQ:y.qq.com/n/ryqq/playlist/<id>、taoge.html?id=<id>、i.y.qq.com/n2/m/share/details/taoge.html?id=<id>、
            //    i2.y.qq.com/n3/other/pages/details/playlist.html?...&id=<id>(微信分享)
            (.tx, [
                #"y\.qq\.com/n/ryqq/playlist/(\d+)"#,
                #"qq\.com[^\s]*?taoge\.html[^\s]*?[?&]id=(\d+)"#,
                #"qq\.com[^\s]*?playlist\.html[^\s]*?[?&]id=(\d+)"#,
                #"y\.qq\.com[^\s]*?/playsquare/(\d+)"#,
            ]),
            // 酷狗:www.kugou.com/songlist/<specialid>/、t1.kugou.com 分享、listid=
            (.kg, [
                #"kugou\.com/songlist/(\d+)"#,
                #"kugou\.com[^\s]*?[?&]listid=(\d+)"#,
                #"kugou\.com[^\s]*?[?&]global_collection_id=(\d+)"#,
            ]),
            // 酷我:www.kuwo.cn/playlist_detail/<pid>、m.kuwo.cn newh5app
            (.kw, [
                #"kuwo\.cn[^\s]*?/playlist_detail/(\d+)"#,
                #"kuwo\.cn[^\s]*?[?&]pid=(\d+)"#,
            ]),
        ]
        for (source, regs) in patterns {
            for pat in regs {
                if let id = firstCapture(text, pattern: pat) {
                    return ParsedRef(source: source, id: id)
                }
            }
        }
        return nil
    }

    private static func firstCapture(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        let range = m.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }

    // MARK: - Import

    /// 分批写入的批大小 —— 每批之间让出主线程,千首大歌单导入时 UI 不卡死。
    private static let batchSize = 100

    /// 拉歌单 → 建本地歌单 → 分批写入。返回新建歌单的 id 和导入曲目数。
    /// progress 在每批写完后回调 (已导入, 总数),用于 UI 进度展示。
    @MainActor
    static func importPlaylist(
        ref: ParsedRef,
        customName: String?,
        playlists: PlaylistStore,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> (playlistID: UUID, count: Int) {
        guard let svc = Songlists.service(for: ref.source) else {
            throw ImportError.unrecognizedURL
        }
        // 用 ID 构造一个最小的 stub —— fetchDetail 只看 .id 和 .source
        let stub = SonglistInfo(
            id: ref.id, source: ref.source,
            name: "", author: "", picURL: nil, trackCount: nil, playCount: nil
        )
        let detail: SonglistDetail
        do {
            detail = try await svc.fetchDetail(stub)
        } catch {
            throw ImportError.fetchFailed(error.localizedDescription)
        }
        guard !detail.tracks.isEmpty else { throw ImportError.emptyPlaylist }

        // 歌单名:用户指定 > 接口返回的名字 > 兜底 "导入的歌单"
        let trimmed = (customName ?? "").trimmingCharacters(in: .whitespaces)
        let name = !trimmed.isEmpty ? trimmed
            : (detail.info.name.isEmpty ? "导入的歌单" : detail.info.name)
        let p = playlists.createPlaylist(name: name)
        // 分批写入:中间批次不落盘(save 会整包编码 trackBank,是主线程卡顿大头),
        // 每批之间 yield 让 UI 有机会刷新,最后统一 persist 一次。
        let all = detail.tracks
        var start = 0
        while start < all.count {
            let end = min(start + batchSize, all.count)
            playlists.addTracks(Array(all[start..<end]), to: p.id, persist: false)
            progress?(end, all.count)
            start = end
            if start < all.count { await Task.yield() }
        }
        playlists.persist()
        return (p.id, all.count)
    }
}

// MARK: - 导入弹窗(平台选择 + URL 粘贴 / 纯 ID + 进度)

struct SonglistImportSheet: View {
    @EnvironmentObject var playlists: PlaylistStore
    @Environment(\.dismiss) private var dismiss

    @State private var raw = ""
    @State private var customName = ""
    /// 用户没贴 URL 只贴了纯 ID 时,需要他选个平台。URL 模式下这个被自动覆盖。
    @State private var manualSource: SourceID = .wy
    @State private var importing = false
    /// 分批写入阶段的进度 (已导入, 总数);拉取阶段为 nil。
    @State private var importProgress: (done: Int, total: Int)?
    @State private var doneCount: Int?
    @State private var error: String?

    /// 实时识别 —— 用户每输入一个字符就重新解析,展示自动识别的平台标签。
    private var parsedRef: SonglistImporter.ParsedRef? {
        SonglistImporter.parse(raw)
    }

    /// 纯数字 ID(没识别出 URL 但用户输的全是数字)→ 需要平台选择器手动配。
    private var pureID: String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty,
              s.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) })
        else { return nil }
        return s
    }

    private var canImport: Bool {
        !importing && doneCount == nil && (parsedRef != nil || pureID != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("歌单链接") {
                    TextField("粘贴酷我/酷狗/QQ/网易云的歌单分享链接或 ID", text: $raw, axis: .vertical)
                        .lineLimit(2...4)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(importing)
                    if let ref = parsedRef {
                        Label("已识别:\(displayName(ref.source))歌单 · \(ref.id)",
                              systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if pureID != nil {
                        // 纯数字 ID:让用户告诉我们是哪个平台
                        Picker("来源平台", selection: $manualSource) {
                            ForEach([SourceID.wy, .tx, .kg, .kw], id: \.self) { s in
                                Text(displayName(s)).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Text("支持的链接形式举例:\n• music.163.com/playlist?id=…\n• y.qq.com/n/ryqq/playlist/…\n• kugou.com/songlist/…\n• kuwo.cn/playlist_detail/…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section("歌单名(可选)") {
                    TextField("留空则用原歌单名", text: $customName)
                        .disabled(importing)
                }

                if importing {
                    Section {
                        if let p = importProgress {
                            ProgressView(value: Double(p.done), total: Double(p.total)) {
                                Text("正在导入 \(p.done)/\(p.total) 首…").font(.caption)
                            }
                        } else {
                            ProgressView {
                                Text("正在拉取曲目…").font(.caption)
                            }
                        }
                    }
                }
                if let doneCount {
                    Section {
                        Label("导入完成,共 \(doneCount) 首", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let error {
                    Text(error).foregroundColor(.red).font(.caption)
                }

                Section {
                    Button(importing ? "导入中…" : "确定导入") {
                        Task { await doImport() }
                    }
                    .disabled(!canImport)
                }
            }
            .navigationTitle("导入歌单")
            .navigationBarTitleDisplayMode(.inline)
            .sheetNavBarSurface()
            // Mac 走 popover —— 跟本地导入弹窗一致,见 LocalImportSheet 同位置注释。
            #if !targetEnvironment(macCatalyst)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(importing)
                }
            }
            #endif
            .interactiveDismissDisabled(importing)
        }
    }

    private func doImport() async {
        let ref: SonglistImporter.ParsedRef
        if let p = parsedRef {
            ref = p
        } else if let id = pureID {
            ref = SonglistImporter.ParsedRef(source: manualSource, id: id)
        } else {
            error = "无法识别链接 / ID"
            return
        }
        importing = true; error = nil; importProgress = nil
        do {
            let result = try await SonglistImporter.importPlaylist(
                ref: ref, customName: customName, playlists: playlists,
                progress: { done, total in importProgress = (done, total) }
            )
            importing = false; importProgress = nil
            doneCount = result.count
            // 让用户看一眼 "导入完成" 再收起 —— 同 LocalImportSheet 节奏
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        } catch {
            importing = false; importProgress = nil
            self.error = error.localizedDescription
        }
    }

    private func displayName(_ s: SourceID) -> String {
        switch s {
        case .wy: return "网易云"
        case .tx: return "QQ 音乐"
        case .kg: return "酷狗"
        case .kw: return "酷我"
        default:  return s.rawValue
        }
    }
}
