import SwiftUI

struct ErrorBanner: View {
    let text: String
    var tone: Tone = .warning
    let onDismiss: () -> Void

    enum Tone { case warning, info }
    private var accent: Color { tone == .info ? .blue : .orange }
    private var icon: String { tone == .info ? "info.circle.fill" : "exclamationmark.triangle.fill" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(accent)
                .font(.system(size: 16, weight: .semibold))
            Text(text)
                .font(.system(size: 13))
                .lineLimit(3)
                .foregroundColor(.primary)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// Identifies the four iPhone tabs. `ShuhaoSection.title` is the short Chinese
/// label used in the tab bar. This app targets iPhone only.
enum ShuhaoSection: String, Hashable, CaseIterable, Identifiable {
    case search, leaderboard, songlist, library, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .search:      return "搜索"
        case .leaderboard: return "排行榜"
        case .songlist:    return "歌单"
        case .library:     return "我的"
        case .settings:    return "设置"
        }
    }
    var systemImage: String {
        switch self {
        case .search:      return "magnifyingglass"
        case .leaderboard: return "chart.bar.fill"
        case .songlist:    return "rectangle.stack.fill"
        case .library:     return "music.note.list"
        case .settings:    return "gearshape.fill"
        }
    }
    /// Legacy integer tag — keeps `@AppStorage("ui.activeTab")` portable.
    var tag: Int {
        switch self {
        case .search: 0; case .leaderboard: 1; case .songlist: 2; case .library: 3; case .settings: 4
        }
    }
    static func from(tag: Int) -> ShuhaoSection {
        ShuhaoSection.allCases.first(where: { $0.tag == tag }) ?? .search
    }
}

/// Root view for iPhone. The player (full-screen) and mini player overlay the
/// classic four-tab `phoneTabs` layout. This app targets iPhone only — the
/// iPad/Mac layouts previously lived under `shuhao/iPad/` and `shuhao/Mac/`
/// and have been removed.
/// 播放错误 / 降级提示横幅。单独成一个视图,把"观察 PlaybackEngine"这件事
/// 圈在这里 —— 引擎每 0.25 秒发布一次进度,谁观察它谁就每秒重建 4 次。
private struct PlaybackBanners: View {
    /// 同样只读低频镜像,不观察 engine —— engine 每 0.25 秒发一次进度,
    /// 观察它就等于在根视图树里每秒制造 4 次失效(见 NowPlayingBar)。
    /// 要清空提示时通过 AppServices 取引擎写回,那是取值不是观察。
    @ObservedObject private var now = NowPlayingBar.shared
    @EnvironmentObject var settings: SettingsStore
    let hasTrack: Bool

    private var engine: PlaybackEngine? { AppServices.shared.playback }

    var body: some View {
        if let err = now.lastError {
            ErrorBanner(text: err, tone: .warning) { engine?.lastError = nil }
                .padding(.bottom, hasTrack ? 110 : 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: now.lastError)
        } else if let notice = now.cascadeNotice, settings.showDebugNotices {
            ErrorBanner(text: notice, tone: .info) { engine?.cascadeNotice = nil }
                .padding(.bottom, hasTrack ? 110 : 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: now.cascadeNotice)
        }
    }
}

