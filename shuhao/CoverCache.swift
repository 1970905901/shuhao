import Foundation
import UIKit

/// Downloads album covers into the App Group container so the LiveActivity
/// + home-screen widget can render them from disk (they can't reach the
/// network reliably themselves).
///
/// Covers are keyed by a hash of the URL — same URL hits the same file every
/// time, so re-playing the same track doesn't re-download. We don't aggressively
/// evict; the container is small (just covers) and iOS reclaims it on uninstall.
enum CoverCache {

    /// 本地封面的有效期。跟各家 CDN 给的 Cache-Control: max-age(30 天)对齐;
    /// 过期后重新拉一次,专辑换封面才不会一直停在旧图。
    private static let ttl: TimeInterval = 30 * 24 * 3600

    /// Returns the local file URL for a remote cover, downloading if missing.
    /// Returns `nil` if the URL is bad, the network failed, or the App Group
    /// container isn't reachable.
    @discardableResult
    static func fetch(_ urlString: String?) async -> URL? {
        guard let urlString, let remote = URL(string: urlString),
              let directory = SharedAppGroup.coversDirectory else {
            return nil
        }
        let local = directory.appendingPathComponent(filename(for: urlString))
        // 本地副本在 TTL 内直接用;过期就重新下载一次,这样平台真给专辑换了封面
        // 也能跟上 —— 之前只判断文件存在,一旦落盘就永远不会更新了。
        if FileManager.default.fileExists(atPath: local.path) {
            let modified = (try? local.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) < ttl {
                return local
            }
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: remote)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            // Re-encode through UIImage to strip EXIF/metadata, downsize to ~256
            // (any larger is wasted: LA cover is 56pt, widget small is ~120pt).
            // Keeps each file ~10-30KB instead of hundreds of KB raw.
            guard let img = UIImage(data: data) else {
                try? data.write(to: local)
                return local
            }
            let resized = downsize(img, to: 256)
            if let jpeg = resized.jpegData(compressionQuality: 0.82) {
                try jpeg.write(to: local, options: .atomic)
            } else {
                try data.write(to: local, options: .atomic)
            }
            return local
        } catch {
            return nil
        }
    }

    /// Stable hash → URL becomes a single filename we can re-derive later.
    /// Using SHA wouldn't add anything here; .hashValue is plenty for dedup.
    private static func filename(for url: String) -> String {
        let h = abs(url.hash)
        return "cover_\(h).jpg"
    }

    private static func downsize(_ image: UIImage, to maxSide: CGFloat) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let longest = max(w, h)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
