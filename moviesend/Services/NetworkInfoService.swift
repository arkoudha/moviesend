import Foundation
import Network

enum NetworkInfoService {
    /// Returns the device's mDNS hostname (e.g. "iPhone-of-User.local")
    static func getLocalHostname() -> String {
        let h = ProcessInfo.processInfo.hostName
        return h.hasSuffix(".local") ? h : "\(h).local"
    }

    static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET),
               let name = String(validatingUTF8: interface.ifa_name),
               name == "en0" {
                var addr = interface.ifa_addr.pointee
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
            }
            ptr = interface.ifa_next
        }
        return address
    }
}
