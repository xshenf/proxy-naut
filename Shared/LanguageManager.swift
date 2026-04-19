import Foundation

enum AppLanguage: String, CaseIterable {
    case system = "system"
    case english = "en"
    case chinese = "zh-Hans"
    
    var displayName: String {
        switch self {
        case .system: return LocalizationManager.string("label.system")
        case .english: return "English"
        case .chinese: return "中文"
        }
    }
}

class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    
    @Published var currentLanguage: AppLanguage = .system
    
    private let languageKey = "app_language"
    
    private init() {
        if let saved = UserDefaults.standard.string(forKey: languageKey),
           let lang = AppLanguage(rawValue: saved) {
            currentLanguage = lang
        }
    }
    
    func setLanguage(_ language: AppLanguage) {
        currentLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: languageKey)
        
        NotificationCenter.default.post(name: .languageChanged, object: nil)
    }
}

extension Notification.Name {
    static let languageChanged = Notification.Name("languageChanged")
}