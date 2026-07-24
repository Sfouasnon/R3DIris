//  MJPEGStreamReader.swift — R3DIris
//  Reads the camera's documented livestream: multipart-HTTP JPEG on port 9090
//  (RCP2_LIVESTREAM_NOTES.md). Plain HTTP — completely separate from the RCP2
//  WebSocket on 9998, so no session-slot cost (field notes rule 1 unaffected).
//
//  Parsing strategy: instead of trusting an undocumented multipart boundary
//  format, scan the byte stream for JPEG SOI (FF D8) … EOI (FF D9) markers and
//  decode each complete JPEG. The first response's headers and the first part's
//  preamble are logged verbatim so the bench documents the actual boundary
//  format (bench checklist step 2).

import Foundation
import CoreGraphics
import ImageIO

@MainActor
final class MJPEGStreamReader: NSObject, ObservableObject {
    struct Stats: Equatable {
        var frames = 0
        var fps: Double = 0
        var bytesPerSecond: Double = 0
        var width = 0
        var height = 0
        var lastFrameAt: Date? = nil
    }

    @Published private(set) var frame: CGImage?
    @Published private(set) var stats = Stats()
    @Published private(set) var isStreaming = false
    @Published private(set) var lastError: String = ""
    /// Changes on every stop/start boundary. Bench capture preflight freezes this
    /// token so metadata from one camera can never be paired with a replacement
    /// stream generation.
    private(set) var generation: UInt64 = 0

    var onLog: ((String) -> Void)?
    /// Called on the main actor for every decoded frame — the analysis hook
    /// (CameraNode throttles; do NOT do heavy work synchronously in here).
    var onFrame: ((CGImage) -> Void)?
    /// Called on the main actor for every exact SOI…EOI JPEG payload before
    /// display-side freshest-frame dropping or ImageIO decoding. Bench
    /// validation uses this to preserve the untouched port-9090 evidence.
    /// The callback must only enqueue/copy the payload; never analyze or write
    /// it synchronously on the stream's main-actor receive path.
    var onJPEG: ((Data, Date) -> Void)?
    /// Decode only the newest buffered frame per callback (drop stale ones) to
    /// keep display latency from creeping. Set by ArrayController.
    var dropToLatestFrame = true
    /// Local decode throttle. The HTTP reader still parses and timestamps every
    /// complete JPEG so transport health remains accurate, but background array
    /// cameras do not need to rasterize every 1920×1080 frame while one camera is
    /// receiving the operator's attention. Zero preserves the full-rate path.
    var minimumDecodeInterval: TimeInterval = 0

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var headerLogged = false
    private var preambleLogged = false
    private var firstFrameLogged = false
    private var frameTimes: [Date] = []
    private var byteWindow: [(Date, Int)] = []
    private var lastDecodeAt = Date.distantPast
    private var logHandshakeDetails = true

