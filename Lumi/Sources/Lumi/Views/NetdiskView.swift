import SwiftUI
import AppKit

struct NetdiskView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NetdiskContent(baidu: app.baidu, library: app.library)
            .environmentObject(app)
    }
}

struct NetdiskContent: View {
    @ObservedObject var baidu: BaiduProvider
    @ObservedObject var library: MediaLibrary
    @EnvironmentObject var app: AppModel

    @State private var currentPath = "/"
    @State private var files: [NetdiskFile] = []
    @State private var isLoading = false
    @State private var keyField = ""
    @State private var secretField = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !baidu.hasCredentials {
                credentialsForm
            } else if baidu.loginState == .waitingCode {
                waitingPanel
            } else if baidu.loginState == .disconnected {
                connectPanel
            } else {
                browser
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if baidu.loginState == .connected { await load(currentPath) }
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("百度网盘")
                .font(.system(size: 22, weight: .bold))
            if baidu.loginState == .connected {
                HStack(spacing: 6) {
                    Circle().fill(Theme.green).frame(width: 7, height: 7)
                    Text("已连接").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if baidu.loginState == .connected {
                Button {
                    Task { await load(currentPath) }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    // MARK: 未配置密钥

    private var credentialsForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("连接你的百度网盘")
                    .font(.system(size: 16, weight: .semibold))
                Text("Lumi 不接触你的账号密码。百度要求「每个应用只服务自己的开发者」，所以需要用你自己在开放平台注册的应用凭证来连接（配置一次，长期有效）。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    stepRow("1", "打开百度网盘开放平台并用百度账号登录；没注册过开发者就点「申请接入」→ 选「个人」（免费，几秒完成）")
                    stepRow("2", "控制台点「创建应用」：用途选「个人使用」、类型「软件」，分类随意，名称和描述填你喜欢的")
                    stepRow("3", "打开应用详情，复制 AppKey 与 SecretKey，粘贴到下面")
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )

                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "https://pan.baidu.com/union/console/applist") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("打开开放平台", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    Text("在浏览器里完成，然后回到这里")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField("粘贴 AppKey", text: $keyField)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 440)
                    SecureField("粘贴 SecretKey", text: $secretField)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 440)
                    HStack(spacing: 12) {
                        Button {
                            Task { await baidu.saveAndVerify(appKey: keyField, appSecret: secretField) }
                        } label: {
                            if baidu.isVerifying {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("验证中…")
                                }
                            } else {
                                Text("保存并验证")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(keyField.isEmpty || secretField.isEmpty || baidu.isVerifying)

                        if let result = baidu.verifyResult {
                            Text(result)
                                .font(.system(size: 12.5))
                                .foregroundStyle(result.hasPrefix("✓") ? Theme.green : Color.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("凭证只保存在本机：~/Library/Application Support/Lumi/config.json（权限 600），不会上传到任何地方。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
    }

    private func stepRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent))
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 等待授权

    private var waitingPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("在你的浏览器中完成授权")
                .font(.system(size: 15, weight: .semibold))
            if let code = baidu.deviceCode {
                HStack(spacing: 14) {
                    Text(code.userCode)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.userCode, forType: .string)
                    } label: {
                        Label("复制验证码", systemImage: "doc.on.doc")
                    }
                    Button {
                        if let url = URL(string: code.verificationUrl) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("打开授权页面", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
                Text("页面地址：" + code.verificationUrl)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(baidu.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("取消") { baidu.cancelLogin() }
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
    }

    // MARK: 未连接

    private var connectPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接后可直接播放你网盘里的视频，无需下载")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button {
                Task { await baidu.startDeviceLogin() }
            } label: {
                Label("连接百度网盘", systemImage: "link")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
    }

    // MARK: 文件浏览器

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
                .padding(.horizontal, 28)
                .padding(.bottom, 10)
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载中…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(files) { file in
                            FileRow(file: file, thumbnail: library.netdiskThumbnail(for: file.fsId)) {
                                if file.isFolder {
                                    Task { await load(file.path) }
                                } else if file.isVideo {
                                    Task { await app.playNetdisk(file) }
                                }
                            }
                        }
                        if files.isEmpty {
                            Text("这个文件夹是空的")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 40)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button("我的资源") { Task { await load("/") } }
                .buttonStyle(.link)
            ForEach(crumbs, id: \.path) { crumb in
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Button(crumb.name) { Task { await load(crumb.path) } }
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: 12.5))
    }

    private var crumbs: [(name: String, path: String)] {
        guard currentPath != "/" else { return [] }
        var result: [(String, String)] = []
        var built = ""
        for part in currentPath.split(separator: "/") {
            built += "/" + part
            result.append((String(part), built))
        }
        return result
    }

    private func load(_ path: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await baidu.listDirectory(path)
            files = list.sorted {
                if $0.isFolder != $1.isFolder { return $0.isFolder && !$1.isFolder }
                return $0.serverFilename.localizedStandardCompare($1.serverFilename) == .orderedAscending
            }
            currentPath = path
            generateMissingThumbnails(for: list)
        } catch {
            app.lastError = error.localizedDescription
        }
    }

    /// 顺序给本目录的视频补缩略图（有缓存会秒过），避免并发拉一堆 dlink。
    private func generateMissingThumbnails(for list: [NetdiskFile]) {
        let videos = list.filter { $0.isVideo }
        guard !videos.isEmpty else { return }
        Task {
            for file in videos {
                if Task.isCancelled { return }
                await app.ensureNetdiskThumbnail(fsId: file.fsId)
            }
        }
    }
}

private struct FileRow: View {
    let file: NetdiskFile
    let thumbnail: NSImage?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if file.isVideo, let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                            Image(systemName: file.isFolder ? "folder.fill" : (file.isVideo ? "film.fill" : "doc.fill"))
                                .font(.system(size: 14))
                                .foregroundStyle(
                                    file.isFolder
                                        ? AnyShapeStyle(Theme.accent.opacity(0.85))
                                        : AnyShapeStyle(.tertiary)
                                )
                        }
                    }
                }
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
                Text(file.serverFilename)
                    .font(.system(size: 13, weight: file.isVideo ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if file.isVideo || file.isFolder {
                    if hovering {
                        Image(systemName: file.isFolder ? "chevron.right" : "play.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(file.isFolder ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
                    }
                }
                if !file.isFolder {
                    Text(file.sizeText)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 76, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
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
