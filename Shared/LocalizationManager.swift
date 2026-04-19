import Foundation

enum LocalizationManager {
    static func string(_ key: String) -> String {
        let language = LanguageManager.shared.currentLanguage
        var code = language.rawValue
        
        if language == .system {
            code = Bundle.main.preferredLocalizations.first ?? "en"
        }
        
        // 标准化语言代码，确保与 .lproj 目录名匹配
        let targetCode = code.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
        
        // 尝试从特定语言的 bundle 中加载
        if let path = Bundle.main.path(forResource: targetCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let localized = bundle.localizedString(forKey: key, value: "__NOT_FOUND__", table: nil)
            if localized != "__NOT_FOUND__" {
                return localized
            }
        }
        
        // 如果上面失败了，回退到主 Bundle 的本地化（可能受系统语言影响）
        return NSLocalizedString(key, comment: "")
    }
    
    static var tabProxy: String { string("tab.proxy") }
    static var tabSubscriptions: String { string("tab.subscriptions") }
    static var tabRules: String { string("tab.rules") }
    static var tabLogs: String { string("tab.logs") }
    static var tabSettings: String { string("tab.settings") }
    
    static var navProxyNodes: String { string("nav.proxy_nodes") }
    static var navSettings: String { string("nav.settings") }
    static var navRules: String { string("nav.rules") }
    static var navLogs: String { string("nav.logs") }
    static var navAddSubscription: String { string("nav.add_subscription") }
    static var navAddCustomProxy: String { string("nav.add_custom_proxy") }
    
    static var menuAddSubscription: String { string("menu.add_subscription") }
    static var menuAddCustomProxy: String { string("menu.add_custom_proxy") }
    static var menuRefreshAll: String { string("menu.refresh_all") }
    
    static var labelName: String { string("label.name") }
    static var labelURL: String { string("label.url") }
    static var labelProtocol: String { string("label.protocol") }
    static var labelServerAddress: String { string("label.server_address") }
    static var labelPort: String { string("label.port") }
    static var labelUUID: String { string("label.uuid") }
    static var labelPassword: String { string("label.password") }
    static var labelScanQRCode: String { string("label.scan_qr_code") }
    static var labelAutoUpdate: String { string("label.auto_update") }
    static var labelEnableAutoUpdate: String { string("label.enable_auto_update") }
    static var labelNetwork: String { string("label.network") }
    static var labelEnableTLS: String { string("label.enable_tls") }
    static var labelEnableMultiplex: String { string("label.enable_multiplex") }
    static var labelMode: String { string("label.mode") }
    static var labelDNSServers: String { string("label.dns_servers") }
    static var labelDoHURL: String { string("label.doh_url") }
    static var labelDNSOverHTTPS: String { string("label.dns_over_https") }
    static var labelBypassChinaIP: String { string("label.bypass_china_ip") }
    static var labelEnhancedAdBlocking: String { string("label.enhanced_ad_blocking") }
    static var labelForceDNSVPN: String { string("label.force_dns_vpn") }
    static var labelVersion: String { string("label.version") }
    static var labelPattern: String { string("label.pattern") }
    static var labelRuleType: String { string("label.rule_type") }
    static var labelAction: String { string("label.action") }
    static var labelTotalRules: String { string("label.total_rules") }
    static var labelLevel: String { string("label.level") }
    static var labelSearch: String { string("label.search") }
    static var labelHideDNS: String { string("label.hide_dns") }
    static var labelOnlyRouting: String { string("label.only_routing") }
    static var labelClearLogs: String { string("label.clear_logs") }
    static var labelExportLogs: String { string("label.export_logs") }
    static var labelAutoScroll: String { string("label.auto_scroll") }
    static var labelFilter: String { string("label.filter") }
    
