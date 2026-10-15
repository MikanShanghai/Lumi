import Foundation
import AetherEngine
import CoreGraphics
import ImageIO

// 诊断小工具：验证「探测 + 抽帧」在某个 URL 上是否可用。
// 用法：swift run LumiProbe <url> [seconds]
// 例：  swift run LumiProbe "http://127.0.0.1:8787/stream" 5

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else {
    print("用法: LumiProbe <url> [seconds]")
    exit(1)
}
let url: URL
if first.contains("://"), let parsed = URL(string: first) {
    url = parsed
} else {
    url = URL(fileURLWithPath: first)
}
let seconds = Double(args.dropFirst().first ?? "") ?? 5
let useUA = args.contains("--ua")
let headers: [String: String] = useUA ? ["User-Agent": "pan.baidu.com"] : [:]

print("[LumiProbe] url = \(url.absoluteString.prefix(140))")

let sem = DispatchSemaphore(value: 0)
Task.detached {
    do {
        let probe = try AetherEngine.probe(url: url, options: LoadOptions(httpHeaders: headers))
        print("  probe OK: duration=\(String(format: "%.1f", probe.durationSeconds))s codec=\(probe.videoCodecName ?? "?") \(probe.videoWidth)x\(probe.videoHeight)")
    } catch {
        print("  probe 失败: \(error)")
    }

    let extractor = FrameExtractor(url: url, httpHeaders: headers)
    let started = Date()
    if let image = await extractor.thumbnail(at: seconds, maxWidth: 480) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("  抽帧 OK: \(image.width)x\(image.height)，用时 \(ms)ms")
        let out = URL(fileURLWithPath: "/tmp/lumi-probe.jpg")
        if let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            if CGImageDestinationFinalize(dest) { print("  已保存: \(out.path)") }
        }
    } else {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("  抽帧失败（用时 \(ms)ms）")
    }
    sem.signal()
}
sem.wait()
