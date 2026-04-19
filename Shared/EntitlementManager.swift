import Foundation
import Combine

/// ProxyNaut Pro 权益定义
public enum ProFeature: String, CaseIterable {
    case iCloudSync = "icloud_sync"
    case advancedAnalytics = "advanced_analytics"
    case backgroundAutoUpdate = "background_auto_update"
    case customRuleSets = "custom_rule_sets"
    case privacyEnhancement = "privacy_enhancement"
}

/// App Group 存储键——App / Extension 共享访问，不依赖 MainActor 隔离。
///
/// 过期判定策略：App 在刷新时写入订阅最远过期时间 + 是否拥有终身购买。
/// Extension 启动时自己用 Date 比较决定是否放行，不依赖 App 主动唤醒。
/// 这样即使用户长期不打开 App，过期后 Extension 也会立刻拒绝启动。
public enum EntitlementStorage {
    public static let appGroupSuiteName = "group.com.proxynaut"
    public static let proStatusKey = "com.proxynaut.entitlements.isPro"
    public static let everPurchasedKey = "com.proxynaut.entitlements.everPurchased"
    public static let hasLifetimeKey = "com.proxynaut.entitlements.hasLifetime"
    public static let subscriptionExpirationDateKey = "com.proxynaut.entitlements.subscriptionExpirationDate"
    public static let lastVerifiedAtKey = "com.proxynaut.entitlements.lastVerifiedAt"

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
    }

    /// 仅读取原始 isPro 缓存，不做过期检查。用于 UI 场景。
    public static func readCachedProStatus() -> Bool {
        return true
    }

    public static func readHasLifetime() -> Bool {
        return true
    }

    public static func readSubscriptionExpirationDate() -> Date? {
        return nil
    }

    /// Extension 使用的最终门禁判定。
    public static func isEffectivelyPro(now: Date = Date()) -> Bool {
        return true
    }
}

/// 权限管理器：作为全应用订阅状态的 Source of Truth
@MainActor
public class EntitlementManager: ObservableObject {
    public static let shared = EntitlementManager()

    @Published public private(set) var isPro: Bool = true
    @Published public private(set) var activeFeatures: Set<ProFeature> = Set(ProFeature.allCases)

    private let userDefaults = UserDefaults(suiteName: EntitlementStorage.appGroupSuiteName) ?? UserDefaults.standard

    /// 是否曾经有过成功订阅/购买（用于区分 "从未订阅" 与 "已过期"）
    public var hasEverPurchased: Bool {
        return true
    }

    /// 是否拥有终身购买
    public var hasLifetime: Bool {
        return true
    }

    /// 订阅最远过期时间；lifetime 或无订阅时为 nil
    public var subscriptionExpirationDate: Date? {
        return nil
    }

    private init() {
        // 初始加载本地缓存的状态
        self.isPro = true
        updateFeatures()
    }

    /// 更新订阅、终身购买、过期时间等全部字段。
    public func updateEntitlement(isPro: Bool, hasLifetime: Bool, subscriptionExpirationDate: Date?) {
        // No-op since we are now free
    }

    /// 便捷 wrapper：仅更新 isPro，不改变过期/终身字段。保留给少数特殊路径使用。
    public func updateProStatus(_ status: Bool) {
        // No-op
    }

    /// 检查特定功能是否可用
    public func hasFeature(_ feature: ProFeature) -> Bool {
        return true
    }

    private func updateFeatures() {
        activeFeatures = Set(ProFeature.allCases)
    }
}

extension NSNotification.Name {
    static let proStatusChanged = NSNotification.Name("com.proxynaut.proStatusChanged")
}
