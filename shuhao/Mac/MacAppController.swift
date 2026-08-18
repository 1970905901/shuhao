import Foundation
import UIKit
import Combine
import Intents
import ObjectiveC.runtime

// MARK: - UIApplicationDelegate

/// 注入到 shuhaoApp 的 @UIApplicationDelegateAdaptor。本身在 iOS 上是无作用的占位,
/// 主要价值在于 Mac Catalyst —— 实现了 AppKit 才有的 `applicationShouldTerminateAfterLastWindowClosed:`
/// (返回 NO ⇒ 红色关闭按钮只是关窗口,app 进程继续跑),以及 `applicationShouldHandleReopen:`
/// (点 Dock 图标时让窗口回来)。Catalyst runtime 会自动把 NSApplicationDelegate 的调用转发
/// 到我们的 UIApplicationDelegate 实例上,前提是 selector 一字不差地暴露出来。
final class ShuhaoAppDelegate: NSObject, UIApplicationDelegate {
    /// SiriKit in-app handling:"用随便听播放晴天"这类 INPlayMediaIntent 由系统
    /// 后台拉起 app 后从这里拿 handler,不走 Intents Extension。
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        if intent is INPlayMediaIntent {
            return MainActor.assumeIsolated { SiriPlayMediaHandler() }
        }
        return nil
    }

    #if targetEnvironment(macCatalyst)
    @objc(applicationShouldTerminateAfterLastWindowClosed:)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: Any) -> Bool {
        // 状态栏图标一直在,用户随时可以从状态栏菜单"打开播放器"把窗口叫回来。
        return false
    }

    @objc(applicationShouldHandleReopen:hasVisibleWindows:)
    func applicationShouldHandleReopen(_ sender: Any, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MacStatusBarController.shared.showMainWindow()
        }
        return true
    }
    #endif
}

// MARK: - Notification names (status bar → views)

extension Notification.Name {
    static let shuhaoMacOpenSearch = Notification.Name("shuhaoMacOpenSearch")
    static let shuhaoMacOpenPlayer = Notification.Name("shuhaoMacOpenPlayer")
}

#if targetEnvironment(macCatalyst)

// MARK: - MacStatusBarController

/// 维护 Mac 状态栏(menu bar)右侧的图标:显示当前歌曲(长文本走滚动),配一个下拉菜单
/// 控制播放/暂停、上一首/下一首、搜索、打开播放器、退出。
///
/// 实现策略:Mac Catalyst 不能直接 `import AppKit`,所以所有 AppKit 类(NSStatusBar、
/// NSStatusItem、NSMenu、NSMenuItem、NSApplication、NSWindow)都通过:
///   - `NSClassFromString("...")` 拿类对象
///   - 对返回值用 `setValue(_:forKey:)` / `value(forKey:)` 读写普通属性
///   - 要传 `SEL` 参数的方法(setAction:、activateIgnoringOtherApps: 等)用
///     `class_getInstanceMethod` + `unsafeBitCast` 拿到带 C 调用约定的 IMP 直接调
///
/// 这套桥接 OC API 上下文的损耗不大,生命周期 stick 在 shared singleton 上 ——
/// 状态栏项跟 app 进程同生死。
@MainActor
final class MacStatusBarController: NSObject {
    static let shared = MacStatusBarController()

    // MARK: AppKit handles (stored as NSObject since the real types aren't visible)
    private var statusItem: NSObject?
    private var statusItemButton: NSObject?
    private var menu: NSObject?
    private var playPauseItem: NSObject?
    private var nextItem: NSObject?
    private var prevItem: NSObject?
    private var searchItem: NSObject?
    private var openPlayerItem: NSObject?
    private var quitItem: NSObject?
    private var dockMenu: NSObject?
    private var dockPlayPauseItem: NSObject?
    private var dockPrevItem: NSObject?
    private var dockNextItem: NSObject?
    private var volumeSlider: NSObject?

    // MARK: State
    private weak var playback: PlaybackEngine?
    private var cancellables = Set<AnyCancellable>()
    private var fullText: String = "随便听"
    private var scrollIdx: Int = 0
    private var scrollTimer: Timer?
    private var hasTrack: Bool = false
    private var isPlaying: Bool = false
    private var installed = false

    /// 一个屏字符数上限,超过就滚动。中英文混排按 unicode scalar 算,够用。
    private let displayWidth: Int = 24
    /// 滚动节奏 —— 0.35s/步,既能看清楚又不会太燥。
    private let scrollInterval: TimeInterval = 0.35

    private override init() { super.init() }

    // MARK: - Install

