import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct NodeListView: View {
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @ObservedObject private var proxyManager = ProxyManager.shared
    @ObservedObject private var extensionCommunicator = AppExtensionCommunicator.shared

    @State private var showingAddSubscription = false
    @State private var showingAddCustomNode = false
    @State private var isRefreshing = false
    @State private var showingLatencyAlert = false
    @State private var selectedGroupName: String = "DEFAULT"
    @State private var hideTimeoutNodes: Bool = true

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 12)
    ]

    private var isActive: Bool {
        return extensionCommunicator.extensionStatus == "connected"
    }

    /// 当前是否处于自动选择模式（urltest / fallback 策略组）
    private var isAutoGroupMode: Bool {
        guard let sub = subscriptionManager.selectedSubscription else { return false }
        guard let group = sub.proxyGroups.first(where: { $0.name == selectedGroupName }) else { return false }
        return group.type == .urlTest || group.type == .fallback
    }
    
    // init() 移至 AppExtensionCommunicator 以避免 StateObject 提前访问警告
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 状态横幅
                    if isActive || extensionCommunicator.extensionStatus == "connecting" {
                        statusBanner
                    }
                    
                    if let error = proxyManager.errorMessage {
                        errorBanner(error)
                    }
                    
                    if subscriptionManager.subscriptions.isEmpty {
                        emptyStateView
                    } else if let subscription = subscriptionManager.selectedSubscription {
                        // 显示选定的订阅
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(subscription.name)
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button {
                                    refreshSubscription(subscription)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal)

                            // --- 策略组选择器 (高级样式) ---
                            if !subscription.proxyGroups.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(subscription.proxyGroups) { group in
                                            let isSelected = selectedGroupName == group.name
                                            Button {
                                                selectedGroupName = group.name
                                                // 触觉反馈
                                                #if canImport(UIKit)
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                #endif
                                                
                                                // 切换到策略组模式
                                                selectAndSwitchGroup(group)
                                            } label: {
                                                Text(localizedGroupName(group.name))
                                                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                                    .padding(.horizontal, 16)
                                                    .padding(.vertical, 8)
                                                    .background(
                                                        ZStack {
                                                            if isSelected {
                                                                RoundedRectangle(cornerRadius: 20)
                                                                    .fill(LinearGradient(
                                                                        gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
                                                                        startPoint: .topLeading,
                                                                        endPoint: .bottomTrailing
                                                                    ))
                                                                    .shadow(color: Color.blue.opacity(0.3), radius: 4, x: 0, y: 2)
                                                            } else {
                                                                RoundedRectangle(cornerRadius: 20)
                                                                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                                                                    .overlay(
                                                                        RoundedRectangle(cornerRadius: 20)
                                                                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                                                    )
                                                            }
                                                        }
                                                    )
                                                    .foregroundColor(isSelected ? .white : .primary)
                                            }
                                        }
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                }
                                .padding(.vertical, 2)
                            }

                            // --- 过滤超时节点开关 ---
                            HStack {
                                Text(LocalizationManager.filterHideTimeout)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Toggle("", isOn: $hideTimeoutNodes)
                                    .labelsHidden()
                                    .scaleEffect(0.8)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)

                            if subscription.nodes.isEmpty {
                                Text(LocalizationManager.emptyNoNodes)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal)
                            } else {
                                let displayNodes = selectedGroupName == "DEFAULT" ? subscription.nodes : 
                                    (subscription.proxyGroups.first(where: { $0.name == selectedGroupName })?.getNodes(allNodes: subscription.nodes) ?? subscription.nodes)
                                let filteredNodes = hideTimeoutNodes ? displayNodes.filter { $0.latency >= 0 || $0.latency == -1 } : displayNodes
                                
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(filteredNodes) { node in
                                        let autoNode = subscriptionManager.activeGroupNode()
                                        NodeCardView(
                                            node: node,
                                            isSelected: subscriptionManager.currentNode?.id == node.id,
                                            isActive: isActive && subscriptionManager.currentNode?.id == node.id,
                                            isAutoSelected: isActive && isAutoGroupMode && autoNode?.id == node.id,
                                            autoDelay: isAutoGroupMode ? subscriptionManager.groupDelay(for: node) : nil
                                        )
                                        .onTapGesture {
                                            selectAndSwitchNode(node)
                                        }
                                    }
                                }
                                .padding(.horizontal)
                                
                                if filteredNodes.isEmpty && !displayNodes.isEmpty {
                                    Text(LocalizationManager.emptyAllNodesTimeout)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 50))
                                .foregroundColor(.gray)
                            Text(LocalizationManager.emptyNoSubscription)
                                .font(.headline)
                            Text(LocalizationManager.emptySelectSubscription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
                .padding(.vertical)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Google 测试按钮
                    Button {
                        testGoogle()
                    } label: {
                        Image(systemName: "globe.asia.australia")
                    }
                    .disabled(!isActive)
                    
                    // 测延迟按钮
                    Button {
                        testLatency()
                    } label: {
                        Image(systemName: "bolt.fill")
                    }
                    
                    // 启动/关闭按钮
                    Button {
                        toggleConnection()
                    } label: {
                        Image(systemName: isActive ? "stop.circle.fill" : (extensionCommunicator.extensionStatus == "connecting" ? "arrow.2.circlepath.circle.fill" : "play.circle.fill"))
                            .foregroundColor(isActive ? .red : (extensionCommunicator.extensionStatus == "connecting" ? .orange : .green))
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            showingAddSubscription = true
                        } label: {
                            Label(LocalizationManager.menuAddSubscription, systemImage: "plus")
                        }

                        Button {
                            showingAddCustomNode = true
                        } label: {
                            Label(LocalizationManager.menuAddCustomProxy, systemImage: "plus.circle")
                        }

                        Button {
                            refreshAll()
                        } label: {
                            Label(LocalizationManager.menuRefreshAll, systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.circle")
                    }
                }
            }
            .onChange(of: subscriptionManager.selectedSubscriptionId) { _ in
                selectedGroupName = "DEFAULT"
            }
            .sheet(isPresented: $showingAddSubscription) {
                AddSubscriptionSheet()
            }
            .sheet(isPresented: $showingAddCustomNode) {
                AddCustomNodeSheetView()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                subscriptionManager.stopGroupPolling()
                LogManager.shared.log("App: Background - Polling stopped", level: .info)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                resumePollingIfNecessary()
                LogManager.shared.log("App: Foreground - Polling resumed if needed", level: .info)
            }
        }
    }
    
    private var statusBanner: some View {
        VStack(spacing: 4) {
            HStack {
                Circle()
                    .fill(isActive ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text("VPN: \(extensionCommunicator.extensionStatus.capitalized)")
                    .font(.caption)
                    .fontWeight(.medium)
                
                Spacer()
                
                if let node = subscriptionManager.currentNode {
                    Text(node.name ?? node.serverAddress)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            if isActive {
                    /* 暂时屏蔽网速显示
                    speedIndicator(for: stats)
                    */
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(8)
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private func speedIndicator(for stats: ProxyStatistics) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10))
                Text(formatSpeed(stats.currentDownloadSpeed > 0 ? stats.currentDownloadSpeed : stats.averageDownloadSpeed))
                    .font(.system(size: 10, design: .monospaced))
            }
            
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 10))
                Text(formatSpeed(stats.currentUploadSpeed > 0 ? stats.currentUploadSpeed : stats.averageUploadSpeed))
                    .font(.system(size: 10, design: .monospaced))
            }
            
            Spacer()
            
            Text("Conns: \(stats.activeConnections)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .foregroundColor(.blue)
    }
    
    // 助手方法
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1024 {
            return String(format: "%.1f KB/s", kb)
        }
        let mb = kb / 1024
        return String(format: "%.1f MB/s", mb)
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }
    
    private var emptyStateView: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()
                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(width: 100, height: 100)
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                    }
                    
                    VStack(spacing: 8) {
                        Text(LocalizationManager.emptyNoSubscription)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(LocalizationManager.emptySelectSubscription)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    
                    Button(action: {
                        showingAddSubscription = true
                    }) {
                        Text(LocalizationManager.buttonAdd)
                            .fontWeight(.bold)
                            .frame(width: 200, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Spacer()
                Spacer() // 略微向上偏移，符合视觉重心
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minHeight: 500) // 基础保障高度
    }
    
    private func errorBanner(_ error: String) -> some View {
        Text(error)
            .font(.caption2)
            .foregroundColor(.red)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)
    }
    
    private func selectAndSwitchNode(_ node: ProxyNode) {
        subscriptionManager.selectNode(node)

        if isActive {
            Task {
                let config = createAppConfiguration(for: node, group: nil)
                extensionCommunicator.saveConfiguration(config)
                
                // --- 新增：通知插件实时切换节点 ---
                extensionCommunicator.sendMessage(.updateConfiguration) { _ in
                    LogManager.shared.log("UI: Node switched to \(node.name ?? "unnamed"), extension notified.", level: .info)
                }
            }
        }
    }

    private func resumePollingIfNecessary() {
        guard let sub = subscriptionManager.selectedSubscription else { return }
        guard let group = sub.proxyGroups.first(where: { $0.name == selectedGroupName }) else { return }
        if (group.type == .urlTest || group.type == .fallback) && isActive {
            subscriptionManager.startGroupPolling()
        }
    }

    private func selectAndSwitchGroup(_ group: ProxyGroup) {
        // 控制 Clash API 轮询
        if (group.type == .urlTest || group.type == .fallback) && isActive {
            // 延迟启动轮询，等 sing-box 配置重载完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.subscriptionManager.startGroupPolling()
            }
        } else {
            subscriptionManager.stopGroupPolling()
        }

        if isActive {
            Task {
                let config = createAppConfiguration(for: nil, group: group)
                extensionCommunicator.saveConfiguration(config)

                extensionCommunicator.sendMessage(.updateConfiguration) { _ in
                    LogManager.shared.log("UI: Group switched to \(group.name), mode: \(group.type.rawValue)", level: .info)
                }
            }
        }
    }
    
    private func toggleConnection() {
        if isActive {
            subscriptionManager.stopGroupPolling()
            extensionCommunicator.stopVPN()
        } else {
            // 首先尝试获取选中的策略组（非默认组）
            let selectedGroup = subscriptionManager.selectedSubscription?.proxyGroups.first(where: { $0.name == selectedGroupName && $0.name != "DEFAULT" })
            
            // 如果没有选中组，则要求选中节点
            guard selectedGroup != nil || subscriptionManager.currentNode != nil else {
                proxyManager.errorMessage = LocalizationManager.errorSelectNodeFirst
                return
            }

            Task {
                proxyManager.errorMessage = nil
                let config = createAppConfiguration(for: subscriptionManager.currentNode, group: selectedGroup)

                await extensionCommunicator.loadOrCreateManager()
                extensionCommunicator.saveConfiguration(config)
                do {
                    try await extensionCommunicator.startVPN()
                } catch {
                    proxyManager.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func createAppConfiguration(for initialNode: ProxyNode?, group: ProxyGroup?) -> AppConfiguration {
        var config = Configuration.shared.load() 

        if let group = group {
            config.isGroupMode = true
            config.selectedGroupID = group.id
        } else if let node = initialNode {
            config.isGroupMode = false
            config.selectedNodeID = node.id
            
            // 补充节点详情（从订阅中查找最新数据）
            var finalNode = node
            for sub in subscriptionManager.subscriptions {
                if let freshNode = sub.nodes.first(where: { $0.id == node.id }) {
                    finalNode.grpcServiceName = freshNode.grpcServiceName
                    finalNode.password = freshNode.password
                    finalNode.network = freshNode.network
                    finalNode.sni = freshNode.sni
                    finalNode.skipCertVerify = freshNode.skipCertVerify
                    break
                }
            }
            
            config.selectedProtocol = finalNode.type
            
            // 下方保留原有的协议具体配置逻辑，但适配可选值
            switch finalNode.type {
            case .vmess:
                config.vmessConfig = VMessConfig(
                    serverAddress: finalNode.serverAddress,
                    serverPort: finalNode.serverPort,
                    userId: finalNode.password ?? "",
                    alterId: finalNode.alterId ?? 0,
                    network: finalNode.network ?? "tcp",
                    tls: finalNode.tls ?? false,
                    skipCertVerify: finalNode.skipCertVerify ?? false,
                    tlsServerName: finalNode.sni,
                    path: finalNode.path,
                    grpcServiceName: finalNode.grpcServiceName
                )
            case .shadowsocks:
                config.shadowsocksConfig = ShadowsocksConfig(
                    serverAddress: finalNode.serverAddress,
                    serverPort: finalNode.serverPort,
                    password: finalNode.password ?? "",
                    encryption: finalNode.encryption ?? "chacha20-ietf-poly1305"
                )
            case .trojan:
                config.trojanConfig = TrojanConfig(
                    serverAddress: finalNode.serverAddress,
                    serverPort: finalNode.serverPort,
                    password: finalNode.password ?? "",
                    enableTLS: finalNode.tls ?? true,
                    skipCertVerify: finalNode.skipCertVerify ?? false,
                    sni: finalNode.sni
                )
            default: break
            }
        }
        
        config.listenPort = 1081 
        
        // 自动携带所属订阅的规则；手动规则（config.rules）不再被覆盖。
        if let currentID = (group != nil ? nil : initialNode?.id) {
             if let sub = subscriptionManager.subscriptions.first(where: { s in s.nodes.contains(where: { $0.id == currentID }) }) {
                config.subscriptionRules = (sub.rulesEnabled ?? true) ? sub.rules : []
            }
        } else if let group = group {
            if let sub = subscriptionManager.subscriptions.first(where: { s in s.proxyGroups.contains(where: { $0.id == group.id }) }) {
                config.subscriptionRules = (sub.rulesEnabled ?? true) ? sub.rules : []
            }
        }
        
        return config
    }
    
    private func testGoogle() {
        proxyManager.errorMessage = LocalizationManager.testing
        let testURL = URL(string: "https://www.google.com/generate_204")!
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 15
        
        let session = URLSession(configuration: sessionConfig)
        session.dataTask(with: testURL) { _, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 {
                    proxyManager.errorMessage = LocalizationManager.testGoogleSuccess
                } else {
                    proxyManager.errorMessage = LocalizationManager.testGoogleFailed
                }
            }
        }.resume()
    }
    
    private func refreshAll() {
        isRefreshing = true
        subscriptionManager.fetchAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isRefreshing = false
        }
    }
    
    private func refreshSubscription(_ subscription: Subscription) {
        Task {
            await subscriptionManager.fetchAndUpdate(subscription)
        }
    }
    
    private func testLatency() {
        Task {
            await subscriptionManager.testAllLatencies()
        }
    }
    private func localizedGroupName(_ name: String) -> String {
        if name == "DEFAULT" || name == "默认" || name == "Default" {
            return LocalizationManager.groupDefault
        }
        
        if name == "自动选择" || name == "Auto Select" || name.lowercased() == "auto" {
            return LocalizationManager.groupAutoSelect
        }
        
        if name == "故障转移" || name == "Fallback" {
            return LocalizationManager.groupFallback
        }
        
        if name.hasPrefix("region.") {
            return LocalizationManager.string(name)
        }
        
        // 兼容旧版本的硬编码中文名称
        let legacyMap: [String: String] = [
            "🇭🇰 香港": "region.hk",
            "🇹🇼 台湾": "region.tw",
            "🇯🇵 日本": "region.jp",
            "🇸🇬 新加坡": "region.sg",
            "🇺🇸 美国": "region.us",
            "🇰🇷 韩国": "region.kr",
            "🇬🇧 英国": "region.uk",
            "🇩🇪 德国": "region.de",
            "🇫🇷 法国": "region.fr",
            "🇦🇺 澳大利亚": "region.au",
            "🇨🇦 加拿大": "region.ca",
            "⚡ 专线": "region.private",
            "🌐 其他": "region.other"
        ]
        
        if let key = legacyMap[name] {
            return LocalizationManager.string(key)
        }
        
        let lowerName = name.lowercased()
        if lowerName == "proxy" || lowerName == "代理" {
            return LocalizationManager.routeProxy
        } else if lowerName == "direct" || lowerName == "直连" {
            return LocalizationManager.routeDirect
        } else if lowerName == "global" || lowerName == "全局" {
            return LocalizationManager.routingGlobal
        }
        
        return name
    }
}

struct NodeCardView: View {
    let node: ProxyNode
    let isSelected: Bool
    let isActive: Bool
    var isAutoSelected: Bool = false  // sing-box urltest 自动选中
    var autoDelay: Int? = nil         // Clash API 返回的真实延迟

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(node.type.displayName.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(protocolColor.opacity(0.2))
                    .foregroundColor(protocolColor)
                    .cornerRadius(4)

                Spacer()

                if let delay = autoDelay {
                    Text("\(delay)ms")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(autoDelayColor(delay))
                } else if node.latency >= 0 {
                    Text("\(node.latency)ms")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(latencyColor)
                } else if node.latency == -2 {
                    Text("Timeout")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }

            Text(node.name ?? node.serverAddress)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .frame(height: 40, alignment: .topLeading)

            HStack {
                Text("\(node.serverAddress)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                if isAutoSelected {
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                } else if isSelected {
                    Image(systemName: isActive ? "bolt.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(isActive ? .green : .blue)
                }
            }
        }
        .padding(12)
        .background((isSelected || isAutoSelected) ? Color.blue.opacity(0.05) : Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isAutoSelected ? Color.orange : (isSelected ? (isActive ? Color.green : Color.blue) : Color.clear), lineWidth: 2)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
    
    private var protocolColor: Color {
        switch node.type {
        case .vmess: return .green
        case .shadowsocks: return .orange
        case .trojan: return .red
        default: return .blue
        }
    }
    
    private var latencyColor: Color {
        if node.latency < 0 { return .gray }
        if node.latency < 150 { return .green }
        if node.latency < 400 { return .orange }
        return .red
    }

    private func autoDelayColor(_ delay: Int) -> Color {
        if delay < 150 { return .green }
        if delay < 400 { return .orange }
        return .red
    }
}

// 保持 AddSubscriptionSheet 代码不变
struct AddSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var autoUpdate = true
    
    var body: some View {
        NavigationStack {
            Form {
                Section(LocalizationManager.sectionSubscriptionInfo) {
                    TextField(LocalizationManager.labelName, text: $name)
                    TextField(LocalizationManager.labelURL, text: $url)
                        .textContentType(.URL)
                        .onChange(of: url) { newValue in
                            if name.isEmpty {
                                name = Subscription.suggestedName(from: newValue)
                            }
                        }
                }
                
                Section {
                    Button {
                        showingScanner = true
                    } label: {
                        Label(LocalizationManager.labelScanQRCode, systemImage: "qrcode.viewfinder")
                    }
                    
                    Toggle(LocalizationManager.labelAutoUpdate, isOn: $autoUpdate)
                }
            }
            .navigationTitle(LocalizationManager.navAddSubscription)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationManager.buttonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizationManager.buttonAdd) {
                        let subscription = Subscription(name: name, url: url, autoUpdate: autoUpdate, updateInterval: .daily)
                        SubscriptionManager.shared.addSubscription(subscription)
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerView { code in
                    DispatchQueue.main.async {
                        self.url = code
                        self.showingScanner = false
                    }
                }
            }
        }
    }
    
    @State private var showingScanner = false
}