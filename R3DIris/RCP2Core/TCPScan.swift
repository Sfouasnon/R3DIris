//  TCPScan.swift — R3DIris / RCP2Core
//  Ported UNCHANGED from REDConductorV3's RCP2/TCPScan.swift (read-only
//  reference — divergences must be deliberate and bench-justified).
//
//  Subnet TCP-connect discovery — the method V1/V2.1 shipped and that reliably
//  finds cameras on the array network. A bare TCP connect to the RCP2 port
//  (9998), immediately closed, does NOT upgrade to a WebSocket and therefore
//  spends NO RCP session slot (field notes rule 2/15 concern is WS probes, not
//  plain TCP connects). PRIMARY discovery; UDP CAMINFO is fallback.

import Foundation
import Network

enum Subnet {
    /// Expand a subnet string into candidate host IPs. Accepts:
    ///   "172.20.114.0/24"  (CIDR)
    ///   "172.20.114.0"     (bare address -> assumes /24)
    ///   "172.20.114"       (shorthand   -> assumes /24, missing octet = 0)
    /// `cap` bounds the count so a wide mask (e.g. link-local /16) can't spawn a
    /// 65k-host sweep — only the first `cap` usable hosts are returned.
    static func hosts(from raw: String, cap: Int = 2048) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        var addr = text
        var prefix = 24
        if let slash = text.firstIndex(of: "/") {
            addr = String(text[..<slash])
            prefix = Int(text[text.index(after: slash)...]) ?? 24
        }
        var octets = addr.split(separator: ".", omittingEmptySubsequences: false).map { UInt32($0) ?? UInt32.max }
        while octets.count < 4 { octets.append(0) }   // "172.20.114" -> 172.20.114.0
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return [] }
        prefix = max(0, min(32, prefix))
        let base = octets.reduce(UInt32(0)) { ($0 << 8) | $1 }
        let hostBits = 32 - prefix
        if hostBits == 0 { return [ipString(base)] }
        let mask: UInt32 = hostBits >= 32 ? 0 : ~UInt32(0) << UInt32(hostBits)
        let network = base & mask
        let total: UInt64 = hostBits >= 32 ? (UInt64(1) << 32) : (UInt64(1) << UInt64(hostBits))
        // Exclude network + broadcast addresses for normal masks (/31,/32 keep all).
        let first: UInt64 = prefix < 31 ? 1 : 0
        let last: UInt64 = prefix < 31 ? total - 1 : total
        var result: [String] = []
        var i = first
        while i < last && result.count < cap {
            result.append(ipString(network | UInt32(i)))
            i += 1
        }
        return result
    }

    static func ipString(_ v: UInt32) -> String {
        "\((v >> 24) & 255).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
    }
}

enum TCPScan {
    /// TCP-connect every host in `cidr` on `port`; return the ones that accept.
    /// `skip` excludes already-connected bodies (rule 2 — never touch a live one).
    static func discover(cidr: String, port: UInt16 = 9998, sourceIP: String? = nil,
                         skip: Set<String> = [], timeout: TimeInterval = 0.6,
                         maxConcurrent: Int = 64) async -> [DiscoveredCamera] {
        let hosts = Subnet.hosts(from: cidr).filter { !skip.contains($0) }
        guard !hosts.isEmpty else { return [] }
        var found: [String] = []
        await withTaskGroup(of: String?.self) { group in
            var next = 0
            func launch() {
                guard next < hosts.count else { return }
                let host = hosts[next]; next += 1
                group.addTask {
                    await probe(host: host, port: port, sourceIP: sourceIP, timeout: timeout) ? host : nil
                }
            }
            for _ in 0..<min(maxConcurrent, hosts.count) { launch() }
            while let result = await group.next() {
                if let result { found.append(result) }
                launch()
            }
        }
        return found.sorted { ipKey($0) < ipKey($1) }.map { DiscoveredCamera(ip: $0, fields: []) }
    }

    /// One TCP connect with a hard timeout. `.ready` = port open (camera present).
    /// `.waiting` = refused/unreachable → not open. Never upgrades to WebSocket.
    private static func probe(host: String, port: UInt16, sourceIP: String?, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 2
        let params = NWParameters(tls: nil, tcp: tcp)
        if let sourceIP, !sourceIP.isEmpty {
            params.requiredLocalEndpoint = .hostPort(host: .init(sourceIP), port: .any)
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        // Per-connection serial queue: stateUpdateHandler and the timeout closure
        // never race, so a single resume flag suffices. DIVERGENCE from the V3
        // original (deliberate, compiler-driven): the flag lives in an
        // @unchecked Sendable box and `finish` is @Sendable so Swift 6 accepts
        // the capture — the serial queue is still what makes it safe.
        let q = DispatchQueue(label: "rcp2.tcpscan.\(host)")
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let state = ResumeState()
            @Sendable func finish(_ ok: Bool) {
                if state.done { return }
                state.done = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:               finish(true)
                case .failed, .cancelled:  finish(false)
                case .waiting:             finish(false)   // ECONNREFUSED / no route
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Single-resume flag for `probe` — mutation is confined to the probe's
    /// per-connection serial queue; @unchecked Sendable documents that the
    /// queue, not the type, provides the safety.
    private final class ResumeState: @unchecked Sendable { var done = false }

    private static func ipKey(_ ip: String) -> UInt32 {
        let p = ip.split(separator: ".").compactMap { UInt8($0) }
        return p.count == 4 ? p.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } : .max
    }
}
