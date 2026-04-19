import SwiftUI

struct SettingsView: View {
    @State private var dnsServers: String = ""
    @State private var enableDNSoverHTTPS = false
    @State private var dohURL: String = "https://dns.google/dns-query"
    @State private var routingMode: String = "Rule"

    @State private var appVersion: String = "1.0.0"
    @State private var buildNumber: String = "1"
    
    // 网络高级设置
    @State private var bypassChina = true
    @State private var adBlock = true
    @State private var forceDNS = true
    
    // Language
    @State private var selectedLanguage: AppLanguage = LanguageManager.shared.currentLanguage
    
    // Limits
    @State private var maxRuleCount: Int = 10000
    
    @ObservedObject var geodata = GeoDataManager.shared
    
    private let appGroupId = "group.com.proxynaut"
    
    var body: some View {
        NavigationStack {
            Form {
                Section(LocalizationManager.sectionRoutingMode) {
                    Picker(LocalizationManager.labelMode, selection: $routingMode) {
                        Text(LocalizationManager.routingRule).tag("Rule")
                        Text(LocalizationManager.routingGlobal).tag("Global")
                        Text(LocalizationManager.routingDirect).tag("Direct")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: routingMode) { newValue in
                        var config = Configuration.shared.getAppConfiguration()
                        config.routingMode = newValue
                        config.enableRouting = (newValue == "Rule")
                        Configuration.shared.save(config)
                        // 通知 ProxyExtension 重新加载，使新模式立即生效
                        AppExtensionCommunicator.shared.sendMessage(.updateConfiguration) { _ in }
                    }

                    Text(routingModeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(LocalizationManager.sectionAdvancedNetworking) {
                    Toggle(LocalizationManager.labelBypassChinaIP, isOn: $bypassChina)
                        .onChange(of: bypassChina) { _ in saveNetworkConfig() }
                    
                    Text(LocalizationManager.settingBypassDesc)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Toggle(LocalizationManager.labelEnhancedAdBlocking, isOn: $adBlock)
                        .onChange(of: adBlock) { _ in saveNetworkConfig() }

                    Toggle(LocalizationManager.labelForceDNSVPN, isOn: $forceDNS)
                        .onChange(of: forceDNS) { _ in saveNetworkConfig() }
                    
                    Text(LocalizationManager.settingForceDNSDesc)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text(LocalizationManager.string("label.max_rules"))
                        Spacer()
                        Stepper("\(maxRuleCount)", value: $maxRuleCount, in: 1000...100000, step: 1000)
                            .onChange(of: maxRuleCount) { newValue in
                                var config = Configuration.shared.getAppConfiguration()
                                config.maxRuleCount = newValue
                                Configuration.shared.save(config)
                                // Trigger rule engine reload
                                RuleSubscriptionManager.shared.reloadAllRules()
                            }
                    }
                }

                Section(LocalizationManager.sectionDNSSettings) {
                    TextField(LocalizationManager.labelDNSServers, text: $dnsServers)
                        .onChange(of: dnsServers) { _ in
                            saveDNSConfig()
                        }

                    Toggle(LocalizationManager.labelDNSOverHTTPS, isOn: $enableDNSoverHTTPS)
                        .onChange(of: enableDNSoverHTTPS) { _ in
                            saveDNSConfig()
                        }

                    if enableDNSoverHTTPS {
                        TextField(LocalizationManager.labelDoHURL, text: $dohURL)
                            .onChange(of: dohURL) { _ in
                                saveDNSConfig()
                            }
                    }
                }


                Section(LocalizationManager.string("section.language")) {
                    Picker(LocalizationManager.string("label.language"), selection: $selectedLanguage) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .onChange(of: selectedLanguage) { newValue in
                        LanguageManager.shared.setLanguage(newValue)
                    }
                }

                Section(LocalizationManager.sectionAbout) {
                    HStack {
                        Text(LocalizationManager.labelVersion)
                        Spacer()
                        Text("\(appVersion) (\(buildNumber))")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadConfig()
                Task {
                    await GeoDataManager.shared.ensureDataExists()
                }
            }
        }
    }
    
    private var routingModeDescription: String {
        switch routingMode {
        case "Rule":
            return LocalizationManager.routingRuleDesc
        case "Global":
            return LocalizationManager.routingGlobalDesc
        case "Direct":
            return LocalizationManager.routingDirectDesc
        default:
            return ""
        }
    }
    
    // MARK: - Load & Save Configuration
    
    private func loadConfig() {
        let config = Configuration.shared.getAppConfiguration()
        
        // Load app version
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        
        // Load routing mode：新字段优先，缺失时回退到旧的 enableRouting
        let persistedMode = config.routingMode
        if persistedMode == "Rule" || persistedMode == "Global" || persistedMode == "Direct" {
            routingMode = persistedMode
        } else {
            routingMode = config.enableRouting ? "Rule" : "Direct"
        }

        // Load DNS config
        if let dnsConfig = config.dnsConfig {
            dnsServers = dnsConfig.servers.joined(separator: ", ")
            enableDNSoverHTTPS = dnsConfig.enableDNSoverHTTPS
            dohURL = dnsConfig.dohURL ?? "https://dns.google/dns-query"
        } else {
            dnsServers = "8.8.8.8, 1.1.1.1"
        }
        
        // Load Network Config
        let netConfig = config.networkConfig ?? NetworkConfig()
        bypassChina = netConfig.bypassChina
        adBlock = netConfig.adBlock
        forceDNS = netConfig.forceDNS
        
        maxRuleCount = config.maxRuleCount == 0 ? 10000 : config.maxRuleCount
    }
    
    private func saveNetworkConfig() {
        var config = Configuration.shared.getAppConfiguration()
        var netConfig = config.networkConfig ?? NetworkConfig()
        netConfig.bypassChina = bypassChina
        netConfig.adBlock = adBlock
        netConfig.forceDNS = forceDNS
        config.networkConfig = netConfig
        Configuration.shared.save(config)
    }

    private func saveDNSConfig() {
        var config = Configuration.shared.getAppConfiguration()
        
        let servers = dnsServers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        
        var dnsConfig = config.dnsConfig ?? DNSConfig()
        dnsConfig.servers = servers.isEmpty ? ["8.8.8.8", "1.1.1.1"] : servers
        dnsConfig.enableDNSoverHTTPS = enableDNSoverHTTPS
        dnsConfig.dohURL = dohURL
        
        config.dnsConfig = dnsConfig
        Configuration.shared.save(config)
        
        // 更新 DNSResolver
        DNSResolver.shared.configure(config: dnsConfig)
    }
}