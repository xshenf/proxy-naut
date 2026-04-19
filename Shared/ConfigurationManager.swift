import Foundation

/// 桥接类：为了保持 Xcode 项目结构兼容，统一调用新的 Configuration.shared
class ConfigurationManager {
    static let shared = ConfigurationManager()
    private init() {}

    func save(_ config: AppConfiguration) {
        Configuration.shared.save(config)
    }

    func load() -> AppConfiguration {
        return Configuration.shared.load()
    }

    func clear() {
        // 统一清理
    }
}
