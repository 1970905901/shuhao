import Foundation

/// App 数据文件的落地位置。
///
/// iOS / iPadOS 上 Documents 是 app 私有容器,直接用即可。
/// Mac Catalyst 不开沙盒时,这两个目录取到的是**用户真实的** ~/Documents 与
/// ~/Library/Caches —— 十来个 json 直接摊在用户自己的文稿目录里,很脏。
/// 所以 Mac 上统一收进各自的 Shuhao 子目录,并把历史散落的文件搬进去。
enum AppPaths {

    /// 歌单、脚本、播放历史等状态文件的目录。
    static let documents: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if targetEnvironment(macCatalyst)
        return scoped(base, moving: stateFiles)
        #else
        return base
        #endif
    }()

    /// 收进子目录之前的老位置(Mac 上就是用户真实的 ~/Documents)。
    /// 只用于定位早期版本遗留在那里、且不适合搬动的东西 —— 比如已下载的音频
    /// 文件。搬 json 是安全的,搬用户的音乐文件不是,所以那些就地兼容读取。
    static var legacyBase: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 可重建的缓存目录(内嵌封面等)。
    static let caches: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #if targetEnvironment(macCatalyst)
        return scoped(base, moving: cacheEntries)
        #else
        return base
        #endif
    }()

    #if targetEnvironment(macCatalyst)
    /// 曾经直接写在用户 ~/Documents 根下的文件,需要搬进子目录。
    private static let stateFiles = [
        "playlists.json", "trackBank.json", "deletedPlaylists.json",
        "scripts.json", "playHistory.json", "playEvents.json",
        "playbackState.json", "localFolders.json",
        "downloadFolders.json", "downloadRecords.json",
    ]

    /// 缓存目录同理。Downloads 不在此列 —— Mac 的下载早已落在 ~/Music/Shuhao。
    private static let cacheEntries = ["EmbeddedCovers"]

    /// 建好 base/Shuhao,把 names 里还留在 base 根下的条目搬进去。
    /// 只在目标不存在时搬,搬失败就保持原样(宁可继续用旧位置也不能弄丢数据)。
    private static func scoped(_ base: URL, moving names: [String]) -> URL {
        let fm = FileManager.default
        let dir = base.appendingPathComponent("Shuhao", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            return base   // 建不出目录(权限等),退回老行为
        }
        for name in names {
            let old = base.appendingPathComponent(name)
            let new = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            try? fm.moveItem(at: old, to: new)
        }
        return dir
    }
    #endif
}
