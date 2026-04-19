import Foundation
import Combine

// MARK: - Rule Subscription Model

struct RuleSubscription: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var enabled: Bool = true
    var lastUpdate: Date?
    var ruleCount: Int = 0
    var autoUpdate: Bool = true
    var updateInterval: UpdateInterval = .daily

    enum UpdateInterval: String, Codable, CaseIterable {
        case manual = "Manual"
        case hourly = "Hourly"
        case daily = "Daily"
        case weekly = "Weekly"

        var seconds: TimeInterval? {
            switch self {
            case .manual: return nil
            case .hourly: return 3600
            case .daily: return 86400
            case .weekly: return 7 * 86400
            }
        }
    }

    /// 是否该自动刷新：已启用、开启自动更新、间隔不是 manual、且距上次更新已超过间隔
    func shouldAutoRefresh(now: Date = Date()) -> Bool {
        guard enabled, autoUpdate, let interval = updateInterval.seconds else { return false }
        guard let last = lastUpdate else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    var statusText: String {
        guard let lastUpdate = lastUpdate else { return LocalizationManager.string("rule.never_updated") }
        let formatter = RelativeDateTimeFormatter()
        let language = LanguageManager.shared.currentLanguage
        let code = language == .system ? (Bundle.main.preferredLocalizations.first ?? "en") : language.rawValue
        formatter.locale = Locale(identifier: code)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastUpdate, relativeTo: Date())
    }
}

// MARK: - Rule Format

enum RuleFormat: String, Codable {
    case clash = "Clash YAML"
    case adguard = "AdGuard / EasyList"
    case hosts = "HOSTS"
    case singbox = "sing-box"
    case auto = "Auto Detect"
}

// MARK: - Rule Subscription Manager

@MainActor
class RuleSubscriptionManager: ObservableObject {
    static let shared = RuleSubscriptionManager()

    @Published var subscriptions: [RuleSubscription] = []
    @Published var allRules: [ProxyRule] = []
    @Published var isLoading = false

    /// 每个订阅ID对应其解析出的规则
    private var subscriptionRules: [UUID: [ProxyRule]] = [:]
    private let appGroupId = "group.com.proxynaut"
    private var userDefaults: UserDefaults {
        return UserDefaults(suiteName: appGroupId) ?? .standard
    }
    private let subscriptionsKey = "ruleSubscriptions"
    private let subscriptionRulesKey = "subscriptionRulesCache"
    private let queue = DispatchQueue(label: "com.proxynaut.rulesubmanager", qos: .background)

    private init() {
        // --- 强制清理阶段：移除已存在的超大 UserDefaults 数据（迁移到文件存储后的清理） ---
        userDefaults.removeObject(forKey: subscriptionRulesKey)
        userDefaults.removeObject(forKey: "cachedRuleSubscriptions")
        userDefaults.synchronize() // 强制同步以清理磁盘配额
        
        loadSubscriptions()
        loadSubscriptionRulesCache()
        loadAllRules()
    }

    // MARK: - Subscription CRUD

    func addSubscription(_ subscription: RuleSubscription) {
        subscriptions.append(subscription)
        saveSubscriptions()
        if subscription.enabled {
            Task {
                await fetchAndUpdate(subscription)
            }
        }
    }

    func removeSubscription(_ subscription: RuleSubscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        saveSubscriptions()
        reloadAllRules()
    }

