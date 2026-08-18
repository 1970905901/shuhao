# 发现页(Home / Discover)实现方案 — Android TV

本方案基于 Mac (Catalyst) / iPad 版"发现"页(`IPadHomeView`)的已上线实现整理。Android TV 需要按 leanback / D-pad 焦点导航的范式做适配,但页面骨架、数据流、混排算法、状态机要一比一对齐。

---

## 1. 页面结构

垂直滚动 feed,三个 section 从上到下:

1. **Hero Banner 轮播** — 每个 enabled 音源贡献 1 张大 banner(取该源热门歌单第 1 张),5–6 秒自动切换,可手动滑动,底部小圆点指示器
2. **推荐歌单横向列表** — 8–12 张歌单卡片,跨源混排
3. **排行榜横向列表** — 12 张榜单卡,按平台配额均摊

所有 section header 的 subtitle 显示当前生效的源列表(如"酷我 · 网易云"),用户在设置里改了源后立即跟着变。

容器宽度上限 1280px(超宽屏不要让卡片横拉到屏边)。section 之间垂直间距 28px,左右内边距 32px,底部留 96px(避免被底栏小播放器挡住)。

---

## 2. 数据来源 — 音源(SourceID)

固定 4 个音源,顺序:`kw → wy → kg → tx`(酷我 → 网易云 → 酷狗 → QQ)。

- 用户在设置里勾选 `homeSources: Set<SourceID>`,默认全开。
- 持久化 key:`pref.homeSources`,值为 rawValue 排序后逗号拼接(如 `"kg,kw,tx,wy"`)。
- **activeSources** = 固定顺序 4 源 filter 留下勾选的。
- 每个源有显示名(`酷我/网易云/酷狗/QQ音乐`)和品牌 tint 色(用于 banner 渐变和 placeholder)。

后端 API:每个音源实现两个接口

```
SonglistService(source):
  fetchRecommended(order, tag=ALL, page=1) → [SonglistInfo]
  // 每页 ~30 张,首页只取前面够用即可

BoardService(source):
  fetchBoards() → [BoardInfo]
  // 各源端会去对方平台 API 拉真实榜单封面 picURL
```

数据模型:

```
SonglistInfo { id, name, picURL, playCount?, author?, source }
BoardInfo    { id, name, picURL, source }
```

---

## 3. 加载流程

每次进入页面、或 `homeSources` 集合发生变化时触发 `load()`。变化检测用 sorted+joined 字符串做 key,等价的集合不重复 fetch。

```
load():
  isLoading = true
  srcs = activeSources

  // ---- 并行拉所有源的歌单(每个源一个协程) ----
  groups: Map<SourceID, [SonglistInfo]> = parallel {
    for s in srcs: (s, fetchTop(s))
  }
  // fetchTop = svc.fetchRecommended(svc.orders[0], ALL, 1),异常返回空数组

  // ---- Hero 池:每个 enabled 源贡献 1 张 ----
  heroes = srcs.mapNotNull { s ->
    groups[s]?.first?.let { HeroItem(info=it,
        accentStart = s.tint,
        accentEnd   = s.tint.opacity(0.55).overlay(black, 0.15)) }
  }
  heroIndex = 0

  // ---- 推荐歌单:跳过每个源的第 1 张(已在 hero),其余 interleave ----
  // 目的是不让一个源在 carousel 里连续好几张
  tails = srcs.associateWith { groups[it].orEmpty().drop(1).take(8) }
  recommendations = []
  for i in 0 until tails.values.maxOf { it.size }:
    for s in srcs:
      tails[s].getOrNull(i)?.let { recommendations += it }
  // 实际展示截前 12 张

  // ---- 排行榜:总数固定 12,按 enabled 源数均摊 ----
  boardSources = AllBoardServices.filter { it.source in homeSources }
  // 并行拉
  bySource: Map<Int, [BoardInfo]> = parallel { ... }
  totalTarget = 12
  n = boardSources.size
  perSource = max(1, totalTarget / n)
  // 第 1 轮:每个源拿 perSource 张
  picked = bySource.mapValues { it.take(perSource) }
  // 第 2 轮:补差到 12,循环往还有剩的源里轮流加 1 张
  remaining = totalTarget - picked.values.sumOf { it.size }
  cursor = 0
  while remaining > 0:
    i = cursor % n; cursor++
    if picked[i].size < bySource[i].size:
      picked[i] += bySource[i][picked[i].size]
      remaining--
    else if cursor > 2*n: break   // 所有源用尽就退出,避免死循环
  boards = picked 按 i 顺序 flatten

  startHeroTimer()
  isLoading = false
```

配额示例:1 源 → 12 张全归它;2 源 → 各 6;3 源 → 各 4;4 源 → 各 3。某源榜单少于配额,差额按轮询补给其他还有的源。

---

## 4. UI 组件规格

### 4.1 SectionHeader

```
[标题(22sp bold rounded)]  [subtitle(13sp tertiary)]            [trailing 按钮]
```

- subtitle = activeSources 显示名按 `" · "` 拼接(如"酷我 · 网易云")。空源时不显示。
- trailing 按钮:"查看全部" / `>`,点击进入对应的全量列表页(歌单广场 / 排行榜首页)。

### 4.2 HeroBanner

尺寸:容器宽度 × 280px,圆角 24px。

层级(下到上):

