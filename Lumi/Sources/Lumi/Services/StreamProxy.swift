import Foundation
import Network

/// 本地流代理：把播放器的请求转发给百度 CDN，并补上百度要求的两个条件：
///   1) URL 上带 access_token（BaiduProvider.playableURL 已拼接）
///   2) 请求头带 User-Agent: pan.baidu.com
/// 播放器（AVPlayer / Infuse / mpv）自己不会加这些，直连会 403（error_code 31045）。
final class StreamProxy: NSObject {
    private var listener: NWListener?
    private var connections: [ProxyConnection] = []
    private let queue = DispatchQueue(label: "com.lumi.streamproxy")
    private var upstreamURL: URL?
    private(set) var port: UInt16 = 0

    var streamURL: URL? {
        guard port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/stream")
    }

    func start(upstream: URL) async throws -> UInt16 {
        stop()
        upstreamURL = upstream
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            guard let self, let upstream = self.upstreamURL else { conn.cancel(); return }
            let pc = ProxyConnection(connection: conn, upstream: upstream, queue: self.queue)
            pc.onFinish = { [weak self] finished in
                guard let self else { return }
                self.connections.removeAll { $0 === finished }
            }
            self.connections.append(pc)
            pc.start()
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.port = port
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        port = 0
        upstreamURL = nil
    }
}

/// 单条连接：解析最小 HTTP 请求 → 转发（补 UA）→ 流式回写。
final class ProxyConnection: NSObject, URLSessionDataDelegate {
    private let connection: NWConnection
    private let upstream: URL
    private let queue: DispatchQueue
    private var requestBuffer = Data()
    private var task: URLSessionDataTask?
    private var isHeadRequest = false
    private var finished = false
    private var suspended = false
    private var inflight = 0
    private let lock = NSLock()
    var onFinish: ((ProxyConnection) -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()

    init(connection: NWConnection, upstream: URL, queue: DispatchQueue) {
        self.connection = connection
        self.upstream = upstream
        self.queue = queue
        super.init()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest()
    }

    private func readRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.requestBuffer.append(data)
                if let headerEnd = self.requestBuffer.range(of: Data([13, 10, 13, 10])) {
                    let header = String(decoding: self.requestBuffer[..<headerEnd.lowerBound], as: UTF8.self)
                    self.forward(header: header)
                    return
                }
                if self.requestBuffer.count > 64 * 1024 {
                    self.finish()
                    return
                }
            }
            if isComplete || error != nil {
                self.finish()
                return
            }
            self.readRequest()
        }
    }

    private func forward(header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? "GET / HTTP/1.1"
        let method = firstLine.components(separatedBy: " ").first ?? "GET"
        isHeadRequest = (method == "HEAD")

        var range: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            range = String(line.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces)
        }

        var req = URLRequest(url: upstream)
        req.httpMethod = method
        req.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        if let range {
            req.setValue(range, forHTTPHeaderField: "Range")
        }
        req.timeoutInterval = 60
        let t = session.dataTask(with: req)
        task = t
        t.resume()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish()
            return
        }
        var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
        let passthrough: Set<String> = [
            "content-type", "content-length", "content-range",
            "accept-ranges", "etag", "last-modified",
        ]
        for (key, value) in http.allHeaderFields {
            let name = "\(key)"
            if passthrough.contains(name.lowercased()) {
                head += "\(name): \(value)\r\n"
            }
        }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        if isHeadRequest {
            completionHandler(.cancel)
            connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.finish()
            })
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        inflight += data.count
        let overHighWater = inflight > 8 * 1024 * 1024
        lock.unlock()
        if overHighWater && !suspended {
            suspended = true
            task?.suspend()
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.inflight -= data.count
            let underLowWater = self.inflight < 4 * 1024 * 1024
            self.lock.unlock()
            if underLowWater && self.suspended {
                self.suspended = false
                self.task?.resume()
            }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    func cancel() {
        task?.cancel()
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        session.invalidateAndCancel()
        onFinish?(self)
    }
}
