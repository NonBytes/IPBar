import SwiftUI
import AppKit
import CoreGraphics
import CoreText
import ServiceManagement
import UserNotifications

@main
struct IPBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = IPModel()

    init() {
        DefaultsKey.registerDefaults()
        let args = CommandLine.arguments
        if args.contains("--dump")   { DumpMode.run() }
        if args.contains("--routes") { DumpMode.runSystem { await SystemInfo.routeTable() } }
        if args.contains("--ports")  { DumpMode.runSystem { await SystemInfo.openPorts() } }
        if args.contains("--diag")   { DumpMode.runDiag() }
        if args.contains("--lan")    { DumpMode.runLan(deep: args.contains("--deep")) }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

        Window("Route Table", id: "ip-routes") {
            RoutesWindow()
        }
        .defaultSize(width: 580, height: 420)

        Window("Open Ports", id: "ip-ports") {
            PortsWindow()
        }
        .defaultSize(width: 640, height: 460)

        Window("Hosts File", id: "ip-hosts") {
            HostsWindow()
        }
        .defaultSize(width: 600, height: 500)

        Window("Network Diagnostics", id: "ip-diag") {
            DiagnosticsWindow()
        }
        .defaultSize(width: 520, height: 440)

        Window("LAN Devices", id: "ip-lan") {
            LanWindow()
        }
        .defaultSize(width: 560, height: 460)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Wi-Fi SSID requires Location authorization on macOS 14+.
        if UserDefaults.standard.bool(forKey: DefaultsKey.showWiFiDetails) {
            LocationAuth.shared.requestIfNeeded()
        }
    }
}

// MARK: - Menu bar label (the app's "IP" pin + optional IP text)

struct MenuBarLabel: View {
    @ObservedObject var model: IPModel
    @AppStorage(DefaultsKey.menuBarMode) private var mode: MenuBarMode = .icon

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: ipPinMenuImage(filled: model.vpnActive))
                .renderingMode(.template)
            if mode == .publicIP, let ip = model.publicInfo.ipv4 ?? model.publicInfo.ipv6 {
                Text(ip).font(.system(size: 12, weight: .medium))
            } else if mode == .localIP, let ip = model.primaryLocalIP {
                Text(ip).font(.system(size: 12, weight: .medium))
            }
        }
    }
}

/// A template menu-bar image matching the app icon's "IP" location pin.
/// When `filled` (VPN active) the pin is solid with the letters knocked out.
func ipPinMenuImage(filled: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 14, height: 16), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        drawIPPin(in: ctx, rect: rect, filled: filled)
        return true
    }
    image.isTemplate = true   // menu bar tints it for light/dark automatically
    return image
}

private func drawIPPin(in ctx: CGContext, rect: CGRect, filled: Bool) {
    ctx.setAllowsAntialiasing(true)
    ctx.setLineJoin(.round); ctx.setLineCap(.round)

    let w = rect.width, h = rect.height
    let cx = rect.midX
    let Rh = w * 0.40                                   // head radius
    let pc = CGPoint(x: cx, y: rect.minY + h * 0.62)    // head centre
    let tipY = rect.minY + h * 0.05                     // tip
    let Ri = Rh * 0.55                                  // inner ring radius

    let d = pc.y - tipY
    let beta = acos(min(0.999, Rh / d))
    let aRight = -CGFloat.pi / 2 + beta
    let aLeft  =  3 * CGFloat.pi / 2 - beta
    let tip = CGPoint(x: cx, y: tipY)
    let pRight = CGPoint(x: pc.x + Rh * cos(aRight), y: pc.y + Rh * sin(aRight))

    let pin = CGMutablePath()
    pin.move(to: tip)
    pin.addLine(to: pRight)
    pin.addArc(center: pc, radius: Rh, startAngle: aRight, endAngle: aLeft, clockwise: false)
    pin.closeSubpath()

    let black = NSColor.black.cgColor

    func drawIP(blend: CGBlendMode) {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, Ri * 1.5, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "IP", attributes: [.font: font, .foregroundColor: black]))
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        ctx.setBlendMode(blend)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: pc.x - b.width / 2 - b.origin.x,
                                   y: pc.y - b.height / 2 - b.origin.y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    if filled {
        ctx.addPath(pin); ctx.setFillColor(black); ctx.fillPath()
        drawIP(blend: .clear)        // knock the letters out of the solid pin
    } else {
        ctx.setStrokeColor(black); ctx.setLineWidth(w * 0.10)
        ctx.addPath(pin); ctx.strokePath()
        drawIP(blend: .normal)
    }
}

