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
/// label used in the tab bar. iPad/Mac do NOT use this — they have their own
/// navigation models under `shuhao/iPad/` and `shuhao/Mac/`.
enum ShuhaoSection: String, Hashable, CaseIterable, Identifiable {
    case search, leaderboard, songlist, library
    var id: String { rawValue }

    var title: String {
        switch self {
        case .search:      return "搜索"
        case .leaderboard: return "排行榜"
        case .songlist:    return "歌单"
        case .library:     return "我的"
        }
    }
    var systemImage: String {
        switch self {
        case .search:      return "magnifyingglass"
        case .leaderboard: return "chart.bar.fill"
        case .songlist:    return "rectangle.stack.fill"
        case .library:     return "music.note.list"
        }
    }
    /// Legacy integer tag — keeps `@AppStorage("ui.activeTab")` portable.
    var tag: Int {
        switch self {
        case .search: 0; case .leaderboard: 1; case .songlist: 2; case .library: 3
        }
    }
    static func from(tag: Int) -> ShuhaoSection {
        ShuhaoSection.allCases.first(where: { $0.tag == tag }) ?? .search
    }
}

/// Root view. Dispatches between three completely independent layouts:
///
/// - **iPhone (compact size class)** → `phoneTabs` (existing TabView UI)
/// - **iPad (regular size class, not Catalyst)** → `IPadRootView` (under `shuhao/iPad/`)
/// - **Mac Catalyst** → `MacRootView` (under `shuhao/Mac/`)
///
/// Per user request these three layouts are NOT trying to share view bodies via
/// sizeClass branches inside SearchView/LibraryView/etc. Each platform owns its
/// own visual language. Shared layer = models, stores, playback, design tokens,
/// resolvers — anything that isn't a screen.
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
    @State private var showPlayer = false
    @State private var leaderboardPath = NavigationPath()
    @State private var songlistPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @AppStorage("ui.activeTab") private var activeTab: Int = 0

    /// True when the binary is running under Mac Catalyst. Detected at runtime
    /// rather than `#if targetEnvironment(macCatalyst)` so a single build can
    /// branch correctly at the view layer.
    private var isCatalyst: Bool {
        ProcessInfo.processInfo.isMacCatalystApp
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isCatalyst {
                MacRootView(onOpenPlayer: openPlayer)
            } else if hSize == .compact {
                phoneTabs
            } else {
                IPadRootView(onOpenPlayer: openPlayer)
            }
            overlays
        }
    }

    /// Show the full PlayerView with the standard spring animation. Passed to
    /// IPadRootView's bottom bar so tapping the cover/title in the QQ-style
    /// bar opens the same modal player the iPhone MiniPlayer opens.
    private func openPlayer() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            showPlayer = true
        }
    }

    // MARK: - iPhone (compact)

    private var phoneTabs: some View {
        TabView(selection: $activeTab) {
            Tab(ShuhaoSection.search.title,
                systemImage: ShuhaoSection.search.systemImage,
                value: ShuhaoSection.search.tag) {
                NavigationStack(path: $searchPath) { SearchView() }
            }
            Tab(ShuhaoSection.leaderboard.title,
                systemImage: ShuhaoSection.leaderboard.systemImage,
                value: ShuhaoSection.leaderboard.tag) {
                NavigationStack(path: $leaderboardPath) { LeaderboardView() }
            }
            Tab(ShuhaoSection.songlist.title,
                systemImage: ShuhaoSection.songlist.systemImage,
                value: ShuhaoSection.songlist.tag) {
                NavigationStack(path: $songlistPath) { SonglistView() }
            }
            Tab(ShuhaoSection.library.title,
                systemImage: ShuhaoSection.library.systemImage,
                value: ShuhaoSection.library.tag) {
                NavigationStack(path: $libraryPath) { LibraryView() }
            }
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
        // 现在用第 4 种:safeAreaInset 挂在 **TabView** 这一层,画出这条悬浮的迷你播放器;
        // 它就是普通 SwiftUI 视图,触摸走正常路径,没有配件位那个黑盒 —— 点击问题因此解决。
        //
        // 但它只负责"画",不负责"让位":实测这层 safeAreaInset 不会算进 tab 内容的
        // 安全区,NavigationStack 里 push 出来的二级页尤其收不到,列表最后一行照样被压住。
        // 让位由下面的 .contentMargins 单独负责 —— 那个是走环境传递的,能进到 push 页里。
        // 两件事拆开做,别指望一个修饰符全包。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 条件读低频镜像 —— 读 playback 会让整个 phoneTabs 每秒重建 4 次
            if now.track != nil {
                MiniPlayer(onTap: openPlayer)
                    .padding(.horizontal, MiniPlayerMetrics.horizontalInset)
                    // 垫高由运行时量出来的 tabbar 位置决定,不写死(见 TabBarMetrics)
                    .padding(.bottom, tabBar.bottomGap)
            }
        }
        // tabbar 未必在首次布局时就在视图树里,出现和切页时各量一次;
        // 量出来的值没变就不会发通知,不会造成额外重建。
        .onAppear { tabBar.refresh() }
        .onChange(of: activeTab) { _, _ in tabBar.refresh() }
        .onChange(of: now.track == nil) { _, _ in tabBar.refresh() }
        // 让位。.contentMargins 通过环境传递给子树里所有滚动视图,包括
        // NavigationStack push 出来的二级页 —— 这正是 safeAreaInset 到不了的地方。
        // 没歌在放时不留白,免得列表底部凭空多一块空隙。
        .bottomContentMargin(now.track != nil ? MiniPlayerMetrics.scrollBottomMargin : 0)
    }

    // MARK: - Overlays (mini player, error banner, full player)

    @ViewBuilder
    private var overlays: some View {
        // iPhone 的 MiniPlayer 现在挂在 TabView 的原生配件位上(见 phoneTabs),
        // 不再是这里的浮层。iPad/Mac 有自己的 IPadBottomBar,同样不走这里。
        //
        // 横幅拆成独立子视图:它必须观察 playback(错误/提示都在引擎上),
        // 而 playback 每 0.25 秒发一次进度。放在这里会把整个根视图拖着一起
        // 每秒重建 4 次,配件位里的触摸就被打断了 —— 只让子视图承担这份重建。
        PlaybackBanners(hasTrack: now.track != nil)

        // PlayerView overlay only fires for iPhone (compact). iPad/Mac own
        // their player as a content-area swap inside IPadRootView so the
        // persistent IPadBottomBar stays visible like QQ 音乐 桌面端.
        if showPlayer, hSize == .compact, !isCatalyst {
            PlayerView(onClose: {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    showPlayer = false
                }
            })
            .transition(.move(edge: .bottom))
            .zIndex(10)
        }
    }
}
