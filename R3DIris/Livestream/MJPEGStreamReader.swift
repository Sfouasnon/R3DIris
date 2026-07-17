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

    var onLog: ((String) -> Void)?
    /// Called on the main actor for every decoded frame — the analysis hook
    /// (CameraNode throttles; do NOT do heavy work synchronously in here).
    var onFrame: ((CGImage) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var headerLogged = false
    private var preambleLogged = false
    private var frameTimes: [Date] = []
    private var byteWindow: [(Date, Int)] = []

    func start(ip: String) {
        stop()
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
        frameTimes.removeAll()
        byteWindow.removeAll()
        stats = Stats()
        lastError = ""
        isStreaming = true
        onLog?("livestream: GET \(url.absoluteString)")
        let task = session.dataTask(with: url)
        self.task = task
        task.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if isStreaming {
            onLog?("livestream: stopped (\(stats.frames) frames)")
        }
        isStreaming = false
    }

    // MARK: - JPEG extraction

    private func consume(_ data: Data) {
        buffer.append(data)
        let now = Date()
        byteWindow.append((now, data.count))
        byteWindow.removeAll { now.timeIntervalSince($0.0) > 3 }
        let windowBytes = byteWindow.reduce(0) { $0 + $1.1 }
        if let oldest = byteWindow.first?.0 {
            let span = max(now.timeIntervalSince(oldest), 0.25)
            stats.bytesPerSecond = Double(windowBytes) / span
        }

        // Bench: log the first part's preamble (boundary + part headers) once.
        if !preambleLogged, let soi = firstSOI(in: buffer) {
            preambleLogged = true
            let preamble = buffer.prefix(min(soi, 512))
            let text = String(data: preamble, encoding: .ascii)?
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n ") ?? "<non-ascii>"
            onLog?("livestream: part preamble before first JPEG: \(text)")
        }

        while let jpeg = extractNextJPEG() {
            decode(jpeg)
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

    private func decode(_ jpeg: Data) {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            onLog?("livestream: JPEG decode failed (\(jpeg.count) bytes)")
            return
        }
        let now = Date()
        frame = img
        stats.frames += 1
        stats.width = img.width
        stats.height = img.height
        stats.lastFrameAt = now
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 3 }
        if frameTimes.count >= 2, let first = frameTimes.first {
            stats.fps = Double(frameTimes.count - 1) / max(now.timeIntervalSince(first), 0.01)
        }
        if stats.frames == 1 {
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
            guard !self.headerLogged else { return }
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
        Task { @MainActor in
            self.consume(data)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error, (error as NSError).code != NSURLErrorCancelled {
                self.lastError = error.localizedDescription
                self.onLog?("livestream: ended with error — \(error.localizedDescription)")
            }
            self.isStreaming = false
        }
    }
}
