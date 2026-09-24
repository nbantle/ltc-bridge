// Art-Net timecode output (ArtTimeCode, OpCode 0x9700) over UDP port 6454,
// sent once per frame to a broadcast or unicast IPv4 address.

import Foundation

struct NetworkInterface: Hashable, Identifiable {
    let name: String
    let address: String
    let broadcast: String
    var id: String { broadcast }
}

final class ArtNetOutput {
    private let socketFD: Int32
    private let lock = NSLock()
    private var target: sockaddr_in?

    init() {
        socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(socketFD) }

    /// Sets the destination IPv4 address (nil or invalid = off). Returns false if the address is invalid.
    @discardableResult
    func setTarget(_ ip: String?) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(6454).bigEndian
        let valid = ip.map { inet_pton(AF_INET, $0, &addr.sin_addr) == 1 } ?? false
        lock.lock(); target = valid ? addr : nil; lock.unlock()
        return valid || ip == nil
    }

    /// Called from the MTC clock thread at each frame boundary.
    func send(_ frames: [Timecode], rate: FrameRate?) {
        guard let rate = rate, let tc = frames.last else { return }
        lock.lock(); let dest = target; lock.unlock()
        guard var dest = dest else { return }
        var packet: [UInt8] = Array("Art-Net".utf8) + [0]
        packet += [0x00, 0x97,              // OpCode 0x9700, little-endian
                   0, 14,                   // protocol version 14
                   0, 0,                    // filler, stream ID
                   UInt8(tc.frames), UInt8(tc.seconds), UInt8(tc.minutes), UInt8(tc.hours),
                   rate.mtcCode]            // 0 film 24, 1 EBU 25, 2 DF 29.97, 3 SMPTE 30
        _ = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// IPv4 interfaces that are up and support broadcast (e.g. Ethernet, Wi-Fi, Dante NICs).
    static func interfaces() -> [NetworkInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [NetworkInterface] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  let bcast = ifa.ifa_dstaddr else { continue }
            func string(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var a = $0.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
                }
                return String(cString: buf)
            }
            result.append(NetworkInterface(name: String(cString: ifa.ifa_name), address: string(addr), broadcast: string(bcast)))
        }
        return result
    }
}
