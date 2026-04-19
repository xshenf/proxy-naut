import NetworkExtension
import Network
import Darwin

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var proxyManager: ProxyManager?
    private var proxyListenPort: UInt16 = 1081
    private var entitlementTimer: DispatchSourceTimer?
    private let entitlementCheckInterval: TimeInterval = 300 // 5 分钟
    
    private func logToSharedFile(_ message: String, level: LogLevel = .info) {
        print("[Extension][\(level.rawValue.uppercased())] \(message)")
        NSLog("[Extension][\(level.rawValue.uppercased())] \(message)")
        LogManager.shared.log(message, level: level, source: "Extension")
    }

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        logToSharedFile("=== startTunnel called ===", level: .info)

        // 订阅门禁：无论是 App 内启动，还是用户从系统设置/快捷指令触发 VPN 开关，
        // 都必须经过这里。防止未订阅用户绕过应用内的付费墙。
        //
        // 判定策略：
        //   - 读 App Group UserDefaults 中 App 刷新时写入的 expirationDate 缓存
        //   - 自己用 Date 比较决定是否过期（不依赖 App 运行、不调 StoreKit）
        //   - 过期即拒，无宽限
        guard EntitlementStorage.isEffectivelyPro() else {
            let error = NSError(
                domain: "PacketTunnel",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Subscription required or expired. Please open ProxyNaut to subscribe or restore."]
            )
            logToSharedFile("Tunnel start denied: subscription invalid or expired in App Group cache", level: .warning)
            completionHandler(error)
            return
        }

        Task { @MainActor in
            // Clean up any previous running instance
            if proxyManager?.isRunning == true {
                logToSharedFile("Previous instance still running, stopping first", level: .warning)
                proxyManager?.stop()
            }
            
            let appGroupId = "group.com.proxynaut"
            var sharedFileNode: ProxyNode?
            var finalConfig: AppConfiguration?

            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
                let fileURL = containerURL.appendingPathComponent("shared_config.json")
                if let data = try? Data(contentsOf: fileURL) {
                    let shared = try? JSONDecoder().decode(SharedConfig.self, from: data)
                    sharedFileNode = shared?.lastNode
                    finalConfig = shared?.config
                    logToSharedFile("Loaded shared config: node=\(sharedFileNode?.name ?? "nil")", level: .info)
                }
            }
            
            var config = finalConfig ?? self.loadConfiguration()
            if config.listenPort == 0 { config.listenPort = 1081 }

            // Load rules from subscriptions
            self.loadSubscriptionRules(into: &config)

            self.proxyListenPort = config.listenPort
            self.proxyManager = ProxyManager.shared
            
            if let node = sharedFileNode {
                ProxyManager.shared.lastNode = node
            } else {
                let userDefaults = UserDefaults(suiteName: appGroupId)
                if let nodeData = userDefaults?.data(forKey: AppExtensionCommunicator.tunnelProxyNodeKey),
                   let node = try? JSONDecoder().decode(ProxyNode.self, from: nodeData) {
                    ProxyManager.shared.lastNode = node
                }
            }
            
            guard config.isGroupMode || ProxyManager.shared.lastNode != nil else {
                let error = NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "未选择节点或策略组"])
                logToSharedFile("Start tunnel failed: \(error.localizedDescription)", level: .error)
                completionHandler(error)
                return
            }
            
            do {
                let allRules = config.rules  // loadSubscriptionRules 之后已是最终合并结果
                let directRules = allRules.filter { $0.action == .direct }.count
                let proxyRules = allRules.filter { $0.action == .proxy }.count
                let rejectRules = allRules.filter { $0.action == .reject }.count
                logToSharedFile("Starting kernel with \(allRules.count) rules (direct=\(directRules), proxy=\(proxyRules), reject=\(rejectRules))", level: .info)
                
                if let actualPort = try await self.proxyManager?.start(with: config) {
                    self.proxyListenPort = actualPort
                }
                
                let tunnelSettings = self.createTunnelSettings(config: config)
                self.setTunnelNetworkSettings(tunnelSettings) { error in
                    if let error = error {
                        completionHandler(error)
                        return
                    }
                    self.startPumping()
                    self.startEntitlementMonitor()
                    completionHandler(nil)
                }
            } catch {
                logToSharedFile("Start tunnel error: \(error.localizedDescription)", level: .error)
                completionHandler(error)
            }
        }
    }

    private var isTunnelStopped = false

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logToSharedFile("=== stopTunnel called reason=\(reason.rawValue) ===", level: .info)
        isTunnelStopped = true
        stopEntitlementMonitor()

        Task { @MainActor in
            self.proxyManager?.stop()
            completionHandler()
        }
    }

    // MARK: - 订阅自检（Extension 内）
    //
    // Extension 启动时已在 startTunnel 做一次门禁。但订阅可能在隧道运行中过期：
    //   - 自动续订失败 / 家长撤销 / 订阅到期
    //   - App 不一定在前台，通知 .proStatusChanged 也可能到不了 App 侧
    // 所以 Extension 自己定时读 App Group UserDefaults 的过期缓存，
    // 一旦判定为 false 就主动 cancelTunnelWithError，系统会把 VPN 停掉并通知用户。
    private func startEntitlementMonitor() {
        entitlementTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + entitlementCheckInterval, repeating: entitlementCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.isTunnelStopped else { return }
            if !EntitlementStorage.isEffectivelyPro() {
                self.logToSharedFile("Subscription expired during tunnel run; cancelling", level: .warning)
                let error = NSError(
                    domain: "PacketTunnel",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "Subscription expired. Please renew to continue using VPN."]
                )
                self.cancelTunnelWithError(error)
            }
        }
        timer.resume()
        entitlementTimer = timer
    }

    private func stopEntitlementMonitor() {
        entitlementTimer?.cancel()
        entitlementTimer = nil
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let message = String(data: messageData, encoding: .utf8) {
            switch message {
            case "getStatus":
                Task { @MainActor in
                    let status = self.proxyManager?.isRunning ?? false
                    completionHandler?((status ? "running" : "stopped").data(using: .utf8))
                }
            case "getStatistics":
                Task { @MainActor in
                    // 正确同步计数器并返回
                    self.proxyManager?.syncStats()
                    if let stats = self.proxyManager?.statistics {
                        let data = try? JSONEncoder().encode(stats)
                        completionHandler?(data)
                    } else {
                        completionHandler?(nil)
                    }
                }
            case "updateConfiguration":
                Task { @MainActor in
                    await self.reloadConfiguration()
                    completionHandler?(nil)
                }
            default:
                completionHandler?(nil)
            }
        } else {
            completionHandler?(nil)
        }
    }

    // MARK: - Configuration Reload

    @MainActor
    private func reloadConfiguration() async {
        logToSharedFile("Reloading configuration from app...", level: .info)

        // 1. 停止当前代理
        if proxyManager?.isRunning == true {
            logToSharedFile("Stopping existing proxy", level: .info)
            proxyManager?.stop()
        }

        // 2. 重新加载最新配置 (文件系统)
        var config = Configuration.shared.load()
        if config.listenPort == 0 { config.listenPort = 1081 }
        
        // 3. 确定最终节点
        var finalNode: ProxyNode?
        
        // 策略A: 从配置中查找 selectedNodeID
        if let nodeID = config.selectedNodeID {
            finalNode = SubscriptionManager.shared.findNode(byID: nodeID)
        }
        
        // 策略B: 兜底查询
        if finalNode == nil {
            finalNode = SubscriptionManager.shared.currentNode ?? SubscriptionManager.shared.subscriptions.first?.nodes.first
        }

        // 4. 加载订阅生成的动态规则
        self.loadSubscriptionRules(into: &config)

        // 如果既没有选中节点，也没有选中策略组，则报错
        if !config.isGroupMode && finalNode == nil {
            logToSharedFile("Reload configuration failed: no node or group selected", level: .error)
            return
        }

        // 同步状态（如果是单节点模式）
        if let node = finalNode {
            ProxyManager.shared.lastNode = node
        }

        logToSharedFile("Restarting kernel with new config. GroupMode=\(config.isGroupMode)", level: .info)

        // 5. 重新启动代理
        do {
            if let actualPort = try await self.proxyManager?.start(with: config) {
                self.proxyListenPort = actualPort
                logToSharedFile("Kernel restarted on port \(actualPort)", level: .info)
            }
        } catch {
            logToSharedFile("Reload configuration error: \(error.localizedDescription)", level: .error)
        }
    }
    
    // MARK: - Configuration & Settings (Simplified)
    
    private func loadConfiguration() -> AppConfiguration {
        let appGroupId = "group.com.proxynaut"
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let fileURL = containerURL.appendingPathComponent("shared_config.json")
            if let data = try? Data(contentsOf: fileURL),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let configData = try? JSONSerialization.data(withJSONObject: dict["config"] ?? [:]),
               let config = try? JSONDecoder().decode(AppConfiguration.self, from: configData) {
                return config
            }
        }
        return AppConfiguration()
    }

    private func loadSubscriptionRules(into config: inout AppConfiguration) {
        let appGroupId = "group.com.proxynaut"
        let manualRules = config.rules
        let subRules = config.subscriptionRules ?? []

        // 1) 读取广告/规则订阅缓存
        var cachedAdRules: [ProxyRule] = []
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let rulesURL = containerURL.appendingPathComponent("cached_rules.json")
            if let data = try? Data(contentsOf: rulesURL),
               let decoded = try? JSONDecoder().decode([ProxyRule].self, from: data) {
                cachedAdRules = decoded
            }
        }

        // 2) 按优先级 manual > subscription > ad > builtin 合并去重；final 规则跳过，留到最后
        var merged: [ProxyRule] = []
        var seen = Set<String>()
        func addRules(_ rules: [ProxyRule]) {
            for rule in rules {
                guard rule.type != .final else { continue }
                let key = "\(rule.type.rawValue):\(rule.pattern):\(rule.action.rawValue)"
                if seen.insert(key).inserted { merged.append(rule) }
            }
        }
        addRules(manualRules)
        addRules(subRules)
        addRules(cachedAdRules)
        if config.useBuiltInRules { addRules(config.baseRules) }

        // 3) 选出 final 规则：按相同优先级取第一条，保证兜底可预期；都没有则兜底走 proxy
        let finalCandidates = manualRules + subRules + cachedAdRules + (config.useBuiltInRules ? config.baseRules : [])
        let finalRule = finalCandidates.first { $0.type == .final }
            ?? ProxyRule(type: .final, pattern: "MATCH", action: .proxy)

        // 4) 截断到 10000 条，为 final 预留 1 槽位
        let maxSafeRules = 10000 - 1
        if merged.count > maxSafeRules { merged = Array(merged.prefix(maxSafeRules)) }
        merged.append(finalRule)

        config.rules = merged
        RuleEngine.shared.loadRules(merged)
        logToSharedFile("Aggregated rules: manual=\(manualRules.count) sub=\(subRules.count) ad=\(cachedAdRules.count) builtin=\(config.useBuiltInRules ? config.baseRules.count : 0) -> total=\(merged.count) (final guarded)", level: .info)
    }
    
    @MainActor
    private func createTunnelSettings(config: AppConfiguration) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "1.1.1.1")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings?.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
        ]
        
        // --- 仅排除当前单一选中节点（如果存在），防止启动超时 ---
        if let node = ProxyManager.shared.lastNode {
            let ips = resolveAllIPs(node.serverAddress)
            for ip in ips {
                if !ip.contains(":") {
                    settings.ipv4Settings?.excludedRoutes?.append(NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255"))
                }
            }
        }
        
        // --- 核心修复：根据开关排除中国 IP 大段，实现系统级直连 ---
        if config.networkConfig?.bypassChina ?? true {
            // 获取 DNS 服务器 IP，如果我们开启了 forceDNS，这些 IP 不能被排除
            let dnsServers = config.dnsConfig?.servers.filter { !$0.isEmpty } ?? ["223.5.5.5", "119.29.29.29"]
            let forceDNS = config.networkConfig?.forceDNS ?? true

            // 汇总了中国电信/联通/移动的核心段
            let chinaIPv4Ranges: [(String, String)] = [
                ("1.0.0.0", "255.0.0.0"), ("14.0.0.0", "255.0.0.0"), ("27.0.0.0", "255.0.0.0"),
                ("36.0.0.0", "255.240.0.0"), ("42.0.0.0", "255.0.0.0"), ("49.0.0.0", "255.0.0.0"),
                ("58.0.0.0", "255.0.0.0"), ("60.0.0.0", "255.0.0.0"), ("61.0.0.0", "255.0.0.0"),
                ("101.0.0.0", "255.0.0.0"), ("103.0.0.0", "255.0.0.0"), ("106.0.0.0", "255.0.0.0"),
                ("110.0.0.0", "255.0.0.0"), ("111.0.0.0", "255.0.0.0"), ("112.0.0.0", "255.0.0.0"),
                ("113.0.0.0", "255.0.0.0"), ("114.0.0.0", "255.0.0.0"), ("115.0.0.0", "255.0.0.0"),
                ("116.0.0.0", "255.0.0.0"), ("117.0.0.0", "255.0.0.0"), ("118.0.0.0", "255.0.0.0"),
                ("119.0.0.0", "255.0.0.0"), ("120.0.0.0", "255.0.0.0"), ("121.0.0.0", "255.0.0.0"),
                ("122.0.0.0", "255.0.0.0"), ("123.0.0.0", "255.0.0.0"), ("124.0.0.0", "255.0.0.0"),
                ("125.0.0.0", "255.0.0.0"), ("140.0.0.0", "255.0.0.0"), ("150.0.0.0", "255.0.0.0"),
                ("153.0.0.0", "255.0.0.0"), ("157.0.0.0", "255.0.0.0"), ("163.0.0.0", "255.0.0.0"),
                ("171.0.0.0", "255.0.0.0"), ("175.0.0.0", "255.0.0.0"), ("180.0.0.0", "255.0.0.0"),
                ("182.0.0.0", "255.0.0.0"), ("183.0.0.0", "255.0.0.0"), ("185.0.0.0", "255.0.0.0"),
                ("210.0.0.0", "255.0.0.0"), ("211.0.0.0", "255.0.0.0"), ("218.0.0.0", "255.0.0.0"),
                ("219.0.0.0", "255.0.0.0"), ("220.0.0.0", "255.0.0.0"), ("221.0.0.0", "255.0.0.0"),
                ("222.0.0.0", "255.0.0.0"), ("223.0.0.0", "255.0.0.0")
            ]
            for (addr, mask) in chinaIPv4Ranges {
                // 检查这个网段是否包含我们的 DNS 服务器 IP
                // 为了简单起见，如果开启了 forceDNS 且 DNS IP 不是公共国外 IP，我们直接不排除那些“敏感”网段，或者通过 includedRoute 覆盖
                settings.ipv4Settings?.excludedRoutes?.append(NEIPv4Route(destinationAddress: addr, subnetMask: mask))
            }
            
            // 如果开启了 forceDNS，我们需要显式地在 includedRoutes 加上 DNS 服务器地址 (32位掩码)
            // 这样即便它在排除列表的大段里，由于 32 位最精准优先，它也会进入隧道
            if forceDNS {
                for dns in dnsServers {
                    settings.ipv4Settings?.includedRoutes?.append(NEIPv4Route(destinationAddress: dns, subnetMask: "255.255.255.255"))
                }
            }

            let ipv6Settings = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [126])
            ipv6Settings.includedRoutes = [NEIPv6Route.default()]
            
            // 排除国内 IPv6 核心段
            ipv6Settings.excludedRoutes = [
                NEIPv6Route(destinationAddress: "240e::", networkPrefixLength: 18),
                NEIPv6Route(destinationAddress: "2408::", networkPrefixLength: 18),
                NEIPv6Route(destinationAddress: "2409::", networkPrefixLength: 18),
                NEIPv6Route(destinationAddress: "2400::", networkPrefixLength: 12),
                NEIPv6Route(destinationAddress: "2406:da00::", networkPrefixLength: 32),
                NEIPv6Route(destinationAddress: "2403:2c80::", networkPrefixLength: 32)
            ]
            settings.ipv6Settings = ipv6Settings
        } else {
            // 开关关闭时，采用全量拦截模式
            let ipv6Settings = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [126])
            ipv6Settings.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6Settings
        }
        
        // 使用配置的 DNS 服务器，如果未配置则使用默认值
        let dnsServers = config.dnsConfig?.servers.filter { !$0.isEmpty } ?? ["8.8.8.8", "1.1.1.1"]
        settings.dnsSettings = NEDNSSettings(servers: dnsServers.isEmpty ? ["8.8.8.8", "1.1.1.1"] : dnsServers)
        
        // 使用配置的 MTU，如果未配置则使用默认值 1500
        settings.mtu = NSNumber(value: config.networkConfig?.mtu ?? 1500)
        
        let proxySettings = NEProxySettings()
        proxySettings.httpEnabled = true
        proxySettings.httpServer = NEProxyServer(address: "127.0.0.1", port: Int(proxyListenPort))
        proxySettings.httpsEnabled = true
        proxySettings.httpsServer = NEProxyServer(address: "127.0.0.1", port: Int(proxyListenPort))
        proxySettings.excludeSimpleHostnames = true
        proxySettings.matchDomains = [""]
        settings.proxySettings = proxySettings
        
        return settings
    }
    
    private func resolveAllIPs(_ hostname: String) -> [String] {
        var ips: [String] = []
        var res: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(hostname, nil, nil, &res) == 0 {
            var curr = res
            while let ptr = curr {
                var addr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if ptr.pointee.ai_family == AF_INET {
                    let sin = ptr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var sin_addr = sin.sin_addr
                    inet_ntop(AF_INET, &sin_addr, &addr, socklen_t(INET6_ADDRSTRLEN))
                    ips.append(String(cString: addr))
                } else if ptr.pointee.ai_family == AF_INET6 {
                    let sin6 = ptr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    var sin6_addr = sin6.sin6_addr
                    inet_ntop(AF_INET6, &sin6_addr, &addr, socklen_t(INET6_ADDRSTRLEN))
                    ips.append(String(cString: addr))
                }
                curr = ptr.pointee.ai_next
            }
        }
        if let res = res { freeaddrinfo(res) }
        return ips
    }
    
    // MARK: - Packet Pumping (Optimized)
    
    private func startPumping() {
        guard let fd = LibboxManager.shared.platformInterface?.tunnelFd, fd != -1 else { return }
        isTunnelStopped = false
        
        let batchLimit = 50 // 每 50 个数据包更新一次统计，减少锁竞争
        
        // 1. PacketFlow -> Libbox
        Task.detached(priority: .userInitiated) { [weak self] in
            var packetCount = 0
            var accumulatedSent: Int = 0
            
            while true {
                guard let self = self, !self.isTunnelStopped else { break }
                
                let packets = await withCheckedContinuation { (continuation: CheckedContinuation<[Data], Never>) in
                    self.packetFlow.readPackets { packets, _ in continuation.resume(returning: packets) }
                }
                
                if self.isTunnelStopped { break }
                
                for packet in packets {
                    packet.withUnsafeBytes { ptr in
                        if let baseAddress = ptr.baseAddress {
                            let written = write(fd, baseAddress, packet.count)
                            if written > 0 {
                                accumulatedSent += Int(written)
                                packetCount += 1
                                
                                if packetCount >= batchLimit {
                                    ProxyStatsCounter.shared.increment(sent: accumulatedSent, received: 0)
                                    accumulatedSent = 0
                                    packetCount = 0
                                }
                            } else if written < 0 {
                                let err = errno
                                if err != EAGAIN && err != EINTR {
                                    NSLog("[PacketTunnel] Write to Libbox failed: errno=\(err)")
                                }
                            }
                        }
                    }
                }
                
                // 每批次结束不管够不够数量都更新一下，保证延迟感低
                if accumulatedSent > 0 {
                    ProxyStatsCounter.shared.increment(sent: accumulatedSent, received: 0)
                    accumulatedSent = 0
                    packetCount = 0
                }
            }
        }
        
        // 2. Libbox -> PacketFlow
        Task.detached(priority: .userInitiated) { [weak self] in
            let bufferSize = 10000
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            
            var packetCount = 0
            var accumulatedReceived: Int = 0
            
            while true {
                guard let self = self, !self.isTunnelStopped else { break }
                
                let bytesRead = read(fd, buffer, bufferSize)
                if bytesRead > 0 {
                    accumulatedReceived += Int(bytesRead)
                    packetCount += 1
                    
                    let data = Data(bytes: buffer, count: bytesRead)
                    let version = buffer[0] >> 4
                    let protocolFamily: Int32 = (version == 6) ? AF_INET6 : AF_INET
                    self.packetFlow.writePackets([data], withProtocols: [NSNumber(value: protocolFamily)])
                    
                    if packetCount >= batchLimit {
                        ProxyStatsCounter.shared.increment(sent: 0, received: accumulatedReceived)
                        accumulatedReceived = 0
                        packetCount = 0
                    }
                } else if bytesRead < 0 {
                    let err = errno
                    if err == EAGAIN || err == EINTR {
                        try? await Task.sleep(nanoseconds: 1_000_000) // 1ms 避让
                        continue
                    }
                    NSLog("[PacketTunnel] Read from Libbox failed: errno=\(err)")
                    break
                } else {
                    // bytesRead == 0 means EOF
                    break
                }
                
                // 少量数据时也进行同步，避免长时间不更新
                if accumulatedReceived > 0 && packetCount > 10 {
                    ProxyStatsCounter.shared.increment(sent: 0, received: accumulatedReceived)
                    accumulatedReceived = 0
                    packetCount = 0
                }
            }
            
            // 退出前最后同步一次
            if accumulatedReceived > 0 {
                ProxyStatsCounter.shared.increment(sent: 0, received: accumulatedReceived)
            }
        }
    }
}