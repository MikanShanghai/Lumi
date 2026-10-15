import Foundation

enum LumiError: LocalizedError {
    case notConfigured
    case notLoggedIn
    case badURL
    case api(Int, String)
    case auth(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没有配置 AppKey / SecretKey"
        case .notLoggedIn: return "还没有连接百度网盘"
        case .badURL: return "地址无效"
        case .api(let code, let msg): return "网盘接口错误（errno=\(code)\(msg.isEmpty ? "" : "，\(msg)")）"
        case .auth(let msg): return msg
        }
    }
}

/// 百度网盘开放平台接入（对齐官方 xpan 接口，流程与 tools/baidu-smoke.mjs 完全一致）
@MainActor
final class BaiduProvider: ObservableObject {
    enum LoginState: Equatable {
        case disconnected
        case waitingCode
        case connected
    }

    @Published private(set) var loginState: LoginState = .disconnected
    @Published private(set) var deviceCode: DeviceCodeInfo?
    @Published private(set) var statusText = ""
    @Published var lastError: String?
    @Published private(set) var hasCredentials: Bool
    @Published private(set) var isVerifying = false
    @Published private(set) var verifyResult: String?

    private var credentials: ConfigStore.Credentials?
    private var token: ConfigStore.StoredToken?
    private var pollTask: Task<Void, Never>?

    init() {
        credentials = ConfigStore.loadCredentials()
        token = ConfigStore.loadToken()
        hasCredentials = credentials != nil
        if token != nil { loginState = .connected }
    }

