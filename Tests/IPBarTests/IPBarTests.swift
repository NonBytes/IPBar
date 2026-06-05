import XCTest
@testable import IPBar

final class IPBarTests: XCTestCase {

    // MARK: headline rule (IPv4 first, IPv6 fallback)

    func testHeadlinePrefersIPv4() {
        let i = NetworkInterface(bsdName: "en0", displayName: "Wi-Fi", kind: .wifi,
                                 ipv4: ["192.168.1.5"], ipv6: ["2001:db8::1"], isUp: true)
        XCTAssertEqual(i.primaryIP, "192.168.1.5")
        XCTAssertEqual(i.secondaryIPs, ["2001:db8::1"])
    }

    func testHeadlineFallsBackToIPv6WhenNoIPv4() {
        let i = NetworkInterface(bsdName: "utun3", displayName: "VPN", kind: .vpn,
                                 ipv4: [], ipv6: ["2001:db8::99", "2001:db8::100"], isUp: true)
        XCTAssertEqual(i.primaryIP, "2001:db8::99")
        XCTAssertEqual(i.secondaryIPs, ["2001:db8::100"])
    }

    func testNoAddressesYieldsNilHeadline() {
        let i = NetworkInterface(bsdName: "en5", displayName: "Ethernet", kind: .ethernet,
                                 ipv4: [], ipv6: [], isUp: true)
        XCTAssertNil(i.primaryIP)
        XCTAssertTrue(i.secondaryIPs.isEmpty)
    }

    func testMultipleIPv4HeadlineIsFirst() {
        let i = NetworkInterface(bsdName: "en0", displayName: "Wi-Fi", kind: .wifi,
                                 ipv4: ["10.0.0.2", "10.0.0.3"], ipv6: ["fd00::1"], isUp: true)
        XCTAssertEqual(i.primaryIP, "10.0.0.2")
        XCTAssertEqual(i.secondaryIPs, ["10.0.0.3", "fd00::1"])
    }

    // MARK: CIDR

    func testCIDRWithPrefix() {
        let i = NetworkInterface(bsdName: "en0", displayName: "Wi-Fi", kind: .wifi,
                                 ipv4: ["10.0.0.2"], ipv6: [], subnetPrefix: 8, isUp: true)
        XCTAssertEqual(i.cidr, "10.0.0.2/8")
    }

    func testCIDRWithoutPrefixIsBareIP() {
        let i = NetworkInterface(bsdName: "en0", displayName: "Wi-Fi", kind: .wifi,
                                 ipv4: ["10.0.0.2"], ipv6: [], subnetPrefix: nil, isUp: true)
        XCTAssertEqual(i.cidr, "10.0.0.2")
    }

    func testCIDRNilWhenNoIPv4() {
        let i = NetworkInterface(bsdName: "utun0", displayName: "VPN", kind: .vpn,
                                 ipv4: [], ipv6: ["fd00::1"], isUp: true)
        XCTAssertNil(i.cidr)
    }

    // MARK: subnet mask (prefix -> dotted)

    private func iface(prefix: Int?) -> NetworkInterface {
        NetworkInterface(bsdName: "en0", displayName: "Wi-Fi", kind: .wifi,
                         ipv4: ["10.0.0.2"], ipv6: [], subnetPrefix: prefix, isUp: true)
    }

    func testSubnetMaskCommonPrefixes() {
        XCTAssertEqual(iface(prefix: 24).subnetMask, "255.255.255.0")
        XCTAssertEqual(iface(prefix: 16).subnetMask, "255.255.0.0")
        XCTAssertEqual(iface(prefix: 8).subnetMask,  "255.0.0.0")
        XCTAssertEqual(iface(prefix: 32).subnetMask, "255.255.255.255")
        XCTAssertEqual(iface(prefix: 0).subnetMask,  "0.0.0.0")
        XCTAssertEqual(iface(prefix: 23).subnetMask, "255.255.254.0")
    }

    func testSubnetMaskNilWhenNoPrefix() {
        XCTAssertNil(iface(prefix: nil).subnetMask)
    }

    // MARK: classification

    func testClassifyVPNByName() {
        XCTAssertEqual(NetworkScanner.classify(name: "utun3", friendly: nil), .vpn)
        XCTAssertEqual(NetworkScanner.classify(name: "ppp0", friendly: nil), .vpn)
        XCTAssertEqual(NetworkScanner.classify(name: "ipsec0", friendly: nil), .vpn)
    }

    func testClassifyLoopback() {
        XCTAssertEqual(NetworkScanner.classify(name: "lo0", friendly: nil), .loopback)
    }

    func testClassifyWiFiAndEthernetByFriendlyName() {
        XCTAssertEqual(NetworkScanner.classify(name: "en0", friendly: "Wi-Fi"), .wifi)
        XCTAssertEqual(NetworkScanner.classify(name: "en4", friendly: "Thunderbolt Ethernet"), .ethernet)
    }

