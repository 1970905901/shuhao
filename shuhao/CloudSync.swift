import Foundation
import Combine

/// Lightweight iCloud sync via NSUbiquitousKeyValueStore.
/// Stores: playlist metadata (id + name + trackIDs), track bank, user-script index, settings.
/// Scripts' raw source isn't synced (too large for KV store's 1MB/entry limit) — only the
/// list of script IDs/names is mirrored, and the actual script content stays local.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()
    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?
    let didReceiveRemoteChange = PassthroughSubject<Void, Never>()

    @Published var lastSyncedAt: Date?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "cloud.enabled") }
    }

    private init() {
        self.enabled = UserDefaults.standard.object(forKey: "cloud.enabled") as? Bool ?? true
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastSyncedAt = Date()
                self?.didReceiveRemoteChange.send()
            }
        }
        store.synchronize()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func push<T: Encodable>(_ value: T, forKey key: String) {
        guard enabled else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        // KV store cap is ~1MB total, 1MB per entry. Skip oversize values.
        if data.count > 900_000 {
            print("[CloudSync] skipping \(key): \(data.count) bytes exceeds limit")
            return
        }
        store.set(data, forKey: key)
        store.synchronize()
    }

    func pull<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard enabled else { return nil }
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func remove(forKey key: String) {
        store.removeObject(forKey: key)
        store.synchronize()
    }
}

extension CloudSync {
    enum Keys {
        static let playlists = "playlists"
        static let trackBank = "trackBank"
        /// 已删除歌单的墓碑(id → 删除时间)。没有它,删除无法跨设备传播:
        /// 其它设备仍持有的副本会被当成新歌单推回来。
        static let deletedPlaylists = "deletedPlaylists.v1"
        /// Legacy: only stored script names/ids. Superseded by `scripts` which
        /// carries the full UserScript bundle (rawScript included).
        static let scriptIndex = "scriptIndex"
        /// Full user scripts (name, version, rawScript). Subject to the KV
        /// store's 1 MB cap — oversize bundles are silently skipped.
        static let scripts = "scripts.v1"
        static let preferredQuality = "preferredQuality"
    }
}
