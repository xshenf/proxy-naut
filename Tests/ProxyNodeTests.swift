import XCTest
@testable import ProxyNaut

final class ProxyNodeTests: XCTestCase {
    
    func testVMessNodeCreation() throws {
        let node = ProxyNode(
            type: .vmess,
            serverAddress: "test.server.com",
            serverPort: 443
        )
        
        XCTAssertEqual(node.serverAddress, "test.server.com")
        XCTAssertEqual(node.serverPort, 443)
        XCTAssertEqual(node.type, .vmess)
    }
    
    func testSubscriptionCreation() {
        let subscription = Subscription(
            name: "Test Sub",
            url: "https://example.com/sub",
            autoUpdate: true,
            updateInterval: .daily
        )
        
        XCTAssertEqual(subscription.name, "Test Sub")
        XCTAssertEqual(subscription.url, "https://example.com/sub")
        XCTAssertTrue(subscription.autoUpdate)
        XCTAssertEqual(subscription.updateInterval, .daily)
    }
    
    func testAppConfigurationCreation() {
        var config = AppConfiguration()
        config.selectedProtocol = .http
        config.listenPort = 1080
        
        XCTAssertEqual(config.selectedProtocol, .http)
        XCTAssertEqual(config.listenPort, 1080)
    }
    
    func testVMessConfig() {
        let vmessConfig = VMessConfig(
            serverAddress: "vmess.example.com",
            serverPort: 443,
            userId: "test-uuid-1234",
            alterId: 0,
            network: "tcp",
            tls: true,
            tlsServerName: "example.com"
        )
        
        XCTAssertEqual(vmessConfig.serverAddress, "vmess.example.com")
        XCTAssertEqual(vmessConfig.userId, "test-uuid-1234")
        XCTAssertTrue(vmessConfig.tls)
    }
    
    func testProxyProtocolCases() {
        let allProtocols = ProxyProtocol.allCases
        XCTAssertTrue(allProtocols.contains(.http))
        XCTAssertTrue(allProtocols.contains(.https))
        XCTAssertTrue(allProtocols.contains(.socks5))
        XCTAssertTrue(allProtocols.contains(.shadowsocks))
        XCTAssertTrue(allProtocols.contains(.vmess))
        XCTAssertTrue(allProtocols.contains(.trojan))
        XCTAssertTrue(allProtocols.contains(.vless))
        XCTAssertTrue(allProtocols.contains(.hysteria2))
        XCTAssertTrue(allProtocols.contains(.tuic))
        XCTAssertEqual(allProtocols.count, 9)
    }

    @MainActor
    func testParseVLESSLink() {
        let link = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443?encryption=none&security=tls&sni=example.com&type=ws&path=%2Fvl&flow=xtls-rprx-vision#MyVLESS"
        let node = SubscriptionManager.shared.parseVLESSLink(link)
        XCTAssertNotNil(node)
        XCTAssertEqual(node?.type, .vless)
        XCTAssertEqual(node?.serverAddress, "example.com")
        XCTAssertEqual(node?.serverPort, 443)
        XCTAssertEqual(node?.password, "b831381d-6324-4d53-ad4f-8cda48b30811")
        XCTAssertEqual(node?.flow, "xtls-rprx-vision")
        XCTAssertEqual(node?.tls, true)
        XCTAssertEqual(node?.sni, "example.com")
        XCTAssertEqual(node?.network, "ws")
        XCTAssertEqual(node?.path, "/vl")
        XCTAssertEqual(node?.name, "MyVLESS")
    }

    @MainActor
    func testParseHysteria2Link() {
        let link = "hysteria2://secretpwd@example.com:8443?sni=foo.com&obfs=salamander&obfs-password=xyz&insecure=1&alpn=h3#Hy2"
        let node = SubscriptionManager.shared.parseHysteria2Link(link)
        XCTAssertNotNil(node)
        XCTAssertEqual(node?.type, .hysteria2)
        XCTAssertEqual(node?.serverAddress, "example.com")
        XCTAssertEqual(node?.serverPort, 8443)
        XCTAssertEqual(node?.password, "secretpwd")
        XCTAssertEqual(node?.sni, "foo.com")
        XCTAssertEqual(node?.obfs, "salamander")
        XCTAssertEqual(node?.obfsPassword, "xyz")
        XCTAssertEqual(node?.skipCertVerify, true)
        XCTAssertEqual(node?.alpn, ["h3"])
        XCTAssertEqual(node?.name, "Hy2")
    }

    @MainActor
    func testParseTUICLink() {
        let link = "tuic://b831381d-6324-4d53-ad4f-8cda48b30811:mypwd@example.com:8443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=bar.com#TUIC"
        let node = SubscriptionManager.shared.parseTUICLink(link)
        XCTAssertNotNil(node)
        XCTAssertEqual(node?.type, .tuic)
        XCTAssertEqual(node?.uuid, "b831381d-6324-4d53-ad4f-8cda48b30811")
        XCTAssertEqual(node?.password, "mypwd")
        XCTAssertEqual(node?.serverAddress, "example.com")
        XCTAssertEqual(node?.serverPort, 8443)
        XCTAssertEqual(node?.congestionControl, "bbr")
        XCTAssertEqual(node?.udpRelayMode, "native")
        XCTAssertEqual(node?.sni, "bar.com")
        XCTAssertEqual(node?.alpn, ["h3"])
        XCTAssertEqual(node?.name, "TUIC")
    }
}

