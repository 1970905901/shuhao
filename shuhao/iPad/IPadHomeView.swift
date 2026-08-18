import SwiftUI

// MARK: - Home (发现页) — QQ 音乐风的 iPad 首页
//
// Vertical scroll feed:
//   1. Hero banner carousel — 每个 enabled 源选一张代表歌单作 banner,
//      自动 5s 切换 + 手动滑动 + 底部点指示器
//   2. 推荐歌单 carousel — 8-10 个最热歌单(混合所有 enabled 源)
//   3. 排行榜 carousel — 各源代表榜单
//
// 所有 section header 的 subtitle 跟着 settings.homeSources 走 — 用户在设置
// 里只勾酷我,subtitle 就只显示 "酷我"。

struct IPadHomeView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var settings: SettingsStore
    /// 数据搬到 shuhaoApp 顶层的 @StateObject 里,跨视图重建保活 —— 详见
    /// HomeFeedStore 的文档注释。返回发现页时不再白屏 + 重新 load。
    @EnvironmentObject var feed: HomeFeedStore
    @Binding var path: NavigationPath
    @State private var heroIndex: Int = 0
    @State private var heroTimer: Timer?

    /// Source order for the home feed. Preserved order matches the iPad sidebar
    /// (kw → wy → kg → tx), filtered to whatever the user enabled in Settings.
    private var activeSources: [SourceID] {
        [.kw, .wy, .kg, .tx].filter { settings.homeSources.contains($0) }
    }

    /// 显示给 section header 用的源列表 — eg "酷我 · 网易云"。无源时不显示。
    private var sourceListLabel: String {
        activeSources.map(\.displayName).joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IPad.Layout.sectionTopSpacing) {
                // 只在"完全没有任何缓存"时显示骨架 —— 后台刷新时老数据继续挂屏。
                if feed.isLoading && feed.heroes.isEmpty {
                    LoadingPlaceholder(topPadding: 120)
                } else {
                    heroBannerCarousel
                    recommendationsCarousel
                    leaderboardCarousel
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 96)   // room for bottom mini player
            .ipadContentWidth()
        }
        .background(IPad.Color.contentBackground)
        // 每次出现都问一下 store 是否需要刷新 —— TTL 内同样的源直接走缓存秒返,
        // 否则后台静默刷新。task id 包含 sorted source set,设置里改了源就触发刷新。
        .task(id: settings.homeSources.map(\.rawValue).sorted().joined(separator: ",")) {
            feed.loadIfNeeded(sources: activeSources)
        }
        .onDisappear { stopHeroTimer() }
    }

    // MARK: - Hero banner carousel
    //
    // 用 SwiftUI TabView(.page) 做轮播 + 一个 Timer 每 6s 推进 heroIndex,
    // 手动滑动会被尊重(TabView 不打架),滑动后 timer 重置周期。

    @ViewBuilder
    private var heroBannerCarousel: some View {
        if !feed.heroes.isEmpty {
            VStack(spacing: 10) {
                TabView(selection: $heroIndex) {
                    ForEach(Array(feed.heroes.enumerated()), id: \.offset) { idx, h in
                        IPadHeroBanner(
                            title: h.info.name,
                            subtitle: "\(h.info.source.displayName) · \(h.info.playCount ?? "热门播放")",
                            imageURL: h.info.picURL,
                            accentStart: h.accentStart,
                            accentEnd: h.accentEnd,
                            action: { path.pushDetail(h.info) }
                        )
                        .padding(.horizontal, 1)
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 280)
                .padding(.top, 8)
                // 手动滑动后重置自动切换的计时,不让 timer 立刻切走用户刚选的页
                .onChange(of: heroIndex) { _, _ in
                    restartHeroTimer()
                }

                // 自定义底部指示器 — 当前页是品牌渐变长 capsule,其它是灰色短点
                HStack(spacing: 6) {
                    ForEach(feed.heroes.indices, id: \.self) { i in
                        let on = i == heroIndex
                        Capsule()
                            .fill(on
                                  ? AnyShapeStyle(DS.Palette.brandGradient)
                                  : AnyShapeStyle(Color.primary.opacity(0.18)))
                            .frame(width: on ? 22 : 6, height: 5)
                            .animation(.spring(duration: 0.3), value: heroIndex)
                            .onTapGesture {
                                heroIndex = i
                            }
                    }
                }
            }
            .onAppear { startHeroTimer() }
        }
    }

    private func startHeroTimer() {
        stopHeroTimer()
        guard feed.heroes.count > 1 else { return }
        heroTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                heroIndex = (heroIndex + 1) % max(feed.heroes.count, 1)
            }
        }
    }

    private func restartHeroTimer() {
        startHeroTimer()   // start 内部会先 stop
    }

    private func stopHeroTimer() {
        heroTimer?.invalidate()
        heroTimer = nil
    }

    // MARK: Carousels

    @ViewBuilder
    private var recommendationsCarousel: some View {
        if !feed.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                IPadSectionHeader("推荐歌单", subtitle: sourceListLabel) {
                    Button("查看全部") { path.pushDetail(IPadDestination.songlist) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(feed.recommendations.prefix(12)) { list in
                            Button {
                                path.pushDetail(list)
                            } label: {
                                IPadAlbumCard(
                                    imageURL: list.picURL,
                                    title: list.name,
                                    subtitle: list.playCount ?? list.author,
                                    fallbackTint: list.source.tint
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var leaderboardCarousel: some View {
        if !feed.boards.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                // subtitle 跟 settings.homeSources 联动 — 用户去掉某个平台就
                // 不会再误以为榜单还展示那个平台
                IPadSectionHeader("排行榜", subtitle: sourceListLabel) {
                    Button("查看全部") { path.pushDetail(IPadDestination.leaderboard) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(feed.boards) { b in
                            Button {
                                path.pushDetail(b)
                            } label: {
                                IPadAlbumCard(
                                    imageURL: b.picURL,
                                    title: b.name,
                                    subtitle: b.source.displayName,
                                    fallbackTint: b.source.tint,
                                    fallbackIcon: "chart.bar.fill"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // 数据加载、HeroItem 数据模型、Color.overlay 混色辅助都搬到 HomeFeedStore.swift。
    // 这里只剩下 view 自己的状态(heroIndex 轮换 + hero 计时器)。
}
