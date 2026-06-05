import Foundation
import SystemConfiguration
import Network
import UserNotifications
import CoreWLAN
import CoreLocation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Settings keys / defaults

enum DefaultsKey {
    static let menuBarMode      = "menuBarMode"
    static let showLoopback     = "showLoopback"
    static let showLinkLocalV6  = "showLinkLocalV6"
    static let enablePublicIP   = "enablePublicIP"
    static let enableISP        = "enableISP"
    static let notifyOnIPChange = "notifyOnIPChange"
    static let refreshSeconds   = "refreshSeconds"
    static let showIPv6         = "showIPv6"
    static let showMAC          = "showMAC"
    static let showWiFiDetails  = "showWiFiDetails"
    static let history          = "ip_history"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            menuBarMode: MenuBarMode.icon.rawValue,
            showLoopback: false,
            showLinkLocalV6: false,
            enablePublicIP: true,
            enableISP: true,
            notifyOnIPChange: true,
            refreshSeconds: 0,
            showIPv6: true,
            showMAC: true,
            showWiFiDetails: true,
        ])
        // One-time migration: ensure ISP/country lookup is on by default.
        // (Previous releases shipped with enableISP defaulting to false.)
        let migKey = "migrated_isp_on_v1"
        if !UserDefaults.standard.bool(forKey: migKey) {
            UserDefaults.standard.set(true, forKey: enableISP)
            UserDefaults.standard.set(true, forKey: migKey)
        }
    }
}

enum MenuBarMode: String, CaseIterable, Sendable {
    case icon       // icon only
    case publicIP   // icon + public IP text
    case localIP    // icon + primary local IP text

    var label: String {
        switch self {
        case .icon:     return "Icon only"
        case .publicIP: return "Public IP"
        case .localIP:  return "Local IP"
        }
    }
}

// MARK: - C helpers

private func bufferToString(_ buffer: [CChar]) -> String {
    buffer.withUnsafeBufferPointer { ptr in
        ptr.baseAddress.map { String(cString: $0) } ?? ""
    }
}

// MARK: - Models

enum InterfaceKind: String, Sendable {
    case wifi, ethernet, cellular, vpn, loopback, other

    var symbol: String {
        switch self {
        case .wifi:      return "wifi"
        case .ethernet:  return "cable.connector"
        case .cellular:  return "antenna.radiowaves.left.and.right"
        case .vpn:       return "lock.shield.fill"
        case .loopback:  return "arrow.triangle.2.circlepath"
        case .other:     return "network"
        }
    }

    var rank: Int {
        switch self {
        case .wifi:      return 0
        case .ethernet:  return 1
        case .cellular:  return 2
        case .vpn:       return 3
        case .other:     return 4
        case .loopback:  return 5
        }
    }
}

struct NetworkInterface: Identifiable, Sendable, Equatable {
    let id: String
    let bsdName: String
    let displayName: String   // "HOME1 (en9)" or hardware name — used in summaries/history
    let hardwareName: String  // "AX88179B" or "Wi-Fi" — shown as main title in UI
    let serviceName: String?  // "HOME1" — user-defined name from System Settings (subtitle in UI)
    let kind: InterfaceKind
    var ipv4: [String]
    var ipv6: [String]            // global / unique-local
    var ipv6LinkLocal: [String]   // fe80::… (hidden unless user opts in)
    var subnetPrefix: Int?        // prefix length for the first IPv4
    var mac: String?
    var gateway: String?          // only set for the default-route interface
    var isPrimary: Bool           // is the default-route interface
    let isUp: Bool
    var wifi: WiFiDetails?        // populated for Wi-Fi interfaces

    init(bsdName: String, displayName: String, hardwareName: String = "",
         serviceName: String? = nil,
         kind: InterfaceKind,
         ipv4: [String], ipv6: [String], ipv6LinkLocal: [String] = [],
         subnetPrefix: Int? = nil, mac: String? = nil, gateway: String? = nil,
         isPrimary: Bool = false, isUp: Bool, wifi: WiFiDetails? = nil) {
        self.id = bsdName
        self.bsdName = bsdName
        self.displayName = displayName
        self.hardwareName = hardwareName.isEmpty ? bsdName : hardwareName
        self.serviceName = serviceName
        self.kind = kind
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.ipv6LinkLocal = ipv6LinkLocal
        self.subnetPrefix = subnetPrefix
        self.mac = mac
        self.gateway = gateway
        self.isPrimary = isPrimary
        self.isUp = isUp
        self.wifi = wifi
    }

    /// IPv4 is the headline; fall back to IPv6 only when there's no IPv4.
    var primaryIP: String? { ipv4.first ?? ipv6.first }

    var secondaryIPs: [String] {
        if ipv4.first != nil {
            return Array(ipv4.dropFirst()) + ipv6
        } else {
            return Array(ipv6.dropFirst())
        }
    }

    /// "192.168.1.5/24" when a prefix is known.
    var cidr: String? {
        guard let ip = ipv4.first else { return nil }
        guard let p = subnetPrefix else { return ip }
        return "\(ip)/\(p)"
    }

    /// Dotted netmask from the prefix length, e.g. 24 → "255.255.255.0".
    var subnetMask: String? {
        guard let p = subnetPrefix, (0...32).contains(p) else { return nil }
        let mask: UInt32 = p == 0 ? 0 : (~UInt32(0) << (32 - p))
        return "\((mask >> 24) & 0xFF).\((mask >> 16) & 0xFF).\((mask >> 8) & 0xFF).\(mask & 0xFF)"
    }
}

struct WiFiDetails: Sendable, Equatable {
    var ssid: String?
    var bssid: String?
    var rssi: Int?          // dBm, e.g. -44 (closer to 0 = stronger)
    var noise: Int?         // dBm
    var channel: Int?
    var band: String?       // "2.4 GHz" / "5 GHz" / "6 GHz"
    var width: String?      // "20 MHz" … "160 MHz"
    var txRate: Double?     // Mbps
    var security: String?   // "WPA2 Personal"
    var phyMode: String?    // "Wi-Fi 6 (ax)"

