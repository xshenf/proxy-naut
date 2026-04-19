import SwiftUI

struct ConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProtocol: ProxyProtocol = .http
    @State private var serverAddress: String = ""
    @State private var serverPort: String = "1081"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var sni: String = ""
    @State private var skipCertVerify: Bool = false
    @State private var enableTLS: Bool = false
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                protocolSelectionTab
                    .tabItem {
                        Label("Protocol", systemImage: "network")
                    }
                    .tag(0)
                
                serverConfigTab
                    .tabItem {
                        Label("Server", systemImage: "server.rack")
                    }
                    .tag(1)
                
                advancedSettingsTab
                    .tabItem {
                        Label("Advanced", systemImage: "gear")
                    }
                    .tag(2)
            }
            .navigationTitle("Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveConfiguration()
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var protocolSelectionTab: some View {
        Form {
            Section("Select Protocol") {
                ForEach(ProxyProtocol.allCases, id: \.self) { proto in
                    HStack {
                        Image(systemName: iconForProtocol(proto))
                            .foregroundColor(selectedProtocol == proto ? .blue : .gray)
                        Text(proto.displayName)
                        Spacer()
                        if selectedProtocol == proto {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedProtocol = proto
                    }
                }
            }
            
            Section("Description") {
                Text(descriptionForProtocol(selectedProtocol))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var serverConfigTab: some View {
        Form {
            Section("Server Address") {
                TextField("Server IP or Domain", text: $serverAddress)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                
                TextField("Port", text: $serverPort)
                    .keyboardType(.numberPad)
            }
            
            if requiresAuth(selectedProtocol) {
                Section("Authentication") {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
            }
            
            if supportsTLS(selectedProtocol) {
                Section("TLS Settings") {
                    Toggle("Enable TLS", isOn: $enableTLS)
                    if enableTLS {
                        TextField("Server Name (SNI)", text: $sni)
                            .autocapitalization(.none)
                        Toggle("Skip Certificate Verify", isOn: $skipCertVerify)
                    }
                }
            }
        }
    }
    
    private var advancedSettingsTab: some View {
        Form {
            Section("DNS") {
                Toggle("Enable DNS", isOn: .constant(true))
                TextField("DNS Servers", text: .constant("8.8.8.8, 1.1.1.1"))
                    .keyboardType(.numbersAndPunctuation)
            }
            
            Section("Network") {
                Picker("Interface", selection: .constant("all")) {
                    Text("All").tag("all")
                    Text("Wi-Fi Only").tag("wifi")
                    Text("Cellular Only").tag("cellular")
                }
                
                Stepper("MTU: 1500", value: .constant(1500), in: 1280...2000)
            }
            
            Section("Logging") {
                Picker("Log Level", selection: .constant("warning")) {
                    Text("Debug").tag("debug")
                    Text("Info").tag("info")
                    Text("Warning").tag("warning")
                    Text("Error").tag("error")
                }
            }
        }
    }
    
    private func iconForProtocol(_ proto: ProxyProtocol) -> String {
        switch proto {
        case .http, .https: return "globe"
        case .socks5: return "arrow.triangle.swap"
        case .shadowsocks: return "lock.shield"
        case .vmess: return "bolt.fill"
        case .trojan: return "bolt.circle.fill"
        case .vless: return "sparkles"
        case .hysteria2: return "hare.fill"
        case .tuic: return "bolt.horizontal.fill"
        }
    }

    private func descriptionForProtocol(_ proto: ProxyProtocol) -> String {
        switch proto {
        case .http: return "Basic HTTP proxy protocol. Suitable for simple web browsing."
        case .https: return "HTTPS proxy with TLS tunneling support."
        case .socks5: return "SOCKS5 protocol supporting both TCP and UDP."
        case .shadowsocks: return "Shadowsocks protocol with AEAD encryption."
        case .vmess: return "VMess protocol from V2Ray project."
        case .trojan: return "Trojan protocol masquerading as HTTPS traffic."
        case .vless: return "VLESS protocol, XTLS/Reality compatible."
        case .hysteria2: return "Hysteria2 QUIC-based high-performance protocol."
        case .tuic: return "TUIC QUIC-based low-latency protocol."
        }
    }
    
    private func requiresAuth(_ proto: ProxyProtocol) -> Bool {
        switch proto {
        case .http, .https, .socks5: return true
        default: return false
        }
    }
    
    private func supportsTLS(_ proto: ProxyProtocol) -> Bool {
        switch proto {
        case .https, .vmess, .trojan: return true
        default: return false
        }
    }
    
    private func saveConfiguration() {
        var config = AppConfiguration()
        config.selectedProtocol = selectedProtocol
        config.listenPort = UInt16(serverPort) ?? 1081
        
        switch selectedProtocol {
        case .http, .https:
            config.httpConfig = HTTPProxyConfig(
                listenPort: UInt16(serverPort) ?? 1081,
                enableAuthentication: !username.isEmpty,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password
            )
        case .socks5:
            config.socks5Config = SOCKS5Config(
                listenPort: UInt16(serverPort) ?? 1081,
                enableAuthentication: !username.isEmpty,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password
            )
        case .shadowsocks:
            config.shadowsocksConfig = ShadowsocksConfig(
                serverAddress: serverAddress,
                serverPort: UInt16(serverPort) ?? 1081,
                password: password
            )
        case .vmess:
            config.vmessConfig = VMessConfig(
                serverAddress: serverAddress,
                serverPort: UInt16(serverPort) ?? 1081,
                userId: username,
                tls: enableTLS,
                skipCertVerify: skipCertVerify,
                tlsServerName: sni.isEmpty ? nil : sni
            )
        case .trojan:
            config.trojanConfig = TrojanConfig(
                serverAddress: serverAddress,
                serverPort: UInt16(serverPort) ?? 1081,
                password: password,
                enableTLS: enableTLS,
                skipCertVerify: skipCertVerify,
                tlsServerName: sni.isEmpty ? nil : sni
            )
        case .vless, .hysteria2, .tuic:
            // 这三种协议不使用旧 Configuration 的 *Config 结构，
            // 节点信息保存在订阅/自定义节点里，由 SingBoxConfigGenerator 直接读取
            break
        }
        
        ConfigurationManager.shared.save(config)
    }
}