    func testClassifyEnFallsBackToEthernet() {
        XCTAssertEqual(NetworkScanner.classify(name: "en9", friendly: "AX88179B"), .ethernet)
        XCTAssertEqual(NetworkScanner.classify(name: "en1", friendly: nil), .ethernet)
    }

    // MARK: ordering

    func testKindRankOrder() {
        XCTAssertLessThan(InterfaceKind.wifi.rank, InterfaceKind.ethernet.rank)
        XCTAssertLessThan(InterfaceKind.ethernet.rank, InterfaceKind.vpn.rank)
        XCTAssertLessThan(InterfaceKind.vpn.rank, InterfaceKind.loopback.rank)
    }

    // MARK: IP masking

    func testMaskIPv4() {
        XCTAssertEqual(maskIP("192.168.111.155"), "xxx.xxx.xxx.155")
        XCTAssertEqual(maskIP("10.66.66.4"),      "xxx.xxx.xxx.4")
        XCTAssertEqual(maskIP("0.0.0.0"),         "xxx.xxx.xxx.0")
    }

    func testMaskIPv6() {
        let result = maskIP("2405:9800:b651:5313:835:56da:2cba:bb9d")
        XCTAssertTrue(result.hasSuffix(":bb9d"))
        XCTAssertTrue(result.contains("xxxx"))
    }

    func testMaskCompoundSubnet() {
        XCTAssertEqual(maskCompound("255.255.255.0 (24)"),   "xxx.xxx.xxx.0 (24)")
        XCTAssertEqual(maskCompound("255.255.255.255 (32)"), "xxx.xxx.xxx.255 (32)")
    }

    func testMaskCompoundGateway() {
        XCTAssertEqual(maskCompound("gw 192.168.111.1"), "gw xxx.xxx.xxx.1")
        XCTAssertEqual(maskCompound("gw 10.0.0.1"),      "gw xxx.xxx.xxx.1")
    }

    func testMaskIPFull() {
        XCTAssertEqual(maskIPFull("192.168.111.1"),   "xxx.xxx.xxx.xxx")
        XCTAssertEqual(maskIPFull("255.255.255.0"),   "xxx.xxx.xxx.xxx")
        XCTAssertTrue(maskIPFull("fd00::1").allSatisfy { $0 == "x" || $0 == ":" })
    }

    func testMaskMAC() {
        XCTAssertEqual(maskMAC("C8:A3:62:D0:A8:71"), "xx:xx:xx:xx:xx:xx")
        XCTAssertEqual(maskMAC("b2:f8:9a:b6:7e:56"), "xx:xx:xx:xx:xx:xx")
    }

    // MARK: lsof parsing (port -> process mapping)

    func testParsePortsMapsProcess() {
        let raw = """
        COMMAND    PID     USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        rapportd   670 nonbytes   10u  IPv4 0x123d7fe040abdb9f      0t0  TCP *:49160 (LISTEN)
        ControlCe  678 nonbytes    9u  IPv4 0x62c4d94683aaaacc      0t0  TCP *:7000 (LISTEN)
        nginx     1234     root    6u  IPv4 0xdeadbeef             0t0  TCP 127.0.0.1:8080 (LISTEN)
        """
        let ports = SystemInfo.parsePorts(raw)
        XCTAssertEqual(ports.count, 3)

        // sorted by port number → 7000, 8080, 49160
        XCTAssertEqual(ports[0].port, 7000)
        XCTAssertEqual(ports[0].process, "ControlCe")

        let nginx = ports.first { $0.port == 8080 }
        XCTAssertEqual(nginx?.process, "nginx")
        XCTAssertEqual(nginx?.pid, "1234")
        XCTAssertEqual(nginx?.user, "root")
        XCTAssertEqual(nginx?.address, "127.0.0.1")
        XCTAssertEqual(nginx?.proto, "IPv4")
    }

