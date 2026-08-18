import SwiftUI

// MARK: - Leaderboard (iPad)
//
// 跟 iPhone 一致:顶部一个源切换 chip bar(酷我/网易云/酷狗/QQ),只显示
// 当前源的榜单为 grid。之前那版"4 源横向并列"虽然信息密度高但跟 iPhone
// 行为不一致 — 用户要的是同样的浏览节奏:选源 → 看榜列表。

struct IPadLeaderboardView: View {
    @Binding var path: NavigationPath
    @AppStorage("ui.boardSource") private var selectedSourceRaw: String = SourceID.kw.rawValue
    @State private var boards: [BoardInfo] = []
    @State private var isLoading = false

    private var selectedSource: SourceID {
        SourceID(rawValue: selectedSourceRaw) ?? .kw
    }
    private var selectedSourceBinding: Binding<SourceID> {
        Binding(get: { selectedSource }, set: { selectedSourceRaw = $0.rawValue })
    }
    private var supportedSources: [SourceID] { Boards.all.map { $0.source } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if isLoading && boards.isEmpty {
                    LoadingPlaceholder(topPadding: 80)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)],
                        spacing: 16
                    ) {
                        ForEach(boards) { b in
                            Button { path.pushDetail(b) } label: {
                                IPadAlbumCard(
                                    imageURL: b.picURL,
                                    title: b.name,
                                    subtitle: b.source.displayName,
                                    fallbackTint: b.source.tint,
                                    fallbackIcon: "chart.bar.fill",
                                    size: 200
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 96)
                    .ipadContentWidth()
                }
            }
        }
        .background(IPad.Color.contentBackground)
        .task(id: selectedSource) {
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("排行榜")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)

            // 源 chips — 复用跟 iPhone 一样的 ChipBar 组件,保持选中态视觉一致
            ChipBar(items: supportedSources,
                    title: { $0.displayName },
                    selection: selectedSourceBinding)
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .ipadContentWidth()
    }

    private func load() async {
        guard let svc = Boards.service(for: selectedSource) else { return }
        boards = svc.list   // 立刻显示静态列表
        isLoading = true
        defer { isLoading = false }
        boards = await svc.fetchBoards()
    }
}
