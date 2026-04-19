class IntegrationTester {
    func runDeepTests() {
        print("\n🔍 Starting Deep Parsing Tests...")
        testColonInValues()
        testCommaInValues()
        testEscapedQuotes()
        testDeeplyNestedGroups()
        testClashMixedIndentation()
        testEmptySections()
        testClashDuplicateKeys()
        print("\n✨ Deep Tests completed.")
    }

    func assert(_ condition: Bool, _ label: String, _ message: String) {
        if condition {
            print("✅ [\(label)] \(message)")
        } else {
            print("❌ [\(label)] FAILED: \(message)")
        }
    }

    func testColonInValues() {
        print("\n--- Test: Colon in Values (Inline) ---")
        let yaml = "proxies:\n  - {name: \"WSNode\", type: vmess, server: server.com, port: 443, uuid: uuid, network: ws, ws-opts: {path: \"/path?param=v1:v2\", headers: {Host: \"v1:v2.com\"}}, tls: true}"
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: SubscriptionParser.SubscriptionFormat.clash)
        assert(config != nil, "Parse", "Should not crash")
        assert(config?.nodes.count == 1, "Count", "Should parse 1 node")
    }

    func testCommaInValues() {
        print("\n--- Test: Comma in Values (Inline) ---")
        let yaml = "proxies:\n  - {name: \"Node,With,Comma\", type: trojan, server: s1, port: 443, password: p1}"
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: SubscriptionParser.SubscriptionFormat.clash)
        assert(config?.nodes.first?.name == "Node,With,Comma", "CommaHandling", "Should parse name containing commas correctly")
    }

    func testEscapedQuotes() {
        print("\n--- Test: Escaped Quotes ---")
        let yaml = "proxies:\n  - {name: \"Node with \\\"Quotes\\\"\", type: ss, server: s1, port: 8388, password: p1, cipher: aes-128-gcm}"
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: SubscriptionParser.SubscriptionFormat.clash)
        assert(config?.nodes.first?.name?.contains("\"Quotes\"") == true, "QuotesHandling", "Should parse escaped quotes in name")
    }

    func testDeeplyNestedGroups() {
        print("\n--- Test: Deeply Nested Groups ---")
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
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: SubscriptionParser.SubscriptionFormat.clash)
        assert(config?.nodes.count == 4, "NestedCount", "Should parse node and 3 groups (Total: \(config?.nodes.count ?? 0))")
        let g1 = config?.nodes.first(where: { $0.name == "G1" })
        assert(g1?.isGroup == true, "G1Group", "G1 should be a group")
        assert(g1?.proxies?.contains("Node1") == true, "G1Members", "G1 should have Node1")
        
        let g3 = config?.nodes.first(where: { $0.name == "G3" })
        assert(g3?.isGroup == true, "G3Group", "G3 should be a group")
        assert(g3?.proxies?.contains("G2") == true, "G3Members", "G3 should have G2 member")
    }
    
    func testClashMixedIndentation() {
        print("\n--- Test: Mixed Indentation ---")
        let yaml = """
proxies:
  - name: Node1
    type: ss
    server: s1
    port: 80
  -  name: Node2
     type: ss
     server: s2
     port: 80
"""
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: SubscriptionParser.SubscriptionFormat.clash)
        assert(config?.nodes.count == 2, "Indentation", "Should handle irregular but valid indentation")
    }
    
    func testEmptySections() {
        print("\n--- Test: Empty Sections ---")
        let yaml = """
proxies:
proxy-groups:
rules:
"""
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: SubscriptionParser.SubscriptionFormat.clash)
        assert(config != nil, "Empty", "Should not crash on empty sections")
    }
    
    func testClashDuplicateKeys() {
        print("\n--- Test: Duplicate Keys ---")
        let yaml = """
proxies:
  - name: Node1
    type: ss
    server: s1
    port: 80
    type: trojan
"""
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: SubscriptionParser.SubscriptionFormat.clash)
        // type: trojan appears second, so it should be the final value in a standard parser
        assert(config?.nodes.first?.type == .trojan, "Parsed", "Should parse despite duplicate keys")
    }
}

IntegrationTester().runDeepTests()
