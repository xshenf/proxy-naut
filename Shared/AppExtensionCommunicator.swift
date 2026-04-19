import Foundation
import NetworkExtension

enum AppExtensionMessage: String, Codable {
    case startProxy
    case stopProxy
    case getStatus
    case getStatistics
    case updateConfiguration
    case getSelectedNode
}

@MainActor
class AppExtensionCommunicator: ObservableObject {
    static let shared = AppExtensionCommunicator()
    
    private var extensionBundleId: String {
        let base = Bundle.main.bundleIdentifier ?? "com.proxynaut.container"
        return base + ".ProxyExtension"
    }
    
    private var appGroupId: String {
        // 通常 App Group 与 Bundle ID 相关联，根据 project.yml 默认为 group.com.proxynaut
        // 如果 Bundle ID 仍为 com.proxyapp，则尝试对应 group.com.proxyapp
        if let base = Bundle.main.bundleIdentifier, base.contains("proxyapp") {
            return "group.com.proxyapp"
        }
        return "group.com.proxynaut"
    }
    
    @Published var extensionStatus: String = "stopped"
    @Published var extensionStatistics: ProxyStatistics?
    @Published var isConfigured: Bool = false
    @Published var permissionDenied: Bool = false
    
    var onStatsUpdate: ((String, String, String) -> Void)?
    var onStatusChange: ((String) -> Void)?
    
    private var manager: NETunnelProviderManager?
    private var statsTimer: Timer?
    private var lastStats: (sent: UInt64, received: UInt64, time: Date)?
    
