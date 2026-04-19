import Foundation

class RuleEngine {
    static let shared = RuleEngine()
    
    private var domainRules: [String: ProxyRule.RuleAction] = [:]
    private var domainSuffixRules: [String: ProxyRule.RuleAction] = [:]
    private var domainKeywordRules: [(String, ProxyRule.RuleAction)] = []
    private var ipCIDRRules: [(CIDRRange, ProxyRule.RuleAction)] = []
    private var geoipRules: [String: ProxyRule.RuleAction] = [:]
    private var portRules: [(ClosedRange<UInt16>, ProxyRule.RuleAction)] = []
    private var defaultAction: ProxyRule.RuleAction = .proxy
    
    private init() {}
    
    func loadRules(_ rules: [ProxyRule]) {
        domainRules.removeAll()
        domainSuffixRules.removeAll()
        domainKeywordRules.removeAll()
        ipCIDRRules.removeAll()
        geoipRules.removeAll()
        portRules.removeAll()
        
        for rule in rules {
            switch rule.type {
            case .domain:
                domainRules[rule.pattern.lowercased()] = rule.action
            case .domainSuffix:
                domainSuffixRules[rule.pattern.lowercased()] = rule.action
            case .domainKeyword:
                domainKeywordRules.append((rule.pattern.lowercased(), rule.action))
            case .ipCIDR:
                if let cidr = CIDRRange.parse(rule.pattern) {
                    ipCIDRRules.append((cidr, rule.action))
                }
            case .geoip:
                geoipRules[rule.pattern.uppercased()] = rule.action
            case .geosite:
                // Swift 层目前不实现全量 Geosite 匹配，仅依赖内核过滤
                break
            case .port:
                if let range = parsePortRange(rule.pattern) {
                    portRules.append((range, rule.action))
                }
            case .final:
                defaultAction = rule.action
            }
        }
        
        ipCIDRRules.sort { $0.0.prefixLength > $1.0.prefixLength }
    }
    
    func match(domain: String? = nil, ip: String? = nil, port: UInt16? = nil) -> ProxyRule.RuleAction {
        let lowercasedDomain = domain?.lowercased()
        
        if let domain = lowercasedDomain {
            if let action = domainRules[domain] {
                return action
            }
            
            for (suffix, action) in domainSuffixRules {
                // 域名后缀匹配需要检查段落边界，避免 "abcn.com" 误匹配 "cn"
                if domain == suffix || domain.hasSuffix(".\(suffix)") {
                    return action
                }
            }
            
            for (keyword, action) in domainKeywordRules {
                if domain.contains(keyword) {
                    return action
                }
            }
        }
        
        if let ip = ip {
            for (cidr, action) in ipCIDRRules {
                if cidr.contains(ip) {
                    return action
                }
            }
        }
        
        if let geoipCode = resolveGeoIP(ip ?? "") {
            if let action = geoipRules[geoipCode] {
                return action
            }
        }
        
        if let port = port {
            for (range, action) in portRules {
                if range.contains(port) {
                    return action
                }
            }
        }
        
        return defaultAction
    }
    
    private func resolveGeoIP(_ ip: String) -> String? {
        guard !ip.isEmpty else { return nil }
        return GeoIPDatabase.shared.lookup(ip)
    }
    
    private func parsePortRange(_ pattern: String) -> ClosedRange<UInt16>? {
        if pattern.contains("-") {
            let parts = pattern.split(separator: "-")
            if parts.count == 2,
               let start = UInt16(parts[0]),
               let end = UInt16(parts[1]) {
                return start...end
            }
        } else if let port = UInt16(pattern) {
            return port...port
        }
        return nil
    }
}

struct CIDRRange {
    let networkAddress: String
    let prefixLength: Int
    let mask: UInt32
    
    static func parse(_ cidr: String) -> CIDRRange? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 0 && prefix <= 32 else {
            return nil
        }
        
        let networkAddress = String(parts[0])
        let mask: UInt32 = prefix == 0 ? 0 : ~((1 << (32 - prefix)) - 1)
        
        return CIDRRange(networkAddress: networkAddress, prefixLength: prefix, mask: mask)
    }
    
    func contains(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4,
              let a = UInt32(parts[0]),
              let b = UInt32(parts[1]),
              let c = UInt32(parts[2]),
              let d = UInt32(parts[3]) else {
            return false
        }
        
        let ipValue = (a << 24) | (b << 16) | (c << 8) | d
        
        let networkParts = networkAddress.split(separator: ".")
        guard networkParts.count == 4,
              let na = UInt32(networkParts[0]),
              let nb = UInt32(networkParts[1]),
              let nc = UInt32(networkParts[2]),
              let nd = UInt32(networkParts[3]) else {
            return false
        }
        
        let networkValue = (na << 24) | (nb << 16) | (nc << 8) | nd
        
        return (ipValue & mask) == (networkValue & mask)
    }
}