    func saveCredentials(appKey: String, appSecret: String) {
        let creds = ConfigStore.Credentials(
            appKey: appKey.trimmingCharacters(in: .whitespacesAndNewlines),
            appSecret: appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !creds.appKey.isEmpty, !creds.appSecret.isEmpty else { return }
        ConfigStore.saveCredentials(creds)
        credentials = creds
        hasCredentials = true
    }

    func disconnect() {
        pollTask?.cancel()
        ConfigStore.clearToken()
        token = nil
        loginState = .disconnected
        deviceCode = nil
        statusText = ""
    }

    /// 保存凭证并验证是否可用：向开放平台请求一次设备码（不需要用户授权），
    /// 能拿到 device_code 就说明这对 AppKey/SecretKey 是有效的。
    func saveAndVerify(appKey: String, appSecret: String) async {
        saveCredentials(appKey: appKey, appSecret: appSecret)
        guard let creds = credentials else { return }
        isVerifying = true
        verifyResult = nil
        defer { isVerifying = false }

        struct Probe: Decodable {
            let deviceCode: String?
            let error: String?
            let errorDescription: String?
            enum CodingKeys: String, CodingKey {
                case deviceCode = "device_code"
                case error
                case errorDescription = "error_description"
            }
        }
        do {
            let url = try makeURL("https://openapi.baidu.com/oauth/2.0/device/code", [
                "response_type": "device_code",
                "client_id": creds.appKey,
                "scope": "basic,netdisk",
            ])
            var req = URLRequest(url: url)
            req.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: req)
            let probe = try JSONDecoder().decode(Probe.self, from: data)
            if probe.deviceCode != nil {
                verifyResult = "✓ 凭证有效，可以连接了"
            } else {
                verifyResult = "✗ " + (probe.errorDescription ?? probe.error ?? "凭证无效")
            }
        } catch {
            verifyResult = "✗ 验证失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 设备码授权

    func startDeviceLogin() async {
        guard let creds = credentials else {
            lastError = "请先填写 AppKey / SecretKey"
            return
        }
        do {
            let url = try makeURL("https://openapi.baidu.com/oauth/2.0/device/code", [
                "response_type": "device_code",
                "client_id": creds.appKey,
                "scope": "basic,netdisk",
            ])
            let info: DeviceCodeInfo = try await getJSON(url)
            deviceCode = info
            loginState = .waitingCode
            statusText = "等待你在浏览器中确认授权…"
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                await self?.pollToken(device: info, creds: creds)
            }
        } catch {
            lastError = "获取设备码失败：\(error.localizedDescription)"
        }
    }

    func cancelLogin() {
        pollTask?.cancel()
        pollTask = nil
        deviceCode = nil
        loginState = token == nil ? .disconnected : .connected
        statusText = ""
    }

    private func pollToken(device: DeviceCodeInfo, creds: ConfigStore.Credentials) async {
        let interval = max(2, device.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        while !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            if Task.isCancelled { return }
            do {
                let resp: TokenResponse = try await getJSON(
                    try makeURL("https://openapi.baidu.com/oauth/2.0/token", [
                        "grant_type": "device_token",
                        "code": device.deviceCode,
                        "client_id": creds.appKey,
                        "client_secret": creds.appSecret,
                    ])
                )
                if let access = resp.accessToken {
                    let stored = ConfigStore.StoredToken(
                        accessToken: access,
                        refreshToken: resp.refreshToken ?? "",
                        expiry: Date().addingTimeInterval(TimeInterval(resp.expiresIn ?? 2592000))
                    )
                    ConfigStore.saveToken(stored)
                    token = stored
                    deviceCode = nil
                    loginState = .connected
                    statusText = ""
                    return
                }
                if resp.error == "authorization_pending" { continue }
                lastError = resp.errorDescription ?? resp.error ?? "授权失败"
                loginState = .disconnected
                return
            } catch {
                statusText = "网络异常，重试中…"
            }
        }
        if loginState == .waitingCode {
            loginState = .disconnected
            lastError = "授权超时，请重试"
        }
    }

    // MARK: - 令牌

    private func ensureToken() async throws -> String {
        guard var current = token else { throw LumiError.notLoggedIn }
        if current.expiry.timeIntervalSinceNow > 60 { return current.accessToken }
        guard let creds = credentials else { throw LumiError.notConfigured }
        let resp: TokenResponse = try await getJSON(
            try makeURL("https://openapi.baidu.com/oauth/2.0/token", [
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": creds.appKey,
                "client_secret": creds.appSecret,
            ])
        )
        guard let access = resp.accessToken else {
            throw LumiError.auth("刷新令牌失败：" + (resp.errorDescription ?? "请重新登录"))
        }
        current = ConfigStore.StoredToken(
            accessToken: access,
            refreshToken: resp.refreshToken ?? current.refreshToken,
            expiry: Date().addingTimeInterval(TimeInterval(resp.expiresIn ?? 2592000))
        )
        ConfigStore.saveToken(current)
        token = current
        return access
    }

    // MARK: - 业务接口

    func listDirectory(_ dir: String) async throws -> [NetdiskFile] {
        let access = try await ensureToken()
        struct ListResponse: Decodable {
            let errno: Int
            let list: [NetdiskFile]?
        }
        let resp: ListResponse = try await getJSON(
            try makeURL("https://pan.baidu.com/rest/2.0/xpan/file", [
                "method": "list",
                "access_token": access,
                "dir": dir,
                "order": "name",
                "limit": "1000",
            ])
        )
        guard resp.errno == 0 else { throw LumiError.api(resp.errno, "") }
        return resp.list ?? []
    }

    /// 取可播放地址：dlink + access_token（必须）；请求头 UA 由 StreamProxy 负责。
    func playableURL(fsId: Int64) async throws -> URL {
        let access = try await ensureToken()
        let resp: FileMetasResponse = try await getJSON(
            try makeURL("https://pan.baidu.com/rest/2.0/xpan/multimedia", [
                "method": "filemetas",
                "dlink": "1",
                "access_token": access,
                "fsids": "[\(fsId)]",
            ])
        )
        guard resp.errno == 0,
              let dlink = resp.list?.first?.dlink,
              var comps = URLComponents(string: dlink) else {
            throw LumiError.api(resp.errno, "")
        }
        let hasToken = comps.queryItems?.contains { $0.name == "access_token" } ?? false
        if !hasToken {
            comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "access_token", value: access)]
        }
        guard let url = comps.url else { throw LumiError.badURL }
        return url
    }

    // MARK: - 网络

    /// 用 URLComponents 构造请求地址：每个参数只被编码一次。
    /// 注意：不要用 URL(string:) 拼接“已手工转义”的字符串——% 会被二次转义（%2E → %252E），
    /// 表现为列表能看、播放报 errno=-6（实测）。
    private func makeURL(_ base: String, _ items: [String: String]) throws -> URL {
        guard var comps = URLComponents(string: base) else { throw LumiError.badURL }
        comps.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw LumiError.badURL }
        return url
    }

    private func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
