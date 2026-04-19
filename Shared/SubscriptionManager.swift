import Foundation
import Network

// MARK: - 策略组数据结构

/// 策略组类型
enum ProxyGroupType: String, Codable {
    case select = "select"           // 手动选择
    case urlTest = "url-test"        // 自动测速
    case fallback = "fallback"       // 故障转移
}

/// 策略组
struct ProxyGroup: Codable, Identifiable {
    var id: String { name }
    var name: String
    var type: ProxyGroupType
    var proxies: [String]  // 节点名称列表
    var testURL: String?   // 测速 URL (url-test/fallback)
    var interval: Int?     // 测速间隔秒数 (url-test/fallback)
    
    /// 获取该策略组包含的所有节点
    func getNodes(allNodes: [ProxyNode]) -> [ProxyNode] {
        return allNodes.filter { node in
            proxies.contains { proxyName in
                node.name == proxyName || node.id == proxyName
            }
        }
    }
}

struct ProxyNode: Codable, Identifiable, Hashable {
    var id: String { "\(type.rawValue)-\(name ?? serverAddress)" }
    var name: String?
    var type: ProxyProtocol
    var serverAddress: String
    var serverPort: UInt16

    var encryption: String?
    var password: String?
    var username: String?
    var alterId: Int?
    var network: String?
    var tls: Bool?
    var sni: String?
    var path: String?
    var skipCertVerify: Bool?
    var grpcServiceName: String?

    // 新增：用于 VLESS / Hysteria2 / TUIC
    var uuid: String?              // TUIC 需要同时 uuid+password，单独存
    var flow: String?              // VLESS
    var obfs: String?              // Hysteria2
    var obfsPassword: String?      // Hysteria2
    var upMbps: Int?               // Hysteria2
    var downMbps: Int?             // Hysteria2
    var congestionControl: String? // TUIC
    var udpRelayMode: String?      // TUIC
    var alpn: [String]?            // 通用 TLS ALPN

    var selected: Bool = false
    var latency: Int = -1
    var countryCode: String?
    var isValid: Bool = true
    var isFavorite: Bool = false

    enum CodingKeys: String, CodingKey {
        case name, type, serverAddress, serverPort
        case encryption, password, username
        case alterId, network, tls, sni, path, skipCertVerify, grpcServiceName
        case uuid, flow, obfs, obfsPassword, upMbps, downMbps
        case congestionControl, udpRelayMode, alpn
    }
}

