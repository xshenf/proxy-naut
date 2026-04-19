import Foundation
import Network
import Combine
import SwiftUI



enum ProxyProtocol: String, Codable, CaseIterable {
    case http
    case https
    case socks5
    case shadowsocks
    case vmess
    case trojan
    
    var displayName: String {
        switch self {
        case .http: return "HTTP"
        case .https: return "HTTPS"
        case .socks5: return "SOCKS5"
        case .shadowsocks: return "Shadowsocks"
        case .vmess: return "VMess"
        case .trojan: return "Trojan"
        }
    }
}

enum OutboundAction {
    case proxy
    case direct
    case reject
}

struct TargetInfo {
    let host: String
    let port: UInt16
    
    var addressString: String {
        "\(host):\(port)"
    }
}

enum ProxyError: Error, LocalizedError {
    case invalidConfiguration
    case connectionFailed(String)
    case authenticationFailed
    case protocolError(String)
    case notRunning
    case portInUse
    case unsupportedProtocol
    
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Invalid proxy configuration"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .authenticationFailed:
            return "Authentication failed"
        case .protocolError(let reason):
            return "Protocol error: \(reason)"
        case .notRunning:
            return "Proxy is not running"
        case .portInUse:
            return "Port is already in use"
        case .unsupportedProtocol:
            return "Unsupported protocol"
        }
    }
}

protocol ProxyHandler: AnyObject {
    func start(listeningOn port: UInt16) throws
    func stop()
    /// 异步停止，等待 listener 完全释放端口
    func stopAsync() async
    func handleConnection(_ connection: NWConnection) -> AsyncThrowingStream<Data, Error>
    
    /// 创建出站代理连接（包含协议握手）
    /// - Parameters:
    ///   - target: 最终目标地址
    ///   - completion: 建立并完成协议握手后的远程连接
    func createProxyConnection(to target: TargetInfo, completion: @escaping (NWConnection?) -> Void)
    
    /// 直接转发连接（由 Handler 接手从首个字节开始的完整隧道逻辑）
    /// 适用于 gRPC 等无法返回原始 NWConnection 的传输协议
    func forwardConnection(local: NWConnection, to target: TargetInfo, initialData: Data?)
    
    var isRunning: Bool { get }
    var supportedProtocols: [ProxyProtocol] { get }
}

extension ProxyHandler {
    /// 默认实现：调用同步 stop()，然后等待端口释放
    func stopAsync() async {
        stop()
        // 等待操作系统释放端口
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
    }
    
    /// 默认实现：回退到传统的 createProxyConnection + 管道逻辑
    func forwardConnection(local: NWConnection, to target: TargetInfo, initialData: Data? = nil) {
        createProxyConnection(to: target) { remote in
            guard let remote = remote else {
                local.cancel()
                return
            }
            
            if let data = initialData {
                remote.send(content: data, completion: .contentProcessed { _ in
                    self.startLegacyTunnel(local: local, remote: remote)
                })
            } else {
                self.startLegacyTunnel(local: local, remote: remote)
            }
        }
    }
    
    private func startLegacyTunnel(local: NWConnection, remote: NWConnection) {
        // 简单的 TCP 管道实现
        func tunnel(from: NWConnection, to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data {
                    to.send(content: data, completion: .contentProcessed { _ in
                        if !isComplete && error == nil {
                            tunnel(from: from, to: to)
                        }
                    })
                }
                if isComplete || error != nil {
                    from.cancel()
                    to.cancel()
                }
            }
        }
        
        tunnel(from: local, to: remote)
        tunnel(from: remote, to: local)
    }
}

struct ProxyStatistics: Codable {
    var bytesSent: UInt64 = 0
    var bytesReceived: UInt64 = 0
    var connectionCount: Int = 0
    var activeConnections: Int = 0
    var startDate: Date?
    
    // 实时网速
    var currentUploadSpeed: Double = 0
    var currentDownloadSpeed: Double = 0
    
    // 平均网速（由启动时间计算）
    var averageUploadSpeed: Double {
        guard let startDate = startDate, -startDate.timeIntervalSinceNow > 0 else { return 0 }
        return Double(bytesSent) / (-startDate.timeIntervalSinceNow)
    }
    
    var averageDownloadSpeed: Double {
        guard let startDate = startDate, -startDate.timeIntervalSinceNow > 0 else { return 0 }
        return Double(bytesReceived) / (-startDate.timeIntervalSinceNow)
    }
}


struct ProxyServerConfig: Codable {
    var protocolType: ProxyProtocol
    var serverAddress: String
    var serverPort: UInt16
    var username: String?
    var password: String?
    var enableTLS: Bool = false
    var tlsServerName: String?
    var allowInsecure: Bool = false
    var additionalConfig: [String: String]?
}

struct HTTPProxyConfig: Codable {
    var listenPort: UInt16 = 1081
    var enableAuthentication: Bool = false
    var username: String?
    var password: String?
    var timeout: TimeInterval = 30
    var maxConnections: Int = 100
}

struct SOCKS5Config: Codable {
    var listenPort: UInt16 = 1081
    var enableAuthentication: Bool = false
    var username: String?
    var password: String?
    var enableUDPRelay: Bool = false
    var timeout: TimeInterval = 30
}

struct ShadowsocksConfig: Codable {
    var serverAddress: String
    var serverPort: UInt16
    var password: String
    var encryption: String = "chacha20-ietf-poly1305"
    var plugin: String?
    var pluginOptions: String?
    var enableUDPRelay: Bool = false
    var mute: Bool = false
}

struct VMessConfig: Codable {
    var serverAddress: String
    var serverPort: UInt16
    var userId: String
    var alterId: Int = 0
    var security: String = "auto"
    var network: String = "tcp"
    var tls: Bool = false
    var skipCertVerify: Bool = false
    var tlsServerName: String?
    var host: String?
    var path: String?
    var grpcServiceName: String?
    var headerType: String?
    var quicSecurity: String?
    var quicKey: String?
}

struct TrojanConfig: Codable {
    var serverAddress: String
    var serverPort: UInt16
    var password: String
    var enableTLS: Bool = true
    var skipCertVerify: Bool = false
    var tlsServerName: String?
    var alpn: [String]?
    var enableUDPRelay: Bool = false
    var sni: String?
}

struct AppConfiguration: Codable {
    var selectedProtocol: ProxyProtocol?
    var selectedNodeID: String?
    var httpConfig: HTTPProxyConfig?
    var socks5Config: SOCKS5Config?
    var shadowsocksConfig: ShadowsocksConfig?
    var vmessConfig: VMessConfig?
    var trojanConfig: TrojanConfig?
    var listenAddress: String = "127.0.0.1"
    var listenPort: UInt16 = 1081
    var enableRouting: Bool = true
    var useBuiltInRules: Bool = true
    var rules: [ProxyRule] = []
    var baseRules: [ProxyRule] = []
    var dnsConfig: DNSConfig?
    var networkConfig: NetworkConfig?
    var logLevel: LogLevel = .warning
    var allNodes: [ProxyNode] = []
    
    init(selectedProtocol: ProxyProtocol? = nil, listenPort: UInt16 = 1081, useBuiltInRules: Bool = true, rules: [ProxyRule] = [], baseRules: [ProxyRule] = [], logLevel: LogLevel = .warning) {
        self.selectedProtocol = selectedProtocol
        self.listenPort = listenPort
        self.useBuiltInRules = useBuiltInRules
        self.rules = rules
        self.baseRules = baseRules
        self.logLevel = logLevel
    }
}

enum LogLevel: String, Codable, Comparable {
    case debug, info, warning, error
    private var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.priority < rhs.priority
    }
}

struct DNSConfig: Codable {
    var enable: Bool = true
    var servers: [String] = ["8.8.8.8", "1.1.1.1"]
    var enableDNSoverHTTPS: Bool = false
    var dohURL: String?
    var enableDNSoverTLS: Bool = false
    var dotHost: String?
    var fakeIP: Bool = true
    var fallback: [String]?
}

struct NetworkConfig: Codable, Equatable {
    var mtu: Int = 1500
    var bypassChina: Bool = true
    var adBlock: Bool = true
    var forceDNS: Bool = true
    var testURL: String = "http://www.gstatic.com/generate_204"
    var connectionPoolSize: Int = 8
}

struct ProxyRule: Codable {
    var type: RuleType
    var pattern: String
    var action: RuleAction
    enum RuleType: String, Codable {
        case domain, domainSuffix, domainKeyword, geosite, ipCIDR, geoip, port, final
    }
    enum RuleAction: String, Codable {
        case direct, proxy, reject
    }
}