    func install(playback: PlaybackEngine) {
        guard !installed else { return }
        installed = true
        self.playback = playback
        createStatusItem()
        createMenu()
        createDockMenu()
        observePlayback()
        startScrollTimer()
        refresh(track: playback.currentTrack, isPlaying: playback.isPlaying)
    }

    // MARK: - AppKit bridging helpers

    /// `NSClassFromString` 拿到的类做一下兜底转换。
    private static func cls(_ name: String) -> NSObject.Type? {
        NSClassFromString(name) as? NSObject.Type
    }

    /// `[NSApplication sharedApplication]`。
    private func nsApp() -> NSObject? {
        Self.cls("NSApplication")?.value(forKey: "sharedApplication") as? NSObject
    }

    /// 调用带 `SEL` 参数的方法 —— `setValue(forKey:)` 处理不了 SEL,只能走 IMP。
    private func invokeSelectorSetter(
        on obj: NSObject,
        setter: String,
        value: Selector,
        klass: AnyClass
    ) {
        let sel = NSSelectorFromString(setter)
        guard let method = class_getInstanceMethod(klass, sel) else { return }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (NSObject, Selector, Selector) -> Void
        unsafeBitCast(imp, to: Fn.self)(obj, sel, value)
    }

    /// 调用带 `BOOL` 参数的方法(activateIgnoringOtherApps: 等)。
    private func invokeBoolSetter(
        on obj: NSObject,
        selector: String,
        value: Bool,
        klass: AnyClass
    ) {
        let sel = NSSelectorFromString(selector)
        guard let method = class_getInstanceMethod(klass, sel) else { return }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (NSObject, Selector, ObjCBool) -> Void
        unsafeBitCast(imp, to: Fn.self)(obj, sel, ObjCBool(value))
    }

    // MARK: - Status item construction

    private func createStatusItem() {
        guard let barClass = Self.cls("NSStatusBar"),
              let bar = barClass.value(forKey: "systemStatusBar") as? NSObject else { return }
        // NSVariableStatusItemLength = -1.0 —— 让 AppKit 跟着 button 的 title 算宽度。
        guard let item = bar.perform(
            NSSelectorFromString("statusItemWithLength:"),
            with: NSNumber(value: -1.0)
        )?.takeUnretainedValue() as? NSObject else { return }
        statusItem = item
        statusItemButton = item.value(forKey: "button") as? NSObject
        // 初始 placeholder,避免在 createMenu / refresh 之前 button 空白。
        statusItemButton?.setValue("♪", forKey: "title")
    }

    // MARK: - Menu construction

