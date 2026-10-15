import SwiftUI
import AppKit
import Combine
import AetherEngine

enum Route: String, CaseIterable, Identifiable {
    case library = "媒体库"
    case netdisk = "百度网盘"
    case settings = "设置"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .library: return "play.rectangle.on.rectangle"
        case .netdisk: return "cloud"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// 一次播放会话：包住 AetherEngine，向控制层提供时间/状态，并定期回写播放进度。
@MainActor
final class PlaybackSession: ObservableObject, Identifiable {
    let id = UUID()
    let engine: AetherEngine
    let title: String
    let sourceLabel: String
    let proxy: StreamProxy?

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isScrubbing = false
    @Published var scrubTime: Double = 0
    @Published var statusText = "加载中…"
    @Published var failed = false
    @Published var rate: Float = 1.0
    @Published var audioTracks: [TrackInfo] = []
    @Published var subtitleTracks: [TrackInfo] = []
    @Published var activeAudioIndex: Int?
    @Published var activeSubtitleIndex: Int?

    /// 进度回写（约每 5 秒一次 + 收尾时一次）。
    var onProgress: ((Double, Double) -> Void)?

    // 悬停进度条时的预览帧
    @Published var previewImage: NSImage?
    @Published var previewUnavailable = false
    private var previewCache: [Int: NSImage] = [:]
    private var previewExtractor: FrameExtractor?
    private var previewTask: Task<Void, Never>?
    private var lastPrewarmAt = Date.distantPast
    private let sourceURL: URL
    private let sourceHeaders: [String: String]
    /// 抽帧专用地址：网盘走直连 dlink（比经代理快 6 倍，实测 14.4s → 2.4s），本地就是文件本身。
    private let previewURL: URL

    private var cancellables = Set<AnyCancellable>()
    private var lastSavedAt = Date.distantPast