    static var sectionSubscriptionInfo: String { string("section.subscription_info") }
    static var sectionInformation: String { string("section.information") }
    static var sectionAutoUpdate: String { string("section.auto_update") }
    static var sectionRoutingMode: String { string("section.routing_mode") }
    static var sectionAdvancedNetworking: String { string("section.advanced_networking") }
    static var sectionDNSSettings: String { string("section.dns_settings") }
    static var sectionRoutingData: String { string("section.routing_data") }
    static var sectionAbout: String { string("section.about") }
    static var sectionRuleSource: String { string("section.rule_source") }
    static var sectionSmartPackages: String { string("section.smart_packages") }
    static var sectionManualRules: String { string("section.manual_rules") }
    static var sectionLogLevel: String { string("section.log_level") }
    static var sectionCommonFilters: String { string("section.common_filters") }
    static var sectionRouteAction: String { string("section.route_action") }
    static var sectionImportLink: String { string("section.import_link") }
    static var sectionBasicConfig: String { string("section.basic_config") }
    static var sectionAuthentication: String { string("section.authentication") }
    static var sectionTransport: String { string("section.transport") }
    static var sectionRealityConfig: String { string("section.reality_config") }
    
    static var buttonCancel: String { string("button.cancel") }
    static var buttonAdd: String { string("button.add") }
    static var buttonSave: String { string("button.save") }
    static var buttonDelete: String { string("button.delete") }
    static var buttonParseLink: String { string("button.parse_link") }
    static var buttonRefreshAll: String { string("button.refresh_all") }
    static var buttonClearAll: String { string("button.clear_all") }
    static var buttonSaveNode: String { string("button.save_node") }
    
    static var emptyNoSubscription: String { string("empty.no_subscription") }
    static var emptyAddSubscription: String { string("empty.add_subscription") }
    static var emptySelectSubscription: String { string("empty.select_subscription") }
    static var emptyNoNodes: String { string("empty.no_nodes") }
    static var emptyNoRules: String { string("empty.no_rules") }
    static var emptyFetching: String { string("empty.fetching") }
    static var emptyNoLogs: String { string("empty.no_logs") }
    static var emptyNoLogsDesc: String { string("empty.no_logs_desc") }
    
    static var statUpload: String { string("stat.upload") }
    static var statDownload: String { string("stat.download") }
    static var statConnections: String { string("stat.connections") }
    static var statUploadSpeed: String { string("stat.upload_speed") }
    static var statDownloadSpeed: String { string("stat.download_speed") }
    
    static var routingRule: String { string("routing.rule") }
    static var routingGlobal: String { string("routing.global") }
    static var routingDirect: String { string("routing.direct") }
    static var routingRuleDesc: String { string("routing.rule_desc") }
    static var routingGlobalDesc: String { string("routing.global_desc") }
    static var routingDirectDesc: String { string("routing.direct_desc") }
    static var settingBypassDesc: String { string("setting.bypass_desc") }
    static var settingForceDNSDesc: String { string("setting.force_dns_desc") }
    static var rulesetBaseDesc: String { string("ruleset.base_desc") }
    
    static var levelAll: String { string("level.all") }
    static var levelInfo: String { string("level.info") }
    static var levelWarning: String { string("level.warning") }
    static var levelError: String { string("level.error") }
    static var routeAll: String { string("route.all") }
    static var routeDirect: String { string("route.direct") }
    static var routeProxy: String { string("route.proxy") }
    static var routeReject: String { string("route.reject") }
    
    static var errorSelectNodeFirst: String { string("error.select_node_first") }
    static var errorHTTPDisabled: String { string("error.http_disabled") }
    static var errorSOCKS5Disabled: String { string("error.socks5_disabled") }
    static var testing: String { string("testing") }
    static var testGoogleSuccess: String { string("test.google_success") }
    static var testGoogleFailed: String { string("test.google_failed") }
    
    static var linkGitHub: String { string("link.github") }
    static var linkPrivacyPolicy: String { string("link.privacy_policy") }
    
    static var sectionLanguage: String { string("section.language") }
    static var labelLanguage: String { string("label.language") }
    static var labelSystem: String { string("label.system") }
static var sectionOptions: String { string("section.options") }
    static var sectionPresetSubscriptions: String { string("section.preset_subscriptions") }
    static var sectionPopularSubscriptions: String { string("section.popular_subscriptions") }
    static var sectionCustomSubscription: String { string("section.custom_subscription") }
    static var navAddRule: String { string("nav.add_rule") }
    static var labelCustomRuleURL: String { string("label.custom_rule_url") }
    static var placeholderDomainIPCIDR: String { string("placeholder.domain_ip_cidr") }
    static var labelUpdateInterval: String { string("label.update_interval") }
    