    private init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
            }
        }



        NSLog("AppExtensionCommunicator starting with BundleID: \(Bundle.main.bundleIdentifier ?? "nil")")
        NSLog("Calculated ExtensionID: \(extensionBundleId), AppGroupID: \(appGroupId)")

        Task {
            if getSharedContainerURL() == nil {
                NSLog("CRITICAL: App Group container at \(appGroupId) is NOT accessible.")
            }
            await loadOrCreateManager()
            updateStatus()
        }
    }


    
    private func getSharedContainerURL() -> URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }
    
    private func updateStatus() {
        guard let manager = manager else {
            if extensionStatus != "disconnected" {
                extensionStatus = "disconnected"
                stopStatsTimer()
                onStatusChange?("disconnected")
            }
            return
        }

        var newStatus: String
        switch manager.connection.status {
        case .connected:
            newStatus = "connected"
            startStatsTimer()
        case .connecting:
            newStatus = "connecting"
        case .reasserting:
            newStatus = "reasserting"
        case .disconnecting:
            newStatus = "disconnecting"
        case .disconnected:
            newStatus = "disconnected"
            stopStatsTimer()
        case .invalid:
            newStatus = "disconnected"
            stopStatsTimer()
        @unknown default:
            newStatus = "unknown"
        }



        // Only update and log if status actually changed
        if extensionStatus != newStatus {
            extensionStatus = newStatus
            onStatusChange?(newStatus)
            NSLog("AppExtensionCommunicator: VPN Status changed to \(newStatus)")

            // VPN 断开时停止策略组轮询
            if newStatus == "disconnected" {
                SubscriptionManager.shared.stopGroupPolling()
            }
        }
    }
    
    private func startStatsTimer() {
        return // 暂时屏蔽
    }
    
    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
        lastStats = nil
        extensionStatistics = nil
    }
    
    @MainActor
    func loadOrCreateManager() async {
        do {
            NSLog("AppExtensionCommunicator: Loading VPN managers...")
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            NSLog("AppExtensionCommunicator: Found \(managers.count) managers from preferences")
            
            if let existing = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionBundleId
            }) {
                self.manager = existing
                self.isConfigured = true
                updateStatus()
                NSLog("AppExtensionCommunicator: Successfully loaded existing manager for \(extensionBundleId)")
                return
            }
            NSLog("AppExtensionCommunicator: No existing manager for \(extensionBundleId), creating new one...")
            await createManager()
        } catch {
            NSLog("AppExtensionCommunicator: Error loading managers: \(error)")
            await createManager()
        }
    }
    
    private func createManager() async {
        let newManager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = extensionBundleId
        proto.serverAddress = "ProxyNaut VPN Server"
        proto.disconnectOnSleep = false
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = "ProxyNaut VPN"
        newManager.isEnabled = true
        
        do {
            NSLog("AppExtensionCommunicator: Attempting to save new VPN manager to preferences...")
            try await newManager.saveToPreferences()
            NSLog("AppExtensionCommunicator: Initial save successful, reloading...")
            try await newManager.loadFromPreferences()
            self.manager = newManager
            self.isConfigured = true
            self.extensionStatus = "configured"
            NSLog("AppExtensionCommunicator: VPN configuration saved and loaded successfully")
        } catch {
            let nsError = error as NSError
            NSLog("ERROR: AppExtensionCommunicator: Failed to save VPN configuration: \(nsError.domain) code=\(nsError.code) info=\(nsError.userInfo)")
            
            if nsError.domain == "NEConfigurationErrorDomain" && nsError.code == 11 {
                NSLog("CRITICAL: IPC Failed usually means a Signing/Entitlement mismatch or App bundle ID conflict.")
            }
            
            if error.localizedDescription.contains("permission") || error.localizedDescription.contains("denied") {
                self.permissionDenied = true
            }
        }
    }
    
    func syncConfiguration() {
        let config = Configuration.shared.getAppConfiguration()
        saveConfiguration(config)
    }
    
    func startVPN() async throws {
        // 启动前强制同步一次当前配置（包括选中的节点）
        syncConfiguration()

        await loadOrCreateManager()

        guard let manager = manager else {
            throw NSError(domain: "AppExtension", code: 1, userInfo: [NSLocalizedDescriptionKey: "VPN 未配置，请重试"])
        }

        // 当系统存在多个 VPN 且选中了其他 VPN 时，iOS 会把我们的 manager 设为 disabled
        // 需要重新 enable 并保存后才能启动
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }

        // Check if already connected
        if manager.connection.status == .connected {
            NSLog("AppExtensionCommunicator: VPN already connected, skipping start")
            return
        }

        // Check if currently connecting
        if manager.connection.status == .connecting {
            NSLog("AppExtensionCommunicator: VPN is currently connecting, waiting...")
            return
        }
        
        do {
            try manager.connection.startVPNTunnel()
            // Don't call updateStatus here - let the NEVPNStatusDidChange notification handle it
        } catch {
            NSLog("ERROR: AppExtensionCommunicator: Failed to start VPN: \(error)")
            throw error
        }
    }
    
    func stopVPN() {
        manager?.connection.stopVPNTunnel()
        updateStatus()
    }
    
    func sendMessage(_ message: AppExtensionMessage, completion: @escaping (Data?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            completion(nil)
            return
        }
        do {
            try session.sendProviderMessage(message.rawValue.data(using: .utf8)!) { response in
                completion(response)
            }
        } catch {
            print("Failed to send message: \(error)")
            completion(nil)
        }
    }
    
    func getStatus() {
        sendMessage(.getStatus) { [weak self] data in
            guard let data = data, let status = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.extensionStatus = status
            }
        }
    }
    
    func getStatistics() {
        sendMessage(.getStatistics) { [weak self] data in
            guard let data = data,
                  var stats = try? JSONDecoder().decode(ProxyStatistics.self, from: data) else { return }
            
            DispatchQueue.main.async {
                let now = Date()
                var currentUpload: UInt64 = 0
                var currentDownload: UInt64 = 0
                
                if let last = self?.lastStats {
                    let duration = now.timeIntervalSince(last.time)
                    if duration > 0 {
                        if stats.bytesSent >= last.sent && stats.bytesReceived >= last.received {
                            currentUpload = UInt64(Double(stats.bytesSent - last.sent) / duration)
                            currentDownload = UInt64(Double(stats.bytesReceived - last.received) / duration)
                        }
                    }
                }
                self?.lastStats = (stats.bytesSent, stats.bytesReceived, now)
                stats.currentUploadSpeed = Double(currentUpload)
                stats.currentDownloadSpeed = Double(currentDownload)
                self?.extensionStatistics = stats
                
                if let self = self {
                    self.onStatsUpdate?(
                        self.formatSpeed(Double(currentUpload)),
                        self.formatSpeed(Double(currentDownload)),
                        SubscriptionManager.shared.currentNode?.name ?? "Default"
                    )
                }
            }
        }
    }
    
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1024 {
            return String(format: "%.1f KB/s", kb)
        } else {
            let mb = kb / 1024
            return String(format: "%.1f MB/s", mb)
        }
    }
    
    static let tunnelProxyNodeKey = "tunnelProxyNode"
    
    func saveConfiguration(_ config: AppConfiguration) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        
        let nodeToSave = ProxyManager.shared.lastNode ?? SubscriptionManager.shared.currentNode
        
        if let userDefaults = UserDefaults(suiteName: appGroupId) {
            userDefaults.set(data, forKey: "appConfiguration")
            if let node = nodeToSave,
               let nodeData = try? JSONEncoder().encode(node) {
                userDefaults.set(nodeData, forKey: Self.tunnelProxyNodeKey)
            }
            userDefaults.synchronize()
        }
        
        // --- 关键修复：确保全局配置也同步到 app_config.json ---
        // 这样 PacketTunnelProvider 在 reloadConfiguration() 时调用 Configuration.shared.load() 才能保证数据最新
        Configuration.shared.save(config)
        
        if let containerURL = getSharedContainerURL() {
            let fileURL = containerURL.appendingPathComponent("shared_config.json")
            let shared = SharedConfig(config: config, lastNode: nodeToSave)
            do {
                let sharedData = try JSONEncoder().encode(shared)
                try sharedData.write(to: fileURL, options: .atomic)
            } catch {
                NSLog("ERROR: AppExtensionCommunicator: Failed to write shared file: \(error)")
            }
        }
    }
    
    func loadConfiguration() -> AppConfiguration? {
        if let containerURL = getSharedContainerURL() {
            let fileURL = containerURL.appendingPathComponent("shared_config.json")
            if let data = try? Data(contentsOf: fileURL),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let configData = try? JSONSerialization.data(withJSONObject: dict["config"] ?? [:]),
               let config = try? JSONDecoder().decode(AppConfiguration.self, from: configData) {
                return config
            }
        }
        guard let userDefaults = UserDefaults(suiteName: appGroupId),
              let data = userDefaults.data(forKey: "appConfiguration"),
              let config = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return nil
        }
        return config
    }
    
    func getExtensionLogs() -> String {
        if let containerURL = getSharedContainerURL() {
            let logURL = containerURL.appendingPathComponent("extension.log")
            if let logs = try? String(contentsOf: logURL, encoding: .utf8) {
                return logs
            }
        }
        return "No extension logs found."
    }
    
    func clearExtensionLogs() {
        if let containerURL = getSharedContainerURL() {
            let logURL = containerURL.appendingPathComponent("extension.log")
            try? FileManager.default.removeItem(at: logURL)
        }
    }
}