    /// Signal quality 0–4 bars from RSSI.
    var bars: Int {
        guard let r = rssi else { return 0 }
        switch r {
        case ..<(-80): return 1
        case ..<(-70): return 2
        case ..<(-60): return 3
        default:       return 4
        }
    }
    /// Signal-to-noise ratio in dB (higher is better).
    var snr: Int? {
        guard let r = rssi, let n = noise else { return nil }
        return r - n
    }
    /// Compact "ch 40 · 5 GHz · Wi-Fi 6 (ax)" descriptor.
    var channelLine: String {
        var parts: [String] = []
        if let c = channel { parts.append("ch \(c)") }
        if let b = band { parts.append(b) }
        if let p = phyMode { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}

enum WiFiScanner {
    /// CoreWLAN details for a Wi-Fi BSD interface (nil if it isn't an active Wi-Fi radio).
    static func details(for bsd: String) -> WiFiDetails? {
        let client = CWWiFiClient.shared()
        guard let i = client.interface(withName: bsd) ?? client.interface(),
              i.interfaceName != nil else { return nil }
        var d = WiFiDetails()
        d.ssid  = i.ssid()            // nil unless Location is authorized (macOS 14+)
        d.bssid = i.bssid()
        let rssi = i.rssiValue();           d.rssi  = rssi  != 0 ? rssi  : nil
        let noise = i.noiseMeasurement();   d.noise = noise != 0 ? noise : nil
        let tx = i.transmitRate();          d.txRate = tx > 0 ? tx : nil
        if let ch = i.wlanChannel() {
            d.channel = ch.channelNumber
            d.band  = bandName(ch.channelBand)
            d.width = widthName(ch.channelWidth)
        }
        d.security = securityName(i.security())
        d.phyMode  = phyModeName(i.activePHYMode())
        // Nothing meaningful → not actually on Wi-Fi.
        if d.rssi == nil && d.channel == nil && d.ssid == nil { return nil }
        return d
    }

    private static func bandName(_ b: CWChannelBand) -> String? {
        switch b {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default:        return nil
        }
    }
    private static func widthName(_ w: CWChannelWidth) -> String? {
        switch w {
        case .width20MHz:  return "20 MHz"
        case .width40MHz:  return "40 MHz"
        case .width80MHz:  return "80 MHz"
        case .width160MHz: return "160 MHz"
        default:           return nil
        }
    }
    private static func securityName(_ s: CWSecurity) -> String? {
        switch s {
        case .none:             return "Open"
        case .WEP, .dynamicWEP: return "WEP"
        case .wpaPersonal:      return "WPA Personal"
        case .wpaPersonalMixed: return "WPA/WPA2 Personal"
        case .wpa2Personal:     return "WPA2 Personal"
        case .wpa3Personal:     return "WPA3 Personal"
        case .wpa3Transition:   return "WPA2/WPA3 Personal"
        case .wpa2Enterprise:   return "WPA2 Enterprise"
        case .wpa3Enterprise:   return "WPA3 Enterprise"
        case .unknown:          return nil
        default:                return "Secured"
        }
    }
    private static func phyModeName(_ m: CWPHYMode) -> String? {
        switch m {
        case .mode11a:  return "Wi-Fi a"
        case .mode11b:  return "Wi-Fi b"
        case .mode11g:  return "Wi-Fi g"
        case .mode11n:  return "Wi-Fi 4 (n)"
        case .mode11ac: return "Wi-Fi 5 (ac)"
        case .mode11ax: return "Wi-Fi 6 (ax)"
        default:        return nil
        }
    }
}

// MARK: - Location (required for Wi-Fi SSID on macOS 14+)

extension Notification.Name {
    /// Posted when Location access becomes authorized (so Wi-Fi SSID can be read).
    static let locationAuthorized = Notification.Name("IPBarLocationAuthorized")
}

@MainActor
final class LocationAuth: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAuth()
    private let manager = CLLocationManager()

    func requestIfNeeded() {
        manager.delegate = self
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if Self.isAuthorized(status) {
            NotificationCenter.default.post(name: .locationAuthorized, object: nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if LocationAuth.isAuthorized(status) {
                NotificationCenter.default.post(name: .locationAuthorized, object: nil)
            }
        }
    }

    static func isAuthorized(_ s: CLAuthorizationStatus) -> Bool {
        s == .authorizedAlways   // macOS maps "when in use" grants to authorizedAlways
    }
}

struct PublicIPInfo: Sendable, Equatable, Codable {
    var ipv4: String?
    var ipv6: String?
    var hostname: String?
    var isp: String?
    var country: String?
    var countryCode: String?

    var primaryIP: String? { ipv4 ?? ipv6 }
    var secondaryIP: String? { ipv4 != nil ? ipv6 : nil }
    var isEmpty: Bool { ipv4 == nil && ipv6 == nil }
}

struct IPHistoryEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var publicIPv4: String?
    var hostname: String?
    var summary: String
}

// MARK: - Local interface scanner (getifaddrs)

enum NetworkScanner {
    private struct Holder {
        var ipv4: [String] = []
        var ipv6: [String] = []
        var ipv6ll: [String] = []
        var prefix: Int? = nil
        var mac: String? = nil
        var up = false
    }

    static func scan() -> [NetworkInterface] {
        let (serviceMap, hardwareMap) = allNames()
        let route = primaryRoute()
        var map: [String: Holder] = [:]

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return [] }
        defer { freeifaddrs(head) }

