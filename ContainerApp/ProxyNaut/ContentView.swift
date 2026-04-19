import SwiftUI

@main
struct ProxyNautApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var autoRefreshTimer: Timer?

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .onOpenURL { url in
                    handleURL(url)
                }
                .task {
                    // 启动时检查一次：自上次刷新已超过用户设定间隔的订阅立即刷新
                    await SubscriptionManager.shared.refreshIfNeeded()
                    await RuleSubscriptionManager.shared.refreshIfNeeded()
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                // 回到前台时刷新订阅状态，缩短 App 长期不开时 Extension 缓存的滞后
                Task {
                    await SubscriptionManager.shared.refreshIfNeeded()
                    await RuleSubscriptionManager.shared.refreshIfNeeded()
                }
                startAutoRefreshTimer()
            case .background, .inactive:
                stopAutoRefreshTimer()
            @unknown default:
                break
            }
        }
    }

    /// 前台保持很久时（例如开着 App 过夜），由 Timer 每 15 分钟触发一次检查，
    /// 命中 hourly/daily/weekly 窗口的订阅会自动刷新。
    private func startAutoRefreshTimer() {
        guard autoRefreshTimer == nil else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task {
                await SubscriptionManager.shared.refreshIfNeeded()
                await RuleSubscriptionManager.shared.refreshIfNeeded()
            }
        }
    }

    private func stopAutoRefreshTimer() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }
    
    private func handleURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        
        if url.scheme == "proxynaut" {
            if url.host == "import" {
                if let queryItems = components.queryItems,
                   let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                    let subscription = Subscription(
                        name: "Imported",
                        url: urlParam,
                        autoUpdate: true,
                        updateInterval: .daily
                    )
                    SubscriptionManager.shared.addSubscription(subscription)
                }
            }
        }
        
        if url.scheme == "vmess" || url.scheme == "ss" || url.scheme == "trojan" {
            let subscription = Subscription(
                name: "Imported Link",
                url: url.absoluteString,
                autoUpdate: false,
                updateInterval: .manual
            )
            SubscriptionManager.shared.addSubscription(subscription)
        }
    }
}

struct MainTabView: View {
    @StateObject private var languageManager = LanguageManager.shared
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            NodeListView()
                .tabItem {
                    Label(LocalizationManager.tabProxy, systemImage: "network")
                }
                .tag(0)
            
            SubscriptionView()
                .tabItem {
                    Label(LocalizationManager.tabSubscriptions, systemImage: "link.circle")
                }
                .tag(1)
            
            RulesView()
                .tabItem {
                    Label(LocalizationManager.tabRules, systemImage: "list.bullet.rectangle")
                }
                .tag(2)
            
            LogsView()
                .tabItem {
                    Label(LocalizationManager.tabLogs, systemImage: "doc.text")
                }
                .tag(3)
            
            SettingsView()
                .tabItem {
                    Label(LocalizationManager.tabSettings, systemImage: "gear")
                }
                .tag(4)
        }
        .id(languageManager.currentLanguage)
    }
}

struct StatisticsView: View {
    let statistics: ProxyStatistics
    
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 30) {
                StatItemView(
                    icon: "arrow.up",
                    title: LocalizationManager.statUpload,
                    value: formatBytes(statistics.bytesSent)
                )
                
                StatItemView(
                    icon: "arrow.down",
                    title: LocalizationManager.statDownload,
                    value: formatBytes(statistics.bytesReceived)
                )
                
                StatItemView(
                    icon: "link",
                    title: LocalizationManager.statConnections,
                    value: "\(statistics.activeConnections)"
                )
            }
            
            if statistics.averageUploadSpeed > 0 || statistics.averageDownloadSpeed > 0 {
                HStack(spacing: 30) {
                    StatItemView(
                        icon: "arrow.up.circle",
                        title: LocalizationManager.statUploadSpeed,
                        value: formatSpeed(statistics.averageUploadSpeed)
                    )
                    
                    StatItemView(
                        icon: "arrow.down.circle",
                        title: LocalizationManager.statDownloadSpeed,
                        value: formatSpeed(statistics.averageDownloadSpeed)
                    )
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }
}

struct StatItemView: View {
    let icon: String
    let title: String
    let value: String
    
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.title2)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
        }
    }
}