struct Subscription: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var lastUpdate: Date?
    var ruleCount: Int = 0
    var autoUpdate: Bool = true
    var updateInterval: UpdateInterval = .daily
    var nodes: [ProxyNode] = []
    var proxyGroups: [ProxyGroup] = []  // 策略组列表
    var rules: [ProxyRule] = []
    var rulesEnabled: Bool?  // 节点订阅自带规则是否参与路由；老数据缺省为 nil，消费方按 true 处理

    enum UpdateInterval: String, Codable, CaseIterable {
        case manual = "Manual"
        case hourly = "Hourly"
        case daily = "Daily"
        case weekly = "Weekly"

        /// 自动刷新的最小间隔；manual 返回 nil 表示不自动刷新
        var seconds: TimeInterval? {
            switch self {
            case .manual: return nil
            case .hourly: return 3600
            case .daily: return 86400
            case .weekly: return 7 * 86400
            }
        }
    }

    /// 是否该自动刷新：开启自动更新、间隔不是 manual、且距上次更新已超过间隔
    func shouldAutoRefresh(now: Date = Date()) -> Bool {
        guard autoUpdate, let interval = updateInterval.seconds else { return false }
        guard let last = lastUpdate else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

struct SubscriptionConfig: Codable {
    var version: String
    var nodes: [ProxyNode]
    var updateTime: Date?
    var remark: String?
    var rules: [ProxyRule]?
}

extension Subscription {
    static func suggestedName(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host else { return "" }
        
        // 提取核心域名: sub.example.com -> Example
        let parts = host.components(separatedBy: ".")
        if parts.count >= 2 {
            let core = parts[parts.count - 2]
            return core.prefix(1).uppercased() + core.dropFirst()
        }
        return host
    }
}

class SubscriptionParser {
    static let shared = SubscriptionParser()
    
    private init() {}
    
    func parse(from data: Data, format: SubscriptionFormat) -> SubscriptionConfig? {
        switch format {
        case .yaml:
            return parseYAML(data)
        case .json:
            return parseJSON(data)
        case .clash:
            return parseClash(data)
        }
    }
    
    enum SubscriptionFormat {
        case yaml
        case json
        case clash
    }
    
    private func parseYAML(_ data: Data) -> SubscriptionConfig? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        
        var nodes: [ProxyNode] = []
        var currentNode: [String: String] = [:]
        
        let lines = content.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("-") && trimmed.contains(":") {
                if !currentNode.isEmpty {
                    if let node = createNode(from: currentNode) {
                        nodes.append(node)
                    }
                    currentNode = [:]
                }
                
                let parts = trimmed.dropFirst().trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    currentNode[key] = value
                }
            } else if trimmed.contains(":") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    currentNode[key] = value
                }
            }
        }
        
        if !currentNode.isEmpty {
            if let node = createNode(from: currentNode) {
                nodes.append(node)
            }
        }
        
        return SubscriptionConfig(version: "1.0", nodes: nodes, updateTime: Date())
    }
    
    private func parseJSON(_ data: Data) -> SubscriptionConfig? {
        struct SubscriptionJSON: Codable {
            var proxies: [ProxyNode]?
            var version: String?
            var updateTime: Date?
        }
        
        // 尝试解析为标准格式
        if let json = try? JSONDecoder().decode(SubscriptionJSON.self, from: data) {
            return SubscriptionConfig(
                version: json.version ?? "1.0",
                nodes: json.proxies ?? [],
                updateTime: json.updateTime
            )
        }
        
        // 尝试解析 Base64 编码的 vmess:// 链接
        if let content = String(data: data, encoding: .utf8) {
            let nodes = parseVMessLinks(content)
            if !nodes.isEmpty {
                return SubscriptionConfig(version: "1.0", nodes: nodes, updateTime: Date())
            }
        }
        
        return try? JSONDecoder().decode(SubscriptionConfig.self, from: data)
    }
    
    private func parseVMessLinks(_ content: String) -> [ProxyNode] {
        var nodes: [ProxyNode] = []
        
        // 匹配 vmess:// 开头的 Base64 编码链接
        let pattern = "vmess://([A-Za-z0-9+/=]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nodes
        }
        
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        
        for match in matches {
            guard let matchRange = Range(match.range(at: 1), in: content) else { continue }
            let base64String = String(content[matchRange])
            
            // Base64 解码
            guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
                  let jsonString = String(data: data, encoding: .utf8),
                  let jsonData = jsonString.data(using: .utf8) else { continue }
            
            // 解析 VMess JSON 配置
            struct VMessConfig: Codable {
                let v: String?      // 版本
                let ps: String?    // 名称
                let add: String    // 地址
                let port: FlexibleString   // 端口
                let id: String     // 用户ID
                let aid: FlexibleString?   // alterId
                let net: String?   // 网络类型
                let type: String?  // 类型
                let host: String?   // 主机
                let path: String?  // 路径
                let tls: String?   // TLS
                let sni: String?   // SNI
                let scy: String?   // 加密
                let alpn: String?  // ALPN
                let allowInsecure: FlexibleString? // 允许不安全证书
            }
            
            // 用于处理 JSON 中可能是 String 也可能是 Int 的字段
            struct FlexibleString: Codable {
                let value: String
                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let str = try? container.decode(String.self) {
                        self.value = str
                    } else if let int = try? container.decode(Int.self) {
                        self.value = String(int)
                    } else {
                        self.value = ""
                    }
                }
                var intValue: Int { Int(value) ?? 0 }
            }
            
            guard let config = try? JSONDecoder().decode(VMessConfig.self, from: jsonData) else {
                NSLog("VMess: Failed to decode JSON: \(jsonString)")
                continue
            }
            
            var node = ProxyNode(
                type: .vmess,
                serverAddress: config.add,
                serverPort: UInt16(config.port.value) ?? 443
            )
            node.name = config.ps
            node.password = config.id
            node.alterId = config.aid?.intValue
            node.network = config.net
            // 处理 vmess JSON 中 tls 可能是空、"tls" 字符串或布尔值的情况
            if let tlsValue = config.tls?.lowercased() {
                node.tls = (tlsValue == "tls" || tlsValue == "true")
            } else {
                node.tls = false
            }
            node.sni = (config.sni?.isEmpty == false) ? config.sni : config.host
            
            // VMess JSON: net=grpc 时 path 字段是 gRPC 服务名，不是 URL 路径
            if node.network == "grpc" {
                node.grpcServiceName = config.path
                node.path = nil
            } else {
                node.path = config.path
            }
            
            // 策略：如果开启了 TLS 且设置了 SNI (通常是伪装域名)，
            // 或者明确设置了 allowInsecure，则默认跳过证书验证。
            let isAllowInsecure = config.allowInsecure?.value == "true" || config.allowInsecure?.value == "1"
            let hasSniCamouflage = node.tls == true && node.sni != nil && node.sni != node.serverAddress
            
            node.skipCertVerify = isAllowInsecure || hasSniCamouflage
            
            if node.skipCertVerify == true {
                NSLog("VMess Link: Enabled skipCertVerify for node: \(node.name ?? "unnamed")")
            }
            
            NSLog("VMess Link: Parsed \(node.name ?? "unnamed") net=\(node.network ?? "-") grpc=\(node.grpcServiceName ?? "-") uuid=\(node.password?.prefix(8).description ?? "nil")...")
            nodes.append(node)
        }
        
        return nodes
    }
    
    private func parseClash(_ data: Data) -> SubscriptionConfig? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        
        var nodes: [ProxyNode] = []
        var rules: [ProxyRule] = []
        var currentNode: [String: String] = [:]
        var inProxies = false
        var inRules = false
        
        let lines = content.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed == "proxies:" {
                inProxies = true
                inRules = false
                continue
            }
            if trimmed == "rules:" {
                inRules = true
                inProxies = false
                continue
            }
            if trimmed.hasPrefix("proxy-groups:") {
                inProxies = false
                inRules = false
                continue
            }
            
            if inProxies {
                if trimmed == "-" || trimmed.hasPrefix("- ") {
                    // 保存上一个节点
                    if !currentNode.isEmpty {
                        if let node = createNode(from: currentNode) {
                            nodes.append(node)
                        }
                        currentNode = [:]
                    }
                    
                    // 如果是单独的 "-"，跳过后续处理
                    if trimmed == "-" {
                        continue
                    }
                    
                    let remainder = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if remainder.hasPrefix("{") {
                        // 内联格式: - { name: ..., type: ... }
                        if let dict = parseClashDict(remainder) {
                            currentNode = dict
                            // 内联节点通常在一行内完成，可以直接保存并清空
                            if let node = createNode(from: currentNode) {
                                nodes.append(node)
                            }
                            currentNode = [:]
                        }
                    } else if remainder.contains(":") {
                        // 缩进格式的第一行: - name: "node"
                        let parts = remainder.split(separator: ":", maxSplits: 1)
                        if parts.count >= 2 {
                            let key = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                            currentNode[key] = value
                        }
                    }
                } else if (line.hasPrefix(" ") || line.hasPrefix("\t")) && trimmed.contains(":") {
                    // 缩进格式的后续行:   type: vmess
                    let parts = trimmed.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        currentNode[key] = value
                    }
                } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("-") {
                    inProxies = false
                }
            }
            
            if inRules {
                if trimmed.hasPrefix("- ") {
                    let ruleStr = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                    let parts = ruleStr.split(separator: ",")
                    if parts.count >= 2 {
                        let typeStr = String(parts[0]).lowercased()
                        let typeMap: [String: ProxyRule.RuleType] = [
                            "domain": .domain, "domain-suffix": .domainSuffix, "domain-keyword": .domainKeyword,
                            "ip-cidr": .ipCIDR, "ip-cidr6": .ipCIDR, "geoip": .geoip, "port": .port, "match": .final,
                            "dst-port": .port, "src-port": .port
                        ]
                        
                        let type = typeMap[typeStr] ?? .domain
                        let isMatch = (typeStr == "match")
                        
                        let pattern = isMatch ? "" : String(parts[1])
                        let actionPart = isMatch ? String(parts[1]) : (parts.count > 2 ? String(parts[2]) : String(parts[1]))
                        
                        let actionStr = actionPart.trimmingCharacters(in: .whitespaces).lowercased()
                        var action: ProxyRule.RuleAction = .proxy
                        if actionStr == "direct" || actionStr.contains("直连") { action = .direct }
                        else if actionStr == "reject" || actionStr.contains("拦截") || actionStr.contains("广告") { action = .reject }
                        
                        rules.append(ProxyRule(type: type, pattern: pattern, action: action))
                    }
                } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    inRules = false
                }
            }
        }
        
        if !currentNode.isEmpty {
            if let node = createNode(from: currentNode) {
                nodes.append(node)
            }
        }
        
        return SubscriptionConfig(version: "1.0", nodes: nodes, updateTime: Date(), remark: nil, rules: rules)
    }
    
    private func parseClashDict(_ str: String) -> [String: String]? {
        var result: [String: String] = [:]
        
        // 移除外层的 { }
        let cleanStr = str.trimmingCharacters(in: CharacterSet(charactersIn: " {}"))
        
        var currentKey = ""
        var currentValue = ""
        var inKey = true
        var inQuotes = false
        var braceDepth = 0
        
        for char in cleanStr {
            if char == "\"" || char == "'" {
                inQuotes.toggle()
            } else if char == "{" && !inQuotes {
                braceDepth += 1
                if !inKey { currentValue.append(char) }
            } else if char == "}" && !inQuotes {
                braceDepth -= 1
                if !inKey { currentValue.append(char) }
            } else if char == "," && !inQuotes && braceDepth == 0 {
                let key = currentKey.trimmingCharacters(in: .whitespaces)
                let val = currentValue.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { result[key] = val }
                currentKey = ""
                currentValue = ""
                inKey = true
            } else if char == ":" && !inQuotes && braceDepth == 0 {
                inKey = false
            } else {
                if inKey {
                    currentKey.append(char)
                } else {
                    currentValue.append(char)
                }
            }
        }
        
        if !currentKey.isEmpty {
            let key = currentKey.trimmingCharacters(in: .whitespaces)
            let val = currentValue.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = val }
        }
        
        return result.isEmpty ? nil : result
    }
    
    private func createNode(from dict: [String: String]) -> ProxyNode? {
        guard let typeStr = dict["type"],
              let protocolType = parseProtocolType(typeStr),
              let server = dict["server"],
              let portStr = dict["port"],
              let port = UInt16(portStr) else {
            return nil
        }
        
        var node = ProxyNode(
            type: protocolType,
            serverAddress: server,
            serverPort: port
        )
        
        node.name = dict["name"]
        // VMess 节点 uuid 字段即为 password（Clash 格式用 uuid，其他协议用 password）
        node.password = dict["uuid"] ?? dict["password"] ?? dict["id"]
        node.username = dict["user"]
        node.encryption = dict["cipher"] ?? dict["encryption"]
        node.alterId = dict["alterid"].flatMap { Int($0) }
        node.network = dict["network"]
        if let tlsStr = dict["tls"]?.lowercased() {
            node.tls = ["true", "yes", "1", "tls"].contains(tlsStr)
        } else {
            node.tls = false
        }
        node.skipCertVerify = false
        if let skipVerify = dict["skip-cert-verify"] ?? dict["tls-skip-verify"] ?? dict["allow-insecure"] {
            node.skipCertVerify = ["true", "yes", "1"].contains(skipVerify.lowercased())
        }
        node.sni = dict["sni"] ?? dict["servername"]
        node.path = dict["path"]
        
        // 智能判定：如果开启了 TLS 且设置了 SNI (通常是伪装域名)，则默认跳过证书验证。
        if node.tls == true && node.sni != nil && node.sni != node.serverAddress {
            if node.skipCertVerify != true {
                node.skipCertVerify = true
                NSLog("Subscription: Auto-enabled skipCertVerify for camouflaged node: \(node.name ?? "unnamed")")
            }
        }
        
        // 解析 gRPC 服务名
        if let grpcOpts = dict["grpc-opts"] {
            // grpcOpts 格式可能为 "{grpc-service-name: 12306}" 或节点内嵌格式
            let inner = grpcOpts.trimmingCharacters(in: CharacterSet(charactersIn: " {}"))
            // 应对 "grpc-service-name: 12306" 或 "grpc-service-name: '12306'"
            let parts = inner.split(separator: ":", maxSplits: 1)
            if parts.count >= 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                if key == "grpc-service-name" {
                    node.grpcServiceName = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " '\" "))
                }
            }
        } else if let serviceName = dict["grpc-service-name"] {
            node.grpcServiceName = serviceName.trimmingCharacters(in: CharacterSet(charactersIn: " '\" "))
        }

        // 新增：VLESS / Hysteria2 / TUIC 字段
        if let flow = dict["flow"], !flow.isEmpty {
            node.flow = flow.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        }
        if let obfs = dict["obfs"], !obfs.isEmpty {
            node.obfs = obfs.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        }
        if let obfsPwd = dict["obfs-password"] ?? dict["obfs_password"] {
            node.obfsPassword = obfsPwd.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        }
        if let up = dict["up"] ?? dict["up-mbps"] {
            node.upMbps = Int(up.trimmingCharacters(in: CharacterSet(charactersIn: " Mmbps'\"")))
        }
        if let down = dict["down"] ?? dict["down-mbps"] {
            node.downMbps = Int(down.trimmingCharacters(in: CharacterSet(charactersIn: " Mmbps'\"")))
        }
        if let cc = dict["congestion-controller"] ?? dict["congestion-control"] ?? dict["cc"] {
            node.congestionControl = cc.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        }
        if let mode = dict["udp-relay-mode"] {
            node.udpRelayMode = mode.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        }
        if let alpnStr = dict["alpn"] {
            let cleaned = alpnStr.trimmingCharacters(in: CharacterSet(charactersIn: " []'\""))
            let list = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }.filter { !$0.isEmpty }
            if !list.isEmpty { node.alpn = list }
        }
        // TUIC 需要同时 uuid + password；Clash 字段名为 uuid
        if node.type == .tuic {
            if let tuicUUID = dict["uuid"] {
                node.uuid = tuicUUID.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            }
            // 上面把 dict["uuid"] 当 password 写入了，TUIC 需要改回真实 password
            if let pwd = dict["password"] {
                node.password = pwd.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            } else {
                node.password = nil
            }
        }

        return node
    }
    
    private func parseProtocolType(_ type: String) -> ProxyProtocol? {
        let cleanType = type.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
        switch cleanType {
        case "http":
            return .http
        case "https":
            return .https
        case "socks5", "socks":
            return .socks5
        case "shadowsocks", "ss":
            return .shadowsocks
        case "vmess", "v2ray":
            return .vmess
        case "trojan":
            return .trojan
        case "vless":
            return .vless
        case "hysteria2", "hy2":
            return .hysteria2
        case "tuic":
            return .tuic
        default:
            return nil
        }
    }
}

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    @Published var subscriptions: [Subscription] = []
    @Published var currentNode: ProxyNode?
    @Published var isLoading = false
    @Published var selectedSubscriptionId: UUID?

    // MARK: - 策略组自动选择联动
    @Published var activeGroupNodeTag: String?        // sing-box urltest 当前选中的 outbound tag
    @Published var groupNodeDelays: [String: Int] = [:] // outbound tag → 延迟(ms)
    private var groupPollingTimer: Timer?
    private lazy var clashAPISession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]  // 绕过 VPN HTTP 代理
        config.timeoutIntervalForRequest = 2
        return URLSession(configuration: config)
    }()

    private let userDefaults = UserDefaults(suiteName: "group.com.proxynaut") ?? UserDefaults.standard
    private let subscriptionsKey = "subscriptions"
    private let currentNodeKey = "currentNode"
    private let selectedSubscriptionKey = "selectedSubscriptionId"

    private init() {
        migrateFromStandardUserDefaults()
        loadSubscriptions()
        loadCurrentNode()
        loadSelectedSubscription()
    }

    private func migrateFromStandardUserDefaults() {
        let standard = UserDefaults.standard
        if let data = standard.data(forKey: subscriptionsKey) {
            userDefaults.set(data, forKey: subscriptionsKey)
            standard.removeObject(forKey: subscriptionsKey)
        }
        if let data = standard.data(forKey: currentNodeKey) {
            userDefaults.set(data, forKey: currentNodeKey)
            standard.removeObject(forKey: currentNodeKey)
        }
        if let idString = standard.string(forKey: selectedSubscriptionKey) {
            userDefaults.set(idString, forKey: selectedSubscriptionKey)
            standard.removeObject(forKey: selectedSubscriptionKey)
        }
    }

    var selectedSubscription: Subscription? {
        guard let id = selectedSubscriptionId else { return nil }
        return subscriptions.first { $0.id == id }
    }

    var activeNodes: [ProxyNode] {
        guard let subscription = selectedSubscription else { return [] }
        return subscription.nodes
    }

    func selectSubscription(_ subscription: Subscription) {
        selectedSubscriptionId = subscription.id
        userDefaults.set(subscription.id.uuidString, forKey: selectedSubscriptionKey)
    }

    func deselectSubscription() {
        selectedSubscriptionId = nil
        userDefaults.removeObject(forKey: selectedSubscriptionKey)
    }

    private func loadSelectedSubscription() {
        if let idString = userDefaults.string(forKey: selectedSubscriptionKey),
           let id = UUID(uuidString: idString) {
            selectedSubscriptionId = id
        }
    }
    
    func addSubscription(_ subscription: Subscription) {
        subscriptions.append(subscription)
        saveSubscriptions()
        selectSubscription(subscription)
        Task {
            await fetchAndUpdate(subscription)
        }
    }
    
    func removeSubscription(_ subscription: Subscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        saveSubscriptions()
    }
    
    func updateSubscription(_ subscription: Subscription) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = subscription
            saveSubscriptions()
        }
    }

    /// 切换节点订阅自带规则的启用状态。仅持久化；VPN 运行中修改需重连或切换节点生效。
    func setRulesEnabled(subscriptionID: UUID, enabled: Bool) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        subscriptions[index].rulesEnabled = enabled
        saveSubscriptions()
    }

    func fetchAll() {
        isLoading = true
        
        Task {
            await refreshAll()
            
            await MainActor.run {
                isLoading = false
            }
        }
    }
    
    /// 可 await 的订阅刷新方法，连接前调用确保节点数据是最新的
    func refreshAll() async {
        for subscription in subscriptions {
            await fetchAndUpdate(subscription)
        }
    }

    /// 根据每个订阅的 autoUpdate/updateInterval/lastUpdate 判断是否需要刷新
    /// App 启动、进入前台、以及前台周期性 Timer 都会调用此方法
    /// force=true 时忽略时间窗口，刷新所有 autoUpdate=true 的订阅
    func refreshIfNeeded(force: Bool = false) async {
        let now = Date()
        let due = subscriptions.filter { sub in
            force ? sub.autoUpdate : sub.shouldAutoRefresh(now: now)
        }
        guard !due.isEmpty else { return }
        NSLog("SubscriptionManager: Auto-refreshing \(due.count) subscription(s) (force=\(force))")
        for sub in due {
            await fetchAndUpdate(sub)
        }
    }
    
    /// 从最新订阅数据中更新 currentNode，确保 grpcServiceName/uuid 等字段不丢失
    func refreshCurrentNode() {
        guard var node = currentNode else { return }
        var updated = false
        
        for sub in subscriptions {
            if let freshNode = sub.nodes.first(where: {
                $0.serverAddress == node.serverAddress &&
                $0.serverPort == node.serverPort &&
                $0.type == node.type
            }) {
                // 用订阅中最新版本的节点整体替换，保留所有已修复字段
                node = freshNode
                updated = true
                NSLog("SubscriptionManager: Refreshed currentNode from subscription: grpcServiceName=\(freshNode.grpcServiceName ?? "nil"), uuid=\(freshNode.password?.prefix(8).description ?? "nil")...")
                break
            }
        }
        
        if updated {
            currentNode = node
            saveCurrentNode()
        }
    }
    
    func findNode(byID id: String) -> ProxyNode? {
        for subscription in subscriptions {
            if let node = subscription.nodes.first(where: { $0.id == id }) {
                return node
            }
        }
        return nil
    }
    
    func fetchAndUpdate(_ subscription: Subscription) async {
        let inputURL = subscription.url.trimmingCharacters(in: .whitespacesAndNewlines)

        if inputURL.hasPrefix("vmess://") {
            await handleVMessLink(inputURL, subscription: subscription)
            return
        }

        // 单个 vless:// / hysteria2:// / hy2:// / tuic:// 链接：直接解析
        if inputURL.hasPrefix("vless://") || inputURL.hasPrefix("hysteria2://") ||
           inputURL.hasPrefix("hy2://") || inputURL.hasPrefix("tuic://") {
            await handleSingleProxyLink(inputURL, subscription: subscription)
            return
        }
        
        guard let url = URL(string: inputURL) else { 
            print("Invalid URL: \(inputURL)")
            return 
        }
        
        print("Fetching: \(url)")
        
        var config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        
        let session = URLSession(configuration: config)
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, application/xml, application/x-yaml, text/yaml, application/json, text/html, */*", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        
        var lastError: Error?
        var lastData: Data?
        
        for attempt in 0..<3 {
            print("Fetch attempt \(attempt + 1)")
            
            do {
                let (data, response) = try await session.data(for: request)
                lastData = data
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    continue
                }
                
                // --- 自动提取建议名称逻辑 ---
                if let contentDisposition = httpResponse.allHeaderFields["Content-Disposition"] as? String {
                    // 解析 filename="..." 或 filename*=...
                    let fileName = contentDisposition.components(separatedBy: "filename=").last?
                        .trimmingCharacters(in: .init(charactersIn: " \"'"))
                        .replacingOccurrences(of: ".yaml", with: "")
                        .replacingOccurrences(of: ".txt", with: "")
                        .replacingOccurrences(of: ".conf", with: "")
                    
                    if let finalName = fileName, !finalName.isEmpty {
                        await MainActor.run {
                            var updated = subscription
                            updated.name = finalName
                            self.updateSubscription(updated)
                        }
                    }
                }
                
                print("HTTP Status: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 {
                    if let dataString = String(data: data, encoding: .utf8) {
                        print("First 500 chars of response: \(dataString.prefix(500))")
                        
                        let isHTML = dataString.contains("<!DOCTYPE") || dataString.contains("<html") || dataString.contains("<body")
                        let isCloudflareChallenge = isHTML && (dataString.contains("cloudflare") || dataString.contains("Just a moment") || dataString.contains("cf-browser-verification"))
                        if isCloudflareChallenge {
                            print("Cloudflare challenge, waiting...")
                            try await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1)))
                            continue
                        }
                        
                        if dataString.contains("proxies:") || dataString.hasPrefix("vmess://") || dataString.hasPrefix("ss://") || dataString.hasPrefix("trojan://") {
                            print("Subscription data detected")
                        }
                        
                        if dataString.count > 1000 {
                            print("Large response (\(dataString.count) chars), likely valid subscription")
                        }
                    }
                    
                    if let config = SubscriptionParser.shared.parse(from: data, format: .clash) {
                        print("Parsed \(config.nodes.count) nodes from Clash format")
                        if !config.nodes.isEmpty {
                            let groups = generateProxyGroups(from: config.nodes)
                            await MainActor.run {
                                var updated = subscription
                                updated.nodes = config.nodes
                                updated.proxyGroups = groups
                                updated.rules = config.rules ?? []
                                updated.ruleCount = updated.rules.count
                                updated.lastUpdate = Date()
                                updateSubscription(updated)
                            }
                            return
                        }
                    }
                    
                    if let config = SubscriptionParser.shared.parse(from: data, format: .yaml) {
                        print("Parsed \(config.nodes.count) nodes from YAML format")
                        if !config.nodes.isEmpty {
                            let groups = generateProxyGroups(from: config.nodes)
                            await MainActor.run {
                                var updated = subscription
                                updated.nodes = config.nodes
                                updated.proxyGroups = groups
                                updated.rules = config.rules ?? []
                                updated.ruleCount = updated.rules.count
                                updated.lastUpdate = Date()
                                updateSubscription(updated)
                            }
                            return
                        }
                    }
                    
                    if let config = SubscriptionParser.shared.parse(from: data, format: .json) {
                        print("Parsed \(config.nodes.count) nodes from JSON format")
                        if !config.nodes.isEmpty {
                            let groups = generateProxyGroups(from: config.nodes)
                            await MainActor.run {
                                var updated = subscription
                                updated.nodes = config.nodes
                                updated.proxyGroups = groups
                                updated.lastUpdate = Date()
                                updateSubscription(updated)
                            }
                            return
                        }
                    }
                    
                    if let dataString = String(data: data, encoding: .utf8) {
                        print("Parse failed, trying raw Base64 decode...")
                        if let decodedData = Data(base64Encoded: dataString, options: .ignoreUnknownCharacters) {
                            if let config = SubscriptionParser.shared.parse(from: decodedData, format: .clash) {
                                print("Parsed from Base64: \(config.nodes.count) nodes")
                                if !config.nodes.isEmpty {
                                    let groups = generateProxyGroups(from: config.nodes)
                                    await MainActor.run {
                                        var updated = subscription
                                        updated.nodes = config.nodes
                                        updated.proxyGroups = groups
                                        updated.lastUpdate = Date()
                                        updateSubscription(updated)
                                    }
                                    return
                                }
                            }
                        }
                        
                        print("Trying to parse embedded links in response...")
                        let nodes = parseSubscriptionLinks(dataString)
                        if !nodes.isEmpty {
                            print("Parsed \(nodes.count) nodes from links")
                            let groups = generateProxyGroups(from: nodes)
                            await MainActor.run {
                                var updated = subscription
                                updated.nodes = nodes
                                updated.proxyGroups = groups
                                updated.lastUpdate = Date()
                                updateSubscription(updated)
                            }
                            return
                        }
                    }
                }
                
                if httpResponse.statusCode == 302 || httpResponse.statusCode == 301 {
                    if let location = httpResponse.value(forHTTPHeaderField: "Location") {
                        print("Redirect to: \(location)")
                        if let redirectURL = URL(string: location) {
                            request.url = redirectURL
                        }
                    }
                }
                
            } catch {
                lastError = error
                print("Fetch error: \(error)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        
        if let data = lastData, let dataString = String(data: data, encoding: .utf8) {
            print("Final attempt with raw data: \(dataString.prefix(200))")

            let nodes = parseSubscriptionLinks(dataString)
            if !nodes.isEmpty {
                print("Parsed \(nodes.count) nodes from links")
                let groups = generateProxyGroups(from: nodes)
                await MainActor.run {
                    var updated = subscription
                    updated.nodes = nodes
                    updated.proxyGroups = groups
                    updated.lastUpdate = Date()
                    updateSubscription(updated)
                }
                return
            }
        }
        
        if let data = lastData, let dataString = String(data: data, encoding: .utf8) {
            let trimmed = dataString.trimmingCharacters(in: .whitespacesAndNewlines)
            print("Raw data length: \(trimmed.count), content: \(trimmed)")
            
            let trimmedData = Data(trimmed.utf8)
            if let decodedData = Data(base64Encoded: trimmedData, options: .ignoreUnknownCharacters) {
                if let decodedString = String(data: decodedData, encoding: .utf8) {
                    print("Decoded Base64 content: \(decodedString.prefix(1000))")
                    
                    let nodes = parseSubscriptionLinks(decodedString)
                    if !nodes.isEmpty {
                        print("Parsed \(nodes.count) nodes from decoded Base64")
                        let groups = generateProxyGroups(from: nodes)
                        await MainActor.run {
                            var updated = subscription
                            updated.nodes = nodes
                            updated.proxyGroups = groups
                            updated.lastUpdate = Date()
                            updateSubscription(updated)
                        }
                        return
                    }
                    
                    if decodedString.contains("proxies:") {
                        print("Found Clash format in decoded data")
                        if let config = SubscriptionParser.shared.parse(from: decodedData, format: .clash) {
                            print("Parsed \(config.nodes.count) nodes from Clash")
                            let groups = generateProxyGroups(from: config.nodes)
                            await MainActor.run {
                                var updated = subscription
                                updated.nodes = config.nodes
                                updated.proxyGroups = groups
                                updated.lastUpdate = Date()
                                updateSubscription(updated)
                            }
                            return
                        }
                    }
                }
            }
            
            let nodes = parseSubscriptionLinks(trimmed)
            if !nodes.isEmpty {
                print("Parsed \(nodes.count) nodes from links")
                let groups = generateProxyGroups(from: nodes)
                await MainActor.run {
                    var updated = subscription
                    updated.nodes = nodes
                    updated.proxyGroups = groups
                    updated.lastUpdate = Date()
                    updateSubscription(updated)
                }
                return
            }
        }
        
        print("All attempts failed")
    }
    
    private func parseSubscriptionLinks(_ content: String) -> [ProxyNode] {
        var nodes: [ProxyNode] = []
        
        print("Looking for proxy links in content...")
        
        let vmessPattern = "vmess://([A-Za-z0-9+/=]+)"
        guard let vmessRegex = try? NSRegularExpression(pattern: vmessPattern, options: []) else { return nodes }
        
        let range = NSRange(content.startIndex..., in: content)
        let vmessMatches = vmessRegex.matches(in: content, options: [], range: range)
        
        print("Found \(vmessMatches.count) vmess:// links")
        
        for match in vmessMatches {
            guard let matchRange = Range(match.range(at: 1), in: content) else { continue }
            let base64String = String(content[matchRange])
            
            print("Decoding vmess Base64: \(base64String.prefix(50))...")
            
            guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
                  var jsonString = String(data: data, encoding: .utf8) else {
                print("Failed to decode Base64")
                continue
            }
            
            jsonString = decodeUnicodeEscapes(jsonString)
            print("VMess JSON: \(jsonString)")
            
            struct VMessConfig: Codable {
                let v: String?
                let ps: String?
                let add: String?
                let port: String?
                let id: String?
                let aid: String?
                let net: String?
                let type: String?
                let host: String?
                let path: String?
                let tls: String?
                let sni: String?
            }
            
            guard let jsonData = jsonString.data(using: .utf8),
                  let config = try? JSONDecoder().decode(VMessConfig.self, from: jsonData),
                  let add = config.add,
                  let portStr = config.port,
                  let port = UInt16(portStr) else {
                print("Failed to parse VMess JSON - missing required fields")
                continue
            }
            
            var node = ProxyNode(
                type: .vmess,
                serverAddress: add,
                serverPort: port
            )
            node.name = config.ps ?? add
            node.password = config.id ?? ""
            node.alterId = Int(config.aid ?? "0")
            node.network = config.net
            node.tls = config.tls == "tls"
            node.sni = config.sni ?? config.host
            
            // VMess JSON: net=grpc 时 path 字段是 gRPC 服务名
            if node.network == "grpc" {
                node.grpcServiceName = config.path
                node.path = nil
            } else {
                node.path = config.path
            }
            
            // gRPC + TLS + SNI 不匹配时自动跳过证书验证
            if node.tls == true && node.sni != nil && node.sni != node.serverAddress {
                node.skipCertVerify = true
            }
            
            print("Parsed node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort) grpc=\(node.grpcServiceName ?? "-")")
            nodes.append(node)
        }
        
        let ssPattern = "ss://([A-Za-z0-9+/=]+)"
        guard let ssRegex = try? NSRegularExpression(pattern: ssPattern, options: []) else { return nodes }
        
        let ssMatches = ssRegex.matches(in: content, options: [], range: range)
        print("Found \(ssMatches.count) ss:// links")
        
        for match in ssMatches {
            guard let matchRange = Range(match.range(at: 1), in: content) else { continue }
            let base64String = String(content[matchRange])
            
            guard let decoded = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
                  var decodedString = String(data: decoded, encoding: .utf8) else { continue }
            
            decodedString = decodeUnicodeEscapes(decodedString)
            decodedString = "ss://\(decodedString)"
            
            if let node = parseSSLink(decodedString) {
                print("Parsed SS node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort)")
                nodes.append(node)
            }
        }
        
        let trojanPattern = "trojan://([A-Za-z0-9+/=]+)"
        guard let trojanRegex = try? NSRegularExpression(pattern: trojanPattern, options: []) else { return nodes }
        
        let trojanMatches = trojanRegex.matches(in: content, options: [], range: range)
        print("Found \(trojanMatches.count) trojan:// links")
        
        for match in trojanMatches {
            guard let matchRange = Range(match.range(at: 1), in: content) else { continue }
            let base64String = String(content[matchRange])
            
            guard let decoded = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
                  var decodedString = String(data: decoded, encoding: .utf8) else { continue }
            
            decodedString = decodeUnicodeEscapes(decodedString)
            decodedString = "trojan://\(decodedString)"
            
            if let node = parseTrojanLink(decodedString) {
                print("Parsed Trojan node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort)")
                nodes.append(node)
            }
        }

        // VLESS / Hysteria2 / TUIC：纯文本 URI，按行扫描
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("vless://") {
                if let node = parseVLESSLink(line) {
                    print("Parsed VLESS node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort)")
                    nodes.append(node)
                }
            } else if line.hasPrefix("hysteria2://") || line.hasPrefix("hy2://") {
                if let node = parseHysteria2Link(line) {
                    print("Parsed Hysteria2 node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort)")
                    nodes.append(node)
                }
            } else if line.hasPrefix("tuic://") {
                if let node = parseTUICLink(line) {
                    print("Parsed TUIC node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort)")
                    nodes.append(node)
                }
            }
        }

        print("Total parsed nodes: \(nodes.count)")
        
        // 过滤无效节点（127.0.0.1 等本地地址）
        let validNodes = nodes.filter { node in
            let addr = node.serverAddress.lowercased()
            return addr != "127.0.0.1" && addr != "localhost" && !addr.isEmpty
        }
        
        if validNodes.count < nodes.count {
            print("Filtered \(nodes.count - validNodes.count) invalid nodes (127.0.0.1/localhost)")
        }
        
        return validNodes
    }
    
    /// 根据节点自动生成策略组（类似 Clash 的行为）
    private func generateProxyGroups(from nodes: [ProxyNode]) -> [ProxyGroup] {
        guard !nodes.isEmpty else { return [] }
        
        var groups: [ProxyGroup] = []
        let allNodeNames = nodes.compactMap { $0.name }
        
        // 1. 主策略组 - 手动选择（包含所有节点）
        let mainGroup = ProxyGroup(
            name: NSLocalizedString("group.default", comment: "Default proxy group name"),
            type: .select,
            proxies: allNodeNames,
            testURL: nil,
            interval: nil
        )
        groups.append(mainGroup)
        
        // 2. 自动测速策略组
        let urlTestGroup = ProxyGroup(
            name: NSLocalizedString("group.auto_select", comment: "Auto select proxy group name"),
            type: .urlTest,
            proxies: allNodeNames,
            testURL: "http://www.gstatic.com/generate_204",
            interval: 300
        )
        groups.append(urlTestGroup)
        
        // 3. 故障转移策略组
        let fallbackGroup = ProxyGroup(
            name: NSLocalizedString("group.fallback", comment: "Fallback proxy group name"),
            type: .fallback,
            proxies: allNodeNames,
            testURL: "http://www.gstatic.com/generate_204",
            interval: 300
        )
        groups.append(fallbackGroup)
        
        // 4. 按地区自动分组（如果节点数 > 3）
        if nodes.count > 3 {
            var regionGroups: [String: [String]] = [:]
            
            for node in nodes {
                guard let name = node.name else { continue }
                let region = detectRegion(from: name)
                if let existing = regionGroups[region] {
                    regionGroups[region] = existing + [name]
                } else {
                    regionGroups[region] = [name]
                }
            }
            
            // 只为有多个节点的地区创建分组
            for (region, nodeNames) in regionGroups.sorted(by: { $0.key < $1.key }) {
                if nodeNames.count >= 1 {
                    let group = ProxyGroup(
                        name: region,
                        type: .select,
                        proxies: nodeNames,
                        testURL: nil,
                        interval: nil
                    )
                    groups.append(group)
                }
            }
        }
        
        return groups
    }
    
    /// 从节点名称中检测地区
    private func detectRegion(from nodeName: String) -> String {
        let name = nodeName.lowercased()
        
        // 香港
        if name.contains("香港") || name.contains("hk") || name.contains("hongkong") || name.contains("hong kong") {
            return "region.hk"
        }
        // 台湾
        if name.contains("台湾") || name.contains("tw") || name.contains("taiwan") || name.contains("taipei") {
            return "region.tw"
        }
        // 日本
        if name.contains("日本") || name.contains("jp") || name.contains("japan") || name.contains("tokyo") {
            return "region.jp"
        }
        // 新加坡
        if name.contains("新加坡") || name.contains("sg") || name.contains("singapore") {
            return "region.sg"
        }
        // 美国
        if name.contains("美国") || name.contains("us") || name.contains("usa") || name.contains("america") || name.contains("united states") {
            return "region.us"
        }
        // 韩国
        if name.contains("韩国") || name.contains("kr") || name.contains("korea") || name.contains("seoul") {
            return "region.kr"
        }
        // 英国
        if name.contains("英国") || name.contains("uk") || name.contains("britain") || name.contains("london") {
            return "region.uk"
        }
        // 德国
        if name.contains("德国") || name.contains("de") || name.contains("germany") || name.contains("frankfurt") {
            return "region.de"
        }
        // 法国
        if name.contains("法国") || name.contains("fr") || name.contains("france") || name.contains("paris") {
            return "region.fr"
        }
        // 澳大利亚
        if name.contains("澳大利亚") || name.contains("au") || name.contains("australia") || name.contains("sydney") {
            return "region.au"
        }
        // 加拿大
        if name.contains("加拿大") || name.contains("ca") || name.contains("canada") || name.contains("toronto") {
            return "region.ca"
        }
        // 专线/特殊线路
        if name.contains("专线") {
            return "region.private"
        }
        
        // 默认未知地区
        return "region.other"
    }
    
    private func decodeUnicodeEscapes(_ json: String) -> String {
        guard let data = json.data(using: .utf8) else { return json }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) else { return json }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject) else { return json }
        return String(data: jsonData, encoding: .utf8) ?? json
    }
    
    private func parseVMessLink(_ link: String) -> ProxyNode? {
        let base64String = String(link.dropFirst(8))
        
        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        struct VMessConfig: Codable {
            let v: String?
            let ps: String?
            let add: String
            let port: String
            let id: String
            let aid: Int?
            let net: String?
            let type: String?
            let host: String?
            let path: String?
            let tls: String?
            let sni: String?
        }
        
        guard let jsonData = jsonString.data(using: .utf8),
              let config = try? JSONDecoder().decode(VMessConfig.self, from: jsonData) else {
            return nil
        }
        
        var node = ProxyNode(
            type: .vmess,
            serverAddress: config.add,
            serverPort: UInt16(config.port) ?? 443
        )
        node.name = config.ps ?? config.add
        node.password = config.id
        node.alterId = config.aid
        node.network = config.net
        node.path = config.path
        node.tls = config.tls == "tls"
        node.sni = config.sni ?? config.host
        
        return node
    }
    
    private func parseSSLink(_ link: String) -> ProxyNode? {
        guard let urlPart = link.dropFirst(5).split(separator: "#", maxSplits: 1).first,
              let url = URL(string: String(urlPart)) else {
            return nil
        }
        
        guard let method = url.user,
              let password = url.password,
              let host = url.host else {
            return nil
        }
        
        var node = ProxyNode(
            type: .shadowsocks,
            serverAddress: host,
            serverPort: UInt16(url.port ?? 443)
        )
        node.password = "\(method):\(password)"
        
        if link.contains("#") {
            let namePart = link.split(separator: "#", maxSplits: 1).last
            node.name = String(namePart ?? "")
        }
        
        return node
    }
    
    private func parseTrojanLink(_ link: String) -> ProxyNode? {
        guard let urlPart = link.dropFirst(8).split(separator: "#", maxSplits: 1).first,
              let url = URL(string: String(urlPart)) else {
            return nil
        }
        
        guard let password = url.user,
              let host = url.host else {
            return nil
        }
        
        var node = ProxyNode(
            type: .trojan,
            serverAddress: host,
            serverPort: UInt16(url.port ?? 443)
        )
        node.password = password
        node.tls = true
        
        if let query = url.query {
            let params = query.split(separator: "&")
            for param in params {
                let parts = param.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    switch parts[0] {
                    case "sni":
                        node.sni = String(parts[1])
                    case "path":
                        node.path = String(parts[1])
                    default:
                        break
                    }
                }
            }
        }
        
        if link.contains("#") {
            let namePart = link.split(separator: "#", maxSplits: 1).last
            node.name = String(namePart ?? "")
        }

        return node
    }

    // MARK: - VLESS / Hysteria2 / TUIC URI 解析

    /// 通用 query string 解析，处理 URL 解码
    private func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let rawValue = String(kv[1])
            let value = rawValue.removingPercentEncoding ?? rawValue
            result[key] = value
        }
        return result
    }

    private func parseAlpnValue(_ raw: String) -> [String]? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: " []'\""))
        let list = cleaned.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }.filter { !$0.isEmpty }
        return list.isEmpty ? nil : list
    }

    /// vless://uuid@host:port?encryption=none&flow=...&security=tls&sni=...&type=ws&path=...&host=...&alpn=h2,h3#name
    func parseVLESSLink(_ link: String) -> ProxyNode? {
        guard link.hasPrefix("vless://") else { return nil }
        let body = String(link.dropFirst("vless://".count))
        let beforeFragment = body.split(separator: "#", maxSplits: 1).first.map(String.init) ?? body
        let fragment: String? = body.contains("#") ? String(body.split(separator: "#", maxSplits: 1).last ?? "") : nil

        // 拆出 userinfo@hostport[?query]
        guard let atIdx = beforeFragment.firstIndex(of: "@") else { return nil }
        let uuid = String(beforeFragment[..<atIdx])
        let rest = String(beforeFragment[beforeFragment.index(after: atIdx)...])

        var hostPort = rest
        var query = ""
        if let qIdx = rest.firstIndex(of: "?") {
            hostPort = String(rest[..<qIdx])
            query = String(rest[rest.index(after: qIdx)...])
        }

        let hostPortParts = hostPort.split(separator: ":", maxSplits: 1)
        guard hostPortParts.count == 2,
              let port = UInt16(hostPortParts[1]) else { return nil }
        let host = String(hostPortParts[0])

        var node = ProxyNode(type: .vless, serverAddress: host, serverPort: port)
        node.password = uuid  // VLESS 复用 password 存 uuid（与 vmess 一致）
        let params = parseQuery(query)
        node.flow = params["flow"]
        if let security = params["security"]?.lowercased() {
            node.tls = (security == "tls" || security == "reality")
        }
        node.sni = params["sni"] ?? params["host"]
        node.network = params["type"]
        if node.network == "grpc" {
            node.grpcServiceName = params["serviceName"] ?? params["path"]
        } else {
            node.path = params["path"]
        }
        if let alpn = params["alpn"] { node.alpn = parseAlpnValue(alpn) }
        if let insecure = params["allowInsecure"] ?? params["insecure"] {
            node.skipCertVerify = ["1", "true", "yes"].contains(insecure.lowercased())
        }
        node.name = fragment?.removingPercentEncoding ?? fragment
        return node
    }

    /// hysteria2://password@host:port?sni=...&obfs=salamander&obfs-password=...&insecure=1&alpn=h3#name
    func parseHysteria2Link(_ link: String) -> ProxyNode? {
        let prefix: String
        if link.hasPrefix("hysteria2://") { prefix = "hysteria2://" }
        else if link.hasPrefix("hy2://") { prefix = "hy2://" }
        else { return nil }

        let body = String(link.dropFirst(prefix.count))
        let beforeFragment = body.split(separator: "#", maxSplits: 1).first.map(String.init) ?? body
        let fragment: String? = body.contains("#") ? String(body.split(separator: "#", maxSplits: 1).last ?? "") : nil

        guard let atIdx = beforeFragment.firstIndex(of: "@") else { return nil }
        let password = String(beforeFragment[..<atIdx]).removingPercentEncoding ?? String(beforeFragment[..<atIdx])
        let rest = String(beforeFragment[beforeFragment.index(after: atIdx)...])

        var hostPort = rest
        var query = ""
        if let qIdx = rest.firstIndex(of: "?") {
            hostPort = String(rest[..<qIdx])
            query = String(rest[rest.index(after: qIdx)...])
        }

        let hostPortParts = hostPort.split(separator: ":", maxSplits: 1)
        guard hostPortParts.count == 2,
              let port = UInt16(hostPortParts[1]) else { return nil }
        let host = String(hostPortParts[0])

        var node = ProxyNode(type: .hysteria2, serverAddress: host, serverPort: port)
        node.password = password
        node.tls = true
        let params = parseQuery(query)
        node.sni = params["sni"] ?? params["peer"]
        node.obfs = params["obfs"]
        node.obfsPassword = params["obfs-password"] ?? params["obfs_password"]
        if let up = params["upmbps"] ?? params["up"] { node.upMbps = Int(up) }
        if let down = params["downmbps"] ?? params["down"] { node.downMbps = Int(down) }
        if let alpn = params["alpn"] { node.alpn = parseAlpnValue(alpn) }
        if let insecure = params["insecure"] ?? params["allowInsecure"] {
            node.skipCertVerify = ["1", "true", "yes"].contains(insecure.lowercased())
        }
        node.name = fragment?.removingPercentEncoding ?? fragment
        return node
    }

    /// tuic://uuid:password@host:port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=...&allow_insecure=1#name
    func parseTUICLink(_ link: String) -> ProxyNode? {
        guard link.hasPrefix("tuic://") else { return nil }
        let body = String(link.dropFirst("tuic://".count))
        let beforeFragment = body.split(separator: "#", maxSplits: 1).first.map(String.init) ?? body
        let fragment: String? = body.contains("#") ? String(body.split(separator: "#", maxSplits: 1).last ?? "") : nil

        guard let atIdx = beforeFragment.firstIndex(of: "@") else { return nil }
        let userinfo = String(beforeFragment[..<atIdx])
        let rest = String(beforeFragment[beforeFragment.index(after: atIdx)...])

        let uuidPwd = userinfo.split(separator: ":", maxSplits: 1)
        guard uuidPwd.count == 2 else { return nil }
        let uuid = String(uuidPwd[0]).removingPercentEncoding ?? String(uuidPwd[0])
        let password = String(uuidPwd[1]).removingPercentEncoding ?? String(uuidPwd[1])

        var hostPort = rest
        var query = ""
        if let qIdx = rest.firstIndex(of: "?") {
            hostPort = String(rest[..<qIdx])
            query = String(rest[rest.index(after: qIdx)...])
        }

        let hostPortParts = hostPort.split(separator: ":", maxSplits: 1)
        guard hostPortParts.count == 2,
              let port = UInt16(hostPortParts[1]) else { return nil }
        let host = String(hostPortParts[0])

        var node = ProxyNode(type: .tuic, serverAddress: host, serverPort: port)
        node.uuid = uuid
        node.password = password
        node.tls = true
        let params = parseQuery(query)
        node.sni = params["sni"] ?? params["peer"]
        node.congestionControl = params["congestion_control"] ?? params["congestion-control"] ?? params["cc"]
        node.udpRelayMode = params["udp_relay_mode"] ?? params["udp-relay-mode"]
        if let alpn = params["alpn"] { node.alpn = parseAlpnValue(alpn) }
        if let insecure = params["allow_insecure"] ?? params["allowInsecure"] ?? params["insecure"] {
            node.skipCertVerify = ["1", "true", "yes"].contains(insecure.lowercased())
        }
        node.name = fragment?.removingPercentEncoding ?? fragment
        return node
    }

    private func handleVMessLink(_ link: String, subscription: Subscription) async {
        let base64String = String(link.dropFirst(8))
        
        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("Invalid vmess link: cannot decode base64")
            return
        }
        
        struct VMessConfig: Codable {
            let v: String?
            let ps: String?
            let add: String
            let port: String
            let id: String
            let aid: Int?
            let net: String?
            let type: String?
            let host: String?
            let path: String?
            let tls: String?
            let sni: String?
        }
        
        guard let jsonData = jsonString.data(using: .utf8),
              let config = try? JSONDecoder().decode(VMessConfig.self, from: jsonData) else {
            print("Invalid vmess JSON")
            return
        }
        
        var node = ProxyNode(
            type: .vmess,
            serverAddress: config.add,
            serverPort: UInt16(config.port) ?? 443
        )
        node.name = config.ps ?? config.add
        node.password = config.id
        node.alterId = config.aid
        node.network = config.net
        node.path = config.path
        node.tls = config.tls == "tls"
        node.sni = config.sni ?? config.host
        
        print("Parsed VMess node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort)")
        
        await MainActor.run {
            var updated = subscription
            updated.nodes = [node]
            updated.lastUpdate = Date()
            updateSubscription(updated)
        }
    }

    private func handleSingleProxyLink(_ link: String, subscription: Subscription) async {
        let node: ProxyNode?
        if link.hasPrefix("vless://") {
            node = parseVLESSLink(link)
        } else if link.hasPrefix("hysteria2://") || link.hasPrefix("hy2://") {
            node = parseHysteria2Link(link)
        } else if link.hasPrefix("tuic://") {
            node = parseTUICLink(link)
        } else {
            node = nil
        }
        guard let parsed = node else {
            print("Failed to parse single proxy link: \(link.prefix(40))…")
            return
        }
        await MainActor.run {
            var updated = subscription
            updated.nodes = [parsed]
            updated.proxyGroups = generateProxyGroups(from: [parsed])
            updated.lastUpdate = Date()
            updateSubscription(updated)
        }
    }

    func selectNode(_ node: ProxyNode) {
        currentNode = node
        saveCurrentNode()
        
        NotificationCenter.default.post(name: .nodeSelectionChanged, object: node)
    }
    
    func loadSubscriptions() {
        if let data = userDefaults.data(forKey: subscriptionsKey),
           var loaded = try? JSONDecoder().decode([Subscription].self, from: data) {
            // 为没有策略组的旧订阅自动生成默认策略组
            var modified = false
            for i in loaded.indices {
                if loaded[i].proxyGroups.isEmpty && !loaded[i].nodes.isEmpty {
                    loaded[i].proxyGroups = generateProxyGroups(from: loaded[i].nodes)
                    modified = true
                }
            }
            subscriptions = loaded
            if modified {
                saveSubscriptions()
            }
        }
    }
    
    func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            userDefaults.set(data, forKey: subscriptionsKey)
        }
    }
    
    func loadCurrentNode() {
        if let data = userDefaults.data(forKey: currentNodeKey),
           let node = try? JSONDecoder().decode(ProxyNode.self, from: data) {
            currentNode = node
        }
    }
    
    func saveCurrentNode() {
        if let node = currentNode,
           let data = try? JSONEncoder().encode(node) {
            userDefaults.set(data, forKey: currentNodeKey)
        } else {
            userDefaults.removeObject(forKey: currentNodeKey)
        }
    }
    
    func testLatency(for node: ProxyNode) async -> Int {
        let iface = await getPhysicalInterface()
        return await performLatencyTest(for: node, via: iface)
    }
    
    func testAllLatencies() async {
        // 获取物理网络接口，绕过 VPN 隧道
        let physicalInterface = await self.getPhysicalInterface()

        // 收集所有需要测试的节点
        var allNodes: [(subIndex: Int, nodeIndex: Int, node: ProxyNode)] = []
        for i in subscriptions.indices {
            for j in subscriptions[i].nodes.indices {
                allNodes.append((i, j, subscriptions[i].nodes[j]))
            }
        }

        // 分批测试，手动控制并发（每批 8 个）
        let batchSize = 8
        for batchStart in stride(from: 0, to: allNodes.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, allNodes.count)
            let batch = Array(allNodes[batchStart..<batchEnd])

            var results: [(Int, Int, Int)] = []

            await withTaskGroup(of: (Int, Int, Int).self) { group in
                for (i, j, node) in batch {
                    group.addTask {
                        let latency = await self.performLatencyTest(for: node, via: physicalInterface)
                        return (i, j, latency)
                    }
                }

                for await result in group {
                    results.append(result)
                }
            }

            // 批量更新 UI
            await MainActor.run {
                for (i, j, latency) in results {
                    if i < self.subscriptions.count && j < self.subscriptions[i].nodes.count {
                        self.subscriptions[i].nodes[j].latency = latency
                    }
                }
            }
        }
    }

    /// 获取物理网络接口（WiFi / 蜂窝），用于绕过 VPN 隧道测延迟
    private func getPhysicalInterface() async -> NWInterface? {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                let iface = path.availableInterfaces.first {
                    $0.type == .wifi || $0.type == .cellular || $0.type == .wiredEthernet
                }
                continuation.resume(returning: iface)
            }
            monitor.start(queue: DispatchQueue(label: "latency.iface"))
        }
    }

    private func performLatencyTest(for node: ProxyNode, via physicalInterface: NWInterface? = nil) async -> Int {
        let timeout = 3.0
        let host = node.serverAddress
        let port = NWEndpoint.Port(integerLiteral: node.serverPort)

        let startTime = CFAbsoluteTimeGetCurrent()
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)

        let parameters = NWParameters.tcp
        // 绑定物理接口，避免 VPN 开启时流量经隧道导致延迟不准
        if let iface = physicalInterface {
            parameters.requiredInterface = iface
        }

        let connection = NWConnection(to: endpoint, using: parameters)
        
        return await withCheckedContinuation { continuation in
            var completed = false
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !completed {
                        completed = true
                        let endTime = CFAbsoluteTimeGetCurrent()
                        connection.cancel()
                        let latency = Int((endTime - startTime) * 1000)
                        
                        // 修正：由于经过了内核转发，延迟如果非常低（如 < 2ms），说明可能还是撞到了某种劫持
                        if latency < 2 {
                            continuation.resume(returning: -2)
                        } else {
                            continuation.resume(returning: latency)
                        }
                    }
                case .failed, .cancelled:
                    if !completed {
                        completed = true
                        continuation.resume(returning: -2)
                    }
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
            
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if !completed {
                    completed = true
                    connection.cancel()
                    continuation.resume(returning: -2)
                }
            }
        }
    }
    
    /// 同步解析 IP (App 侧版本)
    private func resolveAllIPs(_ hostname: String) -> [String] {
        var ips: [String] = []
        var res: UnsafeMutablePointer<addrinfo>?
        let n = getaddrinfo(hostname, nil, nil, &res)
        defer { if res != nil { freeaddrinfo(res) } }
        
        if n == 0 {
            var curr = res
            while let ptr = curr {
                var addr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if ptr.pointee.ai_family == AF_INET {
                    let sin = ptr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var sin_addr = sin.sin_addr
                    inet_ntop(AF_INET, &sin_addr, &addr, socklen_t(INET6_ADDRSTRLEN))
                    ips.append(String(cString: addr))
                }
                curr = ptr.pointee.ai_next
            }
        }
        return ips
    }

    // MARK: - Clash API 策略组轮询

    func startGroupPolling() {
        stopGroupPolling()
        // 立即查一次
        fetchGroupInfo()
        // 每 15 秒轮询一次，降低耗电
        groupPollingTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.fetchGroupInfo()
        }
    }

    func stopGroupPolling() {
        groupPollingTimer?.invalidate()
        groupPollingTimer = nil
        activeGroupNodeTag = nil
        groupNodeDelays = [:]
    }

    private func fetchGroupInfo() {
        // 合并为一次 /proxies 请求：从返回中直接取 proxy 组的 now/all 以及各节点 delay
        guard let url = URL(string: "http://127.0.0.1:9090/proxies") else { return }
        clashAPISession.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let proxies = json["proxies"] as? [String: Any] else {
                return
            }
            let group = proxies["proxy"] as? [String: Any]
            let now = group?["now"] as? String
            let allTags = (group?["all"] as? [String]) ?? []
            var delays: [String: Int] = [:]
            for tag in allTags {
                if let proxyInfo = proxies[tag] as? [String: Any],
                   let history = proxyInfo["history"] as? [[String: Any]],
                   let last = history.last,
                   let delay = last["delay"] as? Int, delay > 0 {
                    delays[tag] = delay
                }
            }
            DispatchQueue.main.async {
                self?.activeGroupNodeTag = now
                self?.groupNodeDelays = delays
            }
        }.resume()
    }

    /// 根据 sing-box outbound tag 找回对应的 ProxyNode
    func activeGroupNode() -> ProxyNode? {
        guard let tag = activeGroupNodeTag else { return nil }
        // tag 格式: "node-{ProxyNode.id}"，其中 id = "{type}-{name}"
        let nodeId = String(tag.dropFirst("node-".count))
        for sub in subscriptions {
            if let node = sub.nodes.first(where: { $0.id == nodeId }) {
                return node
            }
        }
        return nil
    }

    /// 获取某节点的 Clash API 延迟（通过代理测出的真实延迟）
    func groupDelay(for node: ProxyNode) -> Int? {
        let tag = "node-\(node.id)"
        return groupNodeDelays[tag]
    }
}

extension Notification.Name {
    static let nodeSelectionChanged = Notification.Name("nodeSelectionChanged")
}