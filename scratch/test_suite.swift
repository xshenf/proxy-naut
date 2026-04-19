class Tester {
    func runTests() {
        print("🚀 Starting Subscription Parser Tests...")
        testClashStandard()
        testClashInline()
        testClashNestedGroups()
        testVMessLink()
        testMixedRules()
        testEdgeCaseSpecialChars()
        testVMessIDvsUUID()
        testVMessJSONNumericalPort()
        print("\n✨ All tests completed.")
    }

    func assert(_ condition: Bool, _ label: String, _ message: String) {
        if condition {
            print("\u{2705} [\(label)] \(message)")
        } else {
            print("\u{274C} [\(label)] FAILED: \(message)")
        }
    }

    func testClashStandard() {
        print("\n--- Test: Clash Standard Indented ---")
        let yaml = """
proxies:
  - name: "Node 1"
    type: shadowsocks
    server: 1.1.1.1
    port: 8388
    cipher: chacha20-ietf-poly1305
    password: pass
  - name: "Node 2"
    type: trojan
    server: 2.2.2.2
    port: 443
    password: pass
"""
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: .clash)
        assert(config?.nodes.count == 2, "Standard", "Should parse 2 indented nodes")
    }

    func testClashInline() {
        print("\n--- Test: Clash Inline Dict ---")
        let yaml = """
proxies:
  - {name: "Inline SS", type: ss, server: 3.3.3.3, port: 8388, cipher: aes-128-gcm, password: pass}
  - {name: "Inline VMess", type: vmess, server: 4.4.4.4, port: 443, uuid: uuid-val, tls: true}
"""
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: .clash)
        assert(config?.nodes.count == 2, "Inline", "Should parse 2 inline nodes")
        assert(config?.nodes.last?.password == "uuid-val", "UUID", "Should find vmess uuid in inline dict")
    }

    func testClashNestedGroups() {
        print("\n--- Test: Clash Nested Groups ---")
        let yaml = """
proxies:
  - {name: "NodeA", type: http, server: 5.5.5.5, port: 80}
proxy-groups:
  - name: "Auto"
    type: url-test
    proxies:
      - NodeA
  - name: "Select"
    type: select
    proxies:
      - Auto
      - DIRECT
"""
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: .clash)
        assert(config?.nodes.count == 3, "Nested", "Should parse 1 node + 2 groups")
    }

    func testVMessLink() {
        print("\n--- Test: VMess Link ---")
        let link = "vmess://eyJ2IjoiMiIsInBzIjoiTGlua05vZGUiLCJhZGQiOiJhZGRyIiwicG9ydCI6MTIzLCJpZCI6InV1aWQiLCJuZXQiOiJ3cyIsInBhdGgiOiIvcGF0aCIsInRscyI6InRscSJ9"
        let config = SubscriptionParser.shared.parse(from: link.data(using: .utf8)!, format: .json)
        assert(config?.nodes.count == 1, "VMessLink", "Should parse 1 vmess link")
    }

    func testMixedRules() {
        print("\n--- Test: Rules ---")
        let yaml = """
rules:
  - DOMAIN,google.com,Proxy
  - DOMAIN-SUFFIX,cn,DIRECT
  - MATCH,DIRECT
"""
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: .clash)
        assert(config?.rules?.count == 3, "Rules", "Should parse 3 rules")
    }

    func testEdgeCaseSpecialChars() {
        print("\n--- Test: Special Chars ---")
        let yaml = """
proxies:
  - {name: "Node:With:Colon", type: http, server: "server.com", port: 80}
  - name: "Node With Emoji 🚀"
    type: trojan
    server: sub.domain.com
    port: 443
    password: 'pass'
"""
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: .clash)
        assert(config?.nodes.first?.name == "Node:With:Colon", "ColonInName", "Should handle colons in quoted inline name")
    }
    
    func testVMessIDvsUUID() {
        print("\n--- Test: VMess ID vs UUID ---")
        let yaml = """
proxies:
  - name: "Node ID"
    type: vmess
    server: 1.1.1.1
    port: 443
    id: "id-val"
  - name: "Node UUID"
    type: vmess
    server: 2.2.2.2
    port: 443
    uuid: "uuid-val"
"""
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: .clash)
        assert(config?.nodes.first?.password == "id-val", "IDMapping", "Should map 'id' to password for VMess")
        assert(config?.nodes.last?.password == "uuid-val", "UUIDMapping", "Should map 'uuid' to password for VMess")
    }

    func testVMessJSONNumericalPort() {
        print("\n--- Test: VMess JSON with Numerical Port ---")
        let json = """
        {"v":"2","ps":"NumPort","add":"1.1.1.1","port":443,"id":"uuid","net":"tcp"}
        """
        let b64 = Data(json.utf8).base64EncodedString()
        let link = "vmess://\\(b64)"
        let config = SubscriptionParser.shared.parse(from: link.data(using: .utf8)!, format: .json)
        assert(config?.nodes.first?.serverPort == 443, "NumericalPort", "Should handle numerical port in VMess JSON")
    }
}

Tester().runTests()