    private func createMenu() {
        guard let menuClass = Self.cls("NSMenu"),
              let m = menuClass.init() as? NSObject else { return }
        // 默认 autoenablesItems = YES 时 AppKit 在菜单打开时按 target/action 重新
        // 启用所有项,会盖掉我们手动设置的灰态 —— 必须关掉手动接管。
        m.setValue(NSNumber(value: false), forKey: "autoenablesItems")
        menu = m

        playPauseItem  = addItem(to: m, title: "播放",     action: #selector(_playPauseTapped))
        prevItem       = addItem(to: m, title: "上一首",   action: #selector(_prevTapped))
        nextItem       = addItem(to: m, title: "下一首",   action: #selector(_nextTapped))
        addSeparator(to: m)
        addVolumeItem(to: m)
        addSeparator(to: m)
        searchItem     = addItem(to: m, title: "搜索",      action: #selector(_searchTapped))
        openPlayerItem = addItem(to: m, title: "打开播放器", action: #selector(_openPlayerTapped))
        addSeparator(to: m)
        quitItem       = addItem(to: m, title: "退出 随便听", action: #selector(_quitTapped))

        statusItem?.setValue(m, forKey: "menu")
    }

    /// Dock 图标右键菜单 —— 跟状态栏菜单同一套播控动作(去掉"退出",Dock 自带)。
    /// Catalyst 没有公开的 dock menu API:AppKit 侧是 NSApplicationDelegate 的
    /// `applicationDockMenu:`,这里往 NSApp.delegate 的类上动态注入这个 selector,
    /// 返回我们用反射搭好的 NSMenu。
    private func createDockMenu() {
        guard let menuClass = Self.cls("NSMenu"),
              let m = menuClass.init() as? NSObject else { return }
        m.setValue(NSNumber(value: false), forKey: "autoenablesItems")
        dockMenu = m
        dockPlayPauseItem = addItem(to: m, title: "播放",   action: #selector(_playPauseTapped))
        dockPrevItem      = addItem(to: m, title: "上一首", action: #selector(_prevTapped))
        dockNextItem      = addItem(to: m, title: "下一首", action: #selector(_nextTapped))
        addSeparator(to: m)
        addItem(to: m, title: "搜索",      action: #selector(_searchTapped))
        addItem(to: m, title: "打开播放器", action: #selector(_openPlayerTapped))
        installDockMenuProvider()
    }

    private func installDockMenuProvider() {
        guard let app = nsApp(),
              let delegate = app.value(forKey: "delegate") as? NSObject,
              let klass = object_getClass(delegate) else { return }
        let sel = NSSelectorFromString("applicationDockMenu:")
        let block: @convention(block) (NSObject, NSObject) -> NSObject? = { _, _ in
            MainActor.assumeIsolated { MacStatusBarController.shared.dockMenu }
        }
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(klass, sel, imp, "@@:@") {
            class_replaceMethod(klass, sel, imp, "@@:@")
        }
    }

    @discardableResult
    private func addItem(to menu: NSObject, title: String, action: Selector) -> NSObject? {
        guard let itemClass = Self.cls("NSMenuItem"),
              let item = itemClass.init() as? NSObject else { return nil }
        item.setValue(title, forKey: "title")
        item.setValue(self, forKey: "target")
        invokeSelectorSetter(on: item, setter: "setAction:", value: action, klass: itemClass)
        _ = menu.perform(NSSelectorFromString("addItem:"), with: item)
        return item
    }

    /// "音量"菜单项 —— NSMenuItem.view 塞一个 NSSlider(应用内音量,独立于系统音量)。
    /// NSSlider 走 `sliderWithValue:minValue:maxValue:target:action:` 类方法构造,
    /// double 参数 perform 传不了,跟 setFrame: 一样用 IMP 直调。
    private func addVolumeItem(to menu: NSObject) {
        guard let itemClass = Self.cls("NSMenuItem"),
              let item = itemClass.init() as? NSObject,
              let sliderClass = Self.cls("NSSlider"),
              let viewClass = Self.cls("NSView"),
              let container = viewClass.init() as? NSObject else { return }
        let sel = NSSelectorFromString("sliderWithValue:minValue:maxValue:target:action:")
        guard let method = class_getClassMethod(sliderClass, sel) else { return }
        typealias MakeFn = @convention(c) (AnyClass, Selector, Double, Double, Double, NSObject?, Selector?) -> NSObject
        // 滑块位置 = 音量的立方根,跟 IPadBottomBar 的音量曲线保持一致
        let slider = unsafeBitCast(method_getImplementation(method), to: MakeFn.self)(
            sliderClass, sel, Double(cbrt(playback?.volume ?? 1)), 0, 1, self, #selector(_volumeChanged(_:)))
        setFrame(container, CGRect(x: 0, y: 0, width: 220, height: 26))
        // 左边距 14 跟普通菜单项文字对齐
        setFrame(slider, CGRect(x: 14, y: 3, width: 192, height: 19))
        _ = container.perform(NSSelectorFromString("addSubview:"), with: slider)
        volumeSlider = slider
        item.setValue(container, forKey: "view")
        _ = menu.perform(NSSelectorFromString("addItem:"), with: item)
    }

    private func setFrame(_ view: NSObject, _ rect: CGRect) {
        let sel = NSSelectorFromString("setFrame:")
        guard let cls = object_getClass(view),
              let method = class_getInstanceMethod(cls, sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, CGRect) -> Void
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(view, sel, rect)
    }

    private func addSeparator(to menu: NSObject) {
        guard let itemClass = Self.cls("NSMenuItem"),
              let sep = itemClass.perform(NSSelectorFromString("separatorItem"))?
                                  .takeUnretainedValue() as? NSObject else { return }
        _ = menu.perform(NSSelectorFromString("addItem:"), with: sep)
    }

    // MARK: - Playback observation

    private func observePlayback() {
        guard let playback else { return }
        Publishers.CombineLatest(playback.$currentTrack, playback.$isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track, playing in
                self?.refresh(track: track, isPlaying: playing)
            }
            .store(in: &cancellables)
        // 播放器页滑条改音量时,状态栏菜单里的 slider 跟着走
        playback.$volume
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in
                self?.volumeSlider?.setValue(NSNumber(value: Double(cbrt(v))), forKey: "doubleValue")
            }
            .store(in: &cancellables)
    }

    private func refresh(track: Track?, isPlaying: Bool) {
        let newText: String
        if let track {
            let singer = track.singer.isEmpty ? "未知" : track.singer
            newText = "\(track.name) - \(singer)"
            hasTrack = true
        } else {
            newText = "随便听"
            hasTrack = false
        }
        // 只在文字真的变了(切歌 / 停掉)的时候重置滚动位置 —— 单纯按 play/pause
        // 不重置,这样从暂停恢复播放时能从原位置接着滚,不会突然跳回开头。
        if newText != fullText {
            fullText = newText
            scrollIdx = 0
        }
        self.isPlaying = isPlaying
        updateDisplay()
    }

    // MARK: - Title scrolling

    private func startScrollTimer() {
        scrollTimer?.invalidate()
        let timer = Timer(timeInterval: scrollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceScroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private func advanceScroll() {
        // 暂停 / 没歌时:freeze。timer 还在转但 advance 是 no-op,开销可以忽略。
        // 跟用户对 menu bar 标题的直觉一致 —— 没在播放就不动,看着才稳。
        guard isPlaying else { return }
        let total = fullText.unicodeScalars.count
        guard total > displayWidth else {
            if scrollIdx != 0 {
                scrollIdx = 0
                updateDisplay()
            }
            return
        }
        // 走 (内容 + "   " 间隔) 的循环,看起来不会突然跳。
        scrollIdx = (scrollIdx + 1) % (total + 3)
        updateDisplay()
    }

    private func updateDisplay() {
        let title: String = {
            let scalars = Array(fullText.unicodeScalars)
            if scalars.count <= displayWidth { return fullText }
            let pad: [Unicode.Scalar] = Array("   ".unicodeScalars)
            let doubled = scalars + pad + scalars
            let start = scrollIdx
            let end = min(start + displayWidth, doubled.count)
            return String(String.UnicodeScalarView(doubled[start..<end]))
        }()
        statusItemButton?.setValue(title, forKey: "title")

        // 菜单项文案 / 灰态联动 ——
        // 有歌:播放 ⇄ 暂停 跟实际状态对齐;前三项可点
        // 无歌:菜单第一项固定显示"播放"且置灰,前三项全灰
        playPauseItem?.setValue(isPlaying ? "暂停" : "播放", forKey: "title")
        playPauseItem?.setValue(NSNumber(value: hasTrack), forKey: "enabled")
        prevItem?.setValue(NSNumber(value: hasTrack), forKey: "enabled")
        nextItem?.setValue(NSNumber(value: hasTrack), forKey: "enabled")
        // Dock 菜单跟状态栏菜单同步文案 / 灰态
        dockPlayPauseItem?.setValue(isPlaying ? "暂停" : "播放", forKey: "title")
        dockPlayPauseItem?.setValue(NSNumber(value: hasTrack), forKey: "enabled")
        dockPrevItem?.setValue(NSNumber(value: hasTrack), forKey: "enabled")
        dockNextItem?.setValue(NSNumber(value: hasTrack), forKey: "enabled")
    }

    // MARK: - Window control

    /// 把主窗口叫回来 + 把 app 提到前台。状态栏菜单"搜索""打开播放器"以及
    /// Dock 点击 reopen 都用这个。
    func showMainWindow() {
        guard let app = nsApp(),
              let windows = app.value(forKey: "windows") as? [NSObject] else { return }
        if let win = windows.first {
            _ = win.perform(NSSelectorFromString("makeKeyAndOrderFront:"), with: nil)
        }
        invokeBoolSetter(on: app, selector: "activateIgnoringOtherApps:",
                         value: true, klass: type(of: app))
    }

    // MARK: - Menu actions (called from AppKit via setAction)

    @objc private func _playPauseTapped() {
        playback?.togglePlayPause()
    }

    @objc private func _volumeChanged(_ sender: NSObject) {
        if let v = sender.value(forKey: "doubleValue") as? Double {
            // 滑块值立方后写入音量,跟 IPadBottomBar 的音量曲线保持一致
            playback?.volume = Float(pow(v, 3))
        }
    }

    @objc private func _prevTapped() {
        playback?.previous()
    }

    @objc private func _nextTapped() {
        playback?.next()
    }

    @objc private func _searchTapped() {
        showMainWindow()
        NotificationCenter.default.post(name: .shuhaoMacOpenSearch, object: nil)
    }

    @objc private func _openPlayerTapped() {
        showMainWindow()
        NotificationCenter.default.post(name: .shuhaoMacOpenPlayer, object: nil)
    }

    @objc private func _quitTapped() {
        guard let app = nsApp() else { return }
        _ = app.perform(NSSelectorFromString("terminate:"), with: nil)
    }
}

#else

// iOS / iPad-native: provide a no-op so the rest of the code can call install()
// unconditionally without #if at every site.
@MainActor
final class MacStatusBarController: NSObject {
    static let shared = MacStatusBarController()
    private override init() { super.init() }
    func install(playback: PlaybackEngine) {}
    func showMainWindow() {}
}

#endif
