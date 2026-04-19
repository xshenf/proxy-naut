
import Foundation
import Network

// Setup constants for source files
let subscriptionManagerPath = "/Users/xshen/workspace/clashx2/Shared/SubscriptionManager.swift"
let configurationPath = "/Users/xshen/workspace/clashx2/Shared/Configuration.swift"
let proxyHandlerPath = "/Users/xshen/workspace/clashx2/Shared/ProxyHandler.swift"

func readFile(_ path: String) -> String {
    return try! String(contentsOfFile: path)
}

// Combine source files but remove imports to avoid duplication
func combineSources() -> String {
    var combined = "import Foundation
import Network
import Combine
"
    
    let files = [proxyHandlerPath, configurationPath, subscriptionManagerPath]
    for file in files {
        let content = readFile(file)
        let lines = content.components(separatedBy: "
")
        for line in lines {
            if !line.hasPrefix("import ") {
                combined += line + "
"
            }
        }
    }
    return combined
}

let testScaffold = """
class Tester {
    func runTests() {
        testClashParsing()
        testVMessLinkParsing()
        testRuleParsing()
        testEdgeCases()
    }

    func assert(_ condition: Bool, _ icon: String, _ message: String) {
        if condition {
            print("\u{2705} \(message)")
        } else {
            print("\u{274C} FAILED: \(message)")
        }
    }

    func testClashParsing() {
        print("\n--- Testing Clash Parsing ---")
        let yaml = \"\"\"
proxies:
  - {name: "StandardNode", type: vmess, server: 1.1.1.1, port: 443, uuid: uuid-1, tls: true}
  - name: "IndentedNode"
    type: shadowsocks
    server: 2.2.2.2
    port: 8388
    cipher: chacha20-ietf-poly1305
    password: pass
proxy-groups:
  - name: "Group1"
    type: select
    proxies:
      - StandardNode
      - IndentedNode
\"\"\"
        let data = yaml.data(using: .utf8)!
        let config = SubscriptionParser.shared.parse(from: data, format: .clash)
        
        assert(config != nil, "Parsing", "Clash YAML should parse")
        assert(config?.nodes.count == 3, "NodeCount", "Should find 3 nodes (2 proxies + 1 group)")
        
        let nodes = config?.nodes ?? []
        let group = nodes.first(where: { $0.isGroup })
        assert(group != nil, "GroupFound", "Should find one group")
        assert(group?.proxies?.count == 2, "GroupMemberCount", "Group should have 2 members")
    }

    func testVMessLinkParsing() {
        print("\n--- Testing VMess Link Parsing ---")
        // {"v":"2","ps":"Tester","add":"8.8.8.8","port":"443","id":"id-val","aid":"0","net":"tcp","type":"none","tls":"tls"}
        let link = "vmess://eyJ2IjoiMiIsInBzIjoiVGVzdGVyIiwiYWRkIjoiOC44LjguOCIsInBvcnQiOiI0NDMiLCJpZCI6ImlkLXZhbCIsImFpZCI6IjAiLCJuZXQiOiJ0Y3AiLCJ0eXBlIjoibm9uZSIsInRscyI6InRscyJ9"
        let data = link.data(using: .utf8)!
        let config = SubscriptionParser.shared.parse(from: data, format: .json)
        
        assert(config != nil, "Parsing", "VMess link should parse")
        assert(config?.nodes.count == 1, "NodeCount", "Should find 1 vmess node")
        assert(config?.nodes.first?.name == "Tester", "NodeName", "Node name should be Tester")
        assert(config?.nodes.first?.password == "id-val", "NodeUUID", "Node password (UUID) should be id-val")
    }

    func testRuleParsing() {
        print("\n--- Testing Rule Parsing ---")
        let yaml = \"\"\"
proxies:
  - {name: "Node", type: trojan, server: 3.3.3.3, port: 443, password: pass}
rules:
  - DOMAIN-SUFFIX,google.com,Proxy
  - IP-CIDR,192.168.1.0/24,DIRECT
  - MATCH,Proxy
\"\"\"
        let data = yaml.data(using: .utf8)!
        let config = SubscriptionParser.shared.parse(from: data, format: .clash)
        
        assert(config?.rules?.count == 3, "RuleCount", "Should parse 3 rules")
        let first = config?.rules?.first
        assert(first?.type == .domainSuffix, "RuleType", "First rule should be domainSuffix")
        assert(first?.pattern == "google.com", "RulePattern", "First rule pattern should be google.com")
        assert(first?.action == .proxy, "RuleAction", "First rule action should be proxy")
    }

    func testEdgeCases() {
        print("\n--- Testing Edge Cases ---")
        
        // Case: colon in name
        let yamlColon = "proxies:\n  - {name: \"Node:With:Colon\", type: http, server: 4.4.4.4, port: 80}"
        let data = yamlColon.data(using: .utf8)!
        let config = SubscriptionParser.shared.parse(from: data, format: .clash)
        assert(config?.nodes.first?.name == "Node:With:Colon", "NameWithColon", "Should handle colon in name inside quotes")
    }
}

Tester().runTests()
"""

let combinedSource = combineSources()
let fullScript = combinedSource + testScaffold
try! fullScript.write(toFile: "/Users/xshen/workspace/clashx2/scratch/SubscriptionTester.swift", atomically: true, encoding: .utf8)
print("Tester created at scratch/SubscriptionTester.swift")
