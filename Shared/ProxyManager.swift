import Foundation
import Network
import CryptoKit
import Libbox
import Darwin

struct SharedConfig: Codable {
    let config: AppConfiguration
    let lastNode: ProxyNode?
}

class ProxyStatsCounter {
    static let shared = ProxyStatsCounter()
    private var _totalSent: UInt64 = 0
    private var _totalReceived: UInt64 = 0
    private let lock = NSLock()
    
    private init() {}
    
    func increment(sent: Int, received: Int) {
        lock.lock()
        _totalSent += UInt64(sent)
        _totalReceived += UInt64(received)
        lock.unlock()
    }
    
    func get() -> (sent: UInt64, received: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (_totalSent, _totalReceived)
    }
}

// MARK: - Proxy Manager Core
@MainActor
class ProxyManager: ObservableObject {
    static let shared = ProxyManager()
    @Published var isRunning = false
    @Published var currentProtocol: ProxyProtocol?
    @Published var statistics: ProxyStatistics = ProxyStatistics()
    @Published var errorMessage: String?
    @Published var actualListenPort: UInt16?
    
    var lastNode: ProxyNode?
    
    private init() {
        self.statistics.startDate = Date()
    }
    
    // 定期同步到 UI 或在 handleAppMessage 时调用
    func syncStats() {
        let current = ProxyStatsCounter.shared.get()
        self.statistics.bytesSent = current.sent
        self.statistics.bytesReceived = current.received
    }
    
    // 兼容代码
    func updateStats(sent: Int, received: Int) {
        ProxyStatsCounter.shared.increment(sent: sent, received: received)
        syncStats()
    }
    
    @MainActor
    func start(with config: AppConfiguration) async throws -> UInt16 {
        await stopAllAsync()
        var mutableConfig = config

        // 强制避让：如果配置仍为 1080，则改用 1081
        if mutableConfig.listenPort == 1080 {
            mutableConfig.listenPort = 1081
            LogManager.shared.log("ProxyManager: Overriding port 1080 with 1081 to avoid conflict", level: .warning)
        }

        let port = mutableConfig.listenPort
        
        // 核心改动：不再强制要求 lastNode，因为可能是策略组模式
        if LibboxManager.shared.start(with: mutableConfig, listenPort: Int(port), rules: mutableConfig.rules, useBuiltInRules: mutableConfig.useBuiltInRules) {
            self.isRunning = true
            self.currentProtocol = config.selectedProtocol ?? .vmess
            self.actualListenPort = port

            LogManager.shared.log("ProxyManager: Kernel started on port \(port), groupRegionMode=\(config.isGroupMode), rules=\(mutableConfig.rules.count)", level: .info)
            return port
        } else {
            throw ProxyError.connectionFailed("Libbox kernel failed to start")
        }
    }
    
    @MainActor
    func stop() {
        LibboxManager.shared.stop()
        self.isRunning = false
    }
    
    private func stopAllAsync() async {
        await MainActor.run { stop() }
    }
}

// MARK: - Core Driver Classes

class LibboxManager {
    static let shared = LibboxManager()
    private var isStarted = false
    private var currentPort: Int = 0
    private static var isSetup = false
    
    var proxyPort: Int { return currentPort }
    
    private func setup() -> Bool {
        guard !LibboxManager.isSetup else { return true }

        let appGroupId = "group.com.proxynaut"
        let fileManager = FileManager.default

        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            let msg = "ERROR: LibboxManager: App Group container not accessible"
            NSLog(msg)
            print(msg)
            LogManager.shared.log("LibboxSetup: FAILED - container not accessible", level: .error, source: "Libbox")
            return false
        }

        let basePath = containerURL.appendingPathComponent("Library/sing-box").path
        let workingPath = containerURL.appendingPathComponent("Application Support/sing-box").path
        let tempPath = containerURL.appendingPathComponent("tmp").path

        try? fileManager.createDirectory(atPath: basePath, withIntermediateDirectories: true)
        try? fileManager.createDirectory(atPath: workingPath, withIntermediateDirectories: true)
        try? fileManager.createDirectory(atPath: tempPath, withIntermediateDirectories: true)

        let setupMsg1 = "LibboxSetup: base=\(basePath)"
        print("[LibboxSetup] \(setupMsg1)")
        NSLog(setupMsg1)
        LogManager.shared.log("LibboxSetup: base=\(basePath)", level: .info, source: "Libbox")

        // 异步下载 GeoIP/GeoSite 数据库（如果是首次启动或文件损坏）
        Task {
            await GeoDataManager.shared.ensureDataExists()
        }

        LibboxSetup(basePath, workingPath, tempPath, false)

