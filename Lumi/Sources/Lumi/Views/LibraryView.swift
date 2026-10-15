import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        LibraryContent(library: app.library)
    }
}

struct LibraryContent: View {
    @ObservedObject var library: MediaLibrary
    @EnvironmentObject var app: AppModel
    @State private var dropTargeted = false
    @State private var sheetGroup: LibraryGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.accent.opacity(dropTargeted ? 0.9 : 0), lineWidth: 2)
                .padding(12)
                .allowsHitTesting(false)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .sheet(item: $sheetGroup) { group in
            EpisodeSheet(group: group, library: library) { item in
                sheetGroup = nil
                app.playLibraryItem(item)
            }
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("媒体库")
                .font(.system(size: 22, weight: .bold))
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if library.isScanning || !library.statusLine.isEmpty {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(library.statusLine).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Button {
                library.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(library.folders.isEmpty)
            if !library.folders.isEmpty {
                Menu {
                    ForEach(library.folders, id: \.self) { folder in
                        Menu(folder.lastPathComponent) {
                            Button("在访达中打开") { NSWorkspace.shared.open(folder) }
                            Button("从媒体库移除", role: .destructive) {
                                library.removeFolder(folder)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("管理媒体库文件夹")
            }
            Button {
                addFolderViaPanel()
            } label: {
                Label("添加文件夹", systemImage: "folder.badge.plus")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var summary: String {
        if library.items.isEmpty && library.folders.isEmpty { return "拖入文件夹或点击「添加文件夹」" }
        return "\(library.items.count) 个视频 · \(library.folders.count) 个文件夹"
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if library.items.isEmpty && library.continueWatching.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !library.continueWatching.isEmpty {
                        continueSection
                    }
                    if !library.items.isEmpty {
                        allVideosSection
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "play.square.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(library.folders.isEmpty ? "还没有本地视频" : "文件夹里没有找到视频")
                .font(.system(size: 15, weight: .semibold))
            Text("把装有视频的文件夹拖进这个窗口，或点击「添加文件夹」")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button {
                addFolderViaPanel()
            } label: {
                Label("添加文件夹…", systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 继续观看

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("最近播放").font(.system(size: 15.5, weight: .semibold))
                Text("\(library.continueWatching.count) 部").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(library.continueWatching.prefix(10)) { record in
                        ContinueCard(record: record, thumbnail: thumbnailFor(record)) {
                            app.playRecord(record)
                        }
                        .task {
                            // 网盘的继续观看条目：懒生成缩略图（拿 dlink → 抽帧 → 缓存）
                            if record.isNetdisk, let fsId = record.fsId {
                                await app.ensureNetdiskThumbnail(fsId: fsId)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func thumbnailFor(_ record: PlaybackRecord) -> NSImage? {
        if record.isNetdisk, let fsId = record.fsId {
            return library.netdiskThumbnail(for: fsId)
        }
        guard let path = record.localPath,
              let item = library.items.first(where: { $0.id == path }) else { return nil }
        return library.thumbnailImage(for: item)
    }

    // MARK: 全部视频

    private var allVideosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("全部视频")
                .font(.system(size: 15.5, weight: .semibold))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 224, maximum: 320), spacing: 18)],
                spacing: 18
            ) {
                ForEach(library.groups) { group in
                    if group.isSeries {
                        SeriesCard(
                            group: group,
                            thumbnail: group.items.first.flatMap { library.thumbnailImage(for: $0) },
                            progress: seriesProgress(group)
                        ) {
                            sheetGroup = group
                        }
                    } else if let item = group.items.first {
                        VideoCard(
                            item: item,
                            thumbnail: library.thumbnailImage(for: item),
                            progress: library.record(forPath: item.id)?.progress ?? 0
                        ) {
                            app.playLibraryItem(item)
                        }
                        .contextMenu {
                            Button("在访达中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                        }
                    }
                }
            }
        }
    }

    /// 剧集卡片的进度：取该剧里"最近播放"那一集的进度。
    private func seriesProgress(_ group: LibraryGroup) -> Double {
        group.items
            .compactMap { library.record(forPath: $0.id) }
            .max { $0.updatedAt < $1.updatedAt }?
            .progress ?? 0
    }

    // MARK: 交互

    private func addFolderViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "加入媒体库"
        if panel.runModal() == .OK {
            for url in panel.urls { library.addFolder(url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                guard let url else { return }
                Task { @MainActor in
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    if isDirectory.boolValue {
                        library.addFolder(url)
                    } else if lumiVideoExtensions.contains(url.pathExtension.lowercased()) {
                        app.playLocal(url: url)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - 卡片

private struct ContinueCard: View {
    let record: PlaybackRecord
    let thumbnail: NSImage?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    ThumbBackground(thumbnail: thumbnail, seed: record.key)
                        .frame(width: 258, height: 146)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        .frame(width: 258, height: 146)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        ProgressTrack(progress: record.progress)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    if record.isNetdisk {
                        Text("网盘")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .padding(10)
                            .frame(width: 258, height: 146, alignment: .topTrailing)
                    }
                }
                Text(record.remainingText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.02 : 1.0)
        .animation(.lumiStandard, value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct VideoCard: View {
    let item: LibraryItem
    let thumbnail: NSImage?
    let progress: Double
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    ThumbBackground(thumbnail: thumbnail, seed: item.id)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(hovering ? 0.22 : 0.08), lineWidth: 0.5)
                        )
                    if progress > 0.02 {
                        ProgressTrack(progress: progress)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 7)
                    }
                    if item.duration != nil {
                        Text(PlaybackSession.format(item.duration ?? 0))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.5)))
                            .padding(7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.metaText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.015 : 1.0)
        .animation(.lumiStandard, value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct ThumbBackground: View {
    let thumbnail: NSImage?
    let seed: String
    var cornerRadius: CGFloat = 10

    var body: some View {
        // 「宽高比盒子」：先在宽度上定出 16:9 的框，图片叠在上面裁剪。
        // 不能直接在 ScrollView 里对可拉伸图片用 contentMode: .fill——
        // 滚动视图给的高度是无界的，会取到无限大把布局撑爆（实测）。
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(gradient)
                        Image(systemName: "film")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// 用文件路径算一个稳定的色相，占位图不闪烁。
    private var gradient: LinearGradient {
        var hash: UInt64 = 5381
        for scalar in seed.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        let hue = Double(hash % 360) / 360
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.52, brightness: 0.52),
                Color(hue: (hue + 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.68, brightness: 0.26),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct ProgressTrack: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - 剧集卡片与选集面板

private struct SeriesCard: View {
    let group: LibraryGroup
    let thumbnail: NSImage?
    let progress: Double
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    ThumbBackground(thumbnail: thumbnail, seed: group.id)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(hovering ? 0.22 : 0.08), lineWidth: 0.5)
                        )
                    if progress > 0.02 {
                        ProgressTrack(progress: progress)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 7)
                    }
                    Text("\(group.items.count) 集")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.5)))
                        .padding(7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                Text(group.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(group.subtitle ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.015 : 1.0)
        .animation(.lumiStandard, value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct EpisodeSheet: View {
    let group: LibraryGroup
    @ObservedObject var library: MediaLibrary
    let onPlay: (LibraryItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.system(size: 18, weight: .bold))
                    if let subtitle = group.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding(20)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        EpisodeRow(
                            label: episodeLabel(index: index, item: item),
                            item: item,
                            thumbnail: library.thumbnailImage(for: item),
                            progress: library.record(forPath: item.id)?.progress ?? 0
                        ) {
                            onPlay(item)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 580, height: 480)
    }

    private func episodeLabel(index: Int, item: LibraryItem) -> String {
        if let info = parseEpisodeInfo(from: item.name) {
            return "E" + String(format: "%02d", info.episode)
        }
        return "#\(index + 1)"
    }
}

private struct EpisodeRow: View {
    let label: String
    let item: LibraryItem
    let thumbnail: NSImage?
    let progress: Double
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle().fill(Color.primary.opacity(0.06))
                            Image(systemName: "film")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.metaText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if progress > 0.02 {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressTrack(progress: progress)
                            .frame(width: 72)
                        Text(progress >= 0.98 ? "已看完" : "已看 \(Int(progress * 100))%")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                } else if hovering {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