    func start(ip: String, logHandshake: Bool = true) {
        stop(log: false)
        generation &+= 1
        guard let url = URL(string: "http://\(ip):\(RCP2.livestreamPort)/") else {
            lastError = "bad URL"
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10          // time to FIRST byte
        config.timeoutIntervalForResource = .infinity  // stream runs until stopped
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        buffer.removeAll()
        headerLogged = false
        preambleLogged = false
        firstFrameLogged = false
        frameTimes.removeAll()
        byteWindow.removeAll()
        lastDecodeAt = .distantPast
        logHandshakeDetails = logHandshake
        stats = Stats()
        lastError = ""
        isStreaming = true
        if logHandshake {
            onLog?("livestream: GET \(url.absoluteString)")
        }
        let task = session.dataTask(with: url)
        self.task = task
        task.resume()
    }

    func stop(log: Bool = true) {
        generation &+= 1
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if log, isStreaming {
            onLog?("livestream: stopped (\(stats.frames) frames)")
        }
        isStreaming = false
    }

    // MARK: - JPEG extraction

    private func consume(_ data: Data, receivedAt: Date) {
        buffer.append(data)
        let now = receivedAt
        byteWindow.append((now, data.count))
        byteWindow.removeAll { now.timeIntervalSince($0.0) > 3 }
        let windowBytes = byteWindow.reduce(0) { $0 + $1.1 }
        if let oldest = byteWindow.first?.0 {
            let span = max(now.timeIntervalSince(oldest), 0.25)
            stats.bytesPerSecond = Double(windowBytes) / span
        }

        // Bench: log the first part's preamble (boundary + part headers) once.
        if logHandshakeDetails, !preambleLogged, let soi = firstSOI(in: buffer) {
            preambleLogged = true
            let preamble = buffer.prefix(min(soi, 512))
            let text = String(data: preamble, encoding: .ascii)?
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n ") ?? "<non-ascii>"
            onLog?("livestream: part preamble before first JPEG: \(text)")
        }

        // Freshest-frame: when frames have backed up, decode only the newest and
        // drop the stale ones undecoded — keeps display latency from creeping and
        // cuts main-thread decode load. Every arrival is still counted for the fps
        // stat and the stall watchdog. With freshest-frame dropping off, a zero
        // decode interval preserves the original decode-every-frame behavior.
        var latest: Data? = nil
        while let jpeg = extractNextJPEG() {
            // URLSession timestamps bytes by delegate chunk before the MainActor
            // hop. If one chunk completes multiple JPEGs, they intentionally
            // share that chunk-arrival timestamp.
            onJPEG?(jpeg, receivedAt)
            recordArrival(at: receivedAt)
            // A decode throttle necessarily keeps only the newest payload even
            // when the operator disabled general freshest-frame dropping.
            if dropToLatestFrame || minimumDecodeInterval > 0 {
                latest = jpeg
            } else {
                decode(jpeg)
            }
        }
        if let latest,
           minimumDecodeInterval <= 0
            || now.timeIntervalSince(lastDecodeAt) >= minimumDecodeInterval {
            lastDecodeAt = now
            decode(latest)
        }
        // Safety: a stream that never yields SOI must not grow unbounded.
        if buffer.count > 32 * 1024 * 1024 {
            onLog?("livestream: 32MB buffered without a complete JPEG — resetting buffer")
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func firstSOI(in data: Data) -> Data.Index? {
        data.firstRange(of: Data([0xFF, 0xD8, 0xFF]))?.lowerBound
    }

    /// Pull one complete SOI…EOI JPEG out of the buffer, discarding any
    /// inter-part bytes before it. Returns nil when no complete frame remains.
    /// Index-safe: always works from buffer.startIndex, never assumes 0-based.
    private func extractNextJPEG() -> Data? {
        guard let start = firstSOI(in: buffer) else {
            // No SOI at all — keep only a small tail (a marker could straddle chunks).
            if buffer.count > 4096 { buffer.removeFirst(buffer.count - 4096) }
            return nil
        }
        if start > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<start)
        }
        guard let eoi = buffer.firstRange(of: Data([0xFF, 0xD9])) else { return nil }
        let jpeg = Data(buffer[buffer.startIndex..<eoi.upperBound])
        buffer.removeSubrange(buffer.startIndex..<eoi.upperBound)
        return jpeg
    }

    /// Count a received frame — fps and the stall watchdog reflect the true
    /// stream rate even when freshest-frame drops some before decode.
    private func recordArrival(at now: Date) {
        stats.frames += 1
        stats.lastFrameAt = now
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 3 }
        if frameTimes.count >= 2, let first = frameTimes.first {
            stats.fps = Double(frameTimes.count - 1) / max(now.timeIntervalSince(first), 0.01)
        }
    }

    private func decode(_ jpeg: Data) {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            onLog?("livestream: JPEG decode failed (\(jpeg.count) bytes)")
            return
        }
        frame = img
        stats.width = img.width
        stats.height = img.height
        if logHandshakeDetails, !firstFrameLogged {
            firstFrameLogged = true
            onLog?("livestream: first frame \(img.width)×\(img.height), \(jpeg.count) bytes")
        }
        onFrame?(img)
    }
}

// MARK: - URLSessionDataDelegate

extension MJPEGStreamReader: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.allow)
        Task { @MainActor in
            guard self.session === session, self.task === dataTask else { return }
            guard self.logHandshakeDetails, !self.headerLogged else { return }
            self.headerLogged = true
            if let http = response as? HTTPURLResponse {
                let headers = http.allHeaderFields
                    .map { "\($0.key): \($0.value)" }
                    .sorted()
                    .joined(separator: " | ")
                self.onLog?("livestream: HTTP \(http.statusCode) — \(headers)")
            } else {
                self.onLog?("livestream: response \(response)")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let receivedAt = Date()
        Task { @MainActor in
            guard self.session === session, self.task === dataTask else { return }
            self.consume(data, receivedAt: receivedAt)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            guard self.session === session, self.task === task else { return }
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.lastError = error.localizedDescription
                self.onLog?("livestream: ended with error — \(error.localizedDescription)")
            }
            session.finishTasksAndInvalidate()
            self.task = nil
            self.session = nil
            self.isStreaming = false
        }
    }
}