        LibboxSetMemoryLimit(true)
        LibboxManager.isSetup = true
        let setupMsg2 = "LibboxSetup: SUCCESS"
        print("[LibboxSetup] \(setupMsg2)")
        NSLog(setupMsg2)
        LogManager.shared.log("LibboxSetup: SUCCESS", level: .info, source: "Libbox")
        return true
    }
    
    // 持有 boxService 和 platform 引用，防止 Go 回调时对象已被 ARC 释放
    private var boxService: LibboxBoxService?
    private var serverHandler: AppCommandServerHandler?
    var platformInterface: AppPlatformInterface?

    @MainActor
    func start(with appConfig: AppConfiguration, listenPort: Int, rules: [ProxyRule] = [], useBuiltInRules: Bool = true) -> Bool {
        LogManager.shared.log("LibboxStart: isGroupMode=\(appConfig.isGroupMode), port=\(listenPort)", level: .info, source: "Libbox")
        guard !isStarted else {
            LogManager.shared.log("LibboxStart: already started, skipping", level: .info, source: "Libbox")
            return true
        }

        guard setup() else {
            LogManager.shared.log("LibboxStart: setup() FAILED", level: .error, source: "Libbox")
            return false
        }

        // 必须先创建 platformInterface，否则下方的 includeTun 判断会因引用 nil 而始终为 false
        let handler = AppCommandServerHandler()
        let platform = AppPlatformInterface()
        self.serverHandler = handler
        self.platformInterface = platform

        let includeTun = platform.underNetworkExtension()
        
        // 规则深度合流：手动规则 + 最新的内置默认规则
        // 规则深度合流优先级：
        // 1. 内置直连域名(最高优先级, 包含 commonChinaDomains)
        // 2. 用户选中的节点对应的订阅规则
        // 3. 内置的 GeoIP:CN 和 Final 规则(兜底)
        var combinedRules: [ProxyRule] = []
        let defaultRules = Configuration.defaultRules
        
        if useBuiltInRules {
            let coreDefaults = defaultRules.filter { $0.type != .geoip && $0.type != .final }
            combinedRules.append(contentsOf: coreDefaults)
        }
        
        combinedRules.append(contentsOf: rules)
        
        if useBuiltInRules {
            let fallbackRules = defaultRules.filter { $0.type == .geoip || $0.type == .final }
            combinedRules.append(contentsOf: fallbackRules)
        }
        
        LogManager.shared.log("LibboxStart: generating config (includeTun=\(includeTun), rules=\(combinedRules.count))...", level: .info, source: "Libbox")
        
        var nodeToStart: ProxyNode? = nil
        var groupToStart: ProxyGroup? = nil
        
        if appConfig.isGroupMode, let groupID = appConfig.selectedGroupID {
            for sub in SubscriptionManager.shared.subscriptions {
                if let group = sub.proxyGroups.first(where: { $0.id == groupID }) {
                    groupToStart = group
                    break
                }
            }
        } else if let nodeID = appConfig.selectedNodeID {
            nodeToStart = SubscriptionManager.shared.findNode(byID: nodeID)
        }
        
        // 兜底：如果找不到节点或组，尝试使用 lastNode
        if nodeToStart == nil && groupToStart == nil {
            nodeToStart = ProxyManager.shared.lastNode
        }

        guard let configStr = SingBoxConfigGenerator.generate(
            for: nodeToStart,
            group: groupToStart,
            allNodes: SubscriptionManager.shared.subscriptions.flatMap { $0.nodes },
            listenPort: listenPort,
            includeTun: includeTun,
            rules: combinedRules,
            useBuiltInRules: false,
            dnsConfig: appConfig.dnsConfig,
            networkConfig: appConfig.networkConfig,
            routingMode: appConfig.routingMode
        ) else {
            LogManager.shared.log("LibboxStart: Config generation FAILED", level: .error, source: "Libbox")
            return false
        }
        LogManager.shared.log("LibboxStart: config generated (\(configStr.count) bytes)", level: .info, source: "Libbox")

        // Validate config
        var checkError: NSError?
        if !LibboxCheckConfig(configStr, &checkError) {
            let errMsg = checkError?.localizedDescription ?? "unknown"
            LogManager.shared.log("LibboxCheckConfig: FAILED - \(errMsg)", level: .error, source: "Libbox")
            LogManager.shared.log("LibboxCheckConfig: config preview - \(configStr.prefix(300))", level: .error, source: "Libbox")
            return false
        }
        LogManager.shared.log("LibboxCheckConfig: PASSED", level: .info, source: "Libbox")

        // Create service
        var serviceError: NSError?
        guard let service = LibboxNewService(configStr, platform, &serviceError) else {
            let errMsg = serviceError?.localizedDescription ?? "unknown"
            LogManager.shared.log("LibboxNewService: FAILED - \(errMsg)", level: .error, source: "Libbox")
            self.serverHandler = nil
            self.platformInterface = nil
            return false
        }
        LogManager.shared.log("LibboxNewService: SUCCESS", level: .info, source: "Libbox")
        self.boxService = service

        // Start service
        do {
            try service.start()
            LogManager.shared.log("LibboxStart: service.start() SUCCESS", level: .info, source: "Libbox")
        } catch {
            LogManager.shared.log("LibboxStart: service.start() FAILED - \(error.localizedDescription)", level: .error, source: "Libbox")
            self.boxService = nil
            self.serverHandler = nil
            self.platformInterface = nil
            return false
        }

        self.isStarted = true
        self.currentPort = listenPort
        LogManager.shared.log("LibboxStart: FULLY STARTED on port \(listenPort)", level: .info, source: "Libbox")
        return true
    }
    
    func stop() {
        // 1. Close service
        if let service = self.boxService {
            do {
                try service.close()
                NSLog("LibboxManager: Service closed")
            } catch {
                NSLog("LibboxManager: close error: \(error.localizedDescription)")
            }
        }

        // 2. Close and cleanup
        self.boxService = nil
        self.serverHandler = nil

        // 3. Close and cleanup platform interface (including FD)
        self.platformInterface?.close()
        self.platformInterface = nil

        self.isStarted = false
        NSLog("LibboxManager: Fully stopped")
    }
}