    func testParsePortsHandlesIPv6Bracket() {
        let raw = """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        cupsd   99 root 7u IPv6 0xabc 0t0 TCP [::1]:631 (LISTEN)
        """
        let ports = SystemInfo.parsePorts(raw)
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].port, 631)
        XCTAssertEqual(ports[0].address, "[::1]")
        XCTAssertEqual(ports[0].proto, "IPv6")
    }

    // MARK: netstat route parsing

    func testParseRoutesSwitchesFamily() {
        let raw = """
        Routing tables

        Internet:
        Destination        Gateway            Flags        Netif Expire
        default            192.168.1.1        UGScg          en0
        127                127.0.0.1          UCS            lo0

        Internet6:
        Destination        Gateway            Flags        Netif Expire
        ::1                ::1                UHL            lo0
        """
        let routes = SystemInfo.parseRoutes(raw)
        XCTAssertEqual(routes.count, 3)

        let def = routes.first { $0.destination == "default" }
        XCTAssertEqual(def?.gateway, "192.168.1.1")
        XCTAssertEqual(def?.netif, "en0")
        XCTAssertEqual(def?.family, "IPv4")

        let v6 = routes.first { $0.destination == "::1" }
        XCTAssertEqual(v6?.family, "IPv6")
    }

    // MARK: ISP org-name normalization (strip ASN prefix from ipinfo.io)

    func testISPOrgNameStripsASN() {
        XCTAssertEqual(ispOrgName("AS133481 AIS Fibre"), "AIS Fibre")
        XCTAssertEqual(ispOrgName("AS7922 Comcast Cable Communications, LLC"),
                       "Comcast Cable Communications, LLC")
    }

    func testISPOrgNameLeavesPlainNames() {
        XCTAssertEqual(ispOrgName("AIS Fibre"), "AIS Fibre")
        XCTAssertEqual(ispOrgName("ASN Networks"), "ASN Networks")   // "ASN" isn't AS+digits
        XCTAssertEqual(ispOrgName("Google"), "Google")
    }

    // MARK: public IP cache round-trip

    func testPublicIPCacheRoundTrip() {
        let info = PublicIPInfo(ipv4: "1.2.3.4", ipv6: "2001:db8::1",
                                hostname: "host.example", isp: "AIS Fibre",
                                country: "Thailand", countryCode: "TH")
        PublicIPCache.save(info)
        let loaded = PublicIPCache.load()
        XCTAssertEqual(loaded?.ipv4, "1.2.3.4")
        XCTAssertEqual(loaded?.countryCode, "TH")
        XCTAssertEqual(loaded?.isp, "AIS Fibre")
    }

    // MARK: ping output parsing

    func testParsePingTime() {
        let raw = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=12.345 ms
        """
        XCTAssertEqual(SystemInfo.parsePingTime(raw), 12.345)
    }

    func testParsePingTimeTimeoutIsNil() {
        let raw = """
        PING 10.0.0.99 (10.0.0.99): 56 data bytes
        Request timeout for icmp_seq 0
        """
        XCTAssertNil(SystemInfo.parsePingTime(raw))
    }

    func testParseDigTime() {
        let raw = ";; Query time: 27 msec\n;; SERVER: 1.1.1.1#53(1.1.1.1)"
        XCTAssertEqual(SystemInfo.parseDigTime(raw), 27)
        XCTAssertNil(SystemInfo.parseDigTime(";; connection timed out; no servers could be reached"))
    }

    // MARK: ARP / LAN device parsing

    func testParseArpDedupesAndNormalizes() {
        let raw = """
        ? (192.168.111.1) at 64:20:e0:8f:69:b on en9 ifscope [ethernet]
        ? (192.168.111.1) at 64:20:e0:8f:69:b on en0 ifscope [ethernet]
        ? (192.168.111.51) at f4:9d:8a:3c:7f:7 on en9 ifscope [ethernet]
        ? (192.168.111.99) at (incomplete) on en0 ifscope [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        """
        let devices = SystemInfo.parseArp(raw)
        // .1 deduped to one row; .51 kept; incomplete + multicast dropped
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].ip, "192.168.111.1")
        XCTAssertEqual(devices[0].mac, "64:20:E0:8F:69:0B")   // padded + uppercased
        XCTAssertEqual(devices[1].ip, "192.168.111.51")
    }

    func testParseArpSortsNumerically() {
        let raw = """
        ? (192.168.111.118) at aa:bb:cc:dd:ee:01 on en0 ifscope [ethernet]
        ? (192.168.111.58) at aa:bb:cc:dd:ee:02 on en0 ifscope [ethernet]
        ? (192.168.111.9) at aa:bb:cc:dd:ee:03 on en0 ifscope [ethernet]
        """
        let ips = SystemInfo.parseArp(raw).map(\.ip)
        XCTAssertEqual(ips, ["192.168.111.9", "192.168.111.58", "192.168.111.118"])
    }

    func testNormalizeMAC() {
        XCTAssertEqual(SystemInfo.normalizeMAC("8:0:27:c:a:b"), "08:00:27:0C:0A:0B")
        XCTAssertEqual(SystemInfo.normalizeMAC("c8:a3:62:d0:a8:71"), "C8:A3:62:D0:A8:71")
    }

    func testIPSortKey() {
        XCTAssertLessThan(SystemInfo.ipSortKey("192.168.1.9"), SystemInfo.ipSortKey("192.168.1.10"))
        XCTAssertLessThan(SystemInfo.ipSortKey("10.0.0.1"), SystemInfo.ipSortKey("192.168.0.1"))
    }

    // MARK: public IP headline mirrors the same rule

    func testPublicInfoHeadlineRule() {
        let both = PublicIPInfo(ipv4: "1.2.3.4", ipv6: "2001:db8::1")
        XCTAssertEqual(both.primaryIP, "1.2.3.4")
        XCTAssertEqual(both.secondaryIP, "2001:db8::1")

        let v6only = PublicIPInfo(ipv4: nil, ipv6: "2001:db8::1")
        XCTAssertEqual(v6only.primaryIP, "2001:db8::1")
        XCTAssertNil(v6only.secondaryIP)
    }
}
