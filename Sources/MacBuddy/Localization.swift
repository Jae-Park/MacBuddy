import Foundation

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("MacBuddy.appLanguageDidChange")
}

enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case korean
    case english

    private static let defaultsKey = "appLanguage"

    static var selected: AppLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
              let language = AppLanguage(rawValue: rawValue)
        else { return .system }
        return language
    }

    var effective: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("ko") ? .korean : .english
    }

    var menuTitle: String {
        switch self {
        case .system: tr("System Default", "시스템 기본값")
        case .korean: "한국어"
        case .english: "English"
        }
    }

    func select() {
        guard self != Self.selected else { return }
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .appLanguageDidChange, object: self)
    }
}

func tr(_ english: String, _ korean: String) -> String {
    AppLanguage.selected.effective == .korean ? korean : english
}
