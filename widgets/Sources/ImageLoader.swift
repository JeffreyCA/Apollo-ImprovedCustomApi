import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downloads and downsamples images inside the timeline provider so widgets
/// render them synchronously (AsyncImage is unreliable in widgets) and stay
/// within the extension's tight memory budget.
enum ImageLoader {
    /// On-disk cache of downsampled JPEGs, keyed by (url, maxPixel). Rotation
    /// (↻) rebuilds re-request mostly the same batch of images; without this
    /// every tap re-downloaded and re-downsampled all of them, which was slow
    /// enough that the button looked dead.
    private static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rw-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func cacheFile(_ urlString: String, _ maxPixel: Int) -> URL {
        cacheDir.appendingPathComponent(String(fnv1a("\(urlString)|\(maxPixel)"), radix: 16) + ".jpg")
    }

    /// Fetch `url`, downsample to `maxPixel` on the long edge, re-encode as
    /// JPEG. Serves from the disk cache when available. Returns nil on any
    /// failure (caller renders a text fallback).
    static func fetchDownsampled(_ urlString: String?, maxPixel: Int) async -> Data? {
        guard let s = urlString, let url = URL(string: s) else { return nil }
        let file = cacheFile(s, maxPixel)
        if let cached = try? Data(contentsOf: file) {
            // Touch for LRU pruning.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return cached
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await rwSession.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let out = downsample(data: data, maxPixel: maxPixel)
        if let out {
            try? out.write(to: file)
            prune()
        }
        return out
    }

    /// Keep the newest `maxFiles` cache entries (by modification date). The
    /// image widgets cycle at most a few dozen images per fetch window, so this
    /// covers full rotations while bounding disk use (~100 × ≤300 KB).
    private static func prune(maxFiles: Int = 100) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: .skipsHiddenFiles),
              files.count > maxFiles else { return }
        let dated = files.map { url -> (URL, Date) in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, d)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxFiles) {
            try? fm.removeItem(at: url)
        }
    }

    static func downsample(data: Data, maxPixel: Int) -> Data? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