1. **底层渐变**:从 `accentStart` 到 `accentEnd` 的 topLeading→bottomTrailing 线性渐变(源 tint 色 → 同色加深 + 偏黑 15%,营造"日落"感)
2. **模糊封面**:歌单封面 32% 不透明 + 28px blur,平铺整个 banner
3. **左侧内容区**(padding 32/28):
   - 标题:34sp heavy rounded white,最多 2 行
   - 副标题:`<源名> · <播放量或"热门播放">`,15sp medium white 85%,最多 3 行
   - CTA 按钮:`[▶ 立即播放]`,白色胶囊背景,文字颜色 = accentStart
4. **右侧封面**:220×220,18px 圆角,带 24px 阴影(0.32 黑)

点击整张 banner → 进入该歌单详情页。

### 4.3 AlbumCard(carousel 卡片)

尺寸 180×180 封面,下方 2 行文字。布局:

```
┌─────────────┐
│             │
│   cover     │  圆角 12,阴影 8px(0.12 黑)
│             │
└─────────────┘
标题(14sp semibold,最多 2 行)
副标题(12sp tertiary,1 行)
```

- 封面加载失败/无 URL → fallback:源 tint 渐变 + 中央 SF Symbol(歌单用 `music.note`,榜单用 `chart.bar.fill`)
- iPad/Mac 上 hover 会放大 1.02 + 加深阴影 + 半透明黑遮罩 + 中央 `▶` 图标。**Android TV 改成 focus 态**:1.08–1.10 缩放、加亮描边(2dp 白色或品牌色)、播放图标遮罩、轻微 elevation 提升。

### 4.4 LoadingPlaceholder

整页 isLoading=true 时只渲染这一个,顶部留白 120px,内容是一组骨架矩形或源 tint 渐变方块。3 个 carousel 各画一行占位即可。

---

## 5. Hero 轮播交互

```
state heroIndex: Int = 0
state heroTimer: Timer? = null

onShow:
  if heroes.size > 1:
    heroTimer = scheduleRepeating(6s) {
      animate(0.5s) { heroIndex = (heroIndex + 1) % heroes.size }
    }

onHide / onPause:
  heroTimer?.cancel(); heroTimer = null

onHeroIndexChange (用户手动滑/D-pad 切):
  restart timer  // 别让 timer 立刻把用户刚选的页切走
```

**底部指示器**:每张一个 capsule,当前页是"长 capsule"(22×5 像素,品牌渐变填充),其他是"小圆点"(6×5,灰 0.18),宽度变化用 spring 0.3s 动画。指示器可点击/可聚焦切页。

---

## 6. 导航

3 个目标:

```
点击 hero banner / 推荐歌单卡片 → 进入 SonglistDetail(songlistInfo)
点击排行榜卡片                  → 进入 LeaderboardDetail(boardInfo)
"查看全部" 推荐歌单 → 歌单广场
"查看全部" 排行榜  → 排行榜首页
```

详情页栈用导航栈(iOS 是 `NavigationPath`,Android 用 Navigation Compose / Fragment 栈均可)。

---

## 7. Android TV 专属适配(必做)

### 7.1 D-pad 焦点导航

- 默认焦点落在 hero banner 上。
- 上下方向键在三个 section 之间跳:hero → 推荐歌单第 1 张 → 排行榜第 1 张。
- 左右方向键在 carousel 内部移动焦点;到尽头不循环,让边缘有"撞墙感"。
- 推荐 `BrowseSupportFragment` 或 Compose `TvLazyRow` + `Modifier.focusable()`。

### 7.2 焦点视觉

替代 hover:

- 选中卡片:1.08–1.10 缩放,描边 2dp 白色(或源 tint),阴影 elevation 提升 4 → 12
- 选中 banner CTA 按钮:整张 banner 微微亮起,CTA 按钮反色突出
- 转场动画 ≤ 150ms

### 7.3 Overscan 安全区

外层 padding 改成 48–56dp(TV 安全区),不能用 32dp。

### 7.4 字体放大

10-foot UI 把所有字号 ×1.2–1.3:

- 标题 22sp → 28sp
- banner 主标题 34sp → 44sp
- 卡片标题 14sp → 18sp
- 副标题/三级文字 +2sp

### 7.5 卡片尺寸

封面 180dp → 220–240dp,banner 高度 280dp → 360dp,内边距相应加大。

### 7.6 自动轮播

后台进入(Activity onPause / 焦点离开 banner 行)就停 timer,回来再起,和移动端一致。

---

## 8. 状态持久化与刷新触发

- `homeSources` 持久化到 SharedPreferences。
- 进入页面、`homeSources` 变化、下拉/手动刷新 → 重新 `load()`。
- 网络失败的源不要让整页报错 —— 单源 fetchTop 异常返回空数组,其余源照常显示。
- 全部源都为空时显示"无可用音源"占位 + 跳到设置的链接。

---

## 9. 关键校验点(实现完拿这些自查)

1. 只勾 1 个源时:hero 只有 1 张(不轮播),推荐和排行榜全是这一个源,subtitle 只显示 1 个源名。
2. 全选 4 源时:hero 有 4 张轮播;推荐前 4 张正好覆盖 4 个源;排行榜 12 张 = 各源 3 张。
3. 中途用户去设置里去掉酷我:页面立即重新加载,所有酷我内容消失,subtitle 同步变化。
4. 某源 API 失败:页面其他源数据正常显示,无 toast/弹窗轰炸。
5. hero 自动切到第 3 张时用户手动切回第 1 张:timer 重置,6 秒后才会切到第 2 张,不是立刻切到第 4 张。
6. 离开页面后台播放音乐:hero timer 停了,内存里没有泄漏的循环引用。
