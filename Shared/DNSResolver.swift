import Foundation
import Network

class DNSResolver {
    static let shared = DNSResolver()
    
    private var useDNSoverHTTPS: Bool = false
    private var useDNSoverTLS: Bool = false
    private var dohURL: String = "https://dns.google/dns-query"
    private var dotHost: String = "dns.google"
    private var servers: [String] = ["8.8.8.8", "1.1.1.1"]
    private var fakeIPEnabled: Bool = true
    private var fakeIPRange: String = "198.18.0.0/15"
    
    private var fakeIPPool: [String: String] = [:]
    private var reverseFakeIP: [String: String] = [:]
    private let fakeIPCIDR: CIDRRange?
    
    private init() {
        fakeIPCIDR = CIDRRange.parse(fakeIPRange)
    }
    
    func configure(config: DNSConfig) {
        servers = config.servers
        useDNSoverHTTPS = config.enableDNSoverHTTPS
        useDNSoverTLS = config.enableDNSoverTLS
        fakeIPEnabled = config.fakeIP
        
        if let url = config.dohURL {
            dohURL = url
        }
        if let host = config.dotHost {
            dotHost = host
        }
    }
    
    func resolve(domain: String) async -> String? {
        if fakeIPEnabled, let fakeIP = getFakeIP(for: domain) {
            return fakeIP
        }
        
        if useDNSoverHTTPS {
            return await resolveDoH(domain: domain)
        } else if useDNSoverTLS {
            return await resolveDoT(domain: domain)
        } else {
            return await resolveUDP(domain: domain)
        }
    }
    
    private func resolveUDP(domain: String) async -> String? {
        let host = NWEndpoint.Host(servers.first ?? "8.8.8.8")
        let port = NWEndpoint.Port(rawValue: 53)!
        
        let connection = NWConnection(host: host, port: port, using: .udp)
        
        return await withCheckedContinuation { continuation in
            var didResume = false
            
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    let query = self.buildDNSQuery(for: domain)
                    connection.send(content: query, completion: .contentProcessed { _ in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, error in
                            if let data = data, let ip = self.parseDNSResponse(data) {
                                if !didResume {
                                    didResume = true
                                    continuation.resume(returning: ip)
                                }
                            } else {
                                if !didResume {
                                    didResume = true
                                    continuation.resume(returning: nil)
                                }
                            }
                            connection.cancel()
                        }
                    })
                }
            }
            
            connection.start(queue: .global(qos: .userInitiated))
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if !didResume {
                    didResume = true
                    continuation.resume(returning: nil)
                    connection.cancel()
                }
            }
        }
    }
    
    private func resolveDoH(domain: String) async -> String? {
        guard let url = URL(string: "\(dohURL)?name=\(domain)&type=A") else { return nil }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return parseDNSResponse(data)
        } catch {
            return nil
        }
    }
    
    private func resolveDoT(domain: String) async -> String? {
        return nil
    }
    
    private func buildDNSQuery(for domain: String) -> Data {
        var query = Data()
        
        let transactionID: UInt16 = UInt16.random(in: 0...65535)
        query.append(contentsOf: withUnsafeBytes(of: transactionID.bigEndian) { Array($0) })
        
        query.append(contentsOf: [0x01, 0x00])  // Flags: standard query, recursion desired
        
        query.append(contentsOf: [0x00, 0x01])  // QDCOUNT: 1 question
        
        query.append(contentsOf: [0x00, 0x00])  // ANCOUNT: 0 answers (这是查询包，不能是1)
        
        query.append(contentsOf: [0x00, 0x00])  // NSCOUNT: 0
        query.append(contentsOf: [0x00, 0x00])  // ARCOUNT: 0
        
        let labels = domain.split(separator: ".")
        for label in labels {
            query.append(UInt8(label.count))
            query.append(contentsOf: label.utf8)
        }
        query.append(0x00)
        
        query.append(contentsOf: [0x00, 0x01])
        
        query.append(contentsOf: [0x00, 0x01])
        
        return query
    }
    
    private func parseDNSResponse(_ data: Data) -> String? {
        guard data.count > 12 else { return nil }
        
        // ANCOUNT at bytes 6-7
        let answerCount = Int(UInt16(data[6]) << 8 | UInt16(data[7]))
        guard answerCount > 0 else { return nil }
        
        // 跳过 Header (12 bytes)
        var offset = 12
        
        // 跳过 Question Section (QDCOUNT 个问题)
        let qdcount = Int(UInt16(data[4]) << 8 | UInt16(data[5]))
        for _ in 0..<qdcount {
            // 跳过 QNAME
            offset = skipDNSName(data: data, offset: offset)
            if offset < 0 { return nil }
            // 跳过 QTYPE (2) + QCLASS (2)
            offset += 4
            if offset > data.count { return nil }
        }
        
        // 解析 Answer Section
        for _ in 0..<answerCount {
            guard offset < data.count else { return nil }
            
            // 跳过 NAME（可能是压缩指针）
            offset = skipDNSName(data: data, offset: offset)
            if offset < 0 { return nil }
            
            // TYPE (2) + CLASS (2) + TTL (4) + RDLENGTH (2) = 10 bytes
            guard offset + 10 <= data.count else { return nil }
            
            let recordType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            offset += 8 // 跳过 TYPE + CLASS + TTL
            
            let rdlength = Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
            offset += 2
            
            // A 记录 (type=1), RDLENGTH=4
            if recordType == 1 && rdlength == 4 && offset + 4 <= data.count {
                let ip = "\(data[offset]).\(data[offset+1]).\(data[offset+2]).\(data[offset+3])"
                return ip
            }
            
            // 跳过这个记录的 RDATA
            offset += rdlength
        }
        
        return nil
    }
    
    /// 跳过 DNS 名称（支持压缩指针），返回下一个字段的偏移量，失败返回 -1
    private func skipDNSName(data: Data, offset: Int) -> Int {
        var pos = offset
        guard pos < data.count else { return -1 }
        
        // 压缩指针：高两位为 11
        if data[pos] & 0xC0 == 0xC0 {
            return pos + 2
        }
        
        // 非压缩：label 逐段跳过
        while pos < data.count && data[pos] != 0 {
            if data[pos] & 0xC0 == 0xC0 {
                // 遇到压缩指针
                return pos + 2
            }
            pos += Int(data[pos]) + 1
        }
        
        return pos + 1  // 跳过终止的 0x00
    }
    
    private func getFakeIP(for domain: String) -> String? {
        if let existing = fakeIPPool[domain] {
            return existing
        }
        
        guard let cidr = fakeIPCIDR else { return nil }
        
        let fakeIP = generateFakeIP()
        fakeIPPool[domain] = fakeIP
        reverseFakeIP[fakeIP] = domain
        
        return fakeIP
    }
    
    private func generateFakeIP() -> String {
        let baseIP = fakeIPRange.split(separator: "/").first ?? "198.18.0.0"
        let parts = baseIP.split(separator: ".").compactMap { Int($0) }
        
        let hostPart = Int.random(in: 1...254)
        return "\(parts[0]).\(parts[1]).\(hostPart).\(Int.random(in: 1...254))"
    }
    
    func resolveFakeIP(_ ip: String) -> String? {
        return reverseFakeIP[ip]
    }
}