        var cursor = head
        while let cur = cursor {
            defer { cursor = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            let name = String(cString: cur.pointee.ifa_name)
            let flags = cur.pointee.ifa_flags
            let up = (flags & UInt32(IFF_UP)) != 0 && (flags & UInt32(IFF_RUNNING)) != 0
            var h = map[name] ?? Holder()
            h.up = h.up || up

            if family == sa_family_t(AF_LINK) {
                if let mac = macAddress(from: addr) { h.mac = mac }
                map[name] = h
                continue
            }

            guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else {
                map[name] = h; continue
            }

            guard let address = numericHost(addr) else { map[name] = h; continue }

            if family == sa_family_t(AF_INET) {
                if !h.ipv4.contains(address) { h.ipv4.append(address) }
                if h.prefix == nil, let nm = cur.pointee.ifa_netmask {
                    h.prefix = prefixLength(fromNetmask: nm)
                }
            } else {
                let lower = address.lowercased()
                if lower.hasPrefix("fe80") {
                    if !h.ipv6ll.contains(address) { h.ipv6ll.append(address) }
                } else if lower != "::1" {
                    if !h.ipv6.contains(address) { h.ipv6.append(address) }
                }
            }
            map[name] = h
        }

        var interfaces: [NetworkInterface] = []
        for (name, h) in map {
            // Only surface interfaces that have a real address. Link-local-only
            // interfaces (idle utun/awdl/llw) are noise; fe80 shows as an extra
            // line on interfaces that already have a routable IP.
            if h.ipv4.isEmpty && h.ipv6.isEmpty { continue }
            let svcName = serviceMap[name]
            let hwName  = hardwareMap[name] ?? name
            let kind    = classify(name: name, friendly: svcName ?? hwName)
            // Title: "HOME1 (en9)" when service differs from hardware, else hardware name
            let display: String = {
                if let svc = svcName {
                    return "\(svc) (\(name))"
                }
                return hwName
            }()
            let isPrimary = (name == route.interface)
            let wifi = (kind == .wifi) ? WiFiScanner.details(for: name) : nil
            interfaces.append(
                NetworkInterface(
                    bsdName: name, displayName: display, hardwareName: hwName,
                    serviceName: svcName,
                    kind: kind,
                    ipv4: h.ipv4, ipv6: h.ipv6, ipv6LinkLocal: h.ipv6ll,
                    subnetPrefix: h.prefix, mac: h.mac,
                    gateway: isPrimary ? route.gateway : nil,
                    isPrimary: isPrimary, isUp: h.up, wifi: wifi
                )
            )
        }

        return interfaces.sorted { a, b in
            if a.isPrimary != b.isPrimary { return a.isPrimary }
            if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
            return a.bsdName < b.bsdName
        }
    }

    // Expose for tests.
    static func classify(name: String, friendly: String?) -> InterfaceKind {
        if name == "lo0" { return .loopback }
        if name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec")
            || name.hasPrefix("tun") || name.hasPrefix("tap") {
            return .vpn
        }
        if let f = friendly?.lowercased() {
            if f.contains("wi-fi") || f.contains("wifi") || f.contains("airport") { return .wifi }
            if f.contains("ethernet") || f.contains("lan") || f.contains("thunderbolt") { return .ethernet }
            if f.contains("iphone") || f.contains("cellular") || f.contains("usb") { return .cellular }
            if f.contains("vpn") { return .vpn }
        }
        if name.hasPrefix("en") || name.hasPrefix("bridge") { return .ethernet }
        return .other
    }

    static func displayName(name: String, kind: InterfaceKind, friendly: String?) -> String {
        if let f = friendly, !f.isEmpty { return f }
        switch kind {
        case .wifi:     return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .vpn:      return "VPN"
        case .loopback: return "Loopback"
        case .other:    return name
        }
    }

    // MARK: low-level helpers

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(sa.pointee.sa_len)
        guard getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        var s = bufferToString(buf)
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        return s.isEmpty ? nil : s
    }

    private static func prefixLength(fromNetmask nm: UnsafeMutablePointer<sockaddr>) -> Int? {
        guard nm.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        return nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
            UInt32(bigEndian: p.pointee.sin_addr.s_addr).nonzeroBitCount
        }
    }

    private static func macAddress(from sa: UnsafeMutablePointer<sockaddr>) -> String? {
        let raw = UnsafeRawPointer(sa)
        let dl = raw.assumingMemoryBound(to: sockaddr_dl.self)
        let nlen = Int(dl.pointee.sdl_nlen)
        let alen = Int(dl.pointee.sdl_alen)
        guard alen == 6 else { return nil }
        let dataOffset = 8                          // offset of sdl_data within sockaddr_dl
        let bytes = (0..<alen).map { raw.load(fromByteOffset: dataOffset + nlen + $0, as: UInt8.self) }
        let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        return mac == "00:00:00:00:00:00" ? nil : mac
    }

    /// Default-route interface + gateway, via SystemConfiguration.
    private static func primaryRoute() -> (interface: String?, gateway: String?) {
        guard let store = SCDynamicStoreCreate(nil, "IPBar" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return (nil, nil) }
        return (dict["PrimaryInterface"] as? String, dict["Router"] as? String)
    }

    /// Returns (serviceNames, hardwareNames) — both keyed by BSD name.
    /// serviceNames: user-defined names from System Settings (e.g. "HOME1", "Wi-Fi")
    /// hardwareNames: driver/hardware names (e.g. "AX88179B", "Wi-Fi")
    private static func allNames() -> (service: [String: String], hardware: [String: String]) {
        var service: [String: String] = [:]
        var hardware: [String: String] = [:]

        // Service names (Network Settings)
        if let prefs = SCPreferencesCreate(nil, "IPBar" as CFString, nil),
           let set = SCNetworkSetCopyCurrent(prefs),
           let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] {
            for svc in services {
                guard let intf = SCNetworkServiceGetInterface(svc),
                      let bsd  = SCNetworkInterfaceGetBSDName(intf) as String?,
                      let name = SCNetworkServiceGetName(svc) as String?
                else { continue }
                service[bsd] = name
            }
        }

        // Hardware names
        if let list = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for intf in list {
                guard let bsd  = SCNetworkInterfaceGetBSDName(intf) as String?,
                      let disp = SCNetworkInterfaceGetLocalizedDisplayName(intf) as String?
                else { continue }
                hardware[bsd] = disp
            }
        }

        return (service, hardware)
    }
}

