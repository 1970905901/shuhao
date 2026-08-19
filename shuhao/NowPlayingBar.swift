import Foundation
import Combine
import UIKit

// MARK: - 把播放状态拆成"低频"与"高频"两份
//
// PlaybackEngine 的 currentTime 每 0.25 秒发布一次。ObservableObject 是整体失效的:
// 只要观察了它,任何一个 @Published 变化都会让视图重建 —— 于是持有
// @EnvironmentObject playback 的视图每秒重建 4 次。
//
// 迷你播放器挂在系统标签栏配件位里,那个宿主对内容重建格外敏感(实测 .task 不触发、
// 普通 ObservableObject 更新也收不到),每秒重建 4 次会把正在进行的触摸打断,
// 表现为"播放时很难点开全屏播放器",暂停时反而正常。
//
// 所以这里做一次拆分:
//   - NowPlayingBar  只在真正换歌 / 播放状态变化时更新,给迷你播放器主体用
//   - PlaybackTicker 承载 4Hz 的进度
//
// ⚠️ PlaybackTicker 的订阅方**只能是 UIKit 图层**(见 MiniPlayer 的 RingLayerView),
// 不能是任何 SwiftUI 视图。哪怕只让一个最小的叶子视图观察它,配件位宿主同样会
// 每秒重新布局 4 次,把正在进行的触摸打断 —— 这就是"一播放就点不动"的原因。
// 收窄观察范围没用,必须让 SwiftUI 完全不参与进度刷新。

@MainActor
final class NowPlayingBar: ObservableObject {
    static let shared = NowPlayingBar()

    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var quality: Quality?
    @Published private(set) var cover: UIImage?
    /// 错误 / 降级提示也走镜像 —— 横幅视图原本直接观察 engine,那同样是每秒
    /// 4 次失效发生在根视图树里。它只需要这两个值,都是低频的。
    @Published private(set) var lastError: String?
    @Published private(set) var cascadeNotice: String?
    /// 全屏播放器需要的额外低频展示字段 —— 避免让播放界面观察 PlaybackEngine 而 4Hz 重建。
    @Published private(set) var currentAudioSpec: AudioSpec?
    @Published private(set) var currentOrigin: ResolveOrigin?
    @Published private(set) var shuffle: Bool = false
    @Published private(set) var loopMode: PlaybackEngine.LoopMode = .all

    private var bag = Set<AnyCancellable>()

    /// 绑定到播放引擎。每条都加 removeDuplicates —— 值没变就不发通知,
    /// 时间在走并不会让这些属性变化,迷你播放器因此不会跟着重建。
    func bind(to engine: PlaybackEngine) {
        bag.removeAll()
        engine.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] in self?.track = $0 }
            .store(in: &bag)
        engine.$isPlaying
            .removeDuplicates()
            .sink { [weak self] in self?.isPlaying = $0 }
            .store(in: &bag)
        engine.$isBuffering
            .removeDuplicates()
            .sink { [weak self] in self?.isBuffering = $0 }
            .store(in: &bag)
        engine.$currentQuality
            .removeDuplicates()
            .sink { [weak self] in self?.quality = $0 }
            .store(in: &bag)
        engine.$nowPlayingCover
            .removeDuplicates { $0 === $1 }
            .sink { [weak self] in self?.cover = $0 }
            .store(in: &bag)
        engine.$lastError
            .removeDuplicates()
            .sink { [weak self] in self?.lastError = $0 }
            .store(in: &bag)
        engine.$cascadeNotice
            .removeDuplicates()
            .sink { [weak self] in self?.cascadeNotice = $0 }
            .store(in: &bag)
        engine.$currentAudioSpec
            .sink { [weak self] in self?.currentAudioSpec = $0 }
            .store(in: &bag)
        engine.$currentOrigin
            .sink { [weak self] in self?.currentOrigin = $0 }
            .store(in: &bag)
        engine.$shuffle
            .removeDuplicates()
            .sink { [weak self] in self?.shuffle = $0 }
            .store(in: &bag)
        engine.$loopMode
            .removeDuplicates()
            .sink { [weak self] in self?.loopMode = $0 }
            .store(in: &bag)
    }
}

/// 4Hz 的播放进度。只有真正需要进度的叶子视图(进度条、歌词滚动)观察它,
/// 不牵连整个播放界面 —— 否则每 0.25 秒整页重绘一次,开场滑入动画期间会严重掉帧。
@MainActor
final class PlaybackTicker: ObservableObject {
    static let shared = PlaybackTicker()

    /// 0…1 进度比例(给进度环用)
    @Published private(set) var fraction: Double = 0
    /// 绝对当前时间(秒)—— 进度条与时间标签用
    @Published private(set) var currentTime: Double = 0
    /// 总时长(秒)—— 进度条上限用
    @Published private(set) var duration: Double = 0

    private var bag = Set<AnyCancellable>()

    func bind(to engine: PlaybackEngine) {
        bag.removeAll()
        engine.$currentTime
            .removeDuplicates()
            .sink { [weak self] in self?.currentTime = $0 }
            .store(in: &bag)
        engine.$duration
            .removeDuplicates()
            .sink { [weak self] in self?.duration = $0 }
            .store(in: &bag)
        engine.$currentTime
            .combineLatest(engine.$duration)
            .map { time, total in total > 0 ? min(1, max(0, time / total)) : 0 }
            .removeDuplicates()
            .sink { [weak self] in self?.fraction = $0 }
            .store(in: &bag)
    }
}
