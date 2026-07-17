//  UDPDiscovery.swift — R3DIris / RCP2Core
//  Ported UNCHANGED from REDConductorV3's RCP2/UDPDiscovery.swift (read-only
//  reference — divergences must be deliberate and bench-justified).
//
//  RCP-native camera discovery over UDP port 1112 (RCP2_FIELD_NOTES.md rule 15).
//
//  Wire format (from RCP SDK v6.62.0 rcp_parser2.c, verified in V2.1 production):
//      '#' + "$API:G:CAMINFO:" + '*' + XX + '\n'
//  where XX is the uppercase-hex XOR of every byte between '#' and '*'.
//
//  Why this matters: probing a camera over WebSocket SPENDS one of its ~8
//  session slots per probe; a UDP datagram spends nothing. All rescans and
//  parked-camera revives go through here — never through WS probes.

import Foundation
import Darwin

struct DiscoveredCamera: Sendable, Identifiable {
    let ip: String
    let fields: [String]
    var id: String { ip }

    var firmware: String {
        fields.first { $0.range(of: #"^\d+\.\d+(\.\d+)*$"#, options: .regularExpression) != nil } ?? ""
    }

    var label: String {
        fields.first {
            !$0.isEmpty && $0.count <= 24
                && $0.range(of: #"^\d+\.\d+(\.\d+)*$"#, options: .regularExpression) == nil
                && Int($0) == nil
        } ?? ""
    }
}

enum UDPDiscovery {
    static let port: UInt16 = 1112

    static func buildPacket() -> Data {
        let body = Array("$API:G:CAMINFO:".utf8)
        let checksum = body.reduce(UInt8(0)) { $0 ^ $1 }
        var packet = Data([UInt8(ascii: "#")])
        packet.append(contentsOf: body)
        packet.append(contentsOf: Array(String(format: "*%02X\n", checksum).utf8))
        return packet
    }

    /// Parse a CAMINFO reply into its token fields (tokens after "CAMINFO",
    /// honoring backslash escapes), or nil if it isn't a CAMINFO datagram.
    static func parseCAMINFO(_ data: Data) -> [String]? {
        guard var text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            text.hasPrefix("#"), text.contains("CAMINFO") else { return nil }
        text.removeFirst()
        if let star = text.lastIndex(of: "*") {
            text = String(text[..<star])
        }
        var tokens: [String] = []
        var current = ""
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == ":" {
                tokens.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        tokens.append(current)
        guard let idx = tokens.firstIndex(of: "CAMINFO") else { return nil }
        return tokens[(idx + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Broadcast (and unicast to `targets`, for broadcast-blocked networks) the
    /// CAMINFO request; collect replies for `timeout` seconds total.
    /// Never throws — a network error just returns what was heard.
    static func discover(timeout: TimeInterval = 1.5, rounds: Int = 3,
                         targets: [String] = [], sourceIP: String? = nil) async -> [DiscoveredCamera] {
        let packet = buildPacket()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: blockingDiscover(
                    packet: packet, timeout: timeout, rounds: max(1, rounds),
                    targets: targets, sourceIP: sourceIP))
            }
        }
    }

    // MARK: - Blocking BSD-socket implementation (runs off the main thread)

    private static func blockingDiscover(packet: Data, timeout: TimeInterval, rounds: Int,
                                         targets: [String], sourceIP: String?) -> [DiscoveredCamera] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Short receive timeout so the collect loop can interleave resends.
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = sourceIP.flatMap { $0.isEmpty ? nil : inet_addr($0) } ?? INADDR_ANY
        let bindResult = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return [] }

        func send(to ip: String) {
            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = port.bigEndian
            dest.sin_addr.s_addr = inet_addr(ip)
            packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                _ = withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var results: [String: [String]] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        let resendInterval = timeout / Double(rounds)
        var nextSend = Date.distantPast

        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            if Date() >= nextSend {
                nextSend = Date().addingTimeInterval(resendInterval)
                send(to: "255.255.255.255")
                for ip in targets { send(to: ip) }
            }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen)
                }
            }
            guard received > 0 else { continue }   // timeout tick or error — loop
            var addrCopy = from.sin_addr
            var ipChars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addrCopy, &ipChars, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: ipChars)
            if let fields = parseCAMINFO(Data(buffer[0..<received])) {
                results[ip] = fields
            }
        }
        return results.map { DiscoveredCamera(ip: $0.key, fields: $0.value) }
            .sorted { $0.ip < $1.ip }
    }
}
