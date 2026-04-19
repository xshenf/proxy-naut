import XCTest

final class DataStructureTests: XCTestCase {
    
    func testProxyNodeCreation() {
        let node = ProxyNode(
            type: .vmess,
            serverAddress: "test.server.com",
            serverPort: 443
        )
        
        XCTAssertEqual(node.serverAddress, "test.server.com")
        XCTAssertEqual(node.serverPort, 443)
        XCTAssertEqual(node.type, .vmess)
        XCTAssertFalse(node.selected)
        XCTAssertEqual(node.latency, -1)
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
        XCTAssertEqual(subscription.nodes.count, 0)
    }
    
    func testAppConfigurationCreation() {
        var config = AppConfiguration()
        config.selectedProtocol = .http
        config.listenPort = 1080
        
        XCTAssertEqual(config.selectedProtocol, .http)
        XCTAssertEqual(config.listenPort, 1080)
    }
    
    func testVMessConfigCreation() {
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
        XCTAssertEqual(vmessConfig.network, "tcp")
    }
    
    func testProxyProtocolCount() {
        let protocols = ProxyProtocol.allCases
        XCTAssertEqual(protocols.count, 9)
    }
    
    func testHTTPProxyConfigCreation() {
        let config = HTTPProxyConfig(
            listenPort: 1080,
            enableAuthentication: true,
            username: "user",
            password: "pass"
        )
        
        XCTAssertEqual(config.listenPort, 1080)
        XCTAssertTrue(config.enableAuthentication)
        XCTAssertEqual(config.username, "user")
        XCTAssertEqual(config.password, "pass")
    }
    
    func testShadowsocksConfigCreation() {
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
    
    func testTrojanConfigCreation() {
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
    
    func testSOCKS5ConfigCreation() {
        let config = SOCKS5Config(
            listenPort: 1080,
            enableAuthentication: true,
            username: "user",
            password: "pass"
        )
        
        XCTAssertEqual(config.listenPort, 1080)
        XCTAssertTrue(config.enableAuthentication)
    }
}

final class ParsingTests: XCTestCase {
    
    func testBase64Encoding() {
        let testString = "Hello World"
        let data = testString.data(using: .utf8)!
        let base64 = data.base64EncodedString()
        
        XCTAssertEqual(base64, "SGVsbG8gV29ybGQ=")
    }
    
    func testBase64Decoding() {
        let base64 = "SGVsbG8gV29ybGQ="
        let data = Data(base64Encoded: base64)!
        let decoded = String(data: data, encoding: .utf8)
        
        XCTAssertEqual(decoded, "Hello World")
    }
    
    func testVMessJSONDecoding() {
        // This is a typical VMess JSON (without the base64 wrapper)
        let vmessJSON = """
        {
            "v": "2",
            "ps": "Test Node",
            "add": "1.2.3.4",
            "port": "443",
            "id": "12345678-1234-1234-1234-123456789012",
            "aid": "0",
            "net": "tcp",
            "type": "none",
            "tls": "tls"
        }
        """
        
        let data = vmessJSON.data(using: .utf8)!
        
        struct VMessJSON: Codable {
            let v: String?
            let ps: String?
            let add: String?
            let port: String?
            let id: String?
            let aid: String?
            let net: String?
            let type: String?
            let tls: String?
        }
        
        let decoded = try? JSONDecoder().decode(VMessJSON.self, from: data)
        
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.ps, "Test Node")
        XCTAssertEqual(decoded?.add, "1.2.3.4")
        XCTAssertEqual(decoded?.tls, "tls")
    }
    
    func testUUIDValidation() {
        let validUUID = "12345678-1234-1234-1234-123456789012"
        let uuid = UUID(uuidString: validUUID)
        
        XCTAssertNotNil(uuid)
        
        let invalidUUID = "not-a-uuid"
        let invalid = UUID(uuidString: invalidUUID)
        
        XCTAssertNil(invalid)
    }
}

final class URLParsingTests: XCTestCase {
    
    func testURLWithCredentials() {
        // Test parsing ss://user:pass@host:port
        let urlString = "ss://chacha20:password@example.com:8388"
        let url = URL(string: urlString)
        
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "example.com")
        XCTAssertEqual(url?.port, 8388)
        XCTAssertEqual(url?.user, "chacha20")
        XCTAssertEqual(url?.password, "password")
    }
    
    func testTrojanURLParsing() {
        // Test trojan://password@host:port?sni=xxx
        let urlString = "trojan://password@example.com:443?sni=example.com"
        let url = URL(string: urlString)
        
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "example.com")
        XCTAssertEqual(url?.port, 443)
        XCTAssertEqual(url?.user, "password")
    }
    
    func testQueryParameterParsing() {
        let urlString = "trojan://pass@example.com:443?sni=example.com&path=/path"
        let url = URL(string: urlString)
        
        XCTAssertNotNil(url)
        
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let sni = components?.queryItems?.first(where: { $0.name == "sni" })?.value
        let path = components?.queryItems?.first(where: { $0.name == "path" })?.value
        
        XCTAssertEqual(sni, "example.com")
        XCTAssertEqual(path, "/path")
    }
}