class SingBoxConfigGenerator {
    // MARK: - Outbound Generation
    
    private static func generateOutbound(for node: ProxyNode, tag: String = "proxy") -> [String: Any]? {
        var outbound: [String: Any]
        
        switch node.type {
        case .vmess:
            outbound = generateVMessOutbound(node)
        case .trojan:
            outbound = generateTrojanOutbound(node)
        case .shadowsocks:
            outbound = generateShadowsocksOutbound(node)
        case .http:
            outbound = generateHTTPOutbound(node)
        case .https:
            outbound = generateHTTPSOutbound(node)
        case .socks5:
            outbound = generateSOCKSOutbound(node)
        case .vless:
            outbound = generateVLESSOutbound(node)
        case .hysteria2:
            outbound = generateHysteria2Outbound(node)
        case .tuic:
            outbound = generateTUICOutbound(node)
        }
        
        outbound["tag"] = tag
        return outbound
    }
    
    private static func generateVMessOutbound(_ node: ProxyNode) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "vmess",
            "server": node.serverAddress,
            "server_port": Int(node.serverPort),
            "uuid": node.password ?? "",
            "security": "auto"
        ]
        
        // alterId
        if let alterId = node.alterId, alterId > 0 {
            outbound["alter_id"] = alterId
        }
        
        addTLS(&outbound, node: node)
        addTransport(&outbound, node: node)
        
        return outbound
    }
    
    private static func generateTrojanOutbound(_ node: ProxyNode) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "trojan",
            "server": node.serverAddress,
            "server_port": Int(node.serverPort),
            "password": node.password ?? ""
        ]
        
        // Trojan 默认启用 TLS
        addTLS(&outbound, node: node, defaultEnabled: true)
        addTransport(&outbound, node: node)
        
        return outbound
    }
    
    private static func generateShadowsocksOutbound(_ node: ProxyNode) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "shadowsocks",
            "server": node.serverAddress,
            "server_port": Int(node.serverPort)
        ]
        
        // 解析 encryption:password 格式或纯 password
        if let password = node.password {
            if password.contains(":") {
                let parts = password.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    outbound["method"] = String(parts[0])
                    outbound["password"] = String(parts[1])
                } else {
                    outbound["method"] = "none"
                    outbound["password"] = password
                }
            } else {
                // 纯密码格式，使用默认加密或从 encryption 字段获取
                outbound["method"] = node.encryption ?? "chacha20-ietf-poly1305"
                outbound["password"] = password
            }
        }
        
        return outbound
    }
    
    private static func generateHTTPOutbound(_ node: ProxyNode) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "http",
            "server": node.serverAddress,
            "server_port": Int(node.serverPort)
        ]
        
        if let username = node.username {
            outbound["username"] = username
        }
        if let password = node.password {
            outbound["password"] = password
        }
        
        // HTTP 出站不支持 TLS（HTTPS 用另一个类型）
        return outbound
    }
    
    private static func generateHTTPSOutbound(_ node: ProxyNode) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "http",
            "server": node.serverAddress,
            "server_port": Int(node.serverPort),
            "tls": ["enabled": true]
        ]
        
        if let username = node.username {
            outbound["username"] = username
        }
        if let password = node.password {
            outbound["password"] = password
        }
        
        if let sni = node.sni {
            var tls = outbound["tls"] as? [String: Any] ?? [:]
            tls["server_name"] = sni
            outbound["tls"] = tls
        }
        
        return outbound
    }
    
    private static func generateSOCKSOutbound(_ node: ProxyNode) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "socks",
            "server": node.serverAddress,
            "server_port": Int(node.serverPort),
            "version": "5"
        ]
        
        if let username = node.username, let password = node.password {
            outbound["username"] = username
            outbound["password"] = password
        }
        
        return outbound
    }
    
    // MARK: - Helper Methods
    
    private static func addTLS(_ outbound: inout [String: Any], node: ProxyNode, defaultEnabled: Bool = false) {
        let tlsEnabled = node.tls ?? defaultEnabled

        if tlsEnabled {
            var tls: [String: Any] = [
                "enabled": true,
                "server_name": node.sni ?? node.serverAddress,
                "insecure": node.skipCertVerify ?? false
            ]
            if let alpn = node.alpn, !alpn.isEmpty {
                tls["alpn"] = alpn
            }
            // libbox 1.9 编译版本不包含 utls，移除 utls
            outbound["tls"] = tls
        }
    }

    private static func generateVLESSOutbound(_ node: ProxyNode) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "vless",
            "server": node.serverAddress,
            "server_port": Int(node.serverPort),
            "uuid": node.password ?? ""
        ]

        if let flow = node.flow, !flow.isEmpty {
            outbound["flow"] = flow
        }

        addTLS(&outbound, node: node)
        addTransport(&outbound, node: node)

        return outbound
    }

    private static func generateHysteria2Outbound(_ node: ProxyNode) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "hysteria2",
            "server": node.serverAddress,
            "server_port": Int(node.serverPort),
            "password": node.password ?? ""
        ]

        if let up = node.upMbps, up > 0 {
            outbound["up_mbps"] = up
        }
        if let down = node.downMbps, down > 0 {
            outbound["down_mbps"] = down
        }

        if let obfs = node.obfs, !obfs.isEmpty, obfs.lowercased() != "none" {
            var obfsDict: [String: Any] = ["type": obfs]
            if let pwd = node.obfsPassword, !pwd.isEmpty {
                obfsDict["password"] = pwd
            }
            outbound["obfs"] = obfsDict
        }

        // Hysteria2 基于 QUIC，强制 TLS，默认 alpn h3
        var tls: [String: Any] = [
            "enabled": true,
            "server_name": node.sni ?? node.serverAddress,
            "insecure": node.skipCertVerify ?? false
        ]
        tls["alpn"] = (node.alpn?.isEmpty == false) ? node.alpn! : ["h3"]
        outbound["tls"] = tls

        return outbound
    }

    private static func generateTUICOutbound(_ node: ProxyNode) -> [String: Any] {
        var outbound: [String: Any] = [
            "type": "tuic",
            "server": node.serverAddress,
            "server_port": Int(node.serverPort),
            "uuid": node.uuid ?? "",
            "password": node.password ?? ""
        ]

        if let cc = node.congestionControl, !cc.isEmpty {
            outbound["congestion_control"] = cc
        }
        if let mode = node.udpRelayMode, !mode.isEmpty {
            outbound["udp_relay_mode"] = mode
        }

        // TUIC 基于 QUIC，强制 TLS，默认 alpn h3
        var tls: [String: Any] = [
            "enabled": true,
            "server_name": node.sni ?? node.serverAddress,
            "insecure": node.skipCertVerify ?? false
        ]
        tls["alpn"] = (node.alpn?.isEmpty == false) ? node.alpn! : ["h3"]
        outbound["tls"] = tls

        return outbound
    }
    
    private static func addTransport(_ outbound: inout [String: Any], node: ProxyNode) {
        if let network = node.network {
            switch network {
            case "grpc":
                outbound["transport"] = [
                    "type": "grpc",
                    "service_name": node.grpcServiceName ?? ""
                ]
            case "ws":
                var ws: [String: Any] = [
                    "type": "ws",
                    "path": node.path ?? "/"
                ]
                if let host = node.sni {
                    ws["headers"] = ["Host": host]
                }
                outbound["transport"] = ws
            case "http", "h2":
                outbound["transport"] = [
                    "type": "http"
                ]
            default:
                break
            }
        }
    }
    
    @MainActor
    static func generate(for node: ProxyNode?, group: ProxyGroup? = nil, allNodes: [ProxyNode] = [], listenPort: Int, includeTun: Bool, rules: [ProxyRule] = [], useBuiltInRules: Bool = true, dnsConfig: DNSConfig? = nil, networkConfig: NetworkConfig? = nil, routingMode: String = "Rule") -> String? {
        // Global/Direct 模式：丢掉用户/内置里的 .direct / .proxy / .final，
        // 仅保留 .reject（广告/黑名单仍生效）；final outbound 由模式统一覆盖
        let normalizedMode: String = {
            switch routingMode {
            case "Global", "Direct": return routingMode
            default: return "Rule"
            }
        }()
        let effectiveRules: [ProxyRule]
        if normalizedMode == "Rule" {
            effectiveRules = rules
        } else {
            effectiveRules = rules.filter { $0.type != .final && $0.action == .reject }
        }
        var outboundsList: [[String: Any]] = []
        
        // 监控节点（用于测速）的 server address，用于 DNS 配置跳过
        var targetServerAddress: String = ""

        if let group = group {
            // 策略组模式
            let groupNodes = group.getNodes(allNodes: allNodes)
            for gNode in groupNodes {
                if let outbound = generateOutbound(for: gNode, tag: "node-\(gNode.id)") {
                    outboundsList.append(outbound)
                }
            }
            
            var groupOutbound: [String: Any] = ["tag": "proxy"]
            let nodeTags = groupNodes.map { "node-\($0.id)" }
            
            switch group.type {
            case .urlTest:
                groupOutbound["type"] = "urltest"
                groupOutbound["outbounds"] = nodeTags
                groupOutbound["url"] = group.testURL ?? "https://www.gstatic.com/generate_204"
                groupOutbound["interval"] = "\(group.interval ?? 300)s"
            case .fallback:
                // sing-box 没有 fallback 类型，用 urltest + 高容差模拟：
                // tolerance 设大后，只要当前节点可用就不会切换，近似故障转移行为
                groupOutbound["type"] = "urltest"
                groupOutbound["outbounds"] = nodeTags
                groupOutbound["url"] = group.testURL ?? "https://www.gstatic.com/generate_204"
                groupOutbound["interval"] = "\(group.interval ?? 300)s"
                groupOutbound["tolerance"] = 5000
            case .select:
                groupOutbound["type"] = "selector"
                groupOutbound["outbounds"] = nodeTags
                groupOutbound["default"] = nodeTags.first
            }
            outboundsList.append(groupOutbound)
            // DNS 豁免：对于策略组，我们难以简单豁免所有 IP。通常 DNS 服务器会通过 proxy 出口。
        } else if let node = node {
            // 单节点模式
            targetServerAddress = node.serverAddress
            if let outbound = generateOutbound(for: node, tag: "proxy") {
                outboundsList.append(outbound)
            }
        }

        if outboundsList.isEmpty {
            NSLog("SingBoxConfig: No outbounds generated")
            return nil
        }

        // inbounds
        var inbounds: [[String: Any]] = [
            [
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": listenPort,
                "sniff": true,
                "sniff_override_destination": true
            ]
        ]

        if includeTun {
            let mtu = networkConfig?.mtu ?? 1500
            inbounds.append([
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "tun0",
                "inet4_address": ["172.19.0.2/30"],
                "inet6_address": ["fd00::2/126"],
                "mtu": mtu,
                "stack": "gvisor",
                "auto_route": false,
                "strict_route": false,
                "sniff": true,
                "sniff_override_destination": true
            ])
        }

        // 构建分流规则
        var routeRules: [[String: Any]] = []
        
        // --- 核心修正：节点服务器地址强制直连，确保测速真实性 ---
        let allServers = allNodes.compactMap { $0.serverAddress }.filter { !$0.isEmpty }
        if !allServers.isEmpty {
            var nodeRule: [String: Any] = ["outbound": "direct"]
            var domains: [String] = []
            var ipCIDRs: [String] = []
            for server in allServers {
                if server.range(of: "^[0-9.]+$", options: .regularExpression) != nil || server.contains(":") {
                    // sing-box 使用 ip_cidr 格式，单个 IP 需要加 /32 或 /128
                    if server.contains(":") {
                        ipCIDRs.append(server.contains("/") ? server : server + "/128")
                    } else {
                        ipCIDRs.append(server.contains("/") ? server : server + "/32")
                    }
                } else {
                    domains.append(server)
                }
            }
            if !domains.isEmpty { nodeRule["domain"] = domains }
            if !ipCIDRs.isEmpty { nodeRule["ip_cidr"] = ipCIDRs }
            if nodeRule["domain"] != nil || nodeRule["ip_cidr"] != nil {
                routeRules.append(nodeRule) // 最早加入，优先级最高
            }
        }
        
        // 1. DNS 劫持：确保所有 DNS 请求都进入 sing-box 的内部 DNS
        routeRules.append([
            "port": [53],
            "outbound": "dns-out"
        ])

        // ---【新增：全量广告拦截】---
        if networkConfig?.adBlock ?? true {
            routeRules.append([
                "outbound": "block",
                "geosite": ["category-ads-all"]
            ])
        }
        
        // ---【核心修复：geosite:cn 提前】---
        // 将国内全量库放到最前端，实现"一票否决"，防止被订阅规则误伤
        // Global/Direct 模式下这条规则会破坏模式语义（Global 是全代理，Direct 是全直连），跳过
        if normalizedMode == "Rule" {
            routeRules.append([
                "outbound": "direct",
                "geosite": ["cn", "bytedance"],
                "geoip": ["cn", "private"],
                "domain_suffix": [
                    ".cn", ".com.cn", ".net.cn",
                    "douyin.com", "douyincdn.com", "douyinpic.com", "douyinstatic.com",
                    "douyinvod.com", "douyinlive.com", "zijieapi.com", "byteimg.com",
                    "snssdk.com", "amemv.com", "bytedance.com", "volccdn.com", "akamaized.net",
                    "sinacloud.net", "sina.cn", "sina.com.cn", "weibo.com", "weibo.cn",
                    "alicdn.com", "aliyun.com", "tencent.com", "myqcloud.com", "baidu.com", "bdstatic.com",
                    "snssdk.com", "pstatp.com", "toutiao.com", "bytecdn.cn", "volcsirius.com"
                ]
            ])
        }
        
        // 3. 基础直连：本地和内网地址
        routeRules.append([
            "ip_cidr": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "172.19.0.0/30"],
            "outbound": "direct"
        ])

        // 将用户/订阅规则转换为 sing-box route rules
        var directDomains: [String] = []
        var directDomainSuffixes: [String] = []
        var directDomainKeywords: [String] = []
        var directIPCIDRs: [String] = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "172.19.0.0/30"]
        var directGeoSites: [String] = []
        var directGeoIPs: [String] = []
        var directPorts: [Int] = []
        
        var proxyDomains: [String] = []
        var proxyDomainSuffixes: [String] = []
        var proxyDomainKeywords: [String] = []
        var proxyGeoSites: [String] = []
        var proxyIPCIDRs: [String] = []
        var proxyGeoIPs: [String] = []
        var proxyPorts: [Int] = []
        
        var rejectDomains: [String] = []
        var rejectDomainSuffixes: [String] = []
        var rejectDomainKeywords: [String] = []
        var rejectGeoSites: [String] = []
        var rejectIPCIDRs: [String] = []

        for rule in effectiveRules {
            switch (rule.type, rule.action) {
            // 拦截
            case (.domain, .reject): rejectDomains.append(rule.pattern)
            case (.domainSuffix, .reject): rejectDomainSuffixes.append(rule.pattern)
            case (.domainKeyword, .reject): rejectDomainKeywords.append(rule.pattern)
            case (.geosite, .reject): rejectGeoSites.append(rule.pattern.lowercased())
            case (.ipCIDR, .reject): rejectIPCIDRs.append(rule.pattern)
            
            // 直连
            case (.domain, .direct): directDomains.append(rule.pattern)
            case (.domainSuffix, .direct): directDomainSuffixes.append(rule.pattern)
            case (.domainKeyword, .direct): directDomainKeywords.append(rule.pattern)
            case (.geosite, .direct): directGeoSites.append(rule.pattern.lowercased())
            case (.ipCIDR, .direct): directIPCIDRs.append(rule.pattern)
            case (.geoip, .direct): directGeoIPs.append(rule.pattern.lowercased())
            case (.port, .direct): if let p = Int(rule.pattern) { directPorts.append(p) }
            
            // 代理
            case (.domain, .proxy): proxyDomains.append(rule.pattern)
            case (.domainSuffix, .proxy): proxyDomainSuffixes.append(rule.pattern)
            case (.domainKeyword, .proxy): proxyDomainKeywords.append(rule.pattern)
            case (.geosite, .proxy): proxyGeoSites.append(rule.pattern.lowercased())
            case (.ipCIDR, .proxy): proxyIPCIDRs.append(rule.pattern)
            case (.geoip, .proxy): proxyGeoIPs.append(rule.pattern.lowercased())
            case (.port, .proxy): if let p = Int(rule.pattern) { proxyPorts.append(p) }
            
            default: break
            }
        }

        let allDirectIPs = Array(Set(directIPCIDRs))
        
        // --- 2. 拒绝规则 (Block) ---
        if !rejectDomains.isEmpty { routeRules.append(["outbound": "block", "domain": rejectDomains]) }
        if !rejectDomainSuffixes.isEmpty { routeRules.append(["outbound": "block", "domain_suffix": rejectDomainSuffixes]) }
        if !rejectDomainKeywords.isEmpty { routeRules.append(["outbound": "block", "domain_keyword": rejectDomainKeywords]) }
        if !rejectGeoSites.isEmpty { routeRules.append(["outbound": "block", "geosite": rejectGeoSites]) }
        if !rejectIPCIDRs.isEmpty { routeRules.append(["outbound": "block", "ip_cidr": rejectIPCIDRs]) }

        // --- 3. 订阅直连规则 (Direct from Sub) ---
        if !directDomains.isEmpty { routeRules.append(["outbound": "direct", "domain": directDomains]) }
        if !directDomainSuffixes.isEmpty { routeRules.append(["outbound": "direct", "domain_suffix": directDomainSuffixes]) }
        if !directDomainKeywords.isEmpty { routeRules.append(["outbound": "direct", "domain_keyword": directDomainKeywords]) }
        if !directGeoSites.isEmpty { routeRules.append(["outbound": "direct", "geosite": directGeoSites]) }
        if !allDirectIPs.isEmpty { routeRules.append(["outbound": "direct", "ip_cidr": allDirectIPs]) }
        if !directGeoIPs.isEmpty { routeRules.append(["outbound": "direct", "geoip": directGeoIPs]) }
        if !directPorts.isEmpty { routeRules.append(["outbound": "direct", "port": directPorts]) }

        // --- 4. 订阅代理规则 (Proxy from Sub) ---
        if !proxyDomains.isEmpty { routeRules.append(["outbound": "proxy", "domain": proxyDomains]) }
        if !proxyDomainSuffixes.isEmpty { routeRules.append(["outbound": "proxy", "domain_suffix": proxyDomainSuffixes]) }
        if !proxyDomainKeywords.isEmpty { routeRules.append(["outbound": "proxy", "domain_keyword": proxyDomainKeywords]) }
        if !proxyGeoSites.isEmpty { routeRules.append(["outbound": "proxy", "geosite": proxyGeoSites]) }
        if !proxyIPCIDRs.isEmpty { routeRules.append(["outbound": "proxy", "ip_cidr": proxyIPCIDRs]) }
        if !proxyGeoIPs.isEmpty { routeRules.append(["outbound": "proxy", "geoip": proxyGeoIPs]) }
        if !proxyPorts.isEmpty { routeRules.append(["outbound": "proxy", "port": proxyPorts]) }

        // --- 基础内置分流（仅处理最基础的兜底） ---
        if useBuiltInRules {
            // 已通过默认规则集实现
        }

        // 确定 final outbound
        // - Global: 固定 proxy（全局代理）
        // - Direct: 固定 direct（全部直连）
        // - Rule: 按用户/订阅里最优先那条 .final 规则决定
        let finalOutbound: String
        switch normalizedMode {
        case "Global":
            finalOutbound = "proxy"
        case "Direct":
            finalOutbound = "direct"
        default:
            let finalAction = rules.first(where: { $0.type == .final })?.action ?? .proxy
            switch finalAction {
            case .direct: finalOutbound = "direct"
            case .proxy: finalOutbound = "proxy"
            case .reject: finalOutbound = "block"
            }
        }

        // DNS 配置
        // dns-direct 必须是国内可直连的 DNS，不能用用户配置的代理 DNS（如 8.8.8.8）
        let dnsDirect = "223.5.5.5"
        let dnsProxy = "tls://1.1.1.1"

        // 构建 DNS 服务器列表
        let dnsServersList: [[String: Any]] = [
            ["tag": "dns-proxy", "address": dnsProxy, "detour": "proxy"],
            ["tag": "dns-direct", "address": dnsDirect, "detour": "direct"],
            ["tag": "dns-block", "address": "rcode://success"],
            ["tag": "dns-local", "address": "local", "detour": "direct"]
        ]

        // DNS 规则
        var dnsRules: [[String: Any]] = []
        
        // 1. 广告 DNS 拦截
        if networkConfig?.adBlock ?? true {
            dnsRules.append(["geosite": ["category-ads-all"], "server": "dns-block"])
        }
        
        // 规则合流
        if !targetServerAddress.isEmpty {
            dnsRules.append(["domain": [targetServerAddress], "server": "dns-direct"])
        }
        
        if !allServers.isEmpty {
            dnsRules.append(["domain": allServers, "server": "dns-direct"])
        }
        
        dnsRules.append(["domain_suffix": [
            ".cn", ".com.cn", ".net.cn", ".org.cn",
            "apple.com", "icloud.com", "baidu.com", "qq.com", "taobao.com", "alicdn.com", "tmall.com"
        ] + Configuration.commonChinaDomains, "server": "dns-direct"])

        if !directDomains.isEmpty { dnsRules.append(["domain": directDomains, "server": "dns-direct"]) }
        if !directDomainSuffixes.isEmpty { dnsRules.append(["domain_suffix": directDomainSuffixes, "server": "dns-direct"]) }
        if !directDomainKeywords.isEmpty { dnsRules.append(["domain_keyword": directDomainKeywords, "server": "dns-direct"]) }
        
        dnsRules.append(["protocol": "dns", "server": "dns-local"])

        // DNS final：Direct 模式下整体用 direct DNS，避免 DNS 仍绕到代理；
        // Rule/Global 下保留 dns-proxy（Global 下少数国内域名 dns-direct 解析没问题，主流量 route 规则决定）
        let dnsFinal = (normalizedMode == "Direct") ? "dns-direct" : "dns-proxy"

        var dnsConfigDict: [String: Any] = [
            "servers": dnsServersList,
            "rules": dnsRules,
            "final": dnsFinal,
            "strategy": "prefer_ipv4"
        ]
        
        if dnsConfig?.fakeIP ?? true {
            dnsConfigDict["fakeip"] = [
                "enabled": true,
                "inet4_range": "198.18.0.0/15"
            ]
        }
        
        // 完整配置
        var json: [String: Any] = [
            "log": [
                "level": "info",
                "timestamp": true
            ],
            "dns": dnsConfigDict,
            "inbounds": inbounds,
            "route": [
                "rules": routeRules,
                "geoip": [
                    "path": "geoip.db"
                ],
                "geosite": [
                    "path": "geosite.db"
                ],
                "final": finalOutbound,
                "auto_detect_interface": true
            ],
            "outbounds": outboundsList + [
                ["type": "direct", "tag": "direct", "udp_fragment": true],
                ["type": "block", "tag": "block"],
                ["type": "block", "tag": "reject"],
                ["type": "dns", "tag": "dns-out"]
            ]
        ]

        // 策略组模式下启用 Clash API，供主 App 查询自动选择结果
        if group != nil {
            json["experimental"] = [
                "clash_api": [
                    "external_controller": "127.0.0.1:9090"
                ]
            ]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted]),
              let prettyStr = String(data: data, encoding: .utf8) else { return nil }

        // 紧凑格式用于传给内核
        guard let compactData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let compactStr = String(data: compactData, encoding: .utf8) else { return nil }

        NSLog("SingBoxConfig: Generated with mode=\(normalizedMode), \(effectiveRules.count)/\(rules.count) user rules, \(routeRules.count) route rules, final=\(finalOutbound)")
        NSLog("SingBoxConfig: Full JSON:\n\(prettyStr)")
        return compactStr
    }
}

