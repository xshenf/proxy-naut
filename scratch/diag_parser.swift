import Foundation

// --- Mock Models to make it compilable as a standalone script ---
enum ProxyProtocol: String, Codable {
    case http, https, socks5, shadowsocks, vmess, trojan
}

struct ProxyRule: Codable {
    enum RuleType: String, Codable {
        case domain, domainSuffix, domainKeyword, ipCIDR, geoip, port, final
    }
    enum RuleAction: String, Codable {
        case proxy, direct, reject
    }
    var type: RuleType
    var pattern: String
    var action: RuleAction
}

struct ProxyNode: Codable, Identifiable {
    var id: String {
        if isGroup { return "group-\(name ?? "unnamed")" }
        return "\(type.rawValue)-\(name ?? serverAddress)"
    }
    var name: String?
    var type: ProxyProtocol
    var serverAddress: String = ""
    var serverPort: UInt16 = 0
    var isGroup: Bool = false
    var groupType: String?
    var proxies: [String]?
    var url: String?
    var interval: Int?
}

struct SubscriptionConfig: Codable {
    var version: String
    var nodes: [ProxyNode]
    var updateTime: Date?
    var rules: [ProxyRule]?
}

// --- Minimal Parser Logic copied from SubscriptionManager.swift with improvements ---

class SubscriptionParser {
    static let shared = SubscriptionParser()
    
