import Foundation

// --- Mocking necessary types ---
enum ProxyProtocol: String, Codable {
    case vmess, shadowsocks, trojan, selector, urltest = "url-test"
}

struct ProxyNode: Codable {
    var name: String?
    var type: ProxyProtocol
    var serverAddress: String?
    var serverPort: UInt16?
    var isGroup: Bool = false
    var groupType: String?
    var proxies: [String]?
    
    init(type: ProxyProtocol, serverAddress: String? = nil, serverPort: UInt16? = nil) {
        self.type = type
        self.serverAddress = serverAddress
        self.serverPort = serverPort
    }
}

struct SubscriptionConfig: Codable {
    var version: String
    var nodes: [ProxyNode]
}

class SubscriptionParser {
    static let shared = SubscriptionParser()
    
    func parse(from data: Data) -> SubscriptionConfig? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        var nodes: [ProxyNode] = []
        let lines = content.components(separatedBy: .newlines)
        var currentSection = ""
        var currentNodeDict: [String: Any] = [:]
        let quoteSet = CharacterSet(charactersIn: " \"'")
        
        func finalizeNode() {
            if !currentNodeDict.isEmpty {
                if let name = currentNodeDict["name"] as? String {
                    if currentSection == "proxies" {
                        var node = ProxyNode(type: .shadowsocks)
                        node.name = name
                        nodes.append(node)
                    } else if currentSection == "proxy-groups" {
                        var node = ProxyNode(type: .selector)
                        node.name = name
                        node.isGroup = true
                        node.groupType = currentNodeDict["type"] as? String
                        node.proxies = currentNodeDict["proxies"] as? [String]
                        nodes.append(node)
                    }
                }
            }
            currentNodeDict = [:]
        }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            
            if indent == 0 && trimmed.hasSuffix(":") {
                finalizeNode()
                currentSection = trimmed.dropLast().lowercased().trimmingCharacters(in: .whitespaces)
                continue
            }
            
            if currentSection == "proxies" || currentSection == "proxy-groups" {
                if trimmed.hasPrefix("- ") && !trimmed.contains(":") && !trimmed.contains("{") {
                    // This is a plain list member outside of a dict initialization
                    let member = trimmed.dropFirst(2).trimmingCharacters(in: quoteSet).trimmingCharacters(in: .whitespaces)
                    if var list = currentNodeDict["proxies"] as? [String] {
                        list.append(member); currentNodeDict["proxies"] = list
                    }
                } else if trimmed.hasPrefix("- ") {
                    finalizeNode()
                    let remainder = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if remainder.hasPrefix("{") {
                        if let range = remainder.range(of: "name:\\s*\"?([^,\"}]+)\"?", options: .regularExpression) {
                             let namePart = remainder[range]
                             if let colonIndex = namePart.firstIndex(of: ":") {
                                 let value = namePart[namePart.index(after: colonIndex)...].trimmingCharacters(in: quoteSet).trimmingCharacters(in: .whitespaces)
                                 currentNodeDict["name"] = value
                             }
                        }
                    } else if remainder.contains(":") {
                        let parts = remainder.split(separator: ":", maxSplits: 1)
                        let key = String(parts[0]).lowercased().trimmingCharacters(in: quoteSet)
                        let val = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: quoteSet) : ""
                        currentNodeDict[key] = val
                    }
                } else if trimmed.contains(":") {
                    let parts = trimmed.split(separator: ":", maxSplits: 1)
                    let key = String(parts[0]).lowercased().trimmingCharacters(in: quoteSet)
                    let val = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: quoteSet) : ""
                    if key == "proxies" {
                        if val.hasPrefix("[") {
                            let listStr = val.trimmingCharacters(in: CharacterSet(charactersIn: " []\"'"))
                            currentNodeDict["proxies"] = listStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: quoteSet).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        } else {
                            currentNodeDict["proxies"] = [String]()
                        }
                    } else {
                        currentNodeDict[key] = val
                    }
                } else if (trimmed.hasPrefix("-") || trimmed.hasPrefix("•")) && indent > 0 {
                    let memberIdx = trimmed.index(after: trimmed.startIndex)
                    let member = trimmed[memberIdx...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quoteSet)
                    if !member.isEmpty {
                        var list = (currentNodeDict["proxies"] as? [String]) ?? []
                        list.append(member)
                        currentNodeDict["proxies"] = list
                    }
                }
            }
        }
        finalizeNode()
        return SubscriptionConfig(version: "1.0", nodes: nodes)
    }
}

let tester = SubscriptionParser()
let yaml = """
proxies:
  - {name: "Node1", type: ss, server: s1, port: 83, password: p}
proxy-groups:
  - name: "G1"
    type: select
    proxies:
      - Node1
  - name: "G2"
    type: select
    proxies: [G1]
  - name: "G3"
    type: select
    proxies:
      - G2
"""
if let config = tester.parse(from: yaml.data(using: .utf8)!) {
    print("Total nodes: \(config.nodes.count)")
    for node in config.nodes {
        print("Node: \(node.name ?? "unnamed") (Group: \(node.isGroup), Proxies: \(node.proxies?.joined(separator: ", ") ?? "none"))")
    }
}
