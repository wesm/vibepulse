import Foundation

enum AppInfo {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "VibePulse"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var gitHash: String {
        Bundle.main.object(forInfoDictionaryKey: "VPGitHash") as? String ?? "unknown"
    }

    static var currentYear: String {
        let year = Calendar.current.component(.year, from: Date())
        return String(year)
    }
}
