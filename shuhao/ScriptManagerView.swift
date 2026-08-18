import SwiftUI
import UniformTypeIdentifiers

struct ScriptManagerView: View {
    @EnvironmentObject var scripts: ScriptStore
    @EnvironmentObject var sources: SourceManager
    @State private var showImport = false
    @State private var importMode: ImportMode = .url
    @State private var inputText: String = ""
    @State private var pickedFileName: String?
    @State private var showFileImporter = false
    @State private var isLoading = false
    @State private var error: String?

    enum ImportMode: String, CaseIterable, Identifiable {
        case url = "从 URL"
        case paste = "从粘贴"
        case file = "从文件"
        var id: String { rawValue }
    }

    var body: some View {
        List {
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
        // 导入弹窗 —— Mac → .popover(点外面/Esc 关,跟设置弹窗一致),iOS → .sheet。
        #if targetEnvironment(macCatalyst)
        .popover(isPresented: $showImport) {
            importForm
                .frame(width: 520, height: 600)
        }
        #else
        .sheet(isPresented: $showImport) {
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
                        Section("脚本文件") {
                            Button {
                                showFileImporter = true
                            } label: {
                                Label(pickedFileName ?? "选择脚本文件", systemImage: "doc.badge.plus")
                            }
                            if pickedFileName != nil {
                                Text("已读取 \(inputText.count) 字符")
                                    .font(.caption).foregroundColor(.secondary)
                            }
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
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [.javaScript, .text, .plainText, .json, .data],
                    allowsMultipleSelection: false
                ) { result in
                    loadPickedFile(result)
                }
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
            guard let text = String(data: data, encoding: .utf8) else {
                error = "无法以 UTF-8 读取该文件"; return
            }
            inputText = text
            pickedFileName = url.lastPathComponent
        } catch {
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
            await sources.load(script: script)
            showImport = false
            reset()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
