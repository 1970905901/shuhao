import SwiftUI
import Combine

/// 发现页 (IPadHomeView) 的数据源。
///
/// 之前数据全存在 IPadHomeView 的 @State 里 —— 侧边栏切走再切回时 SwiftUI 重建
/// 视图,@State 重置,`.task` 再跑一遍 load(),用户看到白屏 + 几秒等待。把数据
/// 提到 shuhaoApp 顶层注入的 ObservableObject 里,跨视图生命周期保活:
///   - 命中缓存(30 分钟内同样的源集合)直接秒返,无网络请求
///   - 缓存过期或源变了 → 后台刷新,**老数据继续挂屏**直到新数据 ready
///   - 第一次启动才显示 LoadingPlaceholder
@MainActor
final class HomeFeedStore: ObservableObject {

    /// 顶部 banner 项 —— 之前是 IPadHomeView 私有的 HeroItem,移到 store 里
    /// 让数据在 view 重建时也能保住。
    struct HeroItem: Identifiable {
        let id = UUID()
        let info: SonglistInfo
        let accentStart: Color
        let accentEnd: Color
    }

    @Published private(set) var heroes: [HeroItem] = []
    @Published private(set) var recommendations: [SonglistInfo] = []
    @Published private(set) var boards: [BoardInfo] = []
    /// 只在"完全没有任何缓存"时为 true。后续刷新(已经有老数据)不切换它,
    /// LoadingPlaceholder 也就不会把发现页清空。
    @Published private(set) var isLoading: Bool = false

    private var lastLoadedAt: Date?
    private var lastLoadedSources: Set<SourceID> = []
    private var currentTask: Task<Void, Never>?

    /// 30 分钟内同样的源组合直接走缓存。发现页内容变化频率不高,这个 TTL 够用了。
    private static let ttl: TimeInterval = 30 * 60

    /// 视图出现时调用。命中缓存返回 false(view 该干嘛干嘛),否则启动后台刷新返回 true。
    @discardableResult
    func loadIfNeeded(sources: [SourceID]) -> Bool {
        let set = Set(sources)
        let fresh = lastLoadedAt.map { Date().timeIntervalSince($0) < Self.ttl } ?? false
        if fresh && set == lastLoadedSources && !heroes.isEmpty {
            return false
        }
        refresh(sources: sources)
        return true
    }

    /// 强制刷新(下拉、设置变化等场景)。旧数据保留,新数据 ready 后整体替换。
    func refresh(sources: [SourceID]) {
        currentTask?.cancel()
        let isFirstLoad = heroes.isEmpty && recommendations.isEmpty && boards.isEmpty
        if isFirstLoad { isLoading = true }
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(sources: sources, isFirstLoad: isFirstLoad)
        }
    }

    // MARK: - Internal

    private func performLoad(sources srcs: [SourceID], isFirstLoad: Bool) async {
        // 1) 并行拉每个源的热门歌单
        let groups = await withTaskGroup(of: (SourceID, [SonglistInfo]).self) { group -> [SourceID: [SonglistInfo]] in
            for s in srcs {
                group.addTask { (s, await Self.fetchTop(s)) }
            }
            var dict: [SourceID: [SonglistInfo]] = [:]
            for await (s, list) in group { dict[s] = list }
            return dict
        }
        if Task.isCancelled { return }

        // 2) Hero pool —— 每个源贡献第一张,源色做渐变
        var heroPool: [HeroItem] = []
        for s in srcs {
            if let first = groups[s]?.first {
                heroPool.append(HeroItem(
                    info: first,
                    accentStart: s.tint,
                    accentEnd: s.tint.opacity(0.55).overlay(.black, amount: 0.15)
                ))
            }
        }

        // 3) Recommendations —— 跳过每个源的第一张(已经在 hero 里),interleave 剩下的
        var merged: [SonglistInfo] = []
        let tails: [SourceID: ArraySlice<SonglistInfo>] = Dictionary(uniqueKeysWithValues:
            srcs.map { s in (s, (groups[s] ?? []).dropFirst().prefix(8)) }
        )
        let maxPer = tails.values.map(\.count).max() ?? 0
        for i in 0..<maxPer {
            for s in srcs {
                let arr = tails[s] ?? []
                let idx = arr.startIndex + i
                if idx < arr.endIndex {
                    merged.append(arr[idx])
                }
            }
        }

        // 4) 排行榜:总数固定 12,按 enabled 源数均摊
        let boardSources = Boards.all.filter { srcs.contains($0.source) }
        var fetchedBoards: [BoardInfo] = []
        await withTaskGroup(of: (Int, [BoardInfo]).self) { group in
            for (idx, svc) in boardSources.enumerated() {
                group.addTask { (idx, await svc.fetchBoards()) }
            }
            var bySource: [Int: [BoardInfo]] = [:]
            for await (idx, list) in group { bySource[idx] = list }

            let totalTarget = 12
            let n = boardSources.count
            guard n > 0 else { return }
            let perSource = max(1, totalTarget / n)

            // 第一轮:每个源按 perSource 拿
            var picked: [Int: ArraySlice<BoardInfo>] = [:]
            var totalPicked = 0
            for i in 0..<n {
                let available = bySource[i] ?? []
                let take = available.prefix(perSource)
                picked[i] = take
                totalPicked += take.count
            }
            // 第二轮:补到 totalTarget —— 从还有剩的源里轮流加
            if totalPicked < totalTarget {
                var remaining = totalTarget - totalPicked
                var cursor = 0
                while remaining > 0 {
                    let i = cursor % n
                    cursor += 1
                    let available = bySource[i] ?? []
                    let already = picked[i]?.count ?? 0
                    if already < available.count {
                        picked[i] = available.prefix(already + 1)
                        remaining -= 1
                    } else if cursor > n * 2 {
                        break
                    }
                }
            }
            for i in 0..<n {
                fetchedBoards.append(contentsOf: picked[i] ?? [])
            }
        }

        if Task.isCancelled { return }

        // 原子地应用,UI 一帧切换新数据 —— 而不是 hero 先到 board 后到的撕裂感
        self.heroes = heroPool
        self.recommendations = merged
        self.boards = fetchedBoards
        self.lastLoadedAt = Date()
        self.lastLoadedSources = Set(srcs)
        if isFirstLoad { self.isLoading = false }
    }

    private static func fetchTop(_ source: SourceID) async -> [SonglistInfo] {
        guard let svc = Songlists.service(for: source),
              let order = svc.orders.first else { return [] }
        return (try? await svc.fetchRecommended(order: order, tag: .all, page: 1)) ?? []
    }
}

// MARK: - Color helper (moved out of IPadHomeView)
//
// HeroItem 计算 accentEnd 时用 —— 之前是 IPadHomeView 私有 extension,挪到这里
// 让 store 能引用。internal 范围,不会污染全局名字。

extension Color {
    /// 简化版颜色混合 —— 让 banner 渐变从源色到稍暗的版本,模拟"日落"感。
    func overlay(_ other: Color, amount: Double) -> Color {
        let f = min(max(amount, 0), 1)
        let a = UIColor(self)
        let b = UIColor(other)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(
            red:   Double(ar + (br - ar) * CGFloat(f)),
            green: Double(ag + (bg - ag) * CGFloat(f)),
            blue:  Double(ab + (bb - ab) * CGFloat(f))
        )
    }
}