// MARK: - Public IP + reverse DNS + ISP

enum PublicIPService {
    static func fetch(includeISP: Bool) async -> PublicIPInfo {
        async let v4task = fetchIPv4()
        async let v6task = fetchIPv6()
        let ipv4 = await v4task
        let v6raw = await v6task
        let ipv6 = (v6raw == ipv4) ? nil : v6raw

        var host: String? = nil
        if let ip = ipv4 { host = await reverseDNS(ip) }

        var isp: String? = nil
        var country: String? = nil
        var code: String? = nil
        if includeISP {
            let g = await fetchGeo()
            isp = g.isp; country = g.country; code = g.code
            if host == nil { host = g.hostname }   // ipinfo.io can supply a hostname too
        }

        let info = PublicIPInfo(ipv4: ipv4, ipv6: ipv6, hostname: host,
                                isp: isp, country: country, countryCode: code)
        // Stale-while-revalidate: cache good results and fall back to the last
        // one when every provider is unreachable (e.g. all rate-limited at once).
        if info.isEmpty { return PublicIPCache.load() ?? info }
        PublicIPCache.save(info)
        return info
    }

    // MARK: IP echo (with fallback)

    private static func fetchIPv4() async -> String? {
        for url in ["https://api.ipify.org", "https://ipv4.icanhazip.com"] {
            if let s = await fetchString(from: url), isValidIPv4(s) { return s }
        }
        return nil
    }

    private static func fetchIPv6() async -> String? {
        for url in ["https://api6.ipify.org", "https://ipv6.icanhazip.com"] {
            if let s = await fetchString(from: url), s.contains(":") { return s }
        }
        return nil
    }

    private static func fetchString(from urlStr: String) async -> String? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        } catch { return nil }
    }

    // MARK: Geo / ISP (provider fallback chain)

    private struct Geo { var isp: String?; var country: String?; var code: String?; var hostname: String? }

    /// Tries providers in order; returns the first one that yields a country code.
    private static func fetchGeo() async -> (isp: String?, country: String?, code: String?, hostname: String?) {
        for provider in [geoIPWhoIs, geoIPInfo, geoIPApiCo] {
            if let g = await provider() {
                return (g.isp, g.country, g.code, g.hostname)
            }
        }
        return (nil, nil, nil, nil)
    }

    // ipwho.is — free, HTTPS, no key. country + country_code + connection.org
    private static func geoIPWhoIs() async -> Geo? {
        guard let data = await fetchData(from: "https://ipwho.is/"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["success"] as? Bool) != false,
              let code = obj["country_code"] as? String, code.count == 2 else { return nil }
        let conn = obj["connection"] as? [String: Any]
        let org = (conn?["org"] as? String) ?? (conn?["isp"] as? String)
        return Geo(isp: org, country: obj["country"] as? String, code: code, hostname: nil)
    }

    // ipinfo.io — HTTPS, no token for basic fields. org is "AS133481 AIS Fibre".
    private static func geoIPInfo() async -> Geo? {
        guard let data = await fetchData(from: "https://ipinfo.io/json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["country"] as? String, code.count == 2 else { return nil }
        let org = (obj["org"] as? String).map(ispOrgName)
        return Geo(isp: org, country: nil, code: code, hostname: obj["hostname"] as? String)
    }

    // ipapi.co — last resort (aggressively rate-limited on the free tier).
    private static func geoIPApiCo() async -> Geo? {
        guard let data = await fetchData(from: "https://ipapi.co/json/"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = (obj["country_code"] as? String) ?? (obj["country"] as? String),
              code.count == 2 else { return nil }
        return Geo(isp: obj["org"] as? String, country: obj["country_name"] as? String,
                   code: code, hostname: nil)
    }

    private static func fetchData(from urlStr: String) async -> Data? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch { return nil }
    }

    private static func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private static func reverseDNS(_ ip: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC,
                                     ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(ip, nil, &hints, &res) == 0, let info = res else {
                    cont.resume(returning: nil); return
                }
                defer { freeaddrinfo(res) }
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let r = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                                    &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD)
                guard r == 0 else { cont.resume(returning: nil); return }
                let name = bufferToString(buf)
                cont.resume(returning: name == ip ? nil : name)
            }
        }
    }
}

// MARK: - History store

enum HistoryStore {
    private static let maxEntries = 100

    static func load() -> [IPHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.history) else { return [] }
        return (try? JSONDecoder().decode([IPHistoryEntry].self, from: data)) ?? []
    }
    static func save(_ entries: [IPHistoryEntry]) {
        let trimmed = Array(entries.suffix(maxEntries))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.history)
        }
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: DefaultsKey.history) }
}

// MARK: - Public IP cache (stale-while-revalidate)

enum PublicIPCache {
    private static let key = "cached_public_ip"

    static func save(_ info: PublicIPInfo) {
        if let data = try? JSONEncoder().encode(info) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    static func load() -> PublicIPInfo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PublicIPInfo.self, from: data)
    }
}

// MARK: - View model

@MainActor
final class IPModel: ObservableObject {
    @Published var interfaces: [NetworkInterface] = []
    @Published var publicInfo = PublicIPInfo()
    @Published var hostName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    @Published var lastUpdated: Date? = nil
    @Published var isRefreshing = false
    @Published var history: [IPHistoryEntry] = []
    @Published var vpnActive = false

    private let monitor = NWPathMonitor()
    private var debounce: Task<Void, Never>? = nil
    private var notifiedPublicIP: String? = nil
    private var didBaselineNotify = false