// MARK: - Root content

struct ContentView: View {
    @EnvironmentObject var model: IPModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(DefaultsKey.showLoopback) private var showLoopback = false
    @AppStorage(DefaultsKey.enablePublicIP) private var enablePublicIP = true

    @State private var screen: PanelScreen = .main
    @State private var toast: String? = nil
    @State private var toastTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch screen {
                case .main:
                    mainView
                case .history:
                    HistoryView(onBack: { screen = .main })
                }
            }
            if let toast {
                Text(toast)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 420)
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    private var mainView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if enablePublicIP {
                PublicIPCard(info: model.publicInfo,
                             isLoading: model.isRefreshing && model.publicInfo.isEmpty,
                             onCopy: copy)
            } else {
                Label("Public IP lookup is off", systemImage: "globe.badge.chevron.backward")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Divider().opacity(0.5)

            let shown = model.interfaces.filter { showLoopback || $0.kind != .loopback }
            if shown.isEmpty {
                Text("No active interfaces")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(shown) { iface in
                        InterfaceRow(iface: iface, onCopy: copy)
                    }
                }
            }

            Divider().opacity(0.5)
            footer
        }
        .padding(14)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Current IP Addresses").font(.system(size: 14, weight: .bold))
                Text(model.hostName).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Text("Click to copy").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            Button { screen = .history } label: { Image(systemName: "clock.arrow.circlepath") }
                .help("History")
            Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "ip-routes") } label: {
                Image(systemName: "arrow.triangle.branch")
            }.help("Route Table")
            Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "ip-ports") } label: {
                Image(systemName: "powerplug")
            }.help("Open Ports")
            Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "ip-hosts") } label: {
                Image(systemName: "doc.text")
            }.help("Hosts File")
            Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "ip-diag") } label: {
                Image(systemName: "waveform.path.ecg")
            }.help("Network Diagnostics")
            Button { NSApp.activate(ignoringOtherApps: true); openWindow(id: "ip-lan") } label: {
                Image(systemName: "rectangle.connected.to.line.below")
            }.help("LAN Devices")
            Button {
                Clipboard.copy(model.summaryText()); showToast("Copied all addresses")
            } label: { Image(systemName: "doc.on.doc") }
                .help("Copy all addresses")
            Button {
                NSApp.activate(ignoringOtherApps: true); openSettings()
            } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Spacer()
            Button(role: .destructive) { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }.tint(.red).help("Quit")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func copy(_ value: String) { Clipboard.copy(value); showToast("Copied \(value)") }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if Task.isCancelled { return }
            await MainActor.run { toast = nil }
        }
    }
}

// MARK: - Public IP card

struct PublicIPCard: View {
    let info: PublicIPInfo
    let isLoading: Bool
    let onCopy: (String) -> Void
    @AppStorage(DefaultsKey.showIPv6) private var showIPv6 = true
    @State private var showHostname = false
    @State private var masked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // "Public IP" text = mask toggle
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { masked.toggle() }
                        } label: {
                            Text("Public IP")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(masked ? .secondary : .primary)
                        }
                        .buttonStyle(.plain)
                        .help(masked ? "Show IP" : "Mask IP")
                        if let flag = countryFlag(info.countryCode) {
                            Text(flag)
                                .font(.system(size: 16))
                                .opacity(info.hostname != nil ? 1.0 : 0.5)
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showHostname.toggle() } }
                                .help(showHostname ? "Hide hostname" : (info.hostname ?? info.country ?? ""))
                        }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    } else if let primary = info.primaryIP {
                        let display = masked ? maskIP(primary) : primary
                        CopyText(display, size: 17, weight: .semibold, mono: masked,
                                 onCopy: { _ in onCopy(primary) })
                    } else {
                        Text("No internet").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !masked, let isp = info.isp {
                        Text(isp).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if showIPv6, let v6 = info.secondaryIP {
                        let display = masked ? maskIP(v6) : v6
                        CopyText(display, size: 11, weight: .regular, mono: true,
                                 color: .secondary, onCopy: { _ in onCopy(v6) })
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: masked)
            }
            // Reverse-DNS hostname: toggle by tapping the flag.
            if showHostname, let host = info.hostname {
                CopyText(host, size: 10, weight: .regular, mono: false,
                         color: .secondary, wrap: true, onCopy: onCopy)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: showHostname)
    }
}

