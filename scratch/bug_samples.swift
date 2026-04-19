import Foundation

// These are cases where the current parser might fail
class BugTester {
    func runBugTests() {
        testNestedMappingInInline()
        testExtraWhitespaceInList()
        testURLSafeBase64()
    }

    func assert(_ condition: Bool, _ label: String, _ message: String) {
        if condition {
            print("\u{2705} [\(label)] \(message)")
        } else {
            print("\u{274C} [\(label)] FAILED: \(message)")
        }
    }

    func testNestedMappingInInline() {
        print("\n--- Test: Nested Mapping in Inline ---")
        // Current parseClashDict doesn't remove quotes from keys/values properly or handle nested colons well
        let yaml = "proxies:\n  - {name: \"Node\", ws-opts: {path: \"/\", headers: {Host: \"bing.com\"}}, type: vmess, server: 1.1.1.1, port: 443, uuid: u}"
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: .clash)
        // Check if Host was parsed correctly as a property if we ever support it, 
        // but for now just ensure it doesn't break the whole node.
        assert(config?.nodes.count == 1, "Nested", "Should parse node despite nested dicts in inline format")
    }

    func testExtraWhitespaceInList() {
        print("\n--- Test: Extra Whitespace in List ---")
        let yaml = "proxies:\n  -    name: Node1\n       type: ss\n       server: s1\n       port: 80\n"
        let config = SubscriptionParser.shared.parse(from: yaml.data(using: .utf8)!, format: .clash)
        assert(config?.nodes.count == 1, "Whitespace", "Should handle multiple spaces after dash")
    }

    func testURLSafeBase64() {
        print("\n--- Test: URL-Safe Base64 VMess ---")
        // Base64 with - and _ instead of + and /
        let json = "{\"v\":\"2\",\"ps\":\"Safe\",\"add\":\"1.1.1.1\",\"port\":443,\"id\":\"uuid\",\"net\":\"tcp\"}"
        let standardB64 = Data(json.utf8).base64EncodedString()
        let urlSafeB64 = standardB64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let link = "vmess://\(urlSafeB64)"
        
        let config = SubscriptionParser.shared.parse(from: link.data(using: .utf8)!, format: .json)
        assert(config?.nodes.count == 1, "URLSafe", "Should handle URL-safe base64 in VMess links")
    }
}

BugTester().runBugTests()
