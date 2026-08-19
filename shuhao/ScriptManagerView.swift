import SwiftUI
import UIKit  // UIDocumentPickerViewController (ScriptFilePicker)
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
            }
            // ⚠️ 从本地选脚本文件不走 SwiftUI 的 `.fileImporter` —— iOS 16/17 上它
            // 嵌在 sheet 里时,系统文档选择器能打开、能浏览文件,但点选 .js/.json
            // 这类"非 document"类型文件时选择器不关闭、回调不触发,表现为"点了
            // 没反映"(已踩坑:挂 Form 上不行、挂 NavigationStack 上也不行,去掉
            // .data 也不行)。换成 UIKit 的 UIDocumentPickerViewController 直连呈现,
            // 选中/取消都走 UIDocumentPickerDelegate,完全绕开 SwiftUI 那层。
            .fullScreenCover(isPresented: $showFileImporter) {
                ScriptFilePicker { result in
                    showFileImporter = false
                    // ScriptFilePicker 回的是单个 URL,loadPickedFile 吃数组,套一层。
                    switch result {
                    case .success(let url):
                        loadPickedFile(.success([url]))
                    case .failure(let error):
                        loadPickedFile(.failure(error))
                    }
                }
                .ignoresSafeArea()
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
            await sources.load(script: script)
            showImport = false
            reset()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - UIKit 文档选择器

/// 用 UIKit 的 `UIDocumentPickerViewController` 实现"从本地选脚本文件"。
///
/// 为什么不用 SwiftUI 的 `.fileImporter`:iOS 16/17 上 `.fileImporter` 嵌在 sheet 里时,
/// 系统文档选择器能打开、能浏览文件,但点选 `.js` / `.json` 这类"非 document"类型
/// 文件时选择器不关闭、回调不触发,表现为"点了没反映"(把修饰符挂到 sheet 内容根、
/// 去掉 `.data` 通配类型都无效)。换成 UIKit 直连呈现,选中/取消都走
/// `UIDocumentPickerDelegate`,完全绕开 SwiftUI 那层对文档选择的处理。
struct ScriptFilePicker: UIViewControllerRepresentable {
    let onPick: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.javaScript, .text, .plainText, .json]
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (Result<URL, Error>) -> Void
        init(onPick: @escaping (Result<URL, Error>) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(.success(url))
            } else {
                onPick(.failure(URLError(.cannotOpenFile)))
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(.failure(URLError(.cancelled)))
        }
    }
}
