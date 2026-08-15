import Foundation

enum AppPreferences {
    static let compactStatusItemKey = "compactStatusItem"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [compactStatusItemKey: true])
    }
}