// MARK: - Internal Interface Implementations

class AppCommandServerHandler: NSObject, LibboxCommandServerHandlerProtocol {
    func getSystemProxyStatus() -> LibboxSystemProxyStatus? {
        return LibboxSystemProxyStatus()
    }
    func postServiceClose() { }
    func serviceReload() throws {
        NSLog("LibboxManager: serviceReload requested")
    }
    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        NSLog("LibboxManager: setSystemProxyEnabled: \(isEnabled)")
    }
}

class AppPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    // 路由日志去重：相同 action+目标 在 2 秒窗口内只记一次，
    // 避免 app 反复连同一域名（广告 SDK、重试）刷屏
    private var recentRoutes: [String: Date] = [:]
    private let routeDedupQueue = DispatchQueue(label: "com.proxynaut.routeDedupe")
    private let routeDedupWindow: TimeInterval = 2.0

    func autoDetectControl(_ fd: Int32) throws { }
    func clearDNSCache() { }
    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws { }
    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32, ret0_: UnsafeMutablePointer<Int32>?) throws { }
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol { 
        return LibboxNetworkInterfaceIterator()
    }
    func includeAllNetworks() -> Bool { return false }
    private var _tunnelFd: Int32 = -1
    var tunnelFd: Int32 { _tunnelFd }
    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        var fds: [Int32] = [0, 0]
        if socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) < 0 {
            throw NSError(domain: "AppPlatformInterface", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Socketpair failed"])
        }
        
        // 增加缓冲区大小以容纳 1500+ 字节的数据包，防止丢包
        let bufSize: Int32 = 512 * 1024 // 512KB
        setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, [bufSize], socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fds[0], SOL_SOCKET, SO_RCVBUF, [bufSize], socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, [bufSize], socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fds[1], SOL_SOCKET, SO_RCVBUF, [bufSize], socklen_t(MemoryLayout<Int32>.size))

        self._tunnelFd = fds[1]
        ret0_?.pointee = fds[0]
    }
    func packageName(byUid uid: Int32, error: NSErrorPointer) -> String { return "" }
    func readWIFIState() -> LibboxWIFIState? { return nil }
    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws { }
    func uid(byPackageName packageName: String?, ret0_: UnsafeMutablePointer<Int32>?) throws { }
    func underNetworkExtension() -> Bool { return Bundle.main.bundlePath.hasSuffix(".appex") }
    func usePlatformAutoDetectControl() -> Bool { return false }
    func usePlatformDefaultInterfaceMonitor() -> Bool { return false }
    func useGetter() -> Bool { return false }
    func useProcFS() -> Bool { return false }
    func writeLog(_ message: String?) {
        guard let msg = message, !msg.isEmpty else { return }
        let lower = msg.lowercased()

        // 路由决策日志（用户最关心）
        // sing-box 对同一 action+目标的多次独立连接会打多条日志（app 重试/广告 SDK 轮询），
        // 按 action+目标 做 2s 窗口折叠，避免刷屏
        if lower.contains("[proxy]") || lower.contains("[direct]") || lower.contains("[block]") {
            if shouldLogRoute(lower) {
                LogManager.shared.log(msg, level: .info, source: "Route")
            }
            return
        }

        // 错误日志
        if lower.contains("error") || lower.contains("fail") {
            LogManager.shared.log(msg, level: .error, source: "Libbox")
            return
        }

        // 生命周期日志
        if lower.contains("started") || lower.contains("closed") || lower.contains("service") {
            LogManager.shared.log(msg, level: .info, source: "Libbox")
            return
        }

        // 其余丢弃（connection 建立细节、DNS 查询等）
    }
    func close() {
        if _tunnelFd != -1 { Darwin.close(_tunnelFd); _tunnelFd = -1 }
    }

    // MARK: - Route log dedup
    private func shouldLogRoute(_ lowerMsg: String) -> Bool {
        let key = routeDedupKey(from: lowerMsg)
        return routeDedupQueue.sync { () -> Bool in
            let now = Date()
            // 注意：命中窗口内不更新时间戳，否则高频访问会无限延后下一次记录
            if let last = recentRoutes[key], now.timeIntervalSince(last) < routeDedupWindow {
                return false
            }
            recentRoutes[key] = now
            if recentRoutes.count > 500 {
                let cutoff = now.addingTimeInterval(-routeDedupWindow)
                recentRoutes = recentRoutes.filter { $0.value > cutoff }
            }
            return true
        }
    }

    private func routeDedupKey(from lowerMsg: String) -> String {
        let action: String
        if lowerMsg.contains("[proxy]") { action = "proxy" }
        else if lowerMsg.contains("[direct]") { action = "direct" }
        else { action = "block" }

        if let range = lowerMsg.range(of: " to ", options: .backwards) {
            let target = lowerMsg[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return "\(action)|\(target)"
        }
        return "\(action)|\(lowerMsg.suffix(80))"
    }
}