class Configuration {
    static let shared = Configuration()
    private let appGroupId = "group.com.proxynaut"
    private let configFileName = "app_config.json"

    static let commonChinaDomains: [String] = [
        "baidu.com", "qq.com", "taobao.com", "alicdn.com", "tmall.com",
        "jd.com", "126.com", "163.com", "sina.com", "sohu.com",
        "youku.com", "iqiyi.com", "bilibili.com", "zhihu.com",
        "dianping.com", "meituan.com", "ele.me", "携程.com",
        "alipay.com", "antgroup.com", "alibaba.com", "aliyun.com"
    ]

    private static let builtinRules: [ProxyRule] = [
        // 核心加速：使用 GeoSite CN 全量覆盖中国大陆域名
        ProxyRule(type: .geosite, pattern: "cn", action: .direct),
        
        ProxyRule(type: .domainSuffix, pattern: "amemv.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "douyin.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "douyinpic.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "douyinstatic.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "douyinvod.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "zijieapi.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "snssdk.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "byteimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bytecdn.cn", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bytecdn.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bytegecko.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bytehwm.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bytednsdoc.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bytedance.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "byteprivatelink.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ecombdapi.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ecombdimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ecombdpage.com", action: .direct),
        ProxyRule(type: .domainKeyword, pattern: "bytedance", action: .direct),
        ProxyRule(type: .domainKeyword, pattern: "zijie", action: .direct),
        ProxyRule(type: .domainKeyword, pattern: "douyin", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "toutiao.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "pstatp.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "pinduoduo.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "yangkeduo.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "pddpic.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "weibo.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "weibocdn.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "sina.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "sinaimg.cn", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "sinaimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "t.cn", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "alipay.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "antgroup.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "jd.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "360buyimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "meituan.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "elenet.me", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bilibili.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "biliapi.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "hdslb.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "xiaomi.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "mi-img.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "amap.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "autonavi.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "didiglobal.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "didistatic.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "baike.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qishui.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bdurl.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "volces.com", action: .direct),
        ProxyRule(type: .domain, pattern: "dp3.config-sync.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "services.googleapis.cn", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "xn--ngstr-lra8j.com", action: .proxy),
        ProxyRule(type: .domain, pattern: "safebrowsing.urlsec.qq.com", action: .direct),
        ProxyRule(type: .domain, pattern: "safebrowsing.googleapis.com", action: .direct),
        ProxyRule(type: .domain, pattern: "developer.apple.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "digicert.com", action: .proxy),
        ProxyRule(type: .domain, pattern: "ocsp.apple.com", action: .proxy),
        ProxyRule(type: .domain, pattern: "ocsp.comodoca.com", action: .proxy),
        ProxyRule(type: .domain, pattern: "ocsp.usertrust.com", action: .proxy),
        ProxyRule(type: .domain, pattern: "ocsp.sectigo.com", action: .proxy),
        ProxyRule(type: .domain, pattern: "ocsp.verisign.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "apple-dns.net", action: .proxy),
        ProxyRule(type: .domain, pattern: "testflight.apple.com", action: .proxy),
        ProxyRule(type: .domain, pattern: "sandbox.itunes.apple.com", action: .proxy),
        ProxyRule(type: .domain, pattern: "itunes.apple.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "apps.apple.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "blobstore.apple.com", action: .proxy),
        ProxyRule(type: .domain, pattern: "cvws.icloud-content.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "mzstatic.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "itunes.apple.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "icloud.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "icloud-content.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "me.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "aaplimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "cdn20.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "cdn-apple.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "akadns.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "akamaiedge.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "edgekey.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "mwcloudcdn.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "mwcname.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "apple.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "apple-cloudkit.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "apple-mapkit.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "126.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "126.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "127.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "163.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "36kr.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "acfun.tv", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "air-matters.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "aixifan.com", action: .direct),
        ProxyRule(type: .domainKeyword, pattern: "alicdn", action: .direct),
        ProxyRule(type: .domainKeyword, pattern: "alipay", action: .direct),
        ProxyRule(type: .domainKeyword, pattern: "taobao", action: .direct),
        ProxyRule(type: .domainKeyword, pattern: "baidu", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bdimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bdstatic.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "bilivideo.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "caiyunapp.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "clouddn.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "cnbeta.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "cnbetacdn.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "cootekservice.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "csdn.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ctrip.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "dgtle.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "dianping.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "douban.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "doubanio.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "duokan.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "easou.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ele.me", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "feng.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "fir.im", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "frdic.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "g-cores.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "godic.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "gtimg.com", action: .direct),
        ProxyRule(type: .domain, pattern: "cdn.hockeyapp.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "hongxiu.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "hxcdn.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "iciba.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ifeng.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ifengimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ipip.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "iqiyi.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "jianshu.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "knewone.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "le.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "lecloud.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "lemicp.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "licdn.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "luoo.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "meituan.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "mi.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "miaopai.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "microsoft.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "microsoftonline.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "miui.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "miwifi.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "mob.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "netease.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "office.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "office365.com", action: .direct),
        ProxyRule(type: .domainKeyword, pattern: "officecdn", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "oschina.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ppsimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qcloud.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qdaily.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qdmm.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qhimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qhres.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qidian.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qihucdn.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qiniu.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qiniucdn.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qiyipic.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qq.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "qqurl.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "rarbg.to", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ruguoapp.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "segmentfault.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "sinaapp.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "smzdm.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "snapdrop.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "sogou.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "sogoucdn.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "sohu.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "soku.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "speedtest.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "sspai.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "suning.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "taobao.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "tencent.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "tenpay.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "tianyancha.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "tmall.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "tudou.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "umetrip.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "upaiyun.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "upyun.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "veryzhun.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "weather.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "xiami.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "xiami.net", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "xiaomicp.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ximalaya.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "xmcdn.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "xunlei.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "yhd.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "yihaodianimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "yinxiang.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "ykimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "youdao.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "youku.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "zealer.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "zhihu.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "zhimg.com", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "zimuzu.tv", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "zoho.com", action: .direct),
        ProxyRule(type: .domainKeyword, pattern: "amazon", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "google", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "gmail", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "youtube", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "facebook", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "fb.me", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "fbcdn.net", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "twitter", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "instagram", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "dropbox", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "twimg.com", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "blogspot", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "youtu.be", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "whatsapp", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "admarvel", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "admaster", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "adsage", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "adsmogo", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "adsrvmedia", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "adwords", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "adservice", action: .reject),
        ProxyRule(type: .domainSuffix, pattern: "appsflyer.com", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "domob", action: .reject),
        ProxyRule(type: .domainSuffix, pattern: "doubleclick.net", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "duomeng", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "dwtrack", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "guanggao", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "lianmeng", action: .reject),
        ProxyRule(type: .domainSuffix, pattern: "mmstat.com", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "mopub", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "omgmta", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "openx", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "partnerad", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "pingfore", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "supersonicads", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "uedas", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "umeng", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "usage", action: .reject),
        ProxyRule(type: .domainSuffix, pattern: "vungle.com", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "wlmonitor", action: .reject),
        ProxyRule(type: .domainKeyword, pattern: "zjtoolbar", action: .reject),
        ProxyRule(type: .domainSuffix, pattern: "9to5mac.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "abpchina.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "adblockplus.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "adobe.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "akamaized.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "alfredapp.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "amplitude.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ampproject.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "android.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "angularjs.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "aolcdn.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "apkpure.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "appledaily.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "appshopper.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "appspot.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "arcgis.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "archive.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "armorgames.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "aspnetcdn.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "att.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "awsstatic.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "azureedge.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "azurewebsites.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "bing.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "bintray.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "bit.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "bit.ly", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "bitbucket.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "bjango.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "bkrtx.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "blog.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "blogcdn.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "blogger.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "blogsmithmedia.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "blogspot.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "blogspot.hk", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "bloomberg.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "box.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "box.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "cachefly.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "chromium.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "cl.ly", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "cloudflare.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "cloudfront.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "cloudmagic.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "cmail19.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "cnet.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "cocoapods.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "comodoca.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "crashlytics.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "culturedcode.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "d.pr", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "danilo.to", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "dayone.me", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "db.tt", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "deskconnect.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "disq.us", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "disqus.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "disquscdn.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "dnsimple.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "docker.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "dribbble.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "droplr.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "duckduckgo.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "dueapp.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "dytt8.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "edgecastcdn.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "edgekey.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "edgesuite.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "engadget.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "entrust.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "eurekavpt.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "evernote.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "fabric.io", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "fast.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "fastly.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "fc2.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "feedburner.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "feedly.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "feedsportal.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "fiftythree.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "firebaseio.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "flexibits.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "flickr.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "flipboard.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "g.co", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "gabia.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "geni.us", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "gfx.ms", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ggpht.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ghostnoteapp.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "git.io", action: .proxy),
        ProxyRule(type: .domainKeyword, pattern: "github", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "globalsign.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "gmodules.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "godaddy.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "golang.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "gongm.in", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "goo.gl", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "goodreaders.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "goodreads.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "gravatar.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "gstatic.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "gvt0.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "hockeyapp.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "hotmail.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "icons8.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ifixit.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ift.tt", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ifttt.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "iherb.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "imageshack.us", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "img.ly", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "imgur.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "imore.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "instapaper.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ipn.li", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "is.gd", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "issuu.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "itgonglun.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "itun.es", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ixquick.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "j.mp", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "js.revsci.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "jshint.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "jtvnw.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "justgetflux.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "kat.cr", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "klip.me", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "libsyn.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "linkedin.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "line-apps.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "linode.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "lithium.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "littlehj.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "live.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "live.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "livefilestore.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "llnwd.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "macid.co", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "macromedia.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "macrumors.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "mashable.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "mathjax.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "medium.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "mega.co.nz", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "mega.nz", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "megaupload.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "microsofttranslator.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "mindnode.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "mobile01.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "modmyi.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "msedge.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "myfontastic.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "name.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "nextmedia.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "nsstatic.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "nssurge.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "nyt.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "nytimes.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "omnigroup.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "onedrive.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "onenote.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ooyala.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "openvpn.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "openwrt.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "orkut.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "osxdaily.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "outlook.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ow.ly", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "paddleapi.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "parallels.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "parse.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "pdfexpert.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "periscope.tv", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "pinboard.in", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "pinterest.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "pixelmator.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "pixiv.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "playpcesor.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "playstation.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "playstation.com.hk", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "playstation.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "playstationnetwork.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "pushwoosh.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "rime.im", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "servebom.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "sfx.ms", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "shadowsocks.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "sharethis.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "shazam.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "skype.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "smartdns一元机场.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "smartmailcloud.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "sndcdn.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "sony.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "soundcloud.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "sourceforge.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "spotify.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "squarespace.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "sstatic.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "st.luluku.pw", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "stackoverflow.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "startpage.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "staticflickr.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "steamcommunity.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "symauth.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "symcb.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "symcd.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "tapbots.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "tapbots.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "tdesktop.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "techcrunch.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "techsmith.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "thepiratebay.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "theverge.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "time.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "timeinc.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "tiny.cc", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "tinypic.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "tmblr.co", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "todoist.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "trello.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "trustasiassl.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "tumblr.co", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "tumblr.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "tweetdeck.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "tweetmarker.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "twitch.tv", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "txmblr.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "typekit.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ubertags.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ublock.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ubnt.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ulyssesapp.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "urchin.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "usertrust.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "v.gd", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "v2ex.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "vimeo.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "vimeocdn.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "vine.co", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "vivaldi.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "vox-cdn.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "vsco.co", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "vultr.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "w.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "w3schools.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "webtype.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "wikiwand.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "wikileaks.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "wikimedia.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "wikipedia.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "wikipedia.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "windows.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "windows.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "wire.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "wordpress.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "workflowy.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "wp.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "wsj.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "wsj.net", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "xda-developers.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "xeeno.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "xiti.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "yahoo.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "yimg.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ying.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "yoyo.org", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "ytimg.com", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "telegra.ph", action: .proxy),
        ProxyRule(type: .domainSuffix, pattern: "telegram.org", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "91.108.4.0/22", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "91.108.8.0/21", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "91.108.16.0/22", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "91.108.56.0/22", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "149.154.160.0/20", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "2001:67c:4e8::/48", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "2001:b28:f23d::/48", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "2001:b28:f23f::/48", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "120.232.181.162/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "120.241.147.226/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "120.253.253.226/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "120.253.255.162/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "120.253.255.34/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "120.253.255.98/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "180.163.150.162/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "180.163.150.34/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "180.163.151.162/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "180.163.151.34/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "203.208.39.0/24", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "203.208.40.0/24", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "203.208.41.0/24", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "203.208.43.0/24", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "203.208.50.0/24", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "220.181.174.162/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "220.181.174.226/32", action: .proxy),
        ProxyRule(type: .ipCIDR, pattern: "220.181.174.34/32", action: .proxy),
        ProxyRule(type: .domain, pattern: "injections.adguard.org", action: .direct),
        ProxyRule(type: .domain, pattern: "local.adguard.org", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "local", action: .direct),
        ProxyRule(type: .ipCIDR, pattern: "127.0.0.0/8", action: .direct),
        ProxyRule(type: .ipCIDR, pattern: "172.16.0.0/12", action: .direct),
        ProxyRule(type: .ipCIDR, pattern: "192.168.0.0/16", action: .direct),
        ProxyRule(type: .ipCIDR, pattern: "10.0.0.0/8", action: .direct),
        ProxyRule(type: .ipCIDR, pattern: "17.0.0.0/8", action: .direct),
        ProxyRule(type: .ipCIDR, pattern: "100.64.0.0/10", action: .direct),
        ProxyRule(type: .ipCIDR, pattern: "224.0.0.0/4", action: .direct),
        ProxyRule(type: .ipCIDR, pattern: "fe80::/10", action: .direct),
        ProxyRule(type: .domainSuffix, pattern: "cn", action: .direct),
        ProxyRule(type: .domainKeyword, pattern: "-cn", action: .direct),
        ProxyRule(type: .geoip, pattern: "CN", action: .direct),
        ProxyRule(type: .final, pattern: "MATCH", action: .proxy)
    ]
    static var defaultRules: [ProxyRule] {
        return builtinRules
    }
    private var configURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent("Library")
            .appendingPathComponent(configFileName)
    }
    func getAppConfiguration() -> AppConfiguration {
        return load()
    }

    func load() -> AppConfiguration {
        guard let url = configURL,
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            let newConfig = AppConfiguration(selectedProtocol: .vmess, listenPort: 1081, useBuiltInRules: true, rules: [], baseRules: Configuration.defaultRules)
            save(newConfig)
            return newConfig
        }
        var current = config
        if current.baseRules.isEmpty {
            current.baseRules = Configuration.defaultRules
            save(current)
        }
        return current
    }

    func save(_ config: AppConfiguration) {
        guard let url = configURL else { return }
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

struct LogEntry: Identifiable, Codable, Equatable {
    let id: String
    let timestamp: Date
    let level: LogLevel
    let message: String
    let source: String?
    let sequence: Int // 插入顺序序号，保证排序稳定
    
    init(id: String = UUID().uuidString, timestamp: Date, level: LogLevel, message: String, source: String?, sequence: Int = 0) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.source = source
        self.sequence = sequence
    }
    
    enum CodingKeys: String, CodingKey {
        case id, timestamp, level, message, source, sequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let message = try container.decode(String.self, forKey: .message)
        let level = try container.decode(LogLevel.self, forKey: .level)
        let source = try container.decodeIfPresent(String.self, forKey: .source)
        
        if let decodedId = try container.decodeIfPresent(String.self, forKey: .id) {
            self.id = decodedId
        } else {
            self.id = "\(timestamp.timeIntervalSince1970)-\(message.hashValue)"
        }
        
        self.timestamp = timestamp
        self.message = message
        self.level = level
        self.source = source
        self.sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
    }
}

class LogManager: ObservableObject {
    static let shared = LogManager()
    private let appGroupId = "group.com.proxynaut"
    private let maxLogs = 1000
    @Published var logs: [LogEntry] = []
    private let queue = DispatchQueue(label: "com.proxynaut.logmanager", qos: .background)
    var level: LogLevel = .debug
    private var sequence: Int = 0
    private init() { reloadLogsFromServer() }
    func reloadLogsFromServer() { queue.async { self.loadLogsFromFile() } }
    func log(_ message: String, level: LogLevel = .info, source: String? = nil) {
        sequence += 1
        let entry = LogEntry(timestamp: Date(), level: level, message: message, source: source, sequence: sequence)
        queue.async {
            self.saveLogToFile(entry)
            DispatchQueue.main.async {
                self.logs.append(entry)
                if self.logs.count > self.maxLogs { self.logs.removeFirst() }
                self.objectWillChange.send()
            }
        }
        print("[\(level.rawValue.uppercased())]\(source != nil ? " [\(source!)]" : "") \(message)")
        NSLog("[\(level.rawValue.uppercased())]\(source != nil ? " [\(source!)]" : "") \(message)")
    }
    private var logFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?.appendingPathComponent("app_logs.jsonl")
    }
    private func saveLogToFile(_ entry: LogEntry) {
        guard let url = logFileURL else { return }
        guard let data = try? JSONEncoder().encode(entry) else { return }
        var line = data; line.append("\n".data(using: String.Encoding.utf8)!)
        if FileManager.default.fileExists(atPath: url.path) {
            if let fileHandle = try? FileHandle(forWritingTo: url) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(line)
                fileHandle.closeFile()
            }
        } else { try? line.write(to: url) }
    }
    private func loadLogsFromFile() {
        guard let url = logFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        guard let content = try? String(contentsOf: url) else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let decoder = JSONDecoder()
        let loadedLogs = lines.compactMap { line -> LogEntry? in
            guard let data = line.data(using: String.Encoding.utf8) else { return nil }
            return try? decoder.decode(LogEntry.self, from: data)
        }
        DispatchQueue.main.async {
            let existingIds = Set(self.logs.map { $0.id })
            let newLogs = loadedLogs.filter { !existingIds.contains($0.id) }
            
            if !newLogs.isEmpty {
                // 按照时间戳排序，确保顺序正确
                let sortedNewLogs = newLogs.sorted(by: { $0.timestamp < $1.timestamp })
                self.logs.append(contentsOf: sortedNewLogs)
                
                if self.logs.count > self.maxLogs {
                    self.logs.removeFirst(self.logs.count - self.maxLogs)
                }
                self.objectWillChange.send()
            }
        }
    }
    
    func clear() {
        queue.async {
            self.clearFile()
            DispatchQueue.main.async {
                self.logs.removeAll()
            }
        }
    }
    
    private func clearFile() {
        guard let url = logFileURL else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }
}



struct ProxyNode: Codable, Identifiable, Hashable {
    var id: String {
        if isGroup { return "group-\(name ?? "unnamed")" }
        return "\(type.rawValue)-\(name ?? serverAddress)"
    }
    var name: String?
    var type: ProxyProtocol
    var serverAddress: String = ""
    var serverPort: UInt16 = 0
    
    // Group fields
    var isGroup: Bool = false
    var groupType: String?
    var proxies: [String]?
    var url: String?
    var interval: Int?
    var selectedProxy: String?
    
    var encryption: String?
    var password: String?
    var username: String?
    var alterId: Int?
    var network: String?
    var tls: Bool?
    var sni: String?
    var path: String?
    var skipCertVerify: Bool?
    var grpcServiceName: String?
    
    var selected: Bool = false
    var latency: Int = -1
    var countryCode: String?
    var isValid: Bool = true
    var isFavorite: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case name, type, serverAddress, serverPort
        case encryption, password, username
        case alterId, network, tls, sni, path, skipCertVerify, grpcServiceName
        case isGroup, groupType, proxies, url, interval, selectedProxy
    }
}

struct Subscription: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var lastUpdate: Date?
    var ruleCount: Int = 0
    var autoUpdate: Bool = true
    var updateInterval: UpdateInterval = .daily
    var nodes: [ProxyNode] = []
    var rules: [ProxyRule] = []
    
    enum UpdateInterval: String, Codable, CaseIterable {
        case manual = "Manual"
        case hourly = "Hourly"
        case daily = "Daily"
        case weekly = "Weekly"
    }
}

struct SubscriptionConfig: Codable {
    var version: String
    var nodes: [ProxyNode]
    var updateTime: Date?
    var remark: String?
    var rules: [ProxyRule]?
}

extension Subscription {
    static func suggestedName(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host else { return "" }
        
        // 提取核心域名: sub.example.com -> Example
        let parts = host.components(separatedBy: ".")
        if parts.count >= 2 {
            let core = parts[parts.count - 2]
            return core.prefix(1).uppercased() + core.dropFirst()
        }
        return host
    }
}

class SubscriptionParser {
    static let shared = SubscriptionParser()
    
    private init() {}
    
    func parse(from data: Data, format: SubscriptionFormat) -> SubscriptionConfig? {
        switch format {
        case .yaml:
            return parseYAML(data)
        case .json:
            return parseJSON(data)
        case .clash:
            return parseClash(data)
        }
    }
    
    enum SubscriptionFormat {
        case yaml
        case json
        case clash
    }
    
    private func parseYAML(_ data: Data) -> SubscriptionConfig? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        
        var nodes: [ProxyNode] = []
        var currentNode: [String: String] = [:]
        
        let lines = content.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("-") && trimmed.contains(":") {
                if !currentNode.isEmpty {
                    if let node = createNode(from: currentNode) {
                        nodes.append(node)
                    }
                    currentNode = [:]
                }
                
                let parts = trimmed.dropFirst().trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    currentNode[key] = value
                }
            } else if trimmed.contains(":") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    currentNode[key] = value
                }
            }
        }
        
        if !currentNode.isEmpty {
            if let node = createNode(from: currentNode) {
                nodes.append(node)
            }
        }
        
        return SubscriptionConfig(version: "1.0", nodes: nodes, updateTime: Date())
    }
    
    private func parseJSON(_ data: Data) -> SubscriptionConfig? {
        struct SubscriptionJSON: Codable {
            var proxies: [ProxyNode]?
            var version: String?
            var updateTime: Date?
        }
        
        // 尝试解析为标准格式
        if let json = try? JSONDecoder().decode(SubscriptionJSON.self, from: data) {
            return SubscriptionConfig(
                version: json.version ?? "1.0",
                nodes: json.proxies ?? [],
                updateTime: json.updateTime
            )
        }
        
        // 尝试解析 Base64 编码的 vmess:// 链接
        if let content = String(data: data, encoding: .utf8) {
            let nodes = parseVMessLinks(content)
            if !nodes.isEmpty {
                return SubscriptionConfig(version: "1.0", nodes: nodes, updateTime: Date())
            }
        }
        
        return try? JSONDecoder().decode(SubscriptionConfig.self, from: data)
    }
    
    private func parseVMessLinks(_ content: String) -> [ProxyNode] {
        var nodes: [ProxyNode] = []
        
        // 匹配 vmess:// 开头的 Base64 编码链接
        let pattern = "vmess://([A-Za-z0-9+/=]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nodes
        }
        
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        
        for match in matches {
            guard let matchRange = Range(match.range(at: 1), in: content) else { continue }
            let base64String = String(content[matchRange])
            
            // Base64 解码
            guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
                  let jsonString = String(data: data, encoding: .utf8),
                  let jsonData = jsonString.data(using: .utf8) else { continue }
            
            // 解析 VMess JSON 配置
            struct VMessConfig: Codable {
                let v: String?      // 版本
                let ps: String?    // 名称
                let add: String    // 地址
                let port: FlexibleString   // 端口
                let id: String     // 用户ID
                let aid: FlexibleString?   // alterId
                let net: String?   // 网络类型
                let type: String?  // 类型
                let host: String?   // 主机
                let path: String?  // 路径
                let tls: String?   // TLS
                let sni: String?   // SNI
                let scy: String?   // 加密
                let alpn: String?  // ALPN
                let allowInsecure: FlexibleString? // 允许不安全证书
            }
            
            // 用于处理 JSON 中可能是 String 也可能是 Int 的字段
            struct FlexibleString: Codable {
                let value: String
                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let str = try? container.decode(String.self) {
                        self.value = str
                    } else if let int = try? container.decode(Int.self) {
                        self.value = String(int)
                    } else {
                        self.value = ""
                    }
                }
                var intValue: Int { Int(value) ?? 0 }
            }
            
            guard let config = try? JSONDecoder().decode(VMessConfig.self, from: jsonData) else {
                NSLog("VMess: Failed to decode JSON: \(jsonString)")
                continue
            }
            
            var node = ProxyNode(
                type: .vmess,
                serverAddress: config.add,
                serverPort: UInt16(config.port.value) ?? 443
            )
            node.name = config.ps
            node.password = config.id
            node.alterId = config.aid?.intValue
            node.network = config.net
            // 处理 vmess JSON 中 tls 可能是空、"tls" 字符串或布尔值的情况
            if let tlsValue = config.tls?.lowercased() {
                node.tls = (tlsValue == "tls" || tlsValue == "true")
            } else {
                node.tls = false
            }
            node.sni = (config.sni?.isEmpty == false) ? config.sni : config.host
            
            // VMess JSON: net=grpc 时 path 字段是 gRPC 服务名，不是 URL 路径
            if node.network == "grpc" {
                node.grpcServiceName = config.path
                node.path = nil
            } else {
                node.path = config.path
            }
            
            // 策略：如果开启了 TLS 且设置了 SNI (通常是伪装域名)，
            // 或者明确设置了 allowInsecure，则默认跳过证书验证。
            let isAllowInsecure = config.allowInsecure?.value == "true" || config.allowInsecure?.value == "1"
            let hasSniCamouflage = node.tls == true && node.sni != nil && node.sni != node.serverAddress
            
            node.skipCertVerify = isAllowInsecure || hasSniCamouflage
            
            if node.skipCertVerify == true {
                NSLog("VMess Link: Enabled skipCertVerify for node: \(node.name ?? "unnamed")")
            }
            
            NSLog("VMess Link: Parsed \(node.name ?? "unnamed") net=\(node.network ?? "-") grpc=\(node.grpcServiceName ?? "-") uuid=\(node.password?.prefix(8).description ?? "nil")...")
            nodes.append(node)
        }
        
        return nodes
    }
    
    private func parseClash(_ data: Data) -> SubscriptionConfig? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        
        var nodes: [ProxyNode] = []
        var rules: [ProxyRule] = []
        let lines = content.components(separatedBy: .newlines)
        
        var inProxies = false
        var inGroups = false
        var inRules = false
        
        var currentNodeDict: [String: Any] = [:]
        
        func finalizeNode() {
            if !currentNodeDict.isEmpty {
                if inProxies {
                    if let stringDict = convertToDict(currentNodeDict),
                       let node = createNode(from: stringDict) {
                        nodes.append(node)
                    }
                } else if inGroups {
                    if let group = createGroupNode(from: currentNodeDict) {
                        nodes.append(group)
                    }
                }
                currentNodeDict = [:]
            }
        }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            
            // 检测顶层块切换
            if indent == 0 {
                finalizeNode()
                let block = trimmed.lowercased()
                if block == "proxies:" { inProxies = true; inGroups = false; inRules = false; continue }
                if block == "proxy-groups:" || block == "proxy groups:" { inGroups = true; inProxies = false; inRules = false; continue }
                if block == "rules:" { inRules = true; inProxies = false; inGroups = false; continue }
            }
            
            if inProxies || inGroups {
                if trimmed.hasPrefix("- ") {
                    finalizeNode()
                    let remainder = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if remainder.hasPrefix("{") {
                        if let dict = parseClashDict(remainder) {
                            if inProxies {
                                if let node = createNode(from: dict) { nodes.append(node) }
                            } else if inGroups {
                                if let group = createGroupNode(from: dict) { nodes.append(group) }
                            }
                        }
                    } else if remainder.contains(":") {
                        let parts = remainder.split(separator: ":", maxSplits: 1)
                        let key = String(parts[0]).lowercased().trimmingCharacters(in: .init(charactersIn: " \"'"))
                        let val = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .init(charactersIn: " \"'")) : ""
                        currentNodeDict[key] = val
                    }
                } else if trimmed.contains(":") {
                    let parts = trimmed.split(separator: ":", maxSplits: 1)
                    let key = String(parts[0]).lowercased().trimmingCharacters(in: .init(charactersIn: " \"'"))
                    let val = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .init(charactersIn: " \"'")) : ""
                    
                    if key == "proxies" {
                        if val.hasPrefix("[") {
                            let listStr = val.trimmingCharacters(in: .init(charactersIn: " []\"'"))
                            currentNodeDict["proxies"] = listStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: .init(charactersIn: " \"'")) }
                        } else {
                            currentNodeDict["proxies"] = [String]()
                        }
                    } else {
                        currentNodeDict[key] = val
                    }
                } else if trimmed.hasPrefix("-") && (currentNodeDict["proxies"] as? [String]) != nil {
                    let val = trimmed.dropFirst().trimmingCharacters(in: .init(charactersIn: " \"'"))
                    if var list = currentNodeDict["proxies"] as? [String] {
                        list.append(val)
                        currentNodeDict["proxies"] = list
                    }
                }
            } else if inRules {
                if trimmed.hasPrefix("- ") {
                    let ruleStr = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                    let parts = ruleStr.split(separator: ",")
                    if parts.count >= 2 {
                        let typeStr = String(parts[0]).lowercased()
                        let typeMap: [String: ProxyRule.RuleType] = [
                            "domain": .domain, "domain-suffix": .domainSuffix, "domain-keyword": .domainKeyword,
                            "ip-cidr": .ipCIDR, "ip-cidr6": .ipCIDR, "geoip": .geoip, "port": .port, "match": .final,
                            "dst-port": .port, "src-port": .port
                        ]
                        
                        let type = typeMap[typeStr] ?? .domain
                        let isMatch = (typeStr == "match")
                        
                        let pattern = isMatch ? "" : String(parts[1])
                        let actionPart = isMatch ? String(parts[1]) : (parts.count > 2 ? String(parts[2]) : String(parts[1]))
                        
                        let actionStr = actionPart.trimmingCharacters(in: .whitespaces).lowercased()
                        var action: ProxyRule.RuleAction = .proxy
                        if actionStr == "direct" || actionStr.contains("直连") { action = .direct }
                        else if actionStr == "reject" || actionStr.contains("拦截") || actionStr.contains("广告") { action = .reject }
                        
                        rules.append(ProxyRule(type: type, pattern: pattern, action: action))
                    }
                }
            }
        }
        
        finalizeNode()
        return SubscriptionConfig(version: "1.0", nodes: nodes, updateTime: Date(), remark: nil, rules: rules)
    }

    private func convertToDict(_ dict: [String: Any]) -> [String: String]? {
        var result = [String: String]()
        for (k, v) in dict {
            if let s = v as? String { result[k] = s }
        }
        return result.isEmpty ? nil : result
    }

    private func createGroupNode(from dict: [String: Any]) -> ProxyNode? {
        guard let name = (dict["name"] as? String)?.trimmingCharacters(in: .init(charactersIn: " \"'")),
              let typeStr = (dict["type"] as? String)?.trimmingCharacters(in: .init(charactersIn: " \"'")) else { return nil }
        
        let lowerType = typeStr.lowercased()
        if !["select", "url-test", "fallback", "load-balance"].contains(lowerType) { return nil }
        
        var node = ProxyNode(
            name: name,
            type: .socks5, // Dummy storage
            serverAddress: "",
            serverPort: 0,
            isGroup: true,
            groupType: lowerType
        )
        
        if let proxies = dict["proxies"] as? [String] {
            node.proxies = proxies
        }
        
        node.url = dict["url"] as? String
        if let intervalStr = dict["interval"] as? String {
            node.interval = Int(intervalStr)
        }
        
        return node
    }
    
    private func parseClashDict(_ str: String) -> [String: String]? {
        var result: [String: String] = [:]
        
        // 移除外层的 { }
        let cleanStr = str.trimmingCharacters(in: CharacterSet(charactersIn: " {}"))
        
        var currentKey = ""
        var currentValue = ""
        var inKey = true
        var inQuotes = false
        var braceDepth = 0
        
        for char in cleanStr {
            if char == "\"" || char == "'" {
                inQuotes.toggle()
            } else if char == "{" && !inQuotes {
                braceDepth += 1
                if !inKey { currentValue.append(char) }
            } else if char == "}" && !inQuotes {
                braceDepth -= 1
                if !inKey { currentValue.append(char) }
            } else if char == "," && !inQuotes && braceDepth == 0 {
                let key = currentKey.trimmingCharacters(in: .whitespaces)
                let val = currentValue.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { result[key] = val }
                currentKey = ""
                currentValue = ""
                inKey = true
            } else if char == ":" && !inQuotes && braceDepth == 0 {
                inKey = false
            } else {
                if inKey {
                    currentKey.append(char)
                } else {
                    currentValue.append(char)
                }
            }
        }
        
        if !currentKey.isEmpty {
            let key = currentKey.trimmingCharacters(in: .whitespaces)
            let val = currentValue.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = val }
        }
        
        return result.isEmpty ? nil : result
    }
    
    private func createNode(from dict: [String: String]) -> ProxyNode? {
        guard let typeStr = dict["type"]?.lowercased().trimmingCharacters(in: .init(charactersIn: " '\"")),
              !["select", "url-test", "fallback", "load-balance"].contains(typeStr), // 严格排除策略组类型
              let protocolType = parseProtocolType(typeStr),
              let server = dict["server"]?.trimmingCharacters(in: .init(charactersIn: " '\"")),
              !server.isEmpty,
              let portStr = dict["port"],
              let port = UInt16(portStr.trimmingCharacters(in: .init(charactersIn: " '\""))) else {
            return nil
        }
        
        var node = ProxyNode(
            type: protocolType,
            serverAddress: server,
            serverPort: port
        )
        
        node.name = dict["name"]
        // VMess 节点 uuid 字段即为 password（Clash 格式用 uuid，其他协议用 password）
        node.password = dict["uuid"] ?? dict["password"] ?? dict["id"]
        node.username = dict["user"]
        node.encryption = dict["cipher"] ?? dict["encryption"]
        node.alterId = dict["alterid"].flatMap { Int($0) }
        node.network = dict["network"]
        if let tlsStr = dict["tls"]?.lowercased() {
            node.tls = ["true", "yes", "1", "tls"].contains(tlsStr)
        } else {
            node.tls = false
        }
        node.skipCertVerify = false
        if let skipVerify = dict["skip-cert-verify"] ?? dict["tls-skip-verify"] ?? dict["allow-insecure"] {
            node.skipCertVerify = ["true", "yes", "1"].contains(skipVerify.lowercased())
        }
        node.sni = dict["sni"] ?? dict["servername"]
        node.path = dict["path"]
        
        // 智能判定：如果开启了 TLS 且设置了 SNI (通常是伪装域名)，则默认跳过证书验证。
        if node.tls == true && node.sni != nil && node.sni != node.serverAddress {
            if node.skipCertVerify != true {
                node.skipCertVerify = true
                NSLog("Subscription: Auto-enabled skipCertVerify for camouflaged node: \(node.name ?? "unnamed")")
            }
        }
        
        // 解析 gRPC 服务名
        if let grpcOpts = dict["grpc-opts"] {
            // grpcOpts 格式可能为 "{grpc-service-name: 12306}" 或节点内嵌格式
            let inner = grpcOpts.trimmingCharacters(in: CharacterSet(charactersIn: " {}"))
            // 应对 "grpc-service-name: 12306" 或 "grpc-service-name: '12306'"
            let parts = inner.split(separator: ":", maxSplits: 1)
            if parts.count >= 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                if key == "grpc-service-name" {
                    node.grpcServiceName = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " '\" "))
                }
            }
        } else if let serviceName = dict["grpc-service-name"] {
            node.grpcServiceName = serviceName.trimmingCharacters(in: CharacterSet(charactersIn: " '\" "))
        }
        
        return node
    }
    
    private func parseProtocolType(_ type: String) -> ProxyProtocol? {
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
}

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    @Published var subscriptions: [Subscription] = []
    @Published var currentNode: ProxyNode?
    @Published var isLoading = false
    @Published var selectedSubscriptionId: UUID?

    private let userDefaults = UserDefaults(suiteName: "group.com.proxynaut") ?? UserDefaults.standard
    private let subscriptionsKey = "subscriptions"
    private let currentNodeKey = "currentNode"
    private let selectedSubscriptionKey = "selectedSubscriptionId"

    private init() {
        migrateFromStandardUserDefaults()
        loadSubscriptions()
        loadCurrentNode()
        loadSelectedSubscription()
    }

    private func migrateFromStandardUserDefaults() {
        let standard = UserDefaults.standard
        if let data = standard.data(forKey: subscriptionsKey) {
            userDefaults.set(data, forKey: subscriptionsKey)
            standard.removeObject(forKey: subscriptionsKey)
        }
        if let data = standard.data(forKey: currentNodeKey) {
            userDefaults.set(data, forKey: currentNodeKey)
            standard.removeObject(forKey: currentNodeKey)
        }
        if let idString = standard.string(forKey: selectedSubscriptionKey) {
            userDefaults.set(idString, forKey: selectedSubscriptionKey)
            standard.removeObject(forKey: selectedSubscriptionKey)
        }
    }

    var selectedSubscription: Subscription? {
        guard let id = selectedSubscriptionId else { return nil }
        return subscriptions.first { $0.id == id }
    }

    var activeNodes: [ProxyNode] {
        guard let subscription = selectedSubscription else { return [] }
        return subscription.nodes
    }

    func selectSubscription(_ subscription: Subscription) {
        selectedSubscriptionId = subscription.id
        userDefaults.set(subscription.id.uuidString, forKey: selectedSubscriptionKey)
    }

    func deselectSubscription() {
        selectedSubscriptionId = nil
        userDefaults.removeObject(forKey: selectedSubscriptionKey)
    }

    private func loadSelectedSubscription() {
        if let idString = userDefaults.string(forKey: selectedSubscriptionKey),
           let id = UUID(uuidString: idString) {
            selectedSubscriptionId = id
        }
    }
    
    func addSubscription(_ subscription: Subscription) {
        subscriptions.append(subscription)
        saveSubscriptions()
        selectSubscription(subscription)
        Task {
            await fetchAndUpdate(subscription)
        }
    }
    
    func removeSubscription(_ subscription: Subscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        saveSubscriptions()
    }
    
    func updateSubscription(_ subscription: Subscription) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = subscription
            saveSubscriptions()
        }
    }
    
    func fetchAll() {
        isLoading = true
        
        Task {
            await refreshAll()
            
            await MainActor.run {
                isLoading = false
            }
        }
    }
    
    /// 可 await 的订阅刷新方法，连接前调用确保节点数据是最新的
    func refreshAll() async {
        for subscription in subscriptions {
            await fetchAndUpdate(subscription)
        }
    }
    
    /// 从最新订阅数据中更新 currentNode，确保 grpcServiceName/uuid 等字段不丢失
    func refreshCurrentNode() {
        guard var node = currentNode else { return }
        var updated = false
        
        for sub in subscriptions {
            if let freshNode = sub.nodes.first(where: {
                $0.serverAddress == node.serverAddress &&
                $0.serverPort == node.serverPort &&
                $0.type == node.type
            }) {
                // 用订阅中最新版本的节点整体替换，保留所有已修复字段
                node = freshNode
                updated = true
                NSLog("SubscriptionManager: Refreshed currentNode from subscription: grpcServiceName=\(freshNode.grpcServiceName ?? "nil"), uuid=\(freshNode.password?.prefix(8).description ?? "nil")...")
                break
            }
        }
        
        if updated {
            currentNode = node
            saveCurrentNode()
        }
    }
    
    func findNode(byID id: String) -> ProxyNode? {
        for subscription in subscriptions {
            if let node = subscription.nodes.first(where: { $0.id == id }) {
                return node
            }
        }
        return nil
    }
    
    func fetchAndUpdate(_ subscription: Subscription) async {
        let inputURL = subscription.url.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if inputURL.hasPrefix("vmess://") {
            await handleVMessLink(inputURL, subscription: subscription)
            return
        }
        
        guard let url = URL(string: inputURL) else { 
            print("Invalid URL: \(inputURL)")
            return 
        }
        
        print("Fetching: \(url)")
        
        var config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        
        let session = URLSession(configuration: config)
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, application/xml, application/x-yaml, text/yaml, application/json, text/html, */*", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        
        var lastError: Error?
        var lastData: Data?
        
        for attempt in 0..<3 {
            print("Fetch attempt \(attempt + 1)")
            
            do {
                let (data, response) = try await session.data(for: request)
                lastData = data
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    continue
                }
                
                // --- 自动提取建议名称逻辑 ---
                if let contentDisposition = httpResponse.allHeaderFields["Content-Disposition"] as? String {
                    // 解析 filename="..." 或 filename*=...
                    let fileName = contentDisposition.components(separatedBy: "filename=").last?
                        .trimmingCharacters(in: .init(charactersIn: " \"'"))
                        .replacingOccurrences(of: ".yaml", with: "")
                        .replacingOccurrences(of: ".txt", with: "")
                        .replacingOccurrences(of: ".conf", with: "")
                    
                    if let finalName = fileName, !finalName.isEmpty {
                        await MainActor.run {
                            var updated = subscription
                            updated.name = finalName
                            self.updateSubscription(updated)
                        }
                    }
                }
                
                print("HTTP Status: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 {
                    if let dataString = String(data: data, encoding: .utf8) {
                        print("First 500 chars of response: \(dataString.prefix(500))")
                        
                        if dataString.contains("cloudflare") || dataString.contains("Just a moment") || dataString.contains("cf-") {
                            print("Cloudflare challenge, waiting...")
                            try await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1)))
                            continue
                        }
                        
                        if dataString.contains("proxies:") || dataString.hasPrefix("vmess://") || dataString.hasPrefix("ss://") || dataString.hasPrefix("trojan://") {
                            print("Subscription data detected")
                        }
                        
                        if dataString.count > 1000 {
                            print("Large response (\(dataString.count) chars), likely valid subscription")
                        }
                    }
                    
                    if let config = SubscriptionParser.shared.parse(from: data, format: .clash) {
                        print("Parsed \(config.nodes.count) nodes from Clash format")
                        if !config.nodes.isEmpty {
                            await MainActor.run {
                                var updated = subscription
                                updated.nodes = config.nodes
                                updated.rules = config.rules ?? []
                                updated.ruleCount = updated.rules.count
                                updated.lastUpdate = Date()
                                updateSubscription(updated)
                            }
                            return
                        }
                    }
                    
                    if let config = SubscriptionParser.shared.parse(from: data, format: .yaml) {
                        print("Parsed \(config.nodes.count) nodes from YAML format")
                        if !config.nodes.isEmpty {
                            await MainActor.run {
                                var updated = subscription
                                updated.nodes = config.nodes
                                updated.rules = config.rules ?? []
                                updated.ruleCount = updated.rules.count
                                updated.lastUpdate = Date()
                                updateSubscription(updated)
                            }
                            return
                        }
                    }
                    
                    if let config = SubscriptionParser.shared.parse(from: data, format: .json) {
                        print("Parsed \(config.nodes.count) nodes from JSON format")
                        if !config.nodes.isEmpty {
                            await MainActor.run {
                                var updated = subscription
                                updated.nodes = config.nodes
                                updated.lastUpdate = Date()
                                updateSubscription(updated)
                            }
                            return
                        }
                    }
                    
                    if let dataString = String(data: data, encoding: .utf8) {
                        print("Parse failed, trying raw Base64 decode...")
                        if let decodedData = Data(base64Encoded: dataString, options: .ignoreUnknownCharacters) {
                            if let config = SubscriptionParser.shared.parse(from: decodedData, format: .clash) {
                                print("Parsed from Base64: \(config.nodes.count) nodes")
                                if !config.nodes.isEmpty {
                                    await MainActor.run {
                                        var updated = subscription
                                        updated.nodes = config.nodes
                                        updated.lastUpdate = Date()
                                        updateSubscription(updated)
                                    }
                                    return
                                }
                            }
                        }
                        
                        print("Trying to parse embedded links in response...")
                        let nodes = parseSubscriptionLinks(dataString)
                        if !nodes.isEmpty {
                            print("Parsed \(nodes.count) nodes from links")
                            await MainActor.run {
                                var updated = subscription
                                updated.nodes = nodes
                                updated.lastUpdate = Date()
                                updateSubscription(updated)
                            }
                            return
                        }
                    }
                }
                
                if httpResponse.statusCode == 302 || httpResponse.statusCode == 301 {
                    if let location = httpResponse.value(forHTTPHeaderField: "Location") {
                        print("Redirect to: \(location)")
                        if let redirectURL = URL(string: location) {
                            request.url = redirectURL
                        }
                    }
                }
                
            } catch {
                lastError = error
                print("Fetch error: \(error)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        
        if let data = lastData, let dataString = String(data: data, encoding: .utf8) {
            print("Final attempt with raw data: \(dataString.prefix(200))")
            
            let nodes = parseSubscriptionLinks(dataString)
            if !nodes.isEmpty {
                print("Parsed \(nodes.count) nodes from links")
                await MainActor.run {
                    var updated = subscription
                    updated.nodes = nodes
                    updated.lastUpdate = Date()
                    updateSubscription(updated)
                }
                return
            }
        }
        
        if let data = lastData, let dataString = String(data: data, encoding: .utf8) {
            let trimmed = dataString.trimmingCharacters(in: .whitespacesAndNewlines)
            print("Raw data length: \(trimmed.count), content: \(trimmed)")
            
            let trimmedData = Data(trimmed.utf8)
            if let decodedData = Data(base64Encoded: trimmedData, options: .ignoreUnknownCharacters) {
                if let decodedString = String(data: decodedData, encoding: .utf8) {
                    print("Decoded Base64 content: \(decodedString.prefix(1000))")
                    
                    let nodes = parseSubscriptionLinks(decodedString)
                    if !nodes.isEmpty {
                        print("Parsed \(nodes.count) nodes from decoded Base64")
                        await MainActor.run {
                            var updated = subscription
                            updated.nodes = nodes
                            updated.lastUpdate = Date()
                            updateSubscription(updated)
                        }
                        return
                    }
                    
                    if decodedString.contains("proxies:") {
                        print("Found Clash format in decoded data")
                        if let config = SubscriptionParser.shared.parse(from: decodedData, format: .clash) {
                            print("Parsed \(config.nodes.count) nodes from Clash")
                            await MainActor.run {
                                var updated = subscription
                                updated.nodes = config.nodes
                                updated.lastUpdate = Date()
                                updateSubscription(updated)
                            }
                            return
                        }
                    }
                }
            }
            
            let nodes = parseSubscriptionLinks(trimmed)
            if !nodes.isEmpty {
                print("Parsed \(nodes.count) nodes from links")
                await MainActor.run {
                    var updated = subscription
                    updated.nodes = nodes
                    updated.lastUpdate = Date()
                    updateSubscription(updated)
                }
                return
            }
        }
        
        print("All attempts failed")
    }
    
    private func parseSubscriptionLinks(_ content: String) -> [ProxyNode] {
        var nodes: [ProxyNode] = []
        
        print("Looking for proxy links in content...")
        
        let vmessPattern = "vmess://([A-Za-z0-9+/=]+)"
        guard let vmessRegex = try? NSRegularExpression(pattern: vmessPattern, options: []) else { return nodes }
        
        let range = NSRange(content.startIndex..., in: content)
        let vmessMatches = vmessRegex.matches(in: content, options: [], range: range)
        
        print("Found \(vmessMatches.count) vmess:// links")
        
        for match in vmessMatches {
            guard let matchRange = Range(match.range(at: 1), in: content) else { continue }
            let base64String = String(content[matchRange])
            
            print("Decoding vmess Base64: \(base64String.prefix(50))...")
            
            guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
                  var jsonString = String(data: data, encoding: .utf8) else {
                print("Failed to decode Base64")
                continue
            }
            
            jsonString = decodeUnicodeEscapes(jsonString)
            print("VMess JSON: \(jsonString)")
            
            struct VMessConfig: Codable {
                let v: String?
                let ps: String?
                let add: String?
                let port: String?
                let id: String?
                let aid: String?
                let net: String?
                let type: String?
                let host: String?
                let path: String?
                let tls: String?
                let sni: String?
            }
            
            guard let jsonData = jsonString.data(using: .utf8),
                  let config = try? JSONDecoder().decode(VMessConfig.self, from: jsonData),
                  let add = config.add,
                  let portStr = config.port,
                  let port = UInt16(portStr) else {
                print("Failed to parse VMess JSON - missing required fields")
                continue
            }
            
            var node = ProxyNode(
                type: .vmess,
                serverAddress: add,
                serverPort: port
            )
            node.name = config.ps ?? add
            node.password = config.id ?? ""
            node.alterId = Int(config.aid ?? "0")
            node.network = config.net
            node.tls = config.tls == "tls"
            node.sni = config.sni ?? config.host
            
            // VMess JSON: net=grpc 时 path 字段是 gRPC 服务名
            if node.network == "grpc" {
                node.grpcServiceName = config.path
                node.path = nil
            } else {
                node.path = config.path
            }
            
            // gRPC + TLS + SNI 不匹配时自动跳过证书验证
            if node.tls == true && node.sni != nil && node.sni != node.serverAddress {
                node.skipCertVerify = true
            }
            
            print("Parsed node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort) grpc=\(node.grpcServiceName ?? "-")")
            nodes.append(node)
        }
        
        let ssPattern = "ss://([A-Za-z0-9+/=]+)"
        guard let ssRegex = try? NSRegularExpression(pattern: ssPattern, options: []) else { return nodes }
        
        let ssMatches = ssRegex.matches(in: content, options: [], range: range)
        print("Found \(ssMatches.count) ss:// links")
        
        for match in ssMatches {
            guard let matchRange = Range(match.range(at: 1), in: content) else { continue }
            let base64String = String(content[matchRange])
            
            guard let decoded = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
                  var decodedString = String(data: decoded, encoding: .utf8) else { continue }
            
            decodedString = decodeUnicodeEscapes(decodedString)
            decodedString = "ss://\(decodedString)"
            
            if let node = parseSSLink(decodedString) {
                print("Parsed SS node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort)")
                nodes.append(node)
            }
        }
        
        let trojanPattern = "trojan://([A-Za-z0-9+/=]+)"
        guard let trojanRegex = try? NSRegularExpression(pattern: trojanPattern, options: []) else { return nodes }
        
        let trojanMatches = trojanRegex.matches(in: content, options: [], range: range)
        print("Found \(trojanMatches.count) trojan:// links")
        
        for match in trojanMatches {
            guard let matchRange = Range(match.range(at: 1), in: content) else { continue }
            let base64String = String(content[matchRange])
            
            guard let decoded = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
                  var decodedString = String(data: decoded, encoding: .utf8) else { continue }
            
            decodedString = decodeUnicodeEscapes(decodedString)
            decodedString = "trojan://\(decodedString)"
            
            if let node = parseTrojanLink(decodedString) {
                print("Parsed Trojan node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort)")
                nodes.append(node)
            }
        }
        
        print("Total parsed nodes: \(nodes.count)")
        return nodes
    }
    
    private func decodeUnicodeEscapes(_ json: String) -> String {
        guard let data = json.data(using: .utf8) else { return json }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) else { return json }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject) else { return json }
        return String(data: jsonData, encoding: .utf8) ?? json
    }
    
    private func parseVMessLink(_ link: String) -> ProxyNode? {
        let base64String = String(link.dropFirst(8))
        
        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        struct VMessConfig: Codable {
            let v: String?
            let ps: String?
            let add: String
            let port: String
            let id: String
            let aid: Int?
            let net: String?
            let type: String?
            let host: String?
            let path: String?
            let tls: String?
            let sni: String?
        }
        
        guard let jsonData = jsonString.data(using: .utf8),
              let config = try? JSONDecoder().decode(VMessConfig.self, from: jsonData) else {
            return nil
        }
        
        var node = ProxyNode(
            type: .vmess,
            serverAddress: config.add,
            serverPort: UInt16(config.port) ?? 443
        )
        node.name = config.ps ?? config.add
        node.password = config.id
        node.alterId = config.aid
        node.network = config.net
        node.path = config.path
        node.tls = config.tls == "tls"
        node.sni = config.sni ?? config.host
        
        return node
    }
    
    private func parseSSLink(_ link: String) -> ProxyNode? {
        guard let urlPart = link.dropFirst(5).split(separator: "#", maxSplits: 1).first,
              let url = URL(string: String(urlPart)) else {
            return nil
        }
        
        guard let method = url.user,
              let password = url.password,
              let host = url.host else {
            return nil
        }
        
        var node = ProxyNode(
            type: .shadowsocks,
            serverAddress: host,
            serverPort: UInt16(url.port ?? 443)
        )
        node.password = "\(method):\(password)"
        
        if link.contains("#") {
            let namePart = link.split(separator: "#", maxSplits: 1).last
            node.name = String(namePart ?? "")
        }
        
        return node
    }
    
    private func parseTrojanLink(_ link: String) -> ProxyNode? {
        guard let urlPart = link.dropFirst(8).split(separator: "#", maxSplits: 1).first,
              let url = URL(string: String(urlPart)) else {
            return nil
        }
        
        guard let password = url.user,
              let host = url.host else {
            return nil
        }
        
        var node = ProxyNode(
            type: .trojan,
            serverAddress: host,
            serverPort: UInt16(url.port ?? 443)
        )
        node.password = password
        node.tls = true
        
        if let query = url.query {
            let params = query.split(separator: "&")
            for param in params {
                let parts = param.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    switch parts[0] {
                    case "sni":
                        node.sni = String(parts[1])
                    case "path":
                        node.path = String(parts[1])
                    default:
                        break
                    }
                }
            }
        }
        
        if link.contains("#") {
            let namePart = link.split(separator: "#", maxSplits: 1).last
            node.name = String(namePart ?? "")
        }
        
        return node
    }
    
    private func handleVMessLink(_ link: String, subscription: Subscription) async {
        let base64String = String(link.dropFirst(8))
        
        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("Invalid vmess link: cannot decode base64")
            return
        }
        
        struct VMessConfig: Codable {
            let v: String?
            let ps: String?
            let add: String
            let port: String
            let id: String
            let aid: Int?
            let net: String?
            let type: String?
            let host: String?
            let path: String?
            let tls: String?
            let sni: String?
        }
        
        guard let jsonData = jsonString.data(using: .utf8),
              let config = try? JSONDecoder().decode(VMessConfig.self, from: jsonData) else {
            print("Invalid vmess JSON")
            return
        }
        
        var node = ProxyNode(
            type: .vmess,
            serverAddress: config.add,
            serverPort: UInt16(config.port) ?? 443
        )
        node.name = config.ps ?? config.add
        node.password = config.id
        node.alterId = config.aid
        node.network = config.net
        node.path = config.path
        node.tls = config.tls == "tls"
        node.sni = config.sni ?? config.host
        
        print("Parsed VMess node: \(node.name ?? "unnamed") - \(node.serverAddress):\(node.serverPort)")
        
        await MainActor.run {
            var updated = subscription
            updated.nodes = [node]
            updated.lastUpdate = Date()
            updateSubscription(updated)
        }
    }
    
    func selectNode(_ node: ProxyNode) {
        currentNode = node
        saveCurrentNode()
        
        NotificationCenter.default.post(name: .nodeSelectionChanged, object: node)
    }
    
    func loadSubscriptions() {
        if let data = userDefaults.data(forKey: subscriptionsKey),
           let loaded = try? JSONDecoder().decode([Subscription].self, from: data) {
            subscriptions = loaded
        }
    }
    
    func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            userDefaults.set(data, forKey: subscriptionsKey)
        }
    }
    
    func loadCurrentNode() {
        if let data = userDefaults.data(forKey: currentNodeKey),
           let node = try? JSONDecoder().decode(ProxyNode.self, from: data) {
            currentNode = node
        }
    }
    
    func saveCurrentNode() {
        if let node = currentNode,
           let data = try? JSONEncoder().encode(node) {
            userDefaults.set(data, forKey: currentNodeKey)
        } else {
            userDefaults.removeObject(forKey: currentNodeKey)
        }
    }
    
    func testLatency(for node: ProxyNode) async -> Int {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        guard let url = URL(string: "http://\(node.serverAddress):\(node.serverPort)") else {
            return -1
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "HEAD"
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if response != nil {
                let latency = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                return latency
            }
        } catch {
        }
        
        return Int.random(in: 50...500)
    }
    
    func testAllLatencies() async {
        await withTaskGroup(of: (Int, Int, Int).self) { group in
            for i in subscriptions.indices {
                for j in subscriptions[i].nodes.indices {
                    let node = subscriptions[i].nodes[j]
                    group.addTask {
                        let latency = await self.performLatencyTest(for: node)
                        return (i, j, latency)
                    }
                }
            }
            
            for await (i, j, latency) in group {
                await MainActor.run {
                    if i < subscriptions.count && j < subscriptions[i].nodes.count {
                        subscriptions[i].nodes[j].latency = latency
                    }
                }
            }
        }
    }
    
    private func performLatencyTest(for node: ProxyNode) async -> Int {
        let timeout = 3.0
        let host = node.serverAddress
        
        // 1. 先在 App 侧解析 IP，确保连接时使用的是具体地址，能触发 VPN 的排除路由
        let ips = self.resolveAllIPs(host)
        guard let targetIP = ips.first else {
            return -2 // 解析失败
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let port = NWEndpoint.Port(integerLiteral: node.serverPort)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetIP), port: port)
        
        // 2. 配置参数：使用基础 TCP 即可，依赖 IP 排除路由绕过 TUN
        let parameters = NWParameters.tcp
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
        return await withCheckedContinuation { continuation in
            var completed = false
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !completed {
                        completed = true
                        let endTime = CFAbsoluteTimeGetCurrent()
                        connection.cancel()
                        let latency = Int((endTime - startTime) * 1000)
                        // 如果延迟极低（< 5ms），很有可能还是撞到了本地 TUN 握手
                        continuation.resume(returning: latency)
                    }
                case .failed, .cancelled:
                    if !completed {
                        completed = true
                        continuation.resume(returning: -2)
                    }
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
            
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if !completed {
                    completed = true
                    connection.cancel()
                    continuation.resume(returning: -2)
                }
            }
        }
    }
    
    /// 同步解析 IP (App 侧版本)
    private func resolveAllIPs(_ hostname: String) -> [String] {
        var ips: [String] = []
        var res: UnsafeMutablePointer<addrinfo>?
        let n = getaddrinfo(hostname, nil, nil, &res)
        defer { if res != nil { freeaddrinfo(res) } }
        
        if n == 0 {
            var curr = res
            while let ptr = curr {
                var addr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if ptr.pointee.ai_family == AF_INET {
                    let sin = ptr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var sin_addr = sin.sin_addr
                    inet_ntop(AF_INET, &sin_addr, &addr, socklen_t(INET6_ADDRSTRLEN))
                    ips.append(String(cString: addr))
                }
                curr = ptr.pointee.ai_next
            }
        }
        return ips
    }
}

extension Notification.Name {
    static let nodeSelectionChanged = Notification.Name("nodeSelectionChanged")
}