    func parseClash(_ content: String) -> SubscriptionConfig? {
        var nodes: [ProxyNode] = []
        var rules: [ProxyRule] = []
        let lines = content.components(separatedBy: .newlines)
        
        var currentSection = ""
        var currentNodeDict: [String: Any] = [:]
        
        func finalizeNode() {
            if !currentNodeDict.isEmpty {
                if currentSection == "proxies" {
                    if let node = createNode(from: currentNodeDict) {
                        nodes.append(node)
                    }
                } else if currentSection == "proxy-groups" {
                    if let group = createGroupNode(from: currentNodeDict) {
                        nodes.append(group)
                    }
                }
                currentNodeDict = [:]
            }
        }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            
            if indent == 0 && trimmed.hasSuffix(":") {
                finalizeNode()
                let section = trimmed.dropLast().lowercased().trimmingCharacters(in: .whitespaces)
                if ["proxies", "proxy-groups", "rules"].contains(section) {
                    currentSection = section
                    continue
                } else {
                    currentSection = "" // resets for other top-level keys like 'dns', 'port' etc.
                }
            }
            
            if currentSection == "proxies" || currentSection == "proxy-groups" {
                if trimmed.hasPrefix("- ") {
                    finalizeNode()
                    let remainder = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if remainder.hasPrefix("{") {
                        if let dict = parseClashDict(remainder) {
                            if currentSection == "proxies" {
                                if let node = createNode(from: dict) { nodes.append(node) }
                            } else {
                                if let group = createGroupNode(from: dict) { nodes.append(group) }
                            }
                        }
                    } else if remainder.contains(":") {
                        let parts = remainder.split(separator: ":", maxSplits: 1)
                        let key = String(parts[0]).lowercased().trimmingCharacters(in: .init(charactersIn: " \"'"))
                        let val = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .init(charactersIn: " \"'")) : ""
                        currentNodeDict[key] = val
                    }
                } else if trimmed.contains(":") {
                    let parts = trimmed.split(separator: ":", maxSplits: 1)
                    let key = String(parts[0]).lowercased().trimmingCharacters(in: .init(charactersIn: " \"'"))
                    let val = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) // don't trim quotes yet, we might need them for list check
                    
                    if key == "proxies" {
                        let cleanVal = val.trimmingCharacters(in: .init(charactersIn: " \"'"))
                        if cleanVal.hasPrefix("[") && cleanVal.hasSuffix("]") {
                            let listStr = cleanVal.trimmingCharacters(in: .init(charactersIn: " []"))
                            currentNodeDict["proxies"] = listStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .init(charactersIn: " \"'")) }.filter { !$0.isEmpty }
                        } else {
                            currentNodeDict["proxies"] = [String]()
                        }
                    } else {
                        currentNodeDict[key] = val.trimmingCharacters(in: .init(charactersIn: " \"'"))
                    }
                } else if (trimmed.hasPrefix("-") || trimmed.hasPrefix("•")) && (currentNodeDict["proxies"] as? [String]) != nil {
                     // Multi-line list item
                    let member = trimmed.dropFirst().trimmingCharacters(in: .init(charactersIn: " \"'"))
                    if var list = currentNodeDict["proxies"] as? [String] {
                        list.append(member)
                        currentNodeDict["proxies"] = list
                    }
                }
            }
        }
        
        finalizeNode()
        return SubscriptionConfig(version: "1.0", nodes: nodes, updateTime: Date(), rules: rules)
    }

    private func createGroupNode(from dict: [String: Any]) -> ProxyNode? {
        guard let name = (dict["name"] as? String)?.trimmingCharacters(in: .init(charactersIn: " \"'")),
              let typeStr = (dict["type"] as? String)?.trimmingCharacters(in: .init(charactersIn: " \"'")) else { return nil }
        
        let lowerType = typeStr.lowercased()
        if !["select", "url-test", "fallback", "load-balance"].contains(lowerType) { return nil }
        
        var node = ProxyNode(name: name, type: .socks5, isGroup: true, groupType: lowerType)
        
        if let proxies = dict["proxies"] as? [String] {
            node.proxies = proxies
        }
        
        node.url = dict["url"] as? String
        return node
    }

    private func createNode(from dict: [String: Any]) -> ProxyNode? {
        guard let typeStr = (dict["type"] as? String)?.lowercased(),
              let server = dict["server"] as? String ?? dict["add"] as? String,
              let portRaw = dict["port"],
              let port = UInt16("\(portRaw)") else { return nil }
              
        let protocolType: ProxyProtocol? = {
             switch typeStr {
             case "ss", "shadowsocks": return .shadowsocks
             case "vmess": return .vmess
             case "trojan": return .trojan
             case "http": return .http
             case "https": return .https
             case "socks5", "socks": return .socks5
             default: return nil
             }
        }()
        
        guard let pType = protocolType else { return nil }
        var node = ProxyNode(name: dict["name"] as? String ?? server, type: pType, serverAddress: server, serverPort: port)
        return node
    }
    
    private func parseClashDict(_ str: String) -> [String: String]? {
        // Implementation omitted for brevity in mock, assume it does basic JSON-like {K: V}
        return nil 
    }
}

// --- Test Suite ---

class Tester {
    func run() {
        print("Starting parser diagnostic...")
        testBasicGroup()
        testMultiLineProxies()
        print("Diagnostic complete.")
    }
    
    func assert(_ condition: Bool, _ msg: String) {
        print(condition ? "✅ \(msg)" : "❌ FAILED: \(msg)")
    }
    
    func testBasicGroup() {
        let yaml = """
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Node1
      - Node2
"""
        let config = SubscriptionParser.shared.parseClash(yaml)
        assert(config?.nodes.count == 1, "Should parse 1 group")
        assert(config?.nodes.first?.name == "Proxy", "Name should match")
        assert(config?.nodes.first?.proxies?.count == 2, "Should have 2 nodes in group")
    }

    func testMultiLineProxies() {
        let yaml = """
proxy-groups:
  - name: G1
    type: select
    proxies: 
      - A
      - B
  - name: G2
    type: select
    proxies: [C, D]
"""
        let config = SubscriptionParser.shared.parseClash(yaml)
        assert(config?.nodes.count == 2, "Should parse 2 groups")
        assert(config?.nodes.first?.proxies?.contains("A") == true, "G1 should have A")
        assert(config?.nodes.last?.proxies?.contains("C") == true, "G2 should have C")
    }
}

Tester().run()