    static var ruleTypeDomain: String { string("rule_type.domain") }
    static var ruleTypeDomainSuffix: String { string("rule_type.domain_suffix") }
    static var ruleTypeDomainKeyword: String { string("rule_type.domain_keyword") }
    static var ruleTypeIPCIDR: String { string("rule_type.ip_cidr") }
    static var ruleTypeGEOIP: String { string("rule_type.geoip") }
    static var ruleTypePort: String { string("rule_type.port") }
    static var actionDirect: String { string("action.direct") }
    static var actionProxy: String { string("action.proxy") }
    static var actionReject: String { string("action.reject") }
    static var labelDefault: String { string("label.default") }
    
    static var groupAutoSelect: String { string("group.auto_select") }
    static var groupFallback: String { string("group.fallback") }
    static var groupDefault: String { string("group.default") }
    
    static var filterHideTimeout: String { string("filter.hide_timeout") }
    static var emptyAllNodesTimeout: String { string("empty.all_nodes_timeout") }
    
    static var premiumNavTitle: String { string("premium.nav_title") }
    static var premiumTitle: String { string("premium.title") }
    static var premiumSubtitle: String { string("premium.subtitle") }
    static var premiumActive: String { string("premium.active") }
    static var premiumActiveDesc: String { string("premium.active_desc") }
    static var premiumTrialActive: String { string("premium.trial_active") }
    static var premiumTrialDays: String { string("premium.trial_days") }
    static var premiumExpired: String { string("premium.expired") }
    static var premiumExpiredDesc: String { string("premium.expired_desc") }
    static var premiumExpiredVPN: String { string("premium.expired_vpn") }
    static var premiumFeatures: String { string("premium.features") }
    static var premiumFeatureVPN: String { string("premium.feature_vpn") }

    static var premiumFeatureSecurity: String { string("premium.feature_security") }
    static var premiumFeatureUpdate: String { string("premium.feature_update") }
    static var premiumSubscribe: String { string("premium.subscribe") }
    static var premiumMonth: String { string("premium.month") }
    static var premiumLoadPrice: String { string("premium.load_price") }
    static var premiumTrialHint: String { string("premium.trial_hint") }
    static var premiumRestore: String { string("premium.restore") }
    static var premiumRestoreSuccess: String { string("premium.restore_success") }
    static var premiumRestoreNothing: String { string("premium.restore_nothing") }
    static var premiumRestoreFailedFormat: String { string("premium.restore_failed_format") }
    static var premiumManageSubscription: String { string("premium.manage_subscription") }
    static var premiumTerms: String { string("premium.terms") }
    static var premiumPrivacy: String { string("premium.privacy") }
    static var premiumDismissPaywall: String { string("premium.dismiss_paywall") }
    static var premiumAutoRenewNotice: String { string("premium.auto_renew_notice") }
    static var premiumLifetimeNotice: String { string("premium.lifetime_notice") }
    static var premiumVerificationFailed: String { string("premium.verification_failed") }
    static var premiumPurchasePending: String { string("premium.purchase_pending") }
    static var premiumExpiredDisconnected: String { string("premium.expired_disconnected") }
    static var premiumPricePeriodFormat: String { string("premium.price_period_format") }
    static var premiumPeriodDay: String { string("premium.period_day") }
    static var premiumPeriodWeek: String { string("premium.period_week") }
    static var premiumPeriodMonth: String { string("premium.period_month") }
    static var premiumPeriodYear: String { string("premium.period_year") }
    static var premiumPeriodValueFormat: String { string("premium.period_value_format") }
    static var premiumNotSubscribed: String { string("premium.not_subscribed") }
    static var premiumNotSubscribedDesc: String { string("premium.not_subscribed_desc") }
}