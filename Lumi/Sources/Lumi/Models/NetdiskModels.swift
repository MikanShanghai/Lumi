import Foundation

struct NetdiskFile: Identifiable, Decodable, Hashable {
    let fsId: Int64
    let path: String
    let serverFilename: String
    let size: Int64
    let isdir: Int
    let category: Int

    var id: Int64 { fsId }
    var isFolder: Bool { isdir == 1 }
    var isVideo: Bool { category == 1 && !isFolder }

    enum CodingKeys: String, CodingKey {
        case fsId = "fs_id"
        case path
        case serverFilename = "server_filename"
        case size, isdir, category
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

struct DeviceCodeInfo: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUrl: String
    let qrcodeUrl: String?
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUrl = "verification_url"
        case qrcodeUrl = "qrcode_url"
        case expiresIn = "expires_in"
        case interval
    }
}

struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case error
        case errorDescription = "error_description"
    }
}

struct FileMetasResponse: Decodable {
    let errno: Int
    let list: [FileMeta]?
}

struct FileMeta: Decodable {
    let fsId: Int64
    let dlink: String?

    enum CodingKeys: String, CodingKey {
        case fsId = "fs_id"
        case dlink
    }
}