    init() {
        history = HistoryStore.load()
        // Show the last known public IP instantly; the refresh below revalidates it.
        if let cached = PublicIPCache.load() { publicInfo = cached }
        startMonitoring()
        startPeriodic()
        // Re-scan once Location is granted so the Wi-Fi SSID/BSSID populate.
        NotificationCenter.default.addObserver(forName: .locationAuthorized,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    var primaryLocalIP: String? {
        let pick = interfaces.first { $0.isPrimary && $0.primaryIP != nil }
            ?? interfaces.first { ($0.kind == .wifi || $0.kind == .ethernet) && $0.primaryIP != nil }
        return pick?.primaryIP
    }

    func refresh() {
        isRefreshing = true
        let scanned = NetworkScanner.scan()
        interfaces = scanned
        vpnActive = scanned.contains { $0.kind == .vpn && $0.primaryIP != nil }

        let wantPublic = UserDefaults.standard.bool(forKey: DefaultsKey.enablePublicIP)
        let wantISP = UserDefaults.standard.bool(forKey: DefaultsKey.enableISP)
        guard wantPublic else {
            publicInfo = PublicIPInfo()
            lastUpdated = Date()
            isRefreshing = false
            recordHistory(info: publicInfo, interfaces: scanned)
            return
        }

        Task { [weak self] in
            let info = await PublicIPService.fetch(includeISP: wantISP)
            guard let self else { return }
            self.publicInfo = info
            self.lastUpdated = Date()
            self.isRefreshing = false
            self.recordHistory(info: info, interfaces: scanned)
            self.maybeNotify(info: info)
        }
    }

    func summaryText() -> String {
        var lines: [String] = ["Host: \(hostName)"]
        if let v4 = publicInfo.ipv4 ?? publicInfo.ipv6 {
            var s = "Public: \(v4)"
            if let h = publicInfo.hostname { s += " (\(h))" }
            lines.append(s)
        }
        for i in interfaces where i.kind != .loopback {
            guard let ip = i.primaryIP else { continue }
            var s = "\(i.displayName): \(i.cidr ?? ip)"
            if !i.ipv6.isEmpty { s += " | " + i.ipv6.joined(separator: ", ") }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    private func recordHistory(info: PublicIPInfo, interfaces: [NetworkInterface]) {
        let primaryLocal = interfaces.first { $0.isPrimary }
            ?? interfaces.first { $0.kind == .wifi || $0.kind == .ethernet }
            ?? interfaces.first { $0.kind != .loopback }
        let summary: String = {
            guard let i = primaryLocal, let ip = i.primaryIP else { return "—" }
            return "\(i.displayName) \(ip)"
        }()
        if let last = history.last, last.publicIPv4 == info.ipv4, last.summary == summary { return }
        history.append(IPHistoryEntry(date: Date(), publicIPv4: info.ipv4,
                                      hostname: info.hostname, summary: summary))
        HistoryStore.save(history)
    }

    private func maybeNotify(info: PublicIPInfo) {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.notifyOnIPChange),
              let ip = info.ipv4 ?? info.ipv6 else { return }
        defer { notifiedPublicIP = ip }
        guard didBaselineNotify else { didBaselineNotify = true; return }   // skip first run
        guard ip != notifiedPublicIP else { return }

        let content = UNMutableNotificationContent()
        content.title = "Public IP changed"
        content.body = ip + (info.hostname.map { " · \($0)" } ?? "")
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func clearHistory() {
        history.removeAll()
        HistoryStore.clear()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            self?.refresh()
        }
    }

    /// Optional periodic refresh; reads the interval each cycle so changes apply live.
    private func startPeriodic() {
        Task { [weak self] in
            while !Task.isCancelled {
                let secs = UserDefaults.standard.integer(forKey: DefaultsKey.refreshSeconds)
                if secs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
                    self?.refresh()
                } else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }
}

// MARK: - Clipboard

// MARK: - IP masking

/// Returns a masked version of an IP address.
/// IPv4: "192.168.1.5"   → "xxx.xxx.xxx.5"
/// IPv6: "2405:9800::1"  → "xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:0001"
func maskIP(_ raw: String) -> String {
    // IPv4 (no colon, has dot)
    if raw.contains("."), !raw.contains(":") {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return raw }
        return "xxx.xxx.xxx.\(parts[3])"
    }
    // IPv6
    if raw.contains(":") {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return raw }
        let prefix = Array(repeating: "xxxx", count: parts.count - 1)
        return (prefix + [parts.last!]).joined(separator: ":")
    }
    return raw
}

/// Mask only the IP portion inside a compound string.
/// e.g. "255.255.255.0 (24)" → "xxx.xxx.xxx.0 (24)"
///      "gw 192.168.1.1"     → "gw xxx.xxx.xxx.1"
func maskCompound(_ s: String) -> String {
    // "gw <ip>" pattern
    if s.hasPrefix("gw ") {
        return "gw " + maskIP(String(s.dropFirst(3)))
    }
    // "a.b.c.d (prefix)" pattern — mask the dotted part, keep the suffix
    let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
    if parts.count == 2, parts[0].contains(".") {
        return maskIP(parts[0]) + " " + parts[1]
    }
    return maskIP(s)
}

/// Fully mask an IP — every component, including the last.
/// "192.168.1.1" → "xxx.xxx.xxx.xxx"; "fd00::1" → "xxxx:…:xxxx"
func maskIPFull(_ raw: String) -> String {
    if raw.contains("."), !raw.contains(":") {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return raw }
        return Array(repeating: "xxx", count: parts.count).joined(separator: ".")
    }
    if raw.contains(":") {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return raw }
        return Array(repeating: "xxxx", count: parts.count).joined(separator: ":")
    }
    return raw
}

/// Normalize an ISP/org string by stripping a leading autonomous-system number.
/// "AS133481 AIS Fibre" → "AIS Fibre"; "AIS Fibre" → "AIS Fibre".
func ispOrgName(_ raw: String) -> String {
    let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
    if parts.count == 2, parts[0].hasPrefix("AS"), Int(parts[0].dropFirst(2)) != nil {
        return parts[1]
    }
    return raw
}

