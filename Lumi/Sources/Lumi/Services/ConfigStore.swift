import Foundation

/// 本地配置与凭证存储。
/// - 应用配置：~/Library/Application Support/Lumi/config.json（AppKey/SecretKey）
/// - 令牌：~/Library/Application Support/Lumi/token.json
enum ConfigStore {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Lumi", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var configURL: URL { dir.appendingPathComponent("config.json") }
    static var tokenURL: URL { dir.appendingPathComponent("token.json") }

    struct Credentials: Codable {
        var appKey: String
        var appSecret: String
    }

    struct StoredToken: Codable {
        var accessToken: String
        var refreshToken: String
        var expiry: Date
    }

    static func loadCredentials() -> Credentials? {
        if let data = try? Data(contentsOf: configURL),
           let creds = try? JSONDecoder().decode(Credentials.self, from: data) {
            return creds
        }
        return nil
    }

    static func saveCredentials(_ creds: Credentials) {
        if let data = try? JSONEncoder().encode(creds) {
            try? data.write(to: configURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
    }

    static func loadToken() -> StoredToken? {
        if let data = try? Data(contentsOf: tokenURL),
           let t = try? JSONDecoder().decode(StoredToken.self, from: data) {
            return t
        }
        return nil
    }

    static func saveToken(_ t: StoredToken) {
        if let data = try? JSONEncoder().encode(t) {
            try? data.write(to: tokenURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        }
    }

    static func clearToken() {
        try? FileManager.default.removeItem(at: tokenURL)
    }
}