// MARK: - GeoDataManager

class GeoDataManager: NSObject, ObservableObject {
    static let shared = GeoDataManager()
    private let appGroupId = "group.com.proxynaut"
    
    @Published var lastUpdateInfo = ""
    
    override init() {
        super.init()
        updateStatus()
    }
    
    private var baseDirectory: URL? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        return containerURL.appendingPathComponent("Library/sing-box", isDirectory: true)
    }
    
    func setup() {
        guard let dir = baseDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    
    func updateStatus() {
        guard let dir = baseDirectory else { 
            lastUpdateInfo = "未获取到存储路径"
            return 
        }
        
        func getFileInfo(name: String) -> String {
            let path = dir.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) {
                let attr = try? FileManager.default.attributesOfItem(atPath: path)
                let size = (attr?[.size] as? Int64 ?? 0) / 1024 / 1024
                let date = attr?[.modificationDate] as? Date ?? Date.distantPast
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd HH:mm"
                return "\(size)MB (\(formatter.string(from: date)))"
            }
            return "缺失"
        }
        
        let ipInfo = getFileInfo(name: "geoip.db")
        let siteInfo = getFileInfo(name: "geosite.db")
        
        DispatchQueue.main.async {
            self.lastUpdateInfo = "GeoIP: \(ipInfo) | GeoSite: \(siteInfo)"
        }
    }
    
    func ensureDataExists() async {
        setup()
        let bundleFiles = ["geoip.db", "geosite.db"]
        for filename in bundleFiles {
            guard let destURL = baseDirectory?.appendingPathComponent(filename) else { continue }
            if !FileManager.default.fileExists(atPath: destURL.path) {
                let resourceName = filename.replacingOccurrences(of: ".db", with: "")
                if let bundleURL = Bundle.main.url(forResource: resourceName, withExtension: "db") {
                    do {
                        try FileManager.default.copyItem(at: bundleURL, to: destURL)
                        LogManager.shared.log("GeoData: Synchronized \(filename) from Bundle", level: .info, source: "App")
                    } catch {
                        LogManager.shared.log("GeoData: Failed to copy \(filename): \(error.localizedDescription)", level: .error, source: "App")
                    }
                } else {
                    LogManager.shared.log("GeoData: \(filename) NOT found in App Bundle. Please check Target Membership.", level: .warning, source: "App")
                }
            }
        }
        updateStatus()
    }
    
    func isReady() -> Bool {
        guard let dir = baseDirectory else { return false }
        let ipPath = dir.appendingPathComponent("geoip.db").path
        let sitePath = dir.appendingPathComponent("geosite.db").path
        
        func check(path: String) -> Bool {
            if FileManager.default.fileExists(atPath: path) {
                let attr = try? FileManager.default.attributesOfItem(atPath: path)
                return (attr?[.size] as? Int64 ?? 0) > 1024 * 100
            }
            return false
        }
        
        return check(path: ipPath) && check(path: sitePath)
    }
}
