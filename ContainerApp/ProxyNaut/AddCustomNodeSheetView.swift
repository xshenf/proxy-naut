import SwiftUI

struct AddCustomNodeSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared

    @State private var name: String = ""
    @State private var type: ProxyProtocol = .vmess
    @State private var serverAddress: String = ""
    @State private var serverPort: String = ""
    @State private var password: String = ""
    @State private var username: String = ""
    @State private var encryption: String = "chacha20-ietf-poly1305"
    @State private var alterId: String = "0"
    @State private var network: String = "tcp"
    @State private var tls: Bool = false
    @State private var sni: String = ""
    @State private var path: String = ""
    @State private var grpcServiceName: String = ""
    @State private var skipCertVerify: Bool = false

    // 新协议字段
    @State private var uuid: String = ""               // TUIC 专用
    @State private var flow: String = ""               // VLESS
    @State private var obfs: String = "none"           // Hysteria2
    @State private var obfsPassword: String = ""       // Hysteria2
    @State private var upMbps: String = ""             // Hysteria2
    @State private var downMbps: String = ""           // Hysteria2
    @State private var congestionControl: String = "bbr" // TUIC
    @State private var udpRelayMode: String = "native"   // TUIC
    @State private var alpnText: String = ""           // 逗号分隔

    // 导入链接
    @State private var importLink: String = ""
    @State private var showingImportSection = false

    private var isFormValid: Bool {
        !name.isEmpty && !serverAddress.isEmpty && !serverPort.isEmpty && UInt16(serverPort) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Import from Link") {
                    Button {
                        showingImportSection.toggle()
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                            Text("Import from Proxy Link")
                        }
                    }

                    if showingImportSection {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $importLink)
                                .frame(height: 80)
                                .font(.caption)

                            Button("Parse Link") {
                                parseImportLink()
                            }
                            .disabled(importLink.isEmpty)
                        }
                    }
                }

                Section("Basic Configuration") {
                    TextField("Name", text: $name)

                    Picker("Protocol", selection: $type) {
                        ForEach(ProxyProtocol.allCases, id: \.self) { protocolType in
                            Text(protocolType.displayName).tag(protocolType)
                        }
                    }
                    .onChange(of: type) { _ in
                        updateDefaultPort()
                    }

                    TextField("Server Address", text: $serverAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    TextField("Port", text: $serverPort)
                        .keyboardType(.numberPad)
                }

                Section("Authentication") {
                    switch type {
                    case .vmess:
                        TextField("UUID", text: $password)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        TextField("Alter ID", text: $alterId)
                            .keyboardType(.numberPad)
                    case .trojan:
                        SecureField("Password", text: $password)
                    case .shadowsocks:
                        TextField("Encryption Method", text: $encryption)
                        SecureField("Password", text: $password)
                    case .http, .https:
                        TextField("Username (optional)", text: $username)
                        SecureField("Password (optional)", text: $password)
                    case .socks5:
                        TextField("Username (optional)", text: $username)
                        SecureField("Password (optional)", text: $password)
                    case .vless:
                        TextField("UUID", text: $password)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        TextField("Flow (optional)", text: $flow)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    case .hysteria2:
                        SecureField("Password", text: $password)
                    case .tuic:
                        TextField("UUID", text: $uuid)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        SecureField("Password", text: $password)
                    }
                }

                // 传输层：仅 VMess / VLESS / Trojan 涉及 ws/grpc
                if type == .vmess || type == .vless || type == .trojan {
                    Section("Transport") {
                        Picker("Network", selection: $network) {
                            Text("TCP").tag("tcp")
                            Text("WebSocket").tag("ws")
                            Text("gRPC").tag("grpc")
                            Text("HTTP").tag("http")
                        }

                        if type == .vmess || type == .trojan || type == .vless {
                            Toggle("Enable TLS", isOn: $tls)
                        }

                        if tls || type == .https {
                            TextField("SNI (optional)", text: $sni)
                                .autocapitalization(.none)
                            Toggle("Skip Certificate Verify", isOn: $skipCertVerify)
                        }

                        if network == "ws" {
                            TextField("Path", text: $path)
                        }

                        if network == "grpc" {
                            TextField("gRPC Service Name", text: $grpcServiceName)
                        }
                    }
                }

                // Hysteria2 专属
                if type == .hysteria2 {
                    Section("Hysteria2 Options") {
                        Picker("Obfs", selection: $obfs) {
                            Text("None").tag("none")
                            Text("Salamander").tag("salamander")
                        }
                        if obfs != "none" {
                            TextField("Obfs Password", text: $obfsPassword)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        TextField("Up Mbps (optional)", text: $upMbps)
                            .keyboardType(.numberPad)
                        TextField("Down Mbps (optional)", text: $downMbps)
                            .keyboardType(.numberPad)
                        TextField("SNI (optional)", text: $sni)
                            .autocapitalization(.none)
                        Toggle("Skip Certificate Verify", isOn: $skipCertVerify)
                        TextField("ALPN (comma separated)", text: $alpnText)
                            .autocapitalization(.none)
                    }
                }

                // TUIC 专属
                if type == .tuic {
                    Section("TUIC Options") {
                        Picker("Congestion Control", selection: $congestionControl) {
                            Text("BBR").tag("bbr")
                            Text("Cubic").tag("cubic")
                            Text("New Reno").tag("new_reno")
                        }
                        Picker("UDP Relay Mode", selection: $udpRelayMode) {
                            Text("Native").tag("native")
                            Text("QUIC").tag("quic")
                        }
                        TextField("SNI (optional)", text: $sni)
                            .autocapitalization(.none)
                        Toggle("Skip Certificate Verify", isOn: $skipCertVerify)
                        TextField("ALPN (comma separated)", text: $alpnText)
                            .autocapitalization(.none)
                    }
                }

                Section {
                    Button("Save") {
                        saveNode()
                    }
                    .disabled(!isFormValid)
                }
            }
            .navigationTitle("Add Custom Proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func parseImportLink() {
        let trimmed = importLink.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmed) else {
            return
        }

        switch url.scheme?.lowercased() {
        case "vmess":
            if let node = parseVMessLink(trimmed) {
                fillFromNode(node)
            }
        case "ss":
            if let node = parseSSLink(trimmed) {
                fillFromNode(node)
            }
        case "trojan":
            if let node = parseTrojanLink(trimmed) {
                fillFromNode(node)
            }
        case "vless":
            if let node = subscriptionManager.parseVLESSLink(trimmed) {
                fillFromNode(node)
            }
        case "hysteria2", "hy2":
            if let node = subscriptionManager.parseHysteria2Link(trimmed) {
                fillFromNode(node)
            }
        case "tuic":
            if let node = subscriptionManager.parseTUICLink(trimmed) {
                fillFromNode(node)
            }
        default:
            break
        }
    }

    private func parseVMessLink(_ link: String) -> ProxyNode? {
        guard let url = URL(string: link),
              let base64 = url.host else { return nil }

        guard let data = Data(base64Encoded: base64),
              let jsonString = String(data: data, encoding: .utf8),
              let jsonData = jsonString.data(using: .utf8) else { return nil }

        struct VMessConfig: Codable {
            let add: String
            let port: String
            let id: String
            let ps: String?
            let aid: String?
            let net: String?
            let path: String?
            let tls: String?
            let sni: String?
            let host: String?
        }

        guard let config = try? JSONDecoder().decode(VMessConfig.self, from: jsonData) else { return nil }

        var node = ProxyNode(
            type: .vmess,
            serverAddress: config.add,
            serverPort: UInt16(config.port) ?? 443
        )
        node.name = config.ps ?? config.add
        node.password = config.id
        node.alterId = Int(config.aid ?? "0")
        node.network = config.net
        node.path = config.path
        node.tls = config.tls == "tls"
        node.sni = config.sni ?? config.host

        return node
    }

    private func parseSSLink(_ link: String) -> ProxyNode? {
        let urlPart = String(link.dropFirst(5))
        let parts = urlPart.split(separator: "#", maxSplits: 1)

        guard let url = URL(string: String(parts[0])) else { return nil }

        guard let userInfo = url.user else { return nil }
        let userInfoDecoded = decodeBase64(userInfo) ?? userInfo

        let components = userInfoDecoded.split(separator: ":", maxSplits: 1)
        guard components.count == 2 else { return nil }

        let method = String(components[0])
        let password = String(components[1])

        var name = "SS Node"
        if parts.count > 1 {
            name = decodeBase64(String(parts[1])) ?? String(parts[1])
        }

        var node = ProxyNode(
            type: .shadowsocks,
            serverAddress: url.host ?? "",
            serverPort: UInt16(url.port ?? 443)
        )
        node.name = name
        node.encryption = method
        node.password = password

        return node
    }

    private func parseTrojanLink(_ link: String) -> ProxyNode? {
        guard let url = URL(string: link) else { return nil }

        guard let password = url.user,
              let host = url.host else { return nil }

        var name = "Trojan Node"
        if let fragment = url.fragment {
            name = decodeBase64(fragment) ?? fragment
            if name.isEmpty { name = "Trojan Node" }
        }

        var node = ProxyNode(
            type: .trojan,
            serverAddress: host,
            serverPort: UInt16(url.port ?? 443)
        )
        node.name = name
        node.password = password
        node.tls = true

        return node
    }

    private func decodeBase64(_ string: String) -> String? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }

        return decoded
    }

    private func fillFromNode(_ node: ProxyNode) {
        name = node.name ?? ""
        type = node.type
        serverAddress = node.serverAddress
        serverPort = String(node.serverPort)
        password = node.password ?? ""
        username = node.username ?? ""
        encryption = node.encryption ?? "chacha20-ietf-poly1305"
        alterId = String(node.alterId ?? 0)
        network = node.network ?? "tcp"
        tls = node.tls ?? false
        sni = node.sni ?? ""
        path = node.path ?? ""
        grpcServiceName = node.grpcServiceName ?? ""
        skipCertVerify = node.skipCertVerify ?? false
        uuid = node.uuid ?? ""
        flow = node.flow ?? ""
        obfs = node.obfs ?? "none"
        obfsPassword = node.obfsPassword ?? ""
        upMbps = node.upMbps.map { String($0) } ?? ""
        downMbps = node.downMbps.map { String($0) } ?? ""
        congestionControl = node.congestionControl ?? "bbr"
        udpRelayMode = node.udpRelayMode ?? "native"
        alpnText = node.alpn?.joined(separator: ",") ?? ""
    }

    private func updateDefaultPort() {
        if serverPort.isEmpty || serverPort == "443" || serverPort == "80" {
            switch type {
            case .vmess, .trojan, .shadowsocks, .https, .vless, .hysteria2, .tuic:
                serverPort = "443"
            case .http:
                serverPort = "8080"
            case .socks5:
                serverPort = "1080"
            }
        }
    }

    private func saveNode() {
        guard let port = UInt16(serverPort) else { return }

        var node = ProxyNode(
            type: type,
            serverAddress: serverAddress,
            serverPort: port
        )

        node.name = name
        node.password = password.isEmpty ? nil : password
        node.username = username.isEmpty ? nil : username
        node.encryption = encryption.isEmpty ? nil : encryption
        node.alterId = Int(alterId) ?? 0
        node.network = network
        node.tls = tls
        node.sni = sni.isEmpty ? nil : sni
        node.path = path.isEmpty ? nil : path
        node.grpcServiceName = grpcServiceName.isEmpty ? nil : grpcServiceName
        node.skipCertVerify = skipCertVerify

        // 按协议写入新字段
        switch type {
        case .vless:
            node.flow = flow.isEmpty ? nil : flow
        case .hysteria2:
            node.obfs = (obfs == "none") ? nil : obfs
            node.obfsPassword = obfsPassword.isEmpty ? nil : obfsPassword
            node.upMbps = Int(upMbps)
            node.downMbps = Int(downMbps)
        case .tuic:
            node.uuid = uuid.isEmpty ? nil : uuid
            node.congestionControl = congestionControl
            node.udpRelayMode = udpRelayMode
        default:
            break
        }

        if !alpnText.isEmpty && (type == .vless || type == .hysteria2 || type == .tuic) {
            let list = alpnText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !list.isEmpty { node.alpn = list }
        }

        // 添加到选定的订阅
        if let selectedSubscription = subscriptionManager.selectedSubscription {
            var updated = selectedSubscription
            updated.nodes.append(node)
            subscriptionManager.updateSubscription(updated)
        } else {
            // 如果没有选定的订阅，创建一个默认的
            let subscription = Subscription(name: "Custom Nodes", url: "")
            var updated = subscription
            updated.nodes.append(node)
            subscriptionManager.addSubscription(updated)
        }

        dismiss()
    }
}