enum Clipboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - System info (route table / open ports)

struct RouteEntry: Identifiable, Sendable {
    let id = UUID()
    let destination: String
    let gateway: String
    let flags: String
    let netif: String
    let expire: String
    let family: String       // "IPv4" / "IPv6"
}

struct PortEntry: Identifiable, Sendable {
    let id = UUID()
    let port: Int
    let portText: String
    let proto: String        // IPv4 / IPv6
    let address: String
    let process: String
    let pid: String
    let user: String
}

struct PingResult: Identifiable, Sendable {
    let id = UUID()
    let order: Int
    let label: String        // "Gateway", "DNS 1", "Cloudflare"…
    let host: String
    let reachable: Bool
    let latencyMs: Double?
    let detail: String       // "timeout" / "failed" / ""

    var latencyText: String { latencyMs.map { String(format: "%.1f ms", $0) } ?? "—" }
    var statusText: String { reachable ? "Online" : (detail.isEmpty ? "Offline" : detail) }
}

struct LanDevice: Identifiable, Sendable {
    let id = UUID()
    let ip: String
    let mac: String
    var hostname: String?
    let netif: String
    var isGateway = false
    var isSelf = false

    var label: String {
        if isSelf { return "This Mac" }
        if isGateway { return hostname ?? "Gateway" }
        return hostname ?? "—"
    }
}

enum SystemInfo {
    /// Kernel routing table (IPv4 + IPv6).
    static func routeTable() async -> String {
        await run("/usr/sbin/netstat", ["-rn"])
    }

