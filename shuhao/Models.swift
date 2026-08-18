import Foundation

nonisolated enum SourceID: String, Codable, CaseIterable, Hashable, Sendable {
    case kw, kg, tx, wy, mg, local
    var displayName: String {
        switch self {
        case .kw: return "酷我"
        case .kg: return "酷狗"
        case .tx: return "QQ音乐"
        case .wy: return "网易云"
        case .mg: return "咪咕"
        case .local: return "本地"
        }
    }
}

nonisolated enum Quality: String, Codable, CaseIterable, Hashable, Sendable {
    case k128 = "128k"
    case k320 = "320k"
    case flac = "flac"
    case flac24 = "flac24bit"
    case hires = "hires"
    case atmos = "atmos"
    case atmosPlus = "atmos_plus"
    case master = "master"
    var displayName: String {
        switch self {
        case .k128: return "标准 128k"
        case .k320: return "高品 320k"
        case .flac: return "无损 FLAC"
        case .flac24: return "Hi-Res 24bit"
        case .hires: return "Hi-Res 高解析"
        case .atmos: return "臻品全景声"
        case .atmosPlus: return "臻品全景声 2.0"
        case .master: return "臻品母带"
        }
    }
    /// Highest → lowest. Single source of truth for cascade order and "pick the best" logic.
    static let ranked: [Quality] = [.master, .atmosPlus, .atmos, .hires, .flac24, .flac, .k320, .k128]
    /// Tiers above flac24bit. Official search metadata rarely advertises these, so
    /// availability checks let the script backend decide instead of requiring the
    /// track to list them — a wrong guess just falls through the quality cascade.
    var isExtendedTier: Bool {
        switch self {
        case .hires, .atmos, .atmosPlus, .master: return true
        case .k128, .k320, .flac, .flac24: return false
        }
    }
}

nonisolated struct Track: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var singer: String
    var albumName: String?
    var albumId: String?
    var source: SourceID
    var songmid: String
    var duration: Int?
    var picURL: String?
    var qualities: [Quality]
    /// Source-specific extras passed to JS scripts as part of `info`. Use this for fields like
    /// Kugou `hash`, NetEase `mvId`, etc.
    var extras: [String: String]

    init(id: String, name: String, singer: String, albumName: String? = nil,
         albumId: String? = nil, source: SourceID, songmid: String,
         duration: Int? = nil, picURL: String? = nil,
         qualities: [Quality] = [], extras: [String: String] = [:]) {
        self.id = id; self.name = name; self.singer = singer
        self.albumName = albumName; self.albumId = albumId
        self.source = source; self.songmid = songmid
        self.duration = duration; self.picURL = picURL
        self.qualities = qualities; self.extras = extras
    }

    var subtitle: String {
        if let album = albumName, !album.isEmpty {
            return "\(singer) · \(album)"
        }
        return singer
    }

    static func makeID(source: SourceID, songmid: String) -> String {
        "\(source.rawValue)_\(songmid)"
    }
}

struct PlaylistMeta: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var trackIDs: [String]

    init(id: UUID = UUID(), name: String, trackIDs: [String] = []) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.trackIDs = trackIDs
    }
}

struct UserScript: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var description: String
    var version: String
    var author: String
    var homepage: String
    var rawScript: String
    var importedAt: Date
    var enabled: Bool

    init(id: UUID = UUID(), name: String, description: String, version: String, author: String, homepage: String, rawScript: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.homepage = homepage
        self.rawScript = rawScript
        self.importedAt = Date()
        self.enabled = enabled
    }
}

struct ScriptCapabilities: Codable, Hashable {
    var sources: [SourceID: SourceCapability]
}

struct SourceCapability: Codable, Hashable {
    var type: String
    var actions: [String]
    var qualities: [Quality]
}