/// Regional-indicator flag emoji from a 2-letter ISO country code ("TH" → 🇹🇭).
func countryFlag(_ code: String?) -> String? {
    guard let code, code.count == 2 else { return nil }
    let base: UInt32 = 127397
    var s = ""
    for v in code.uppercased().unicodeScalars {
        guard (65...90).contains(v.value), let scalar = UnicodeScalar(base + v.value) else { return nil }
        s.unicodeScalars.append(scalar)
    }
    return s.isEmpty ? nil : s
}

// MARK: - Interface row

struct InterfaceRow: View {
    let iface: NetworkInterface
    let onCopy: (String) -> Void
    @AppStorage(DefaultsKey.showLinkLocalV6) private var showLinkLocal = false
    @AppStorage(DefaultsKey.showIPv6) private var showIPv6 = true
    @AppStorage(DefaultsKey.showMAC) private var showMAC = true
    @AppStorage(DefaultsKey.showWiFiDetails) private var showWiFiDetails = true
    @State private var masked = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iface.kind.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color(iface.kind))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                // Title: service name ("HOME1") when set, else the hardware name.
                let title = iface.serviceName ?? iface.hardwareName
                // Second line carries the hardware name, only when it's distinct from the title.
                let subName: String? = (iface.hardwareName != title) ? iface.hardwareName : nil
                HStack(spacing: 5) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { masked.toggle() }
                    } label: {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(masked ? .secondary : .primary)
                    }
                    .buttonStyle(.plain)
                    .help(masked ? "Show IPs" : "Mask IPs")
                    // No distinct hardware line → keep the BSD badge next to the title.
                    if subName == nil { Badge(text: iface.bsdName, color: .blue) }
                    if iface.kind == .vpn { Badge(text: "VPN", color: .purple) }
                    if iface.isPrimary { Badge(text: "DEFAULT", color: .green) }
                }
                // Subtitle: "AX88179B  en9" — hardware name + BSD badge (no parens).
                if let subName {
                    HStack(spacing: 5) {
                        Text(subName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Badge(text: iface.bsdName, color: .blue)
                    }
                }
                if showMAC, let mac = iface.mac {
                    CopyText(mac.uppercased(), size: 10, weight: .regular, mono: true,
                             color: .secondary, onCopy: onCopy)
                }
                if showWiFiDetails, let w = iface.wifi {
                    WiFiDetailLine(wifi: w)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                // Primary IP
                if let primary = iface.primaryIP {
                    let display = masked ? maskIP(primary) : primary
                    CopyText(display, size: 17, weight: .semibold, mono: masked,
                             wrap: masked, onCopy: { _ in onCopy(primary) })
                } else {
                    Text("—").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                // Subnet mask
                if let mask = iface.subnetMask, let p = iface.subnetPrefix, !iface.ipv4.isEmpty {
                    let display = masked ? maskCompound("\(mask) (\(p))") : "\(mask) (\(p))"
                    Text(display).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                // Gateway (no "gw" prefix — just the IP)
                if let gw = iface.gateway {
                    let display = masked ? maskIP(gw) : gw
                    CopyText(display, size: 10, weight: .regular, mono: true,
                             color: .secondary, onCopy: { _ in onCopy(gw) })
                }
                // Secondary (IPv4 extra + IPv6)
                ForEach(secondaryShown, id: \.self) { ip in
                    let display = masked ? maskIP(ip) : ip
                    CopyText(display, size: 11, weight: .regular, mono: true,
                             color: .secondary, onCopy: { _ in onCopy(ip) })
                }
                if showIPv6 && showLinkLocal {
                    ForEach(iface.ipv6LinkLocal, id: \.self) { ip in
                        let display = masked ? maskIP(ip) : ip
                        CopyText(display, size: 10, weight: .regular, mono: true,
                                 color: .secondary.opacity(0.8), onCopy: { _ in onCopy(ip) })
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: masked)
        }
        .contentShape(Rectangle())
    }

    private var secondaryShown: [String] {
        showIPv6 ? iface.secondaryIPs : iface.secondaryIPs.filter { !$0.contains(":") }
    }

    private func color(_ kind: InterfaceKind) -> Color {
        switch kind {
        case .wifi:     return .green
        case .ethernet: return .teal
        case .cellular: return .orange
        case .vpn:      return .purple
        case .loopback: return .gray
        case .other:    return .secondary
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Wi-Fi detail line

struct WiFiDetailLine: View {
    let wifi: WiFiDetails
    @State private var expanded = false

    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let mono: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // SSID line — tap to reveal / hide the full per-line details. (No chevron.)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    // Signal-bars icon (distinct from the interface's plain "wifi" glyph);
                    // the bars fill to match RSSI strength.
                    Image(systemName: "cellularbars", variableValue: Double(wifi.bars) / 4.0)
                        .font(.system(size: 10))
                        .foregroundStyle(signalColor)
                    Text(wifi.ssid ?? "Wi-Fi")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide Wi-Fi details" : "Show Wi-Fi details")

            if expanded {
                ForEach(rows) { row in
                    HStack(spacing: 4) {
                        Text(row.label + ":")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .font(.system(size: 9, design: row.mono ? .monospaced : .default))
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    /// One labelled value per line; BSSID/width/SNR/noise included.
    private var rows: [Row] {
        var r: [Row] = []
        if let v = wifi.rssi     { r.append(Row(label: "Signal",   value: "\(v) dBm (\(wifi.bars)/4)", mono: false)) }
        if let v = wifi.channel  { r.append(Row(label: "Channel",  value: "\(v)", mono: false)) }
        if let v = wifi.band     { r.append(Row(label: "Band",     value: v, mono: false)) }
        if let v = wifi.width    { r.append(Row(label: "Width",    value: v, mono: false)) }
        if let v = wifi.phyMode  { r.append(Row(label: "Mode",     value: v, mono: false)) }
        if let v = wifi.security { r.append(Row(label: "Security", value: v, mono: false)) }
        if let v = wifi.txRate   { r.append(Row(label: "Tx Rate",  value: "\(Int(v)) Mbps", mono: false)) }
        if let v = wifi.snr      { r.append(Row(label: "SNR",      value: "\(v) dB", mono: false)) }
        if let v = wifi.noise    { r.append(Row(label: "Noise",    value: "\(v) dBm", mono: false)) }
        if let v = wifi.bssid    { r.append(Row(label: "BSSID",    value: v, mono: true)) }
        return r
    }

    private var signalColor: Color {
        switch wifi.bars {
        case 4, 3: return .green
        case 2:    return .yellow
        default:   return .orange
        }
    }
}

// MARK: - Copyable text

struct CopyText: View {
    let value: String
    let size: CGFloat
    let weight: Font.Weight
    let mono: Bool
    var color: Color? = nil
    var wrap: Bool = false
    let onCopy: (String) -> Void
    @State private var hovering = false

    init(_ value: String, size: CGFloat, weight: Font.Weight, mono: Bool,
         color: Color? = nil, wrap: Bool = false, onCopy: @escaping (String) -> Void) {
        self.value = value; self.size = size; self.weight = weight
        self.mono = mono; self.color = color; self.wrap = wrap; self.onCopy = onCopy
    }

    var body: some View {
        Text(value)
            .font(.system(size: size, weight: weight, design: mono ? .monospaced : .rounded))
            .foregroundStyle(color ?? .primary)
            .lineLimit(wrap ? nil : 1)
            .truncationMode(wrap ? .tail : .middle)
            .fixedSize(horizontal: false, vertical: wrap)
            .multilineTextAlignment(.trailing)
            .underline(hovering, color: (color ?? .primary).opacity(0.4))
            .onHover { hovering = $0 }
            .onTapGesture { onCopy(value) }
            .help("Click to copy \(value)")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(DefaultsKey.menuBarMode) private var menuBarMode: MenuBarMode = .icon
    @AppStorage(DefaultsKey.showLoopback) private var showLoopback = false
    @AppStorage(DefaultsKey.showLinkLocalV6) private var showLinkLocalV6 = false
    @AppStorage(DefaultsKey.enablePublicIP) private var enablePublicIP = true
    @AppStorage(DefaultsKey.enableISP) private var enableISP = false
    @AppStorage(DefaultsKey.notifyOnIPChange) private var notifyOnIPChange = true
    @AppStorage(DefaultsKey.refreshSeconds) private var refreshSeconds = 0
    @AppStorage(DefaultsKey.showIPv6) private var showIPv6 = true
    @AppStorage(DefaultsKey.showMAC) private var showMAC = true
    @AppStorage(DefaultsKey.showWiFiDetails) private var showWiFiDetails = true

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }))

                Picker("Menu bar shows", selection: $menuBarMode) {
                    ForEach(MenuBarMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }

                Picker("Auto-refresh", selection: $refreshSeconds) {
                    Text("Off").tag(0)
                    Text("15s").tag(15)
                    Text("30s").tag(30)
                    Text("1m").tag(60)
                    Text("5m").tag(300)
                }
            }

            Section("Display") {
                Toggle("Show IPv6 addresses", isOn: $showIPv6)
                Toggle("Show MAC address", isOn: $showMAC)
                Toggle("Show Wi-Fi details (signal, channel)", isOn: $showWiFiDetails)
                Toggle("Show loopback (lo0)", isOn: $showLoopback)
                Toggle("Show link-local IPv6 (fe80::)", isOn: $showLinkLocalV6)
                    .disabled(!showIPv6)
                Text("SSID needs Location access (System Settings → Privacy → Location).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Public IP") {
                Toggle("Look up public IP", isOn: $enablePublicIP)
                Toggle("Look up ISP / country", isOn: $enableISP)
                    .disabled(!enablePublicIP)
                Toggle("Notify when public IP changes", isOn: $notifyOnIPChange)
                    .disabled(!enablePublicIP)
                Text("ISP lookup contacts ipapi.co. Disable both to keep all lookups local.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

// MARK: - History

enum PanelScreen {
    case main, history
}

struct HistoryView: View {
    @EnvironmentObject var model: IPModel
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { onBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Text("History").font(.system(size: 14, weight: .bold))
                Spacer()
                Button("Clear") { model.clearHistory() }
                    .buttonStyle(.borderless)
                    .disabled(model.history.isEmpty)
            }
            if model.history.isEmpty {
                Text("No changes recorded yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.history.reversed()) { HistoryRow(entry: $0) }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(14)
    }
}

struct HistoryRow: View {
    let entry: IPHistoryEntry
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.publicIPv4 ?? "No public IP")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if let host = entry.hostname {
                    Text(host).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(entry.summary).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Hosts file window

struct HostsWindow: View {
    @State private var original = ""
    @State private var text = ""
    @State private var loading = true
    @State private var saving = false
    @State private var statusMsg: String? = nil
    @State private var statusOK = true
    @State private var statusTask: Task<Void, Never>? = nil

    private var isDirty: Bool { text != original }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                Text("/etc/hosts").font(.headline)
                if isDirty {
                    Text("Edited").font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let msg = statusMsg {
                    Label(msg, systemImage: statusOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(statusOK ? .green : .red)
                }
                if loading || saving { ProgressView().controlSize(.small) }
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading || saving)
                    .help("Reload from disk")
                Button { text = original } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!isDirty || saving)
                    .help("Discard changes")
                Button { Task { await save() } } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || saving)
                .help("Save (requires admin password)")
            }
            .padding(10)

            Divider()

            // Editor
            ZStack(alignment: .topLeading) {
                if loading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        TextEditor(text: $text)
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minWidth: 580, minHeight: 420, alignment: .topLeading)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // Status bar
            HStack(spacing: 4) {
                Text("\(text.components(separatedBy: "\n").count) lines")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(HostsFile.path).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .onAppear { load() }
    }

    private func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let content = (try? HostsFile.load()) ?? "# Could not read \(HostsFile.path)"
            DispatchQueue.main.async {
                original = content
                text = content
                loading = false
            }
        }
    }

    private func save() async {
        saving = true
        do {
            try await HostsFile.save(text)
            original = text
            showStatus("Saved successfully", ok: true)
        } catch {
            let msg = error.localizedDescription
            // User cancelled auth dialog — don't show an error message.
            if !msg.lowercased().contains("cancel") {
                showStatus("Save failed: \(msg)", ok: false)
            }
        }
        saving = false
    }

    private func showStatus(_ msg: String, ok: Bool) {
        statusMsg = msg; statusOK = ok
        statusTask?.cancel()
        statusTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { statusMsg = nil }
        }
    }
}

// MARK: - Table windows (route table / open ports)

struct TableToolbar: View {
    let title: String
    let count: Int
    let loading: Bool
    let onRefresh: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Text("\(count)")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.secondary.opacity(0.15), in: Capsule())
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { onRefresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(loading)
            Button { onCopy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .disabled(count == 0)
        }
        .padding(10)
    }
}

struct RoutesWindow: View {
    @State private var rows: [RouteEntry] = []
    @State private var loading = true
    @State private var sort: [KeyPathComparator<RouteEntry>] = [.init(\.netif)]

    var body: some View {
        VStack(spacing: 0) {
            TableToolbar(title: "Route Table", count: rows.count, loading: loading,
                         onRefresh: { Task { await load() } },
                         onCopy: { Clipboard.copy(tsv()) })
            Divider()
            Table(rows, sortOrder: $sort) {
                TableColumn("Destination", value: \.destination) { Text($0.destination).monospaced() }
                TableColumn("Gateway", value: \.gateway) { Text($0.gateway).monospaced() }
                TableColumn("Flags", value: \.flags) { Text($0.flags) }.width(min: 60)
                TableColumn("Interface", value: \.netif) { Text($0.netif) }.width(min: 70)
                TableColumn("Family", value: \.family) { Text($0.family) }.width(min: 55)
                TableColumn("Expire", value: \.expire) { Text($0.expire) }.width(min: 55)
            }
            .onChange(of: sort) { _, s in rows.sort(using: s) }
        }
        .frame(minWidth: 540, minHeight: 320)
        .task { await load() }
    }

    private func load() async {
        loading = true
        var r = await SystemInfo.routes()
        r.sort(using: sort)
        rows = r
        loading = false
    }

    private func tsv() -> String {
        let header = "Destination\tGateway\tFlags\tInterface\tFamily\tExpire"
        let body = rows.map { "\($0.destination)\t\($0.gateway)\t\($0.flags)\t\($0.netif)\t\($0.family)\t\($0.expire)" }
        return ([header] + body).joined(separator: "\n")
    }
}

struct PortsWindow: View {
    @State private var rows: [PortEntry] = []
    @State private var loading = true
    @State private var sort: [KeyPathComparator<PortEntry>] = [.init(\.port)]

    var body: some View {
        VStack(spacing: 0) {
            TableToolbar(title: "Open Ports (LISTEN)", count: rows.count, loading: loading,
                         onRefresh: { Task { await load() } },
                         onCopy: { Clipboard.copy(tsv()) })
            Divider()
            Table(rows, sortOrder: $sort) {
                TableColumn("Port", value: \.port) { Text($0.portText).monospaced() }.width(min: 60)
                TableColumn("Proto", value: \.proto) { Text($0.proto) }.width(min: 55)
                TableColumn("Address", value: \.address) { Text($0.address).monospaced() }
                TableColumn("Process", value: \.process) { Text($0.process).bold() }
                TableColumn("PID", value: \.pid) { Text($0.pid).monospaced() }.width(min: 55)
                TableColumn("User", value: \.user) { Text($0.user) }
            }
            .onChange(of: sort) { _, s in rows.sort(using: s) }
        }
        .frame(minWidth: 600, minHeight: 360)
        .task { await load() }
    }

    private func load() async {
        loading = true
        var p = await SystemInfo.ports()
        p.sort(using: sort)
        rows = p
        loading = false
    }

    private func tsv() -> String {
        let header = "Port\tProto\tAddress\tProcess\tPID\tUser"
        let body = rows.map { "\($0.portText)\t\($0.proto)\t\($0.address)\t\($0.process)\t\($0.pid)\t\($0.user)" }
        return ([header] + body).joined(separator: "\n")
    }
}

struct DiagnosticsWindow: View {
    @State private var dns: [String] = []
    @State private var rows: [PingResult] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            TableToolbar(title: "Network Diagnostics", count: rows.count, loading: loading,
                         onRefresh: { Task { await load() } },
                         onCopy: { Clipboard.copy(tsv()) })
            Divider()
            if !dns.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "server.rack").foregroundStyle(.secondary)
                    Text("DNS").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(dns.joined(separator: ", "))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            Table(rows) {
                TableColumn("Target") { r in
                    HStack(spacing: 6) {
                        Circle().fill(r.reachable ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(r.label)
                    }
                }.width(min: 110)
                TableColumn("Host") { Text($0.host).monospaced() }
                TableColumn("Status") { r in
                    Text(r.statusText).foregroundStyle(r.reachable ? Color.primary : Color.red)
                }.width(min: 70)
                TableColumn("Latency") { Text($0.latencyText).monospaced() }.width(min: 70)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await load() }
    }

    private func load() async {
        loading = true
        let r = await SystemInfo.diagnostics()
        dns = r.dns
        rows = r.results
        loading = false
    }

    private func tsv() -> String {
        let header = "Target\tHost\tStatus\tLatency"
        let body = rows.map { "\($0.label)\t\($0.host)\t\($0.statusText)\t\($0.latencyText)" }
        let dnsLine = dns.isEmpty ? "" : "DNS servers: \(dns.joined(separator: ", "))\n"
        return dnsLine + ([header] + body).joined(separator: "\n")
    }
}

struct LanWindow: View {
    @State private var rows: [LanDevice] = []
    @State private var loading = true
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("LAN Devices").font(.headline)
                Text("\(rows.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.secondary.opacity(0.15), in: Capsule())
                Spacer()
                if loading || scanning {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        if scanning { Text("Scanning…").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(loading || scanning)
                Button { Task { await deepScan() } } label: {
                    Label("Deep Scan", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(loading || scanning)
                .help("Ping-sweep the subnet to discover more devices (~10s)")
                Button { Clipboard.copy(tsv()) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(rows.isEmpty)
            }
            .padding(10)
            Divider()
            Table(rows) {
                TableColumn("Device") { d in
                    HStack(spacing: 6) {
                        Image(systemName: icon(d)).foregroundStyle(color(d))
                        Text(d.label)
                    }
                }.width(min: 130)
                TableColumn("IP") { Text($0.ip).monospaced() }.width(min: 110)
                TableColumn("MAC") { Text($0.mac).monospaced() }.width(min: 140)
                TableColumn("Interface") { Text($0.netif) }.width(min: 70)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .task { await load() }
    }

    private func icon(_ d: LanDevice) -> String {
        if d.isSelf { return "laptopcomputer" }
        if d.isGateway { return "wifi.router" }
        return "desktopcomputer"
    }
    private func color(_ d: LanDevice) -> Color {
        if d.isSelf { return .green }
        if d.isGateway { return .blue }
        return .secondary
    }

    private func load() async {
        loading = true
        rows = await SystemInfo.lanDevices(resolveNames: true)
        loading = false
    }

    private func deepScan() async {
        scanning = true
        await SystemInfo.pingSweep()
        rows = await SystemInfo.lanDevices(resolveNames: true)
        scanning = false
    }

    private func tsv() -> String {
        let header = "Device\tIP\tMAC\tInterface"
        let body = rows.map { "\($0.label)\t\($0.ip)\t\($0.mac)\t\($0.netif)" }
        return ([header] + body).joined(separator: "\n")
    }
}
