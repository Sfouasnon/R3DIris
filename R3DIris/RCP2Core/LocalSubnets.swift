//  LocalSubnets.swift — R3DIris / RCP2Core
//  Zero-config discovery: enumerate this Mac's IPv4 interfaces and derive
//  the subnets worth sweeping, so Detect Cameras works with an EMPTY subnet
//  field the way RED Control Pro does — the operator never types network
//  numbers unless the auto-detected sweep comes up dry (manual entry stays
//  as the override for routed/odd topologies).

import Foundation
import Darwin

struct DetectedSubnet: Sendable, Equatable, Identifiable {
    let interface: String     // e.g. "en0"
    let address: String       // this host's IPv4 on that interface
    let cidr: String          // sweepable "a.b.c.d/p"
    var id: String { "\(interface) \(cidr)" }

    var hostCount: Int { Subnet.hosts(from: cidr).count }
}

enum LocalSubnets {
    /// IPv4 subnets on active interfaces, deduplicated, ordered:
    /// real NICs first (en*/bridge*/utun excluded-last), loopback only when
    /// extra 127.x aliases exist (that's the sim array — real setups never
    /// sweep loopback).
    ///
    /// Wide masks are clamped to a /24 around this host: a corporate /16
    /// would blow the sweep cap and stall discovery; the /24 around our own
    /// address is where an array subnet's cameras live in practice. The
    /// clamp is logged by the caller so a cross-/24 array is diagnosable.
    static func detect() -> [DetectedSubnet] {
        var results: [DetectedSubnet] = []
        var loopbackAddrs: [String] = []

        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return [] }
        defer { freeifaddrs(ifaddrsPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  let addrPtr = entry.pointee.ifa_addr,
                  addrPtr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            let addr = ipv4String(addrPtr)
            guard let addr else { continue }

            if (flags & IFF_LOOPBACK) != 0 {
                loopbackAddrs.append(addr)
                continue
            }
            guard let maskPtr = entry.pointee.ifa_netmask,
                  let mask = ipv4String(maskPtr) else { continue }

            let prefix = prefixLength(ofMask: mask)
            // Clamp wide masks to the /24 around this host (see doc comment).
            let usablePrefix = max(prefix, 24)
            guard let cidr = network(of: addr, prefix: usablePrefix) else { continue }
            let subnet = DetectedSubnet(interface: name, address: addr, cidr: cidr)
            if !results.contains(where: { $0.cidr == subnet.cidr }) {
                results.append(subnet)
            }
        }

        // Loopback: only interesting when the sim array's aliases exist
        // (127.0.0.1 alone is every Mac; >1 address means setup_loopback ran).
        if loopbackAddrs.count > 1 {
            results.append(DetectedSubnet(interface: "lo0",
                                          address: loopbackAddrs.first ?? "127.0.0.1",
                                          cidr: "127.0.0.0/24"))
        }
        return results
    }

    /// Every IPv4 address assigned to this Mac (loopback included) — used to
    /// validate the operator's source-IP entry: binding a sweep to an address
    /// this machine doesn't own fails every probe SILENTLY (bench finding
    /// 2026-07-17: "127.0.0.0" in the source field zeroed a sweep that should
    /// have found the sim).
    static func ownIPv4Addresses() -> [String] {
        var results: [String] = []
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return [] }
        defer { freeifaddrs(ifaddrsPtr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard (Int32(entry.pointee.ifa_flags) & IFF_UP) != 0,
                  let addrPtr = entry.pointee.ifa_addr,
                  addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let addr = ipv4String(addrPtr) else { continue }
            if !results.contains(addr) { results.append(addr) }
        }
        return results
    }

    private static func ipv4String(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    private static func prefixLength(ofMask mask: String) -> Int {
        let octets = mask.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return 24 }
        return octets.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    private static func network(of address: String, prefix: Int) -> String? {
        let octets = address.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, (0...32).contains(prefix) else { return nil }
        let value = octets.reduce(UInt32(0)) { ($0 << 8) | $1 }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        return "\(Subnet.ipString(value & mask))/\(prefix)"
    }
}