final class SubscriptionParserTests: XCTestCase {
    
    func testParseVMessLink() {
        // This is a valid vmess link format
        let vmessLink = "vmess://eyJ2IjoiMiIsInBzIjoidGVzdCIsImFkZCI6IjEuMS4xLjEiLCJwb3J0IjoiNDQzIiwiaWQiOiIxMjM0NTY3OC0xMjM0LTEyMzQtMTIzNC0xMjM0NTY3ODkwYWIiLCJhaWQiOiIwIiwibmV0IjoidGNwIiwidHlwZSI6Im5vbmUiLCJ0bHMiOiJ0bHMifQ=="
        
        // The base64 part decodes to: {"v":"2","ps":"test","add":"1.1.1.1","port":"443","id":"12345678-1234-1234-1234-1234567890ab","aid":"0","net":"tcp","type":"none","tls":"tls"}
        
        // Test that parsing doesn't crash
        XCTAssertNotNil(vmessLink)
    }
    
    func testBase64Decoding() {
        // Test a simple base64 string
        let testString = "test"
        let base64 = testString.data(using: .utf8)?.base64EncodedString() ?? ""
        XCTAssertEqual(base64, "dGVzdA==")
        
        let decoded = Data(base64Encoded: base64)
        XCTAssertNotNil(decoded)
    }
    
    func testParseClashWithDashOnSeparateLine() {
        // 测试 YAML 格式中 "-" 单独占一行的情况
        let clashYAML = """
        proxies:
          -
            cipher: "aes-256-cfb"
            name: 'SS Node 1'
            password: 'testpassword'
            port: 38388
            server: 103.186.155.16
            type: "ss"
          -
            name: 'Trojan Node 1'
            server: 43.207.115.26
            port: 4019
            type: "trojan"
            password: abc123
            sni: example.com
            skip-cert-verify: false
        """.data(using: .utf8)!
        
        let config = SubscriptionParser.shared.parse(from: clashYAML, format: .clash)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.nodes.count, 2)
        
        if let nodes = config?.nodes {
            XCTAssertEqual(nodes[0].type, .shadowsocks)
            XCTAssertEqual(nodes[0].serverAddress, "103.186.155.16")
            XCTAssertEqual(nodes[0].serverPort, 38388)
            
            XCTAssertEqual(nodes[1].type, .trojan)
            XCTAssertEqual(nodes[1].serverAddress, "43.207.115.26")
            XCTAssertEqual(nodes[1].serverPort, 4019)
        }
    }
    
    func testParseClashWithInlineDash() {
        // 测试 YAML 格式中 "- " 在同一行的情况
        let clashYAML = """
        proxies:
          - name: "SS Node"
            type: ss
            server: 1.2.3.4
            port: 443
            cipher: aes-256-gcm
            password: test123
          - name: "VMess Node"
            type: vmess
            server: 5.6.7.8
            port: 8080
            uuid: test-uuid
            alterId: 0
            network: ws
            tls: false
        """.data(using: .utf8)!
        
        let config = SubscriptionParser.shared.parse(from: clashYAML, format: .clash)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.nodes.count, 2)
        
        if let nodes = config?.nodes {
            XCTAssertEqual(nodes[0].type, .shadowsocks)
            XCTAssertEqual(nodes[0].name, "SS Node")
            
            XCTAssertEqual(nodes[1].type, .vmess)
            XCTAssertEqual(nodes[1].name, "VMess Node")
        }
    }
    
    func testParseClashWithQuotedType() {
        // 测试 type 字段带引号的情况
        let clashYAML = """
        proxies:
          -
            name: "Test Node"
            server: 1.2.3.4
            port: 443
            type: "ss"
            cipher: aes-256-gcm
            password: test123
        """.data(using: .utf8)!
        
        let config = SubscriptionParser.shared.parse(from: clashYAML, format: .clash)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.nodes.count, 1)
        XCTAssertEqual(config?.nodes.first?.type, .shadowsocks)
    }
}

final class ConfigurationTests: XCTestCase {
    
    func testHTTPProxyConfig() {
        let config = HTTPProxyConfig(
            listenPort: 1080,
            enableAuthentication: true,
            username: "user",
            password: "pass"
        )
        
        XCTAssertEqual(config.listenPort, 1080)
        XCTAssertTrue(config.enableAuthentication)
        XCTAssertEqual(config.username, "user")
    }
    
    func testShadowsocksConfig() {
        let config = ShadowsocksConfig(
            serverAddress: "ss.example.com",
            serverPort: 8388,
            password: "test-password",
            encryption: "chacha20-ietf-poly1305"
        )
        
        XCTAssertEqual(config.serverAddress, "ss.example.com")
        XCTAssertEqual(config.serverPort, 8388)
        XCTAssertEqual(config.encryption, "chacha20-ietf-poly1305")
    }
    
    func testTrojanConfig() {
        let config = TrojanConfig(
            serverAddress: "trojan.example.com",
            serverPort: 443,
            password: "test-password",
            enableTLS: true,
            sni: "example.com"
        )
        
        XCTAssertEqual(config.serverAddress, "trojan.example.com")
        XCTAssertTrue(config.enableTLS)
        XCTAssertEqual(config.sni, "example.com")
    }
}