    /// TCP sockets in LISTEN state, with owning process when visible.
    static func openPorts() async -> String {
        let out = await run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"])
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return await run("/usr/sbin/netstat", ["-an", "-p", "tcp"])
        }
        return out
    }

    /// Parsed route table rows.
    static func routes() async -> [RouteEntry] {
        parseRoutes(await routeTable())
    }

    /// Parsed listening ports, each mapped to its owning process.
    static func ports() async -> [PortEntry] {
        parsePorts(await openPorts())
    }

    // MARK: Diagnostics (DNS servers + ping reachability/latency)

    /// Resolver addresses currently in use (SCDynamicStore global DNS).
    static func dnsServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "IPBar" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dict["ServerAddresses"] as? [String] else { return [] }
        return servers
    }

    /// Default gateway IP (SCDynamicStore global IPv4).
    static func defaultGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "IPBar" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return dict["Router"] as? String
    }

    /// Gather DNS servers and probe a standard set of targets concurrently.
    /// Gateway + public anchors use ICMP; DNS servers use a real query (they
    /// commonly block ICMP but still answer on :53).
    static func diagnostics() async -> (dns: [String], results: [PingResult]) {
        let dns = dnsServers()
        var order = 0
        var pings: [(order: Int, label: String, host: String)] = []
        var digs:  [(order: Int, label: String, host: String)] = []
        if let gw = defaultGateway() { pings.append((order, "Gateway", gw)); order += 1 }
        for (idx, s) in dns.enumerated() { digs.append((order, "DNS \(idx + 1)", s)); order += 1 }
        pings.append((order, "Cloudflare", "1.1.1.1")); order += 1
        pings.append((order, "Google DNS", "8.8.8.8")); order += 1
        let resolveOrder = order

        var results = await withTaskGroup(of: PingResult.self) { group in
            for t in pings { group.addTask { await pingHost(t.host, order: t.order, label: t.label) } }
            for t in digs  { group.addTask { await digQuery(t.host, order: t.order, label: t.label) } }
            var acc: [PingResult] = []
            for await r in group { acc.append(r) }
            return acc
        }
        results.append(await resolveTest("cloudflare.com", order: resolveOrder))
        return (dns, results.sorted { $0.order < $1.order })
    }

    /// Single ICMP echo (no root needed on macOS); parses round-trip time.
    static func pingHost(_ host: String, order: Int, label: String) async -> PingResult {
        let v6 = host.contains(":")
        let tool = v6 ? "/sbin/ping6" : "/sbin/ping"
        let args = v6 ? ["-c", "1", "-i", "1", host] : ["-c", "1", "-t", "2", host]
        let out = await run(tool, args)
        if let ms = parsePingTime(out) {
            return PingResult(order: order, label: label, host: host,
                              reachable: true, latencyMs: ms, detail: "")
        }
        return PingResult(order: order, label: label, host: host,
                          reachable: false, latencyMs: nil, detail: "timeout")
    }

    /// Probe a resolver with a real DNS query (works even when it blocks ICMP).
    static func digQuery(_ server: String, order: Int, label: String) async -> PingResult {
        let out = await run("/usr/bin/dig",
                            ["@\(server)", "+time=2", "+tries=1", "+stats", "example.com"])
        if let ms = parseDigTime(out) {
            return PingResult(order: order, label: label, host: server,
                              reachable: true, latencyMs: ms, detail: "")
        }
        return PingResult(order: order, label: label, host: server,
                          reachable: false, latencyMs: nil, detail: "timeout")
    }

    /// Extract query time (ms) from `dig +stats` output ("Query time: 27 msec").
    static func parseDigTime(_ raw: String) -> Double? {
        guard let r = raw.range(of: "Query time:") else { return nil }
        let digits = raw[r.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
        return Double(digits)
    }

    // MARK: LAN device discovery (ARP table + reverse DNS)

    /// Devices in the ARP cache, deduped, flagged, optionally reverse-resolved.
    static func lanDevices(resolveNames: Bool) async -> [LanDevice] {
        var devices = parseArp(await run("/usr/sbin/arp", ["-an"]))
        let gw = defaultGateway()
        let selfIPs = Set(NetworkScanner.scan().flatMap { $0.ipv4 })
        for i in devices.indices {
            if devices[i].ip == gw { devices[i].isGateway = true }
            if selfIPs.contains(devices[i].ip) { devices[i].isSelf = true }
        }
        guard resolveNames else { return devices }
        return await withTaskGroup(of: (Int, String?).self) { group in
            for (idx, d) in devices.enumerated() {
                group.addTask { (idx, await reverseDNSHost(d.ip)) }
            }
            var out = devices
            for await (idx, name) in group { out[idx].hostname = name }
            return out
        }
    }

    /// Ping-sweep the primary /24 (in bounded batches) to populate the ARP cache.
    static func pingSweep() async {
        guard let gw = defaultGateway() else { return }
        let oct = gw.split(separator: ".")
        guard oct.count == 4 else { return }
        let base = "\(oct[0]).\(oct[1]).\(oct[2])."
        let hosts = Array(1...254)
        for start in stride(from: 0, to: hosts.count, by: 32) {
            let slice = hosts[start..<min(start + 32, hosts.count)]
            await withTaskGroup(of: Void.self) { group in
                for h in slice {
                    group.addTask { _ = await run("/sbin/ping", ["-c", "1", "-t", "1", "\(base)\(h)"]) }
                }
                for await _ in group {}
            }
        }
    }

    /// Parse `arp -an` output into deduped LAN devices, sorted by IP.
    static func parseArp(_ raw: String) -> [LanDevice] {
        var seen = Set<String>()
        var result: [LanDevice] = []
        for line in raw.split(separator: "\n") {
            let s = String(line)
            guard let lp = s.firstIndex(of: "("), let rp = s.firstIndex(of: ")"), lp < rp else { continue }
            let ip = String(s[s.index(after: lp)..<rp])
            guard let atR = s.range(of: " at ") else { continue }
            let mac = String(s[atR.upperBound...].prefix { $0 != " " })
            if mac == "(incomplete)" || mac.isEmpty { continue }
            var netif = ""
            if let onR = s.range(of: " on ") {
                netif = String(s[onR.upperBound...].prefix { $0 != " " })
            }
            // Skip multicast / broadcast noise.
            if ip.hasPrefix("224.") || ip.hasPrefix("239.") || ip == "255.255.255.255" { continue }
            let low = mac.lowercased()
            if low.hasPrefix("1:0:5e") || low.hasPrefix("33:33") || low == "ff:ff:ff:ff:ff:ff" { continue }
            guard seen.insert(ip).inserted else { continue }   // one row per IP
            result.append(LanDevice(ip: ip, mac: normalizeMAC(mac), hostname: nil, netif: netif))
        }
        return result.sorted { ipSortKey($0.ip) < ipSortKey($1.ip) }
    }

    /// Pad each octet to two hex digits and uppercase ("8f:69:b" → "8F:69:0B").
    static func normalizeMAC(_ mac: String) -> String {
        mac.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.count == 1 ? "0" + $0.uppercased() : $0.uppercased() }
            .joined(separator: ":")
    }

    /// Numeric sort key for dotted IPv4.
    static func ipSortKey(_ ip: String) -> UInt32 {
        let p = ip.split(separator: ".").compactMap { UInt32($0) }
        guard p.count == 4 else { return 0 }
        return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]
    }

    /// Reverse-DNS a single address (best effort; LAN hosts often have no PTR).
    static func reverseDNSHost(_ ip: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC,
                                     ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(ip, nil, &hints, &res) == 0, let info = res else {
                    cont.resume(returning: nil); return
                }
                defer { freeaddrinfo(res) }
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let r = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                                    &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD)
                guard r == 0 else { cont.resume(returning: nil); return }
                let name = buf.withUnsafeBufferPointer { p in p.baseAddress.map { String(cString: $0) } ?? "" }
                cont.resume(returning: (name.isEmpty || name == ip) ? nil : name)
            }
        }
    }

    /// Time a DNS lookup to confirm resolution works (isolates DNS from connectivity).
    static func resolveTest(_ host: String, order: Int) async -> PingResult {
        await withCheckedContinuation { (cont: CheckedContinuation<PingResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                     ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                                     ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                let start = Date()
                let rc = getaddrinfo(host, nil, &hints, &res)
                let ms = Date().timeIntervalSince(start) * 1000
                if rc == 0 { freeaddrinfo(res) }
                cont.resume(returning: PingResult(
                    order: order, label: "DNS resolve", host: host,
                    reachable: rc == 0, latencyMs: rc == 0 ? ms : nil,
                    detail: rc == 0 ? "" : "failed"))
            }
        }
    }

    /// Extract round-trip time (ms) from `ping` output ("time=12.3 ms").
    static func parsePingTime(_ raw: String) -> Double? {
        guard let r = raw.range(of: "time=") else { return nil }
        let after = raw[r.upperBound...]
        let num = after.prefix { $0.isNumber || $0 == "." }
        return Double(num)
    }

    static func parseRoutes(_ raw: String) -> [RouteEntry] {
        var result: [RouteEntry] = []
        var family = "IPv4"
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.contains("Internet6") { family = "IPv6"; continue }
            if line.contains("Internet:") { family = "IPv4"; continue }
            if line.hasPrefix("Routing tables") { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 4, cols[0] != "Destination" else { continue }
            result.append(RouteEntry(destination: cols[0], gateway: cols[1], flags: cols[2],
                                     netif: cols[3], expire: cols.count >= 5 ? cols[4] : "",
                                     family: family))
        }
        return result
    }

    static func parsePorts(_ raw: String) -> [PortEntry] {
        var seen = Set<String>()
        var result: [PortEntry] = []
        for line in raw.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 9, cols[0] != "COMMAND" else { continue }
            let command = cols[0], pid = cols[1], user = cols[2], type = cols[4]
            var name = ""
            if let idx = cols.firstIndex(of: "(LISTEN)"), idx > 0 {
                name = cols[idx - 1]
            } else if let n = cols.last(where: { $0.contains(":") }) {
                name = n
            }
            guard !name.isEmpty else { continue }
            let portStr = name.components(separatedBy: ":").last ?? ""
            let address: String = {
                if let r = name.range(of: ":", options: .backwards) { return String(name[..<r.lowerBound]) }
                return name
            }()
            let key = "\(type)|\(name)|\(pid)"
            if !seen.insert(key).inserted { continue }
            result.append(PortEntry(port: Int(portStr) ?? 0, portText: portStr,
                                    proto: type, address: address.isEmpty ? "*" : address,
                                    process: command, pid: pid, user: user))
        }
        return result.sorted { ($0.port, $0.process) < ($1.port, $1.process) }
    }

    /// Run a command off the main thread and return combined stdout/stderr.
    static func run(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard FileManager.default.isExecutableFile(atPath: path) else {
                    cont.resume(returning: "Not available: \(path)")
                    return
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    // readDataToEndOfFile drains as it reads, so no pipe-buffer deadlock.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    cont.resume(returning: "Error running \(path): \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Hosts file

enum HostsFile {
    static let path = "/etc/hosts"

    static func load() throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Write via osascript so macOS shows its standard admin auth dialog.
    static func save(_ content: String) async throws {
        // Write to a temp file first, then move with privilege.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipbar_hosts_\(UUID().uuidString)")
        try content.write(to: tmp, atomically: true, encoding: .utf8)

        let script = """
        do shell script "cp \(tmp.path.shellEscaped) /etc/hosts" \\
            with administrator privileges
        """
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                let src = NSAppleScript(source: script)!
                src.executeAndReturnError(&err)
                try? FileManager.default.removeItem(at: tmp)
                if let e = err {
                    let msg = e[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                    cont.resume(throwing: NSError(domain: "HostsFile", code: -1,
                                                  userInfo: [NSLocalizedDescriptionKey: msg]))
                } else {
                    cont.resume()
                }
            }
        }
    }
}

private extension String {
    /// Shell-escape a file path (wrap in single quotes, escape embedded quotes).
    var shellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - CLI dump mode

enum DumpMode {
    static func run() -> Never {
        let interfaces = NetworkScanner.scan().filter { $0.kind != .loopback }
        print("Host: \(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)")
        print("Interfaces (\(interfaces.count)):")
        for i in interfaces {
            let star = i.isPrimary ? " *default*" : ""
            print("  [\(i.kind.rawValue)] \(i.displayName)\(star)")
            print("      headline: \(i.cidr ?? i.primaryIP ?? "—")")
            if let mac = i.mac { print("      mac:      \(mac)") }
            if let gw = i.gateway { print("      gateway:  \(gw)") }
            if !i.secondaryIPs.isEmpty { print("      other:    \(i.secondaryIPs.joined(separator: ", "))") }
            if !i.ipv6LinkLocal.isEmpty { print("      link-local: \(i.ipv6LinkLocal.joined(separator: ", "))") }
            if let w = i.wifi {
                var bits: [String] = []
                if let s = w.ssid { bits.append("ssid \(s)") }
                if let r = w.rssi { bits.append("\(r) dBm (\(w.bars)/4)") }
                if !w.channelLine.isEmpty { bits.append(w.channelLine) }
                if let width = w.width { bits.append(width) }
                if let sec = w.security { bits.append(sec) }
                if let tx = w.txRate { bits.append("\(Int(tx)) Mbps") }
                print("      wifi:     \(bits.joined(separator: " · "))")
            }
        }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var pub = PublicIPInfo()
        Task {
            pub = await PublicIPService.fetch(includeISP: true)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 8)
        print("Public IP:")
        print("      headline: \(pub.primaryIP ?? "—")")
        print("      v4: \(pub.ipv4 ?? "—")  v6: \(pub.ipv6 ?? "—")")
        print("      host: \(pub.hostname ?? "—")")
        print("      isp: \(pub.isp ?? "—")  country: \(pub.country ?? "—") [\(pub.countryCode ?? "—")] \(countryFlag(pub.countryCode) ?? "")")
        exit(0)
    }

    /// Print DNS servers + ping diagnostics, then exit (for the --diag CLI flag).
    static func runDiag() -> Never {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var dns: [String] = []
        nonisolated(unsafe) var rows: [PingResult] = []
        Task {
            let r = await SystemInfo.diagnostics()
            dns = r.dns; rows = r.results; sem.signal()
        }
        _ = sem.wait(timeout: .now() + 12)
        print("DNS servers: \(dns.joined(separator: ", "))")
        for r in rows {
            let label = r.label.padding(toLength: 12, withPad: " ", startingAt: 0)
            let host = r.host.padding(toLength: 18, withPad: " ", startingAt: 0)
            print("  \(label) \(host) \(r.statusText)  \(r.latencyText)")
        }
        exit(0)
    }

    /// Print discovered LAN devices, then exit (for the --lan CLI flag).
    static func runLan(deep: Bool) -> Never {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var rows: [LanDevice] = []
        Task {
            if deep { await SystemInfo.pingSweep() }
            rows = await SystemInfo.lanDevices(resolveNames: true)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + (deep ? 30 : 10))
        print("LAN devices (\(rows.count)):")
        for d in rows {
            let ip = d.ip.padding(toLength: 16, withPad: " ", startingAt: 0)
            let mac = d.mac.padding(toLength: 18, withPad: " ", startingAt: 0)
            let tag = d.isSelf ? " [self]" : (d.isGateway ? " [gateway]" : "")
            print("  \(ip) \(mac) \(d.netif)  \(d.hostname ?? "")\(tag)")
        }
        exit(0)
    }

    /// Run an async string producer synchronously, print it, and exit (for CLI flags).
    static func runSystem(_ loader: @escaping @Sendable () async -> String) -> Never {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out = ""
        Task { out = await loader(); sem.signal() }
        sem.wait()
        print(out)
        exit(0)
    }
}