    func toggleEnabled(_ subscription: RuleSubscription) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index].enabled.toggle()
            saveSubscriptions()
            reloadAllRules()
        }
    }

    func updateSubscription(_ subscription: RuleSubscription) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = subscription
            saveSubscriptions()
        }
    }

    // MARK: - Fetch & Parse

    func fetchAll() async {
        await MainActor.run { isLoading = true }

        for subscription in subscriptions where subscription.enabled {
            await fetchAndUpdate(subscription)
        }

        reloadAllRules()

        await MainActor.run { isLoading = false }
    }

    /// 根据每个订阅的 autoUpdate/updateInterval/lastUpdate 判断是否需要刷新
    /// App 启动、进入前台、以及前台周期性 Timer 都会调用此方法
    /// force=true 时忽略时间窗口，刷新所有 enabled && autoUpdate 的订阅
    func refreshIfNeeded(force: Bool = false) async {
        let now = Date()
        let due = subscriptions.filter { sub in
            force ? (sub.enabled && sub.autoUpdate) : sub.shouldAutoRefresh(now: now)
        }
        guard !due.isEmpty else { return }
        LogManager.shared.log("Auto-refreshing \(due.count) rule subscription(s) (force=\(force))", level: .info, source: "RuleSub")
        for sub in due {
            await fetchAndUpdate(sub)
        }
        reloadAllRules()
    }

    func fetchAndUpdate(_ subscription: RuleSubscription) async {
        guard let url = URL(string: subscription.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            LogManager.shared.log("Invalid rule subscription URL: \(subscription.name)", level: .error, source: "RuleSub")
            return
        }

        LogManager.shared.log("Fetching rules: \(subscription.name)", level: .info, source: "RuleSub")

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, application/yaml, application/json, */*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            // 探测默认 Action
            var defaultAction: ProxyRule.RuleAction = .reject
            let lowerName = subscription.name.lowercased()
            let lowerUrl = subscription.url.lowercased()
            
            if lowerName.contains("direct") || lowerName.contains("直连") || lowerUrl.contains("direct") {
                defaultAction = .direct
            } else if lowerName.contains("gfw") || lowerName.contains("proxy") || lowerName.contains("代理") || lowerUrl.contains("gfw") || lowerUrl.contains("proxy") {
                defaultAction = .proxy
            }

            let rules = parseRules(data: data, format: .auto, defaultAction: defaultAction)

            await MainActor.run {
                // 保存解析后的规则到内存缓存
                subscriptionRules[subscription.id] = rules

                if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                    subscriptions[index].ruleCount = rules.count
                    subscriptions[index].lastUpdate = Date()
                    saveSubscriptions()
                }

                // 持久化订阅规则并重新聚合
                saveSubscriptionRulesCache()
                reloadAllRules()
            }

            LogManager.shared.log("Fetched \(rules.count) rules from: \(subscription.name)", level: .info, source: "RuleSub")

        } catch {
            LogManager.shared.log("Failed to fetch \(subscription.name): \(error.localizedDescription)", level: .error, source: "RuleSub")
        }
    }

    // MARK: - Rule Parsing

    func parseRules(data: Data, format: RuleFormat, defaultAction: ProxyRule.RuleAction = .reject) -> [ProxyRule] {
        guard let content = String(data: data, encoding: .utf8) else { return [] }

        switch format {
        case .clash:
            return parseClashRules(content, defaultAction: defaultAction)
        case .adguard:
            return parseAdGuardRules(content, defaultAction: defaultAction)
        case .hosts:
            return parseHostsRules(content)
        case .singbox:
            return parseSingBoxRules(content)
        case .auto:
            // Try to auto-detect format
            if content.lowercased().contains("payload:") || content.contains("RULE-SET") {
                return parseClashRules(content, defaultAction: defaultAction)
            } else if content.contains("||") || content.hasPrefix("!") {
                return parseAdGuardRules(content, defaultAction: defaultAction)
            } else if content.hasPrefix("127.0.0.1") || content.hasPrefix("0.0.0.0") {
                return parseHostsRules(content)
            } else {
                // Try all formats including plain list
                var rules = parseClashRules(content, defaultAction: defaultAction)
                if rules.isEmpty { rules = parseAdGuardRules(content, defaultAction: defaultAction) }
                if rules.isEmpty { rules = parseHostsRules(content) }
                if rules.isEmpty { rules = parsePlainList(content, defaultAction: defaultAction) }
                return rules
            }
        }
    }

    private func parseClashRules(_ content: String, defaultAction: ProxyRule.RuleAction = .reject) -> [ProxyRule] {
        var rules: [ProxyRule] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            // 跳过注释、空行、yaml头部
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed != "payload:" else { continue }

            // 处理 YAML 列表符号 "- "
            if trimmed.hasPrefix("-") {
                trimmed = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            }

            // Parse: TYPE,PATTERN,ACTION (optional)
            let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

            if parts.count >= 2 {
                let typeStr = parts[0].uppercased()
                let pattern = parts[1]
                let action = parts.count >= 3 ? parseClashAction(parts[2]) : defaultAction

                if let type = mapClashType(typeStr) {
                    rules.append(ProxyRule(type: type, pattern: pattern, action: action))
                }
            } else if parts.count == 1 && !trimmed.contains(":") {
                // 如果只有一项且不是键值对，尝试作为纯域名处理
                rules.append(ProxyRule(type: .domain, pattern: trimmed, action: defaultAction))
            }
        }

        return rules
    }

    private func mapClashType(_ type: String) -> ProxyRule.RuleType? {
        switch type {
        case "DOMAIN": return .domain
        case "DOMAIN-SUFFIX": return .domainSuffix
        case "DOMAIN-KEYWORD": return .domainKeyword
        case "IP-CIDR", "IP-CIDR6": return .ipCIDR
        case "GEOIP": return .geoip
        case "PORT": return .port
        case "MATCH": return .final
        default: return nil
        }
    }

    private func parseAdGuardRules(_ content: String, defaultAction: ProxyRule.RuleAction = .reject) -> [ProxyRule] {
        var rules: [ProxyRule] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("!"), !trimmed.hasPrefix("[") else { continue }

            // ||domain^ => domain reject
            if trimmed.hasPrefix("||") {
                let domain = trimmed
                    .replacingOccurrences(of: "||", with: "")
                    .replacingOccurrences(of: "^", with: "")
                    .replacingOccurrences(of: "$third-party", with: "")
                    .replacingOccurrences(of: "$all", with: "")
                    .trimmingCharacters(in: .whitespaces)

                if !domain.isEmpty {
                    if domain.contains("*") || domain.contains("?") {
                        // Wildcard => keyword match
                        let cleanDomain = domain.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
                        if !cleanDomain.isEmpty {
                            rules.append(ProxyRule(type: .domainKeyword, pattern: cleanDomain, action: defaultAction))
                        }
                    } else if domain.hasPrefix(".") {
                        // .domain => suffix match
                        rules.append(ProxyRule(type: .domainSuffix, pattern: String(domain.dropFirst()), action: defaultAction))
                    } else {
                        rules.append(ProxyRule(type: .domain, pattern: domain, action: defaultAction))
                    }
                }
            }
            // @@ => whitelist (skip for now, handled separately)
            // ### => element rule (skip, not applicable)
        }

        return rules
    }

    private func parsePlainList(_ content: String, defaultAction: ProxyRule.RuleAction) -> [ProxyRule] {
        var rules: [ProxyRule] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("/") && !trimmed.contains(" ") else { continue }

            // .google.com => domainSuffix
            if trimmed.hasPrefix(".") {
                rules.append(ProxyRule(type: .domainSuffix, pattern: String(trimmed.dropFirst()), action: defaultAction))
            } else if trimmed.contains("/") && (trimmed.contains(".") || trimmed.contains(":")) {
                // x.x.x.x/x => ipCIDR
                rules.append(ProxyRule(type: .ipCIDR, pattern: trimmed, action: defaultAction))
            } else if trimmed.contains(".") {
                // google.com => domain
                rules.append(ProxyRule(type: .domain, pattern: trimmed, action: defaultAction))
            }
        }
        return rules
    }

    private func parseHostsRules(_ content: String) -> [ProxyRule] {
        var rules: [ProxyRule] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0) }
            if parts.count >= 2 {
                let ip = parts[0]
                let domain = parts[1]

                // Only block rules (0.0.0.0 or 127.0.0.1)
                if (ip == "0.0.0.0" || ip == "127.0.0.1") && domain != "localhost" && !domain.hasPrefix("broadcasthost") {
                    rules.append(ProxyRule(type: .domain, pattern: domain, action: .reject))
                }
            }
        }

        return rules
    }

    private func parseSingBoxRules(_ content: String) -> [ProxyRule] {
        var rules: [ProxyRule] = []

        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ruleSets = json["rules"] as? [[String: Any]] else {
            return rules
        }

        for ruleSet in ruleSets {
            let actionStr = (ruleSet["outbound"] as? String ?? "").lowercased()
            let action: ProxyRule.RuleAction = actionStr == "direct" ? .direct :
                                               actionStr == "block" ? .reject : .proxy

            if let domains = ruleSet["domain"] as? [String] {
                for domain in domains {
                    rules.append(ProxyRule(type: .domain, pattern: domain, action: action))
                }
            }

            if let domainSuffixes = ruleSet["domain_suffix"] as? [String] {
                for suffix in domainSuffixes {
                    rules.append(ProxyRule(type: .domainSuffix, pattern: suffix, action: action))
                }
            }

            if let domainKeywords = ruleSet["domain_keyword"] as? [String] {
                for keyword in domainKeywords {
                    rules.append(ProxyRule(type: .domainKeyword, pattern: keyword, action: action))
                }
            }

            if let ipCIDRs = ruleSet["ip_cidr"] as? [String] {
                for cidr in ipCIDRs {
                    rules.append(ProxyRule(type: .ipCIDR, pattern: cidr, action: action))
                }
            }
        }

        return rules
    }

    // MARK: - Helper

    private func parseClashAction(_ actionStr: String) -> ProxyRule.RuleAction {
        let lower = actionStr.lowercased().trimmingCharacters(in: .whitespaces)
        // 增加对常见中文字符的兼容
        if lower.contains("direct") || lower.contains("直连") {
            return .direct
        } else if lower.contains("reject") || lower.contains("拦截") || lower.contains("block") {
            return .reject
        } else {
            // 默认走代理
            return .proxy
        }
    }

    // MARK: - Rule Aggregation

    private func loadAllRules() {
        // Load manually added rules from configuration
        let config = Configuration.shared.load()
        let manualRules = config.rules

        let currentSubRules = subscriptionRules
        let currentSubs = subscriptions
        
        queue.async {
            // 聚合已启用的订阅规则
            var mergedRules = manualRules
            var subCount = 0
            let limit = config.maxRuleCount > 0 ? config.maxRuleCount : 10000
            
            for sub in currentSubs where sub.enabled {
                if let rules = currentSubRules[sub.id] {
                    let availableSpace = limit - mergedRules.count
                    if availableSpace <= 0 {
                        LogManager.shared.log("[RuleSub] Max rule limit reached (\(limit)). Skipping further rules.", level: .warning, source: "RuleSub")
                        break
                    }
                    
                    if rules.count > availableSpace {
                        mergedRules.append(contentsOf: rules.prefix(availableSpace))
                        LogManager.shared.log("[RuleSub] Partially added \(availableSpace) rules from \(sub.name) (limit reached).", level: .warning, source: "RuleSub")
                    } else {
                        mergedRules.append(contentsOf: rules)
                    }
                    subCount += 1
                }
            }
            
            DispatchQueue.main.async {
                self.allRules = mergedRules
            }
            LogManager.shared.log("[RuleSub] Loaded \(manualRules.count) manual + \(mergedRules.count - manualRules.count) subscription rules (from \(subCount) subs) = \(mergedRules.count) total (Limit: \(limit))", level: .info, source: "RuleSub")
        }
    }

    func reloadAllRules() {
        queue.async {
            let config = Configuration.shared.load()
            let manualRules = config.rules
            let limit = config.maxRuleCount > 0 ? config.maxRuleCount : 10000

            // 聚合已启用的订阅规则
            var mergedRules = manualRules
            for sub in self.subscriptions where sub.enabled {
                if let rules = self.subscriptionRules[sub.id] {
                    let availableSpace = limit - mergedRules.count
                    if availableSpace <= 0 { break }
                    
                    if rules.count > availableSpace {
                        mergedRules.append(contentsOf: rules.prefix(availableSpace))
                    } else {
                        mergedRules.append(contentsOf: rules)
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.allRules = mergedRules
            }

            // Cache all rules to App Group for the extension to access
            self.cacheRulesForExtension(mergedRules)

            RuleEngine.shared.loadRules(mergedRules)
            LogManager.shared.log("RuleEngine reloaded with \(mergedRules.count) total rules (Limit: \(limit))", level: .info, source: "RuleSub")
        }
    }

    /// Cache rules to App Group container so the Network Extension can access them
    private func cacheRulesForExtension(_ rules: [ProxyRule]) {
        let appGroupId = "group.com.proxynaut"
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            LogManager.shared.log("Cannot access App Group container for rule caching", level: .error, source: "RuleSub")
            return
        }

        // Save as JSON for the extension to read
        let rulesURL = containerURL.appendingPathComponent("cached_rules.json")
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: rulesURL)
        }

        // 彻底移除 UserDefaults 存储 large data 的逻辑，只保留文件路径
        LogManager.shared.log("Cached \(rules.count) rules to file: \(rulesURL.lastPathComponent)", level: .info, source: "RuleSub")
    }

    // MARK: - Persistence

    private func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            userDefaults.set(data, forKey: subscriptionsKey)
        }
    }

    private func loadSubscriptions() {
        guard let data = userDefaults.data(forKey: subscriptionsKey),
              let subs = try? JSONDecoder().decode([RuleSubscription].self, from: data) else {
            // Start with an empty list instead of presets
            subscriptions = []
            return
        }
        subscriptions = subs
    }

    // MARK: - Persistence (File based for large data)

    private var rulesCacheURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent("subscription_rules_cache.json")
    }

    private func saveSubscriptionRulesCache() {
        var stringKeyed: [String: [ProxyRule]] = [:]
        for (key, value) in subscriptionRules {
            stringKeyed[key.uuidString] = value
        }
        
        guard let url = rulesCacheURL else { return }
        
        queue.async {
            if let data = try? JSONEncoder().encode(stringKeyed) {
                try? data.write(to: url)
            }
            
            // 清理旧的 UserDefaults 冗余数据，避免 4MB 限制报错
            self.userDefaults.removeObject(forKey: self.subscriptionRulesKey)
            self.userDefaults.removeObject(forKey: "cachedRuleSubscriptions")
        }
    }

    private func loadSubscriptionRulesCache() {
        guard let url = rulesCacheURL, FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let stringKeyed = try? JSONDecoder().decode([String: [ProxyRule]].self, from: data) else {
            // 如果文件不存在，尝试从旧的 UserDefaults 迁移一次（可选），或者直接返回
            return
        }
        
        subscriptionRules = [:]
        for (key, value) in stringKeyed {
            if let uuid = UUID(uuidString: key) {
                subscriptionRules[uuid] = value
            }
        }
    }

    // MARK: - Default Presets

    static let defaultPresets: [RuleSubscription] = []
}
