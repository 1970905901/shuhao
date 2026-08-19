import SwiftUI

struct ScriptManagerView: View {
    @EnvironmentObject var scripts: ScriptStore
    @EnvironmentObject var sources: SourceManager
    @State private var showImport = false
    @State private var importMode: ImportMode = .url
    @State private var inputText: String = ""
    @State private var pickedFileName: String?
    @State private var isLoading = false
    @State private var error: String?
    /// 系统文件选择器是否弹出(SwiftUI .fileImporter,iOS 16+ 官方 API)。
    @State private var showFilePicker = false

    enum ImportMode: String, CaseIterable, Identifiable {
        case url = "从 URL"
        case paste = "从粘贴"
        case file = "从文件"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            // 加载失败/切换失败的错误提示 —— 之前只在导入表单里显示,列表页
            // 重载失败(网络问题等)完全无感知。放列表顶部,出错了才出现。
            if let loadErr = sources.lastError {
                Section {
                    Label(loadErr, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .onTapGesture { sources.lastError = nil }
                }
            }
            if scripts.scripts.isEmpty {
                ShUnavailableView(
                    title: "暂无自定义脚本",
                    systemImage: "doc.text",
                    description: Text("点击右上角 + 从 URL 或粘贴板导入脚本")
                )
            } else {
                ForEach(scripts.scripts) { script in
                    let isLoaded = sources.loadedScripts.contains { $0.script.id == script.id }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(script.name).font(.headline)
                            Spacer()
                            if isLoaded {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            }
                        }
                        if !script.description.isEmpty {
                            Text(script.description).font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                        Text("v\(script.version) · \(script.author)").font(.caption2).foregroundColor(.secondary)
                        HStack {
                            Toggle("启用", isOn: Binding(
                                get: { script.enabled },
                                set: { newValue in
                                    scripts.toggle(script.id, enabled: newValue)
                                    if newValue {
                                        Task { await sources.load(script: script) }
                                    } else {
                                        sources.unload(scriptID: script.id)
                                    }
                                }
                            ))
                            .labelsHidden()
                            Button("重新加载") {
                                Task { await sources.load(script: script) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button(role: .destructive) { delete(script.id) } label: {
                            Label("删除脚本", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(script.id) } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
                .onDelete { idx in
                    let ids = idx.map { scripts.scripts[$0].id }
                    for id in ids { delete(id) }
                }
            }
        }
        .navigationTitle("自定义音源")
        .navigationBarTitleDisplayMode(.inline)
        .sheetNavBarSurface()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImport = true } label: { Image(systemName: "plus") }
            }
        }
        // 导入弹窗 —— Mac → .popover(点外面/Esc 关,跟设置弹窗一致),iOS → fullScreenCover。
        // ⚠️ iOS 用 fullScreenCover 而不是 sheet:fullScreenCover 是独立的呈现上下文,
        // 里面再弹 .fileImporter 时不会被嵌套 sheet 的呈现控制器干扰 —— 这是历史
        // 上"文档选择器能打开但点文件无反应"的根因之一(iOS 16/17 上 sheet 内嵌
        // fileImporter/UIDocumentPicker 回调会丢)。
        #if targetEnvironment(macCatalyst)
        .popover(isPresented: $showImport) {
            importForm
                .frame(width: 520, height: 600)
        }
        #else
        .fullScreenCover(isPresented: $showImport) {
            importForm
        }
        #endif
    }

    private var importForm: some View {
        NavigationStack {
            Form {
                Picker("方式", selection: $importMode) {
                    ForEach(ImportMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if importMode == .file {
                    Section {
                        Button {
                            // 点按钮才弹文件选择器 —— 不在 Form 内部直接挂 .fileImporter,
                            // 避免选择器呈现上下文和 Form 的滚动/焦点系统打架。
                            showFilePicker = true
                        } label: {
                            Label(pickedFileName ?? "选择脚本文件", systemImage: "doc.badge.plus")
                        }
                        if pickedFileName != nil {
                            Text("已读取 \(inputText.count) 字符")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    } header: {
                        Text("脚本文件")
                    } footer: {
                        // 系统文件界面点文件是"选中",要再点右上角"打开"才会返回
                        Text("在系统文件界面选中脚本后,请点右上角「打开」完成选择")
                            .font(.caption)
                    }
                } else {
                    Section(importMode == .url ? "脚本 URL" : "脚本内容") {
                        TextEditor(text: $inputText)
                            .frame(minHeight: importMode == .url ? 60 : 200)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                if let error {
                    Text(error).foregroundColor(.red).font(.caption)
                }
                Section {
                    Button(isLoading ? "导入中..." : "导入并加载") {
                        Task { await doImport() }
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                }
            }
            .navigationTitle("导入脚本")
            .navigationBarTitleDisplayMode(.inline)
            .sheetNavBarSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showImport = false; reset() }
                }
            }
            .shOnChange(of: importMode) {
                // Each mode takes a different input; don't carry stale text/file across.
                inputText = ""; pickedFileName = nil; error = nil
            }
            // SwiftUI 原生文件选择器,挂在 fullScreenCover 内容的根上 —— 系统级呈现,
            // 选中/取消回调由 SwiftUI 托管,不存在 delegate 释放或嵌套呈现丢失的问题。
            // .item 通配类型保证任意扩展名(.js/.txt/.json/...)都能被选中。
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false,
                onCompletion: loadPickedFile
            )
        }
    }

    private func delete(_ id: UUID) {
        sources.unload(scriptID: id)
        scripts.remove(id)
    }

    /// Read the user-picked script file into `inputText` (security-scoped access required).
    private func loadPickedFile(_ result: Result<[URL], Error>) {
        error = nil
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            // 1) 去 UTF-8 BOM(EF BB BF),不少 JS 文件被编辑器加上 BOM
            // 2) 优先 UTF-8;失败再退到 ASCII,避免一上来就报"无法以 UTF-8 读取"
            let stripped: Data
            if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
                stripped = data.subdata(in: 3..<data.count)
            } else {
                stripped = data
            }
            let text: String
            if let utf8 = String(data: stripped, encoding: .utf8) {
                text = utf8
            } else if let ascii = String(data: stripped, encoding: .ascii) {
                text = ascii
            } else {
                error = "无法识别文件编码(请确认是 UTF-8 / ASCII 文本)"; return
            }
            inputText = text
            pickedFileName = url.lastPathComponent
        } catch {
            // 用户主动取消选择器不算错误,别把 "cancelled" 显示成红色报错。
            let e = error as NSError
            if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        inputText = ""
        pickedFileName = nil
        error = nil
        isLoading = false
    }

    private func doImport() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let raw: String
            switch importMode {
            case .url:
                guard let url = URL(string: inputText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    error = "URL 无效"; return
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let s = String(data: data, encoding: .utf8) else {
                    error = "无法以 UTF-8 解码"; return
                }
                raw = s
            case .paste, .file:
                raw = inputText
            }
            let script = ScriptStore.parseMetadata(from: raw)
            scripts.add(script)
            let loaded = await sources.load(script: script)
            if loaded {
                showImport = false
                reset()
            } else {
                // 脚本进了列表但加载失败 —— 明确告诉用户,别静默关掉表单。
                // (load 失败原因已写入 sources.lastError,这里转成表单内提示)
                self.error = sources.lastError ?? "脚本加载失败,请检查脚本内容"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
