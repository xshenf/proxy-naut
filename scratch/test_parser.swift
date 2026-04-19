import Foundation

// 模拟 ProxyProtocol
enum ProxyProtocol: String, Codable {
    case shadowsocks, vmess, trojan, http, https, socks5
}

// 模拟 ProxyNode
struct ProxyNode: Codable {
    var type: ProxyProtocol
    var serverAddress: String
    var serverPort: UInt16
    var name: String?
}

class SubscriptionParserTest {
    
    func parseProtocolType(_ type: String) -> ProxyProtocol? {
        switch type.lowercased() {
        case "http", "https":
            return type.lowercased() == "https" ? .https : .http
        case "socks5", "socks":
            return .socks5
        case "shadowsocks", "ss":
            return .shadowsocks
        case "vmess", "v2ray":
            return .vmess
        case "trojan":
            return .trojan
        default:
            return nil
        }
    }

    func parseClashDict(_ str: String) -> [String: String]? {
        var result: [String: String] = [:]
        let cleanStr = str.trimmingCharacters(in: CharacterSet(charactersIn: " {}"))
        var currentKey = ""
        var currentValue = ""
        var inKey = true
        var inQuotes = false
        var braceDepth = 0
        
        for char in cleanStr {
            if char == "\"" || char == "'" { inQuotes.toggle() }
            else if char == "{" && !inQuotes { braceDepth += 1; if !inKey { currentValue.append(char) } }
            else if char == "}" && !inQuotes { braceDepth -= 1; if !inKey { currentValue.append(char) } }
            else if char == "," && !inQuotes && braceDepth == 0 {
                let key = currentKey.trimmingCharacters(in: .whitespaces).lowercased()
                let val = currentValue.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { result[key] = val }
                currentKey = ""; currentValue = ""; inKey = true
            } else if char == ":" && !inQuotes && braceDepth == 0 { inKey = false }
            else { if inKey { currentKey.append(char) } else { currentValue.append(char) } }
        }
        if !currentKey.isEmpty {
            let key = currentKey.trimmingCharacters(in: .whitespaces).lowercased()
            let val = currentValue.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = val }
        }
        return result.isEmpty ? nil : result
    }

    func createNode(from dict: [String: String]) -> ProxyNode? {
        print("DEBUG: Trying to create node from dict: \(dict)")
        guard let typeStr = dict["type"],
              let protocolType = parseProtocolType(typeStr),
              let server = dict["server"],
              let portStr = dict["port"],
              let port = UInt16(portStr) else {
            return nil
        }
        return ProxyNode(type: protocolType, serverAddress: server, serverPort: port, name: dict["name"])
    }

    func parseClash(_ content: String) -> [ProxyNode] {
        var nodes: [ProxyNode] = []
        var currentNodeDict: [String: String] = [:]
        var inProxies = false
        let lines = content.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "proxies:" { inProxies = true; continue }
            if trimmed.hasPrefix("proxy-groups:") { inProxies = false; continue }
            
            if inProxies {
                if trimmed.hasPrefix("- ") {
                    if !currentNodeDict.isEmpty {
                        if let node = createNode(from: currentNodeDict) { nodes.append(node) }
                        currentNodeDict = [:]
                    }
                    let remainder = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if remainder.hasPrefix("{") {
                        if let dict = parseClashDict(remainder) {
                            if let node = createNode(from: dict) { nodes.append(node) }
                        }
                        currentNodeDict = [:]
                    } else if remainder.contains(":") {
                        let parts = remainder.split(separator: ":", maxSplits: 1)
                        if parts.count >= 2 {
                            let key = String(parts[0]).lowercased().trimmingCharacters(in: .whitespaces)
                            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                            currentNodeDict[key] = value
                        }
                    }
                } else if !trimmed.isEmpty && trimmed.contains(":") {
                    let parts = trimmed.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0]).lowercased().trimmingCharacters(in: .whitespaces)
                        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        currentNodeDict[key] = value
                    }
                }
            }
        }
        if !currentNodeDict.isEmpty { if let node = createNode(from: currentNodeDict) { nodes.append(node) } }
        return nodes
    }
}

let testContent = """
proxies:
  - {name: "🚀 自动选择", type: select, url: "http://www.gstatic.com/generate_204", interval: 300, proxies: ["Node1"]}
  - {name: "🛑 全球拦截", type: select, proxies: ["REJECT", "DIRECT", "Node1"]}
  - {name: "Node1", type: vmess, server: 1.1.1.1, port: 443}
proxy-groups:
  - name: "Group"
"""

let tester = SubscriptionParserTest()
let result = tester.parseClash(testContent)
print("--- RESULT ---")
print("Total nodes found: \(result.count)")
for node in result {
    print("Node: \(node.name ?? "unnamed") [\(node.type)] @ \(node.serverAddress)")
}
