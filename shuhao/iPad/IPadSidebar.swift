import SwiftUI

// MARK: - Sidebar selection target

/// The currently-selected sidebar row. Drives what `IPadRootView` shows in the
/// detail pane. QQ 音乐式分组:
///   - 推荐(发现) / 排行 / 歌单 / 搜索 / 资料库 (主导航)
///   - 资料库子项:已下载 / 播放历史 / 听歌报告
///   - 用户歌单: 每个歌单一行,直接进入详情
enum IPadDestination: Hashable {
    case home          // 发现 (首页 hero + carousel)
    case search
    case leaderboard
    case songlist
    case library
    case downloads
    case history
    case stats
    case playlist(UUID)
}

extension NavigationPath {
    /// 从列表/根页点卡片进详情时统一用这个,不要直接 append。
    ///
    /// Mac Catalyst 的 NavigationStack 在 back 手势刚触发、动画还没收尾时,如果用户
    /// 立刻在(视觉上回到的)列表上点另一张卡片,append 会和 pop 竞态:path binding
    /// 同步落后导致旧条目没被弹出,append 把新条目压到 [oldDetail, newDetail],
    /// 表现是"返回到上一个打开过的歌单"。Catalyst 上重置 path 后再 append,保证
    /// 每次进详情都是干净的 depth-1 栈,back 一定回根页。
    ///
    /// iPhone/iPad 触控更慢竞态不易触发,保留原来的层级累积(支持发现页"查看全部"
    /// → 歌单列表 → 详情这种三级返回)。
    mutating func pushDetail<V: Hashable>(_ value: V) {
        #if targetEnvironment(macCatalyst)
        self = NavigationPath()
        #endif
        append(value)
    }
}

// MARK: - Sidebar

/// QQ 音乐风的 sidebar:窄宽度(240pt)、分组分隔、selected 行带左侧色条 + 浅底色。
/// 跟 iPhone tab bar 完全不共享 — iPhone 端是 4 个 tab,iPad 端把所有入口都列在
/// sidebar 里(包括用户的所有歌单)。
struct IPadSidebar: View {
    @Binding var selection: IPadDestination
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var history: PlayHistoryStore
    let onOpenSettings: () -> Void

    /// Mac Catalyst 时,window 左上角有红/黄/绿三个系统按钮(traffic lights)。
    /// 它们绘制在 content 区域里(没有独立的 title bar),会跟 sidebar logo
    /// 撞在一起。给 sidebar 顶部加 24pt padding 把 brandHeader 往下压。
    /// iPad/iPhone 不需要,top padding 维持 18pt。
    private var sidebarTopInset: CGFloat {
        ProcessInfo.processInfo.isMacCatalystApp ? 36 : 18
    }

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
                .padding(.top, sidebarTopInset)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    group("在线音乐") {
                        row(.home,        "发现",   "house.fill")
                        row(.search,      "搜索",   "magnifyingglass")
                        row(.leaderboard, "排行榜", "chart.bar.fill")
                        row(.songlist,    "歌单",   "rectangle.stack.fill")
                    }

                    group("我的音乐") {
                        row(.library,   "资料库",       "music.note.list")
                        row(.downloads, "本地与下载",   "arrow.down.circle.fill",
                            badge: downloads.completedCount)
                        row(.history,   "最近播放",     "clock.arrow.circlepath",
                            badge: history.tracks.count)
                        row(.stats,     "听歌报告",     "chart.bar.xaxis")
                    }

                    if !playlists.playlists.isEmpty {
                        group("我的歌单") {
                            ForEach(playlists.playlists) { p in
                                row(.playlist(p.id), p.name, "music.note",
                                    badge: nil, useBrandIcon: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }

            settingsFooter
        }
        .frame(width: IPad.Layout.sidebarWidth, alignment: .leading)
        .background(IPad.Color.sidebarBackground)
        .overlay(
            // 右侧分隔线 — 比浮 sidebar 更稳重的视觉边界,QQ 音乐/网易云都用了细线
            Rectangle()
                .fill(IPad.Color.separator)
                .frame(width: 0.5),
            alignment: .trailing
        )
    }

    // MARK: Subviews

    /// 从 bundle 拿到实际的 AppIcon 图像 — `UIImage(named: "AppIcon")` 在 iOS 上
    /// 不可靠,要走 Info.plist 的 CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles。
    /// 跟 SplashView 用的是同一个 helper(extension Bundle.icon)。
    private var appIcon: UIImage? {
        UIImage(named: "AppIcon") ?? Bundle.main.iPadSidebarIcon
    }

    /// 系统语言下的 app 名 — InfoPlist.xcstrings 已经把 CFBundleDisplayName
    /// 翻译成"随便听"(zh)/ "shuhao"(en),infoDictionary 会返回当前语言版本。
    private var appDisplayName: String {
        (Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? "shuhao"
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = appIcon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFill()
                } else {
                    // 极端 fallback — 找不到 AppIcon 资源时画一个品牌渐变色块
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(DS.Palette.brandGradient)
                        Image(systemName: "music.note")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.black.opacity(0.06), lineWidth: 0.5)
            )

            Text(appDisplayName)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Palette.textTertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            content()
        }
    }

    private func row(_ dest: IPadDestination,
                     _ title: String,
                     _ icon: String,
                     badge: Int? = nil,
                     useBrandIcon: Bool = false) -> some View {
        let isSelected = selection == dest
        return Button {
            selection = dest
        } label: {
            HStack(spacing: 10) {
                // Left-edge selection bar — QQ 音乐 sidebar 的标志性细节
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? DS.Palette.brandStart : .clear)
                    .frame(width: 3, height: 18)

                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(
                        useBrandIcon
                            ? AnyShapeStyle(DS.Palette.brandGradient)
                            : AnyShapeStyle(isSelected ? DS.Palette.brandStart : DS.Palette.textSecondary)
                    )

                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 7)
            .padding(.trailing, 12)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? DS.Palette.brandStart.opacity(0.10) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsFooter: some View {
        HStack(spacing: 8) {
            Button(action: onOpenSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("设置")
                        .font(.system(size: 13))
                }
                .foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(
            Rectangle()
                .fill(IPad.Color.separator)
                .frame(height: 0.5),
            alignment: .top
        )
    }
}

// MARK: - Bundle.iPadSidebarIcon
//
// 从 Info.plist `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles` 取最后
// 一个图标文件名,再用 `UIImage(named:)` 加载。SplashView 也有类似 helper,
// 这里属性名加前缀避免冲突。

extension Bundle {
    var iPadSidebarIcon: UIImage? {
        guard let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        return UIImage(named: last)
    }
}