struct RootTabView: View {
    /// 只观察低频镜像,不观察 PlaybackEngine —— 见 NowPlayingBar 的说明
    @ObservedObject private var now = NowPlayingBar.shared
    /// 迷你播放器该垫多高,来自运行时量到的真实 tabbar 位置
    @ObservedObject private var tabBar = TabBarMetrics.shared
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var hSize
    /// 播放器是否挂载在视图树上。进出场动画由 isOpen 绑定驱动(纯 transform,
    /// 无快照),这里只负责挂/卸,避免 .transition 快照造成的关闭残影。
    @State private var playerMounted = false
    /// 是否展开:true 停在屏内,false 整屏下移离屏。滑入/滑出都靠这个 Bool 做动画。
    @State private var playerOpen = false
    /// 每次打开 +1。关闭动画(滑出约 0.55s)期间若又快速重开,playerToken 会变,
    /// 延后卸载就不会误把刚重开的播放器卸掉。
    @State private var playerToken = 0
    @State private var leaderboardPath = NavigationPath()
    @State private var songlistPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @AppStorage("ui.activeTab") private var activeTab: Int = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            phoneTabs
            overlays
            // 迷你播放器直接挂在 root ZStack 上(而不是内部 TabView 的 overlay)。
            // 原因:之前挂在 TabView 的 `.overlay(alignment: .bottom)` 上,而那个
            // overlay 在 `.frame(maxHeight: .infinity)` 拉伸之前就绑死了,锚点跟着
            // 某个 tab 的固有高度走 —— 搜索页空态内容不高时,悬浮条被甩到屏幕中间。
            // root ZStack 显式撑满全屏且对齐底部,ZStack 的 alignment 比"先 overlay
            // 再 frame 拉伸"可靠得多,锚点确定就是屏幕底。
            // 它只负责"画",让位(列表底部留白)仍由 phoneTabs 的 .bottomContentMargin 负责。
            if now.track != nil {
                MiniPlayer(onTap: openPlayer)
                    .padding(.horizontal, MiniPlayerMetrics.horizontalInset)
                    // 垫高由运行时量出来的 tabbar 位置决定,不写死(见 TabBarMetrics)
                    .padding(.bottom, tabBar.bottomGap)
            }
        }
        // 必须显式撑满全屏,否则 ZStack 的"底部"对齐会跟着内容高度走。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Show the full PlayerView with the standard spring animation. Tapping the
    /// mini player opens the same modal player.
    private func openPlayer() {
        // 仅 iPhone 走这套挂载/展开;iPad/Mac 已移除,这里就是唯一的浮层入口。
        guard hSize == .compact else { return }
        // 挂载(先以 off-screen 状态挂一帧),下一拍再动画展开,避免首帧闪现。
        // 展开由 isOpen 绑定驱动 —— 纯 transform,绝不做快照过渡(否则关闭残影)。
        playerToken += 1
        playerMounted = true
        DispatchQueue.main.async {
            withAnimation(PlayerView.playerSpring) { playerOpen = true }
        }
    }

    /// 用户左缘右滑越过阈值后由 PlayerView 调来。滑出动画交给 isOpen=false 驱动
    /// (向右飞出,见 PlayerView 的 offset),动画跑完再卸载本视图 —— 此时它已在
    /// 屏幕右缘外,卸载无缝。
    private func dismissPlayer() {
        let token = playerToken
        // 关闭用更短阻尼的弹簧,右滑跟手、收得干脆(进场仍用 playerSpring 从右缘滑入)。
        withAnimation(PlayerView.playerCloseSpring) { playerOpen = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            // 这 0.55s 内若又重开,playerToken 会变,就不卸载刚重开的播放器。
            if token == playerToken { playerMounted = false }
        }
    }

    // MARK: - iPhone (compact)

    private var phoneTabs: some View {
        // iOS 16/17/18 统一用经典 TabView(selection:)+tabItem。新的 Tab(...) 标签 API
        // 是 iOS 18 专属,在 iOS 16 部署目标下无法编译;经典写法 iPhone 行为一致。
        TabView(selection: $activeTab) {
            NavigationStack(path: $searchPath) { SearchView() }
                .tabItem { Label(ShuhaoSection.search.title, systemImage: ShuhaoSection.search.systemImage) }
                .tag(ShuhaoSection.search.tag)
            NavigationStack(path: $leaderboardPath) { LeaderboardView() }
                .tabItem { Label(ShuhaoSection.leaderboard.title, systemImage: ShuhaoSection.leaderboard.systemImage) }
                .tag(ShuhaoSection.leaderboard.tag)
            NavigationStack(path: $songlistPath) { SonglistView() }
                .tabItem { Label(ShuhaoSection.songlist.title, systemImage: ShuhaoSection.songlist.systemImage) }
                .tag(ShuhaoSection.songlist.tag)
            NavigationStack(path: $libraryPath) { LibraryView() }
                .tabItem { Label(ShuhaoSection.library.title, systemImage: ShuhaoSection.library.systemImage) }
                .tag(ShuhaoSection.library.tag)
            // 设置从 Library 顶栏搬到独立 tab,跟其它四个 tab 同一行。
            // SettingsView 内部已有 .navigationTitle + NavigationLink 到 ScriptManager,
            // 这里再包一层 NavigationStack 让它作为根 tab 也能正常 push。
            NavigationStack { SettingsView() }
                .tabItem { Label(ShuhaoSection.settings.title, systemImage: ShuhaoSection.settings.systemImage) }
                .tag(ShuhaoSection.settings.tag)
        }
        // ⚠️ 迷你播放器的挂载方式,改之前务必读完这段 —— 这里来回折腾过很多次。
        //
        // 三种做法的实际结果:
        //   1. ZStack 里浮一层 overlay          → 点击正常,但 overlay 不参与布局,
        //                                        列表最后一行被压住
        //   2. NavigationStack 上补 safeAreaInset → 不生效。栈内的滚动视图已经铺满了,
        //                                        拿不到这层安全区
        //   3. .tabViewBottomAccessory(iOS 26)  → 遮挡解决了,但配件位宿主里的触摸
        //                                        时灵时不灵,播放中尤其明显。为此试过
        //                                        Button / DragGesture / 自定义 UIKit
        //                                        识别器 / 把 4Hz 刷新彻底移出 SwiftUI,
        //                                        全都没能修好
        //
        // 现在用第 4 种的进化版:迷你播放器是 RootTabView 的 root ZStack 的一个
        // bottom 对齐子视图(见 body),由 TabBarMetrics 量出来的 tabbar 顶边到屏幕底
        // 距离(`bottomGap`)垫高到 tabbar 上方。之所以不挂在 TabView 的
        // `.overlay(alignment: .bottom)` 上:那个 overlay 在 `.frame(maxHeight: .infinity)`
        // 拉伸之前就绑死了锚点,搜索页空态内容不高时会被甩到屏幕中间。
        // `.safeAreaInset` 同样不行 —— 在带 NavigationStack 的 tab 上行为不一致,
        // 排行榜/歌单页会把悬浮条甩到屏幕中间。root ZStack 的 alignment 才可靠。
        //
        // 它只负责"画",不负责"让位":列表让位由下面的 .bottomContentMargin 单独负责 ——
        // 那个是走环境传递的,能进到 NavigationStack push 出来的二级页里。
        // 两件事拆开做,别指望一个修饰符全包。
        // (迷你播放器本身已移到 RootTabView 的 root ZStack 上,见 body。)
        // tabbar 未必在首次布局时就在视图树里,出现和切页时各量一次;
        // 量出来的值没变就不会发通知,不会造成额外重建。
        .onAppear { tabBar.refresh() }
        .shOnChange(of: activeTab) { tabBar.refresh() }
        .shOnChange(of: now.track == nil) { tabBar.refresh() }
        // 让位。.contentMargins 通过环境传递给子树里所有滚动视图,包括
        // NavigationStack push 出来的二级页 —— 这正是 safeAreaInset 到不了的地方。
        // 没歌在放时不留白,免得列表底部凭空多一块空隙。
        .bottomContentMargin(now.track != nil ? MiniPlayerMetrics.scrollBottomMargin : 0)
        // 显式撑满,防止 TabView 在某些内容较短的 tab(如搜索空态)上收缩。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Overlays (mini player, error banner, full player)

    @ViewBuilder
    private var overlays: some View {
        // 迷你播放器现在挂在 RootTabView 的 root ZStack 上(见 body),不再是这里的浮层。
        // iPad/Mac 有自己的 IPadBottomBar,同样不走这里。
        //
        // 横幅拆成独立子视图:它必须观察 playback(错误/提示都在引擎上),
        // 而 playback 每 0.25 秒发一次进度。放在这里会把整个根视图拖着一起
        // 每秒重建 4 次,配件位里的触摸就被打断了 —— 只让子视图承担这份重建。
        PlaybackBanners(hasTrack: now.track != nil)

        // PlayerView 浮层仅 iPhone 挂载;iPad/Mac 已移除。
        if playerMounted, hSize == .compact {
            // isOpen 绑定驱动滑入/滑出(纯 transform);onClose 由 PlayerView 在
            // 拖动越阈值时调来,经 dismissPlayer 做滑出 + 延后卸载。
            PlayerView(onClose: dismissPlayer, isOpen: $playerOpen)
                .zIndex(10)
        }
    }
}
