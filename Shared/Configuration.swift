import Foundation
import Combine

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

struct GroupConfig: Codable {
    var name: String
    var type: String // url-test, fallback, selector
    var nodeIDs: [String]
    var testURL: String?
    var interval: Int?
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
    var selectedGroupID: String?
    var isGroupMode: Bool = false
    var httpConfig: HTTPProxyConfig?
    var socks5Config: SOCKS5Config?
    var shadowsocksConfig: ShadowsocksConfig?
    var vmessConfig: VMessConfig?
    var trojanConfig: TrojanConfig?
    var listenAddress: String = "127.0.0.1"
    var listenPort: UInt16 = 1081
    var enableRouting: Bool = true
    // "Rule" / "Global" / "Direct"；保留 enableRouting 是为了读取旧的 JSON 不丢失
    var routingMode: String = "Rule"
    var useBuiltInRules: Bool = true
    var rules: [ProxyRule] = []
    var subscriptionRules: [ProxyRule]?
    var baseRules: [ProxyRule] = []
    var dnsConfig: DNSConfig?
    var networkConfig: NetworkConfig?
    var logLevel: LogLevel = .warning
    var maxRuleCount: Int = 10000
    
    init(selectedProtocol: ProxyProtocol? = nil, listenPort: UInt16 = 1081, useBuiltInRules: Bool = true, rules: [ProxyRule] = [], baseRules: [ProxyRule] = [], logLevel: LogLevel = .warning, maxRuleCount: Int = 10000) {
        self.selectedProtocol = selectedProtocol
        self.listenPort = listenPort
        self.useBuiltInRules = useBuiltInRules
        self.rules = rules
        self.baseRules = baseRules
        self.logLevel = logLevel
        self.maxRuleCount = maxRuleCount
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
    enum RuleType: String, Codable, CaseIterable {
        case domain, domainSuffix, domainKeyword, geosite, ipCIDR, geoip, port, final
    }
    enum RuleAction: String, Codable, CaseIterable {
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
    private var cachedFileHandle: FileHandle?
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
        NSLog("[\(level.rawValue.uppercased())]\(source != nil ? " [\(source!)]" : "") \(message)")
    }
    private var logFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?.appendingPathComponent("app_logs.jsonl")
    }
    private func obtainFileHandle() -> FileHandle? {
        if let handle = cachedFileHandle { return handle }
        guard let url = logFileURL else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        cachedFileHandle = handle
        return handle
    }
    private func saveLogToFile(_ entry: LogEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        var line = data; line.append("\n".data(using: String.Encoding.utf8)!)
        guard let handle = obtainFileHandle() else { return }
        handle.write(line)
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
                // 将 Extension 进程写入的新日志转发到主 App 进程的 NSLog，使其显示在 Xcode 控制台
                for log in newLogs {
                    NSLog("[%@]%@ %@", log.level.rawValue.uppercased(), log.source != nil ? " [\(log.source!)]" : "", log.message)
                }

                self.logs.append(contentsOf: newLogs)
                // 全量按时间戳排序，修复跨进程日志交错
                self.logs.sort { $0.timestamp < $1.timestamp }

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
        cachedFileHandle?.closeFile()
        cachedFileHandle = nil
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }
}
