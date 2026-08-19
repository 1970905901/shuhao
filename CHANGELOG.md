# Release Notes — shuhao music 2.0

> 基于上游 [SincereXing/walkman](https://github.com/SincereXing/walkman)（随便听 · 三端播放器）fork，针对 **iPhone 单端体验** 全面定制。
> 版本 **2.0 (31)** · 最低适配 iOS 16.0 · 仅支持 iPhone

---

## 🎉 主要变化（相对上游 walkman）

### 🔥 功能移除（按用户要求精简）

- **删除听歌识曲（ShazamKit）**：移除 `SongRecognizer` / `RecognizeView` / 麦克风权限，App 不再申请 `NSMicrophoneUsageDescription`
- **删除实时音浪（AudioWave）**：移除 `AudioLevel` 单例、RMS 计算、60Hz displayLink，播放更省电
- **删除锁屏/车机专辑栏歌词**：移除设置开关、`nowPlayingAlbumText`、歌词同步 watcher，锁屏恢复显示专辑名
- **删除内置直连兜底**：播放地址解析改为**纯脚本模式**，脚本失败直接报错、不再静默回落平台直连
- **删除 iPad / Mac / Widget 支持**：仅保留 iPhone（`TARGETED_DEVICE_FAMILY=1`），移除三端布局与 DMG 分发

### ✨ 功能与体验

- **黑胶唱片播放页**：网易云风格黑胶封面（碟身 + 同心纹 + 中心圆形封面），**静态不旋转**（用户要求），彻底消除旋转相关的视觉跳变
- **迷你播放器紧贴 Tab 栏**：间距改为几乎无缝细缝（1pt），按系统安全区精确计算
- **设置升级为独立底部 Tab**（第 5 个），入口更直接
- **品牌独立**：应用名 `shuhao music`、白底粉色音符图标、Bundle ID `shuhao.com`、版本 2.0
- **启动体验**：LaunchScreen 纯色背景 + 应用内启动页读当前图标，全程图标一致，不闪现旧版

### 🚀 性能与稳定性（大量优化）

| 优化 | 效果 |
|---|---|
| 摘除 8+ 视图对 PlaybackEngine 的直接观察（改低频镜像 + 取指令） | 播放中视图不再随 currentTime 每秒重建 4 次 |
| 播放状态持久化移到后台队列 | 播放中每 0.5s 磁盘 I/O 不再阻塞主线程 |
| 锁屏/控制中心信息节流（4Hz → 1Hz） | 跨进程 XPC 写入大幅减少 |
| 进度发布 2Hz（原 4Hz） | 进度条/歌词每秒重建减半 |
| 设置页 Form → List | 修复 iOS 16 滚动掉帧 |
| coverPage 布局稳定化（ZStack 固定居中） | 暂停/播放时黑胶纹丝不动 |
| 歌词行 Equatable + 歌词缓存设上限（500 首） | 长歌词滚动不掉帧、内存不无界增长 |
| 常驻观察者 deinit 清理 | 消除 NotificationCenter token 悬挂 |
| 死代码清理（-157 行） | 包体更小、编译更快 |

### 🐛 关键 Bug 修复

- **黑胶"暂停/播放循环变大变小"**：定位为 CALayer transform 写入与 SwiftUI 布局叠加，最终静态化根治
- **播放中打开/关闭播放器卡顿**：多个主线程负载源（XPC 写入、磁盘持久化、4Hz 重建）逐一消除
- **本地脚本导入**：历经多轮修复，最终用原生 `UIDocumentPickerViewController` + 具体 UTI 类型，文件选择器可靠弹出并可选中
- **启动闪现旧图标**：LaunchScreen 纯色化 + SplashView 读当前图标
- **打开播放器整窗变黑 / tab 变透明**：移除强制深色 scheme
- **迷你播放器定位**：多轮修复，最终 root ZStack 底部锚定 + 系统 API 测量

---

## 📦 安装

不上架 App Store，需自行构建或使用 CI 产物：

1. 打开 `shuhao.xcodeproj`，**替换签名团队 + Bundle ID**（`shuhao.com` 系列绑定当前账号）
2. 真机直接运行;或从 GitHub Actions 下载 `shuhao-ios-ipa`
3. **安装后先到「设置 → 自定义音源」导入 lx-music v4 兼容脚本**（App 不内置任何音源）

---

## ⚠️ 与上游的差异摘要

| 维度 | 上游 walkman | shuhao music 2.0 |
|---|---|---|
| 平台 | iPhone + iPad + Mac + Widget | **仅 iPhone** |
| 音源解析 | 脚本 + 内置直连兜底 | **纯脚本模式** |
| 听歌识曲 | 有 | **无** |
| 播放音浪 | 有 | **无** |
| 锁屏歌词 | 有 | **无** |
| 黑胶旋转 | iPad 黑胶唱盘旋转 | **静态黑胶** |
| 版本 | — | **2.0 (31)** |

完整对照见 README「🔀 与原仓库差异」章节。