    init(
        engine: AetherEngine,
        title: String,
        sourceLabel: String = "",
        proxy: StreamProxy? = nil,
        sourceURL: URL,
        sourceHeaders: [String: String] = [:],
        previewURL: URL? = nil
    ) {
        self.engine = engine
        self.title = title
        self.sourceLabel = sourceLabel
        self.proxy = proxy
        self.sourceURL = sourceURL
        self.sourceHeaders = sourceHeaders
        self.previewURL = previewURL ?? sourceURL

        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .playing:
                    self.isPlaying = true
                    self.statusText = ""
                case .paused:
                    self.isPlaying = false
                    self.statusText = ""
                case .loading:
                    self.statusText = "加载中…"
                case .seeking:
                    break
                case .ended:
                    self.isPlaying = false
                    self.statusText = "播放结束"
                    if self.duration > 0 { self.onProgress?(self.duration, self.duration) }
                case .error(let message):
                    self.isPlaying = false
                    self.failed = true
                    self.statusText = "出错了：\(message)"
                case .idle:
                    break
                @unknown default:
                    break
                }
            }
            .store(in: &cancellables)

        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                if value.isFinite, value > 0 { self?.duration = value }
            }
            .store(in: &cancellables)

        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self, !self.isScrubbing, value.isFinite else { return }
                self.currentTime = value
                if self.duration > 0, Date().timeIntervalSince(self.lastSavedAt) > 5 {
                    self.lastSavedAt = Date()
                    self.onProgress?(value, self.duration)
                }
                if self.duration > 30 {
                    self.prewarmPreview(at: value)
                }
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in self?.audioTracks = tracks }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in self?.subtitleTracks = tracks }
            .store(in: &cancellables)

        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in self?.activeAudioIndex = index }
            .store(in: &cancellables)

        engine.$activeSubtitleTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in self?.activeSubtitleIndex = index }
            .store(in: &cancellables)
    }

    var timeText: String {
        let t = isScrubbing ? scrubTime : currentTime
        return "\(Self.format(t)) / \(Self.format(duration))"
    }

    func togglePlay() {
        engine.togglePlayPause()
    }

    func seek(to seconds: Double) {
        Task { await engine.seek(to: max(0, seconds)) }
    }

    /// 快进/快退（按钮与方向键共用）。
    func skip(by seconds: Double) {
        let base = isScrubbing ? scrubTime : currentTime
        var target = base + seconds
        if duration > 0 { target = min(target, duration) }
        seek(to: max(0, target))
    }

    func setRate(_ value: Float) {
        rate = value
        engine.setRate(value)
    }

    func selectAudio(_ index: Int) {
        engine.selectAudioTrack(index: index)
    }

    func selectSubtitle(_ index: Int) {
        engine.selectSubtitleTrack(index: index)
    }

    func clearSubtitle() {
        engine.clearSubtitle()
    }

    // MARK: 预览帧（进度条悬停）

    /// 请求某一时刻的预览帧。按 5 秒分桶缓存；220ms 防抖，避免拖动时狂抽帧。
    func requestPreview(at seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let bucket = max(0, Int(seconds / 5) * 5)
        if let cached = previewCache[bucket] {
            previewUnavailable = false
            previewImage = cached
            return
        }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.previewExtractor == nil {
                self.previewExtractor = FrameExtractor(url: self.previewURL, httpHeaders: self.sourceHeaders)
            }
            guard let extractor = self.previewExtractor else { return }
            if let cgImage = await extractor.thumbnail(at: Double(bucket), maxWidth: 240) {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                self.previewCache[bucket] = image
                if !Task.isCancelled {
                    self.previewUnavailable = false
                    self.previewImage = image
                }
            } else if !Task.isCancelled {
                self.previewUnavailable = true
            }
        }
    }

    func clearPreview() {
        previewTask?.cancel()
    }

    /// 播放时预热"当前位置附近"的预览帧（每 20 秒最多一次）：
    /// 用户悬停进度条时大概率命中缓存，直接秒出画面。
    private func prewarmPreview(at seconds: Double) {
        guard Date().timeIntervalSince(lastPrewarmAt) > 20 else { return }
        lastPrewarmAt = Date()
        let bucket = max(0, Int(seconds / 5) * 5)
        guard previewCache[bucket] == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            if self.previewExtractor == nil {
                self.previewExtractor = FrameExtractor(url: self.previewURL, httpHeaders: self.sourceHeaders)
            }
            guard let extractor = self.previewExtractor else { return }
            if let cgImage = await extractor.thumbnail(at: Double(bucket), maxWidth: 240) {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                self.previewCache[bucket] = image
            }
        }
    }

    func teardown() {
        onProgress?(isScrubbing ? scrubTime : currentTime, duration)
        previewTask?.cancel()
        cancellables.removeAll()
        engine.stop()
    }

    nonisolated static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var route: Route = .library
    @Published var playback: PlaybackSession?
    @Published var lastError: String?

    let baidu = BaiduProvider()
    let library = MediaLibrary()

    /// 播放内核是长生命周期实例（AetherEngine 的设计：换片只 load，不重建引擎）。
    private(set) var engine: AetherEngine?
    private(set) var engineError: String?
    /// 进入播放器前窗口是否已是全屏（退出播放器时用来恢复原状）。
    private var windowWasFullScreenBeforePlayer = false

    init() {
        do {
            engine = try AetherEngine()
        } catch {
            engineError = "播放内核初始化失败：\(error)"
        }
    }

    // MARK: 本地

    func playLocal(url: URL) {
        let path = url.standardizedFileURL.path
        Task {
            await startPlayback(
                url: url,
                title: url.lastPathComponent,
                sourceLabel: "本地文件",
                proxy: nil,
                recordKey: "local:" + path,
                isNetdisk: false,
                fsId: nil,
                localPath: path
            )
        }
    }

    func playLibraryItem(_ item: LibraryItem) {
        playLocal(url: item.url)
    }

    // MARK: 网盘

    func playNetdisk(_ file: NetdiskFile) async {
        await playNetdiskFile(fsId: file.fsId, title: file.serverFilename)
    }

    func playNetdiskFile(fsId: Int64, title: String) async {
        do {
            let upstream = try await baidu.playableURL(fsId: fsId)
            let proxy = StreamProxy()
            let port = try await proxy.start(upstream: upstream)
            guard let streamURL = URL(string: "http://127.0.0.1:\(port)/stream") else {
                throw LumiError.badURL
            }
            await startPlayback(
                url: streamURL,
                title: title,
                sourceLabel: "百度网盘 · 直连",
                proxy: proxy,
                previewURL: upstream,
                recordKey: "netdisk:\(fsId)",
                isNetdisk: true,
                fsId: fsId,
                localPath: nil
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 「继续观看」的入口（本地 / 网盘通用）。
    func playRecord(_ record: PlaybackRecord) {
        if record.isNetdisk, let fsId = record.fsId {
            Task { await playNetdiskFile(fsId: fsId, title: record.title) }
        } else if let path = record.localPath {
            playLocal(url: URL(fileURLWithPath: path))
        }
    }

    // MARK: 播放

    private func startPlayback(
        url: URL,
        title: String,
        sourceLabel: String,
        proxy: StreamProxy?,
        previewURL: URL? = nil,
        recordKey: String,
        isNetdisk: Bool,
        fsId: Int64?,
        localPath: String?
    ) async {
        guard let engine else {
            proxy?.stop()
            lastError = engineError ?? "播放内核不可用"
            return
        }

        playback?.teardown()
        playback?.proxy?.stop()

        windowWasFullScreenBeforePlayer = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false

        let session = PlaybackSession(
            engine: engine,
            title: title,
            sourceLabel: sourceLabel,
            proxy: proxy,
            sourceURL: url,
            sourceHeaders: ["User-Agent": "pan.baidu.com"],
            previewURL: previewURL
        )
        session.onProgress = { [weak self] position, duration in
            self?.library.saveRecord(
                key: recordKey,
                title: title,
                isNetdisk: isNetdisk,
                fsId: fsId,
                localPath: localPath,
                position: position,
                duration: duration
            )
        }
        playback = session

        // 续播：有记录就从上次的位置开始（超过 5 秒才值得续）
        let resume = library.record(for: recordKey)?.position ?? 0
        do {
            try await engine.load(
                url: url,
                startPosition: resume > 5 ? resume : nil,
                options: LoadOptions(httpHeaders: ["User-Agent": "pan.baidu.com"])
            )
            engine.play()
        } catch {
            session.failed = true
            session.statusText = "无法播放：\(error)"
            lastError = "无法播放：\(error)"
        }
    }

    /// 为网盘视频补缩略图（有缓存就跳过；失败静默）。
    func ensureNetdiskThumbnail(fsId: Int64) async {
        guard library.netdiskThumbnail(for: fsId) == nil else { return }
        guard baidu.loginState == .connected else { return }
        guard let url = try? await baidu.playableURL(fsId: fsId) else { return }
        let extractor = FrameExtractor(url: url, httpHeaders: ["User-Agent": "pan.baidu.com"])
        for time in [12.0, 4.0, 1.0] {
            if let image = await extractor.thumbnail(at: time, maxWidth: 480) {
                library.saveNetdiskThumbnail(image, fsId: fsId)
                return
            }
        }
    }

    func closePlayer() {
        restoreWindowStateIfNeeded()
        playback?.teardown()
        playback?.proxy?.stop()
        playback = nil
    }

    /// 退出播放器时恢复窗口状态：如果播放器把窗口切进了全屏（而进播放器前不是全屏），
    /// 一起退出全屏。否则 Esc 只关掉播放层、窗口仍留在全屏，状态就和最初对不上了。
    private func restoreWindowStateIfNeeded() {
        guard !windowWasFullScreenBeforePlayer,
              let window = NSApp.keyWindow,
              window.styleMask.contains(.fullScreen) else { return }
        // 稍微延后：如果系统自己也响应了 Esc（退出全屏），150ms 后窗口已不在全屏，
        // 这里就自然变成 no-op，不会出现「退出又被切回去」的抢按键问题。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak window] in
            guard let window, window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}
