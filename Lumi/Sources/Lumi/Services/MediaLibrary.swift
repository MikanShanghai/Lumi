import Foundation
import AppKit
import CryptoKit
import AetherEngine

/// 视为视频的扩展名（文件级常量，避免跨 actor 访问问题）。
let lumiVideoExtensions: Set<String> = [
    "mp4", "mkv", "mov", "m4v", "avi", "ts", "m2ts", "webm",
    "flv", "wmv", "mpg", "mpeg", "rmvb", "iso", "mts",
]

// MARK: - 剧集识别与归组

struct EpisodeInfo {
    var show: String
    var season: Int
    var episode: Int
}

/// 媒体库里的一组：剧集（多集）或单部视频。
struct LibraryGroup: Identifiable {
    var id: String
    var title: String
    var season: Int?
    var items: [LibraryItem]

    var isSeries: Bool { season != nil }

    var subtitle: String? {
        guard let season else { return nil }
        return "第 \(season) 季 · \(items.count) 集"
    }
}

/// 从文件名解析剧集信息：S01E02 / 第3集 / EP04 / 1x05。
func parseEpisodeInfo(from filename: String) -> EpisodeInfo? {
    let stem = (filename as NSString).deletingPathExtension

    if let match = stem.firstMatch(of: #/(?i)^(.*?)[\s._\-]*s(\d{1,2})[\s._\-]*e(\d{1,3})/#),
       let season = Int(match.2), let episode = Int(match.3) {
        let show = cleanShowName(String(match.1))
        if !show.isEmpty { return EpisodeInfo(show: show, season: season, episode: episode) }
    }

    if let match = stem.firstMatch(of: #/第(\d{1,2})季[\s._\-]*第(\d{1,3})集/#),
       let season = Int(match.1), let episode = Int(match.2) {
        let show = cleanShowName(String(stem[..<match.range.lowerBound]))
        if !show.isEmpty { return EpisodeInfo(show: show, season: season, episode: episode) }
    }

    if let match = stem.firstMatch(of: #/第(\d{1,3})集/#), let episode = Int(match.1) {
        let show = cleanShowName(String(stem[..<match.range.lowerBound]))
        if !show.isEmpty { return EpisodeInfo(show: show, season: 1, episode: episode) }
    }

    if let match = stem.firstMatch(of: #/(?i)^(.*?)[\s._\-]+ep?(\d{1,3})(?:[\s._\-]|$)/#),
       let episode = Int(match.2) {
        let show = cleanShowName(String(match.1))
        if !show.isEmpty { return EpisodeInfo(show: show, season: 1, episode: episode) }
    }

    if let match = stem.firstMatch(of: #/(\d{1,2})x(\d{1,3})/#),
       let season = Int(match.1), let episode = Int(match.2) {
        let show = cleanShowName(String(stem[..<match.range.lowerBound]))
        if !show.isEmpty { return EpisodeInfo(show: show, season: season, episode: episode) }
    }

    return nil
}

private func cleanShowName(_ raw: String) -> String {
    var name = raw
    for separator in [".", "_", "-"] {
        name = name.replacingOccurrences(of: separator, with: " ")
    }
    for bracket in ["【", "】", "[", "]", "（）", "()"] {
        name = name.replacingOccurrences(of: bracket, with: " ")
    }
    while name.contains("  ") {
        name = name.replacingOccurrences(of: "  ", with: " ")
    }
    let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)

    // 剥掉尾部的发行标记（年份 / 分辨率 / 编码 / 音轨 / 语言…），
    // 否则「Show.2024.1080p.S01E02」和「Show.2024.4K.S01E03」会被拆成两部剧。
    var tokens = cleaned.split(separator: " ").map(String.init)
    while let last = tokens.last, isReleaseTag(last) {
        tokens.removeLast()
    }
    let result = tokens.joined(separator: " ")
    return result.isEmpty ? cleaned : result
}

private func isReleaseTag(_ token: String) -> Bool {
    let t = token.lowercased()
    if t.count == 4, Int(t) != nil { return true }   // 年份
    let exact: Set<String> = [
        "4k", "8k", "hdr", "hdr10", "dv", "sdr", "hevc", "avc", "x264", "x265",
        "h264", "h265", "aac", "ac3", "eac3", "dts", "truehd", "atmos",
        "bluray", "web-dl", "webdl", "webrip", "hdrip", "dvdrip", "remux",
        "repack", "proper", "国语", "中字", "双语", "内封", "外挂",
        "修复版", "完整版", "高清", "蓝光",
    ]
    if exact.contains(t) { return true }
    if t.hasSuffix("p"), Int(t.dropLast()).map({ $0 >= 360 && $0 <= 4320 }) ?? false { return true }  // 720p / 1080p
    if t.hasPrefix("ddp") || t.hasPrefix("dd+") { return true }
    if t.contains("字幕") || t.contains("配音") { return true }
    return false
}

/// 媒体库里的一个视频文件。
struct LibraryItem: Identifiable, Hashable, Codable {
    var id: String              // 绝对路径
    var name: String
    var size: Int64
    var modifiedAt: Date
    var duration: Double?
    var width: Int?
    var height: Int?
    var codec: String?
    var thumbName: String?      // 缩略图缓存文件名

    var url: URL { URL(fileURLWithPath: id) }

    var metaText: String {
        var parts: [String] = []
        if let duration, duration > 0 { parts.append(PlaybackSession.format(duration)) }
        if let width, let height, width > 0 { parts.append("\(width)×\(height)") }
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if parts.isEmpty { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}

/// 播放记录（继续观看的来源）。本地文件与网盘文件共用。
struct PlaybackRecord: Codable, Identifiable {
    var key: String             // "local:<path>" / "netdisk:<fsid>"
    var title: String
    var isNetdisk: Bool
    var fsId: Int64?
    var localPath: String?
    var position: Double
    var duration: Double
    var updatedAt: Date

    var id: String { key }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var isFinished: Bool { progress >= 0.98 }

    var remainingText: String {
        if isFinished { return "已看完" }
        let remain = max(duration - position, 0)
        return remain > 0 ? "剩余 " + PlaybackSession.format(remain) : "已看完"
    }
}

/// 媒体库：目录管理 / 扫描 / 元数据探测 / 缩略图缓存 / 播放进度记忆。
@MainActor
final class MediaLibrary: ObservableObject {
    @Published var folders: [URL] = []
    @Published var items: [LibraryItem] = []
    @Published var records: [PlaybackRecord] = []
    @Published var isScanning = false
    @Published var statusLine = ""

    private let foldersFile: URL
    private let itemsFile: URL
    private let recordsFile: URL
    private let thumbsDir: URL
    private let netdiskThumbsDir: URL
    private let imageCache = NSCache<NSString, NSImage>()
    private var enrichTask: Task<Void, Never>?

    init() {
        let root = ConfigStore.dir
        foldersFile = root.appendingPathComponent("library-folders.json")
        itemsFile = root.appendingPathComponent("library-items.json")
        recordsFile = root.appendingPathComponent("playback-records.json")
        thumbsDir = root.appendingPathComponent("thumbnails", isDirectory: true)
        netdiskThumbsDir = root.appendingPathComponent("netdisk-thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: netdiskThumbsDir, withIntermediateDirectories: true)
        loadState()
        if !folders.isEmpty { rescan() }
    }

    // MARK: 持久化

    private func loadState() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: foldersFile),
           let list = try? decoder.decode([String].self, from: data) {
            folders = list.map { URL(fileURLWithPath: $0) }
        }
        if let data = try? Data(contentsOf: itemsFile),
           let list = try? decoder.decode([LibraryItem].self, from: data) {
            items = list
        }
        if let data = try? Data(contentsOf: recordsFile),
           let list = try? decoder.decode([PlaybackRecord].self, from: data) {
            records = list
        }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folders.map(\.path)) {
            try? data.write(to: foldersFile, options: .atomic)
        }
    }

    private func saveItems() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: itemsFile, options: .atomic)
        }
    }

    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: recordsFile, options: .atomic)
        }
    }

    // MARK: 文件夹

    func addFolder(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard !folders.contains(standardized) else { return }
        folders.append(standardized)
        saveFolders()
        rescan()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        saveFolders()
        rescan()
    }

    // MARK: 扫描

    func rescan() {
        guard !isScanning, !folders.isEmpty else { return }
        isScanning = true
        statusLine = "正在扫描…"
        let folders = self.folders
        Task {
            let found = await Self.walk(folders)
            var existing = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            var merged: [LibraryItem] = []
            for var file in found {
                if let old = existing.removeValue(forKey: file.id) {
                    file.duration = old.duration
                    file.width = old.width
                    file.height = old.height
                    file.codec = old.codec
                    file.thumbName = old.thumbName
                }
                merged.append(file)
            }
            merged.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            items = merged
            saveItems()
            isScanning = false
            statusLine = ""
            enrichMissing()
        }
    }

    nonisolated private static func walk(_ folders: [URL]) async -> [LibraryItem] {
        await Task.detached(priority: .utility) {
            var result: [LibraryItem] = []
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            for folder in folders {
                guard let enumerator = fm.enumerator(
                    at: folder,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let url as URL in enumerator {
                    guard lumiVideoExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }
                    result.append(LibraryItem(
                        id: url.path,
                        name: url.lastPathComponent,
                        size: Int64(values?.fileSize ?? 0),
                        modifiedAt: values?.contentModificationDate ?? .distantPast,
                        duration: nil, width: nil, height: nil, codec: nil, thumbName: nil
                    ))
                    if result.count >= 3000 { return result }
                }
            }
            return result
        }.value
    }

    // MARK: 元数据 + 缩略图

    private func enrichMissing() {
        enrichTask?.cancel()
        let pending = items.filter { $0.thumbName == nil || $0.duration == nil }
        guard !pending.isEmpty else { return }
        enrichTask = Task { [weak self] in
            let batchSize = 3
            var done = 0
            for start in stride(from: 0, to: pending.count, by: batchSize) {
                if Task.isCancelled { break }
                let batch = Array(pending[start..<min(start + batchSize, pending.count)])
                await withTaskGroup(of: Void.self) { group in
                    for item in batch {
                        group.addTask { [weak self] in await self?.enrich(item) }
                    }
                }
                done += batch.count
                self?.statusLine = done == pending.count ? "" : "生成缩略图 \(done)/\(pending.count)"
            }
        }
    }

    private func enrich(_ item: LibraryItem) async {
        let url = item.url

        // 探测（阻塞式 API → 放到后台线程）
        let probe: (Double, Int, Int, String?)? = await Task.detached(priority: .utility) {
            guard let result = try? AetherEngine.probe(url: url) else { return nil }
            return (result.durationSeconds, Int(result.videoWidth), Int(result.videoHeight), result.videoCodecName)
        }.value

        var thumbName = item.thumbName
        if thumbName == nil {
            let duration = probe?.0 ?? 0
            let target = duration > 60 ? duration * 0.1 : max(duration * 0.3, 3)
            let extractor = FrameExtractor(url: url)
            var image = await extractor.thumbnail(at: target, maxWidth: 480)
            if image == nil {
                image = await extractor.thumbnail(at: 1, maxWidth: 480)
            }
            if let image {
                let name = Self.thumbFileName(for: item.id)
                Self.writeJPEG(image, to: thumbsDir.appendingPathComponent(name))
                thumbName = name
            } else {
                print("[Lumi] 缩略图失败：\(item.name)")
            }
        }

        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if let probe {
            items[index].duration = probe.0
            items[index].width = probe.1
            items[index].height = probe.2
            items[index].codec = probe.3
        }
        items[index].thumbName = thumbName
        saveItems()
    }

    func thumbnailImage(for item: LibraryItem) -> NSImage? {
        guard let thumbName = item.thumbName else { return nil }
        let key = thumbName as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: thumbsDir.appendingPathComponent(thumbName)) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    // MARK: 网盘缩略图（按 fsId 缓存，文件在各目录共用）

    func netdiskThumbnail(for fsId: Int64) -> NSImage? {
        let name = "nd-\(fsId).jpg"
        let key = name as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: netdiskThumbsDir.appendingPathComponent(name)) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    func saveNetdiskThumbnail(_ image: CGImage, fsId: Int64) {
        let name = "nd-\(fsId).jpg"
        Self.writeJPEG(image, to: netdiskThumbsDir.appendingPathComponent(name))
        imageCache.removeObject(forKey: name as NSString)
    }

    private static func thumbFileName(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24) + ".jpg"
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
        try? data.write(to: url)
    }

    // MARK: 播放记录

    func saveRecord(
        key: String, title: String, isNetdisk: Bool,
        fsId: Int64? = nil, localPath: String? = nil,
        position: Double, duration: Double
    ) {
        // 开头几秒不记（没真的看）；有效记录才保存
        guard position > 1, duration > 0 else { return }
        let record = PlaybackRecord(
            key: key, title: title, isNetdisk: isNetdisk,
            fsId: fsId, localPath: localPath,
            position: position, duration: duration, updatedAt: Date()
        )
        if let index = records.firstIndex(where: { $0.key == key }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.updatedAt > $1.updatedAt }
        saveRecords()
    }

    func record(for key: String) -> PlaybackRecord? {
        records.first { $0.key == key }
    }

    func record(forPath path: String) -> PlaybackRecord? {
        record(for: "local:" + path)
    }

    /// 最近播放：看过一点的都算（含已看完），按时间倒序。
    var continueWatching: [PlaybackRecord] {
        records
            .filter { $0.progress > 0.02 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 按剧集信息归组：S01E02 / 第3集 等自动并成一部剧；识别不出的一律当单片。
    var groups: [LibraryGroup] {
        var series: [String: (title: String, season: Int, episodes: [(Int, LibraryItem)])] = [:]
        var singles: [LibraryItem] = []
        for item in items {
            if let info = parseEpisodeInfo(from: item.name), !info.show.isEmpty {
                let key = info.show.lowercased() + "|s" + String(info.season)
                series[key, default: (info.show, info.season, [])].episodes.append((info.episode, item))
            } else {
                singles.append(item)
            }
        }
        let seriesGroups = series.map { key, value in
            LibraryGroup(
                id: "series:" + key,
                title: value.title,
                season: value.season,
                items: value.episodes
                    .sorted { $0.0 == $1.0 ? $0.1.name.localizedStandardCompare($1.1.name) == .orderedAscending : $0.0 < $1.0 }
                    .map(\.1)
            )
        }
        let singleGroups = singles.map {
            LibraryGroup(id: "item:" + $0.id, title: $0.name, season: nil, items: [$0])
        }
        return (seriesGroups + singleGroups)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
