import Foundation

/// One executable is packaged as either the long-lived test app or the clean
/// production app. Only user data and caches are separated; heavyweight local
/// recognition engines are deliberately shared between both installations.
enum AppEnvironment {
    private static let productionValue = "production"
    private static let infoKey = "MeetingScribeDataEnvironment"
    static let startupErrorKey = "productionSeedStartupError"

    static let isProduction: Bool = {
        Bundle.main.object(forInfoDictionaryKey: infoKey) as? String == productionValue
    }()

    static var label: String { isProduction ? "正式环境" : "测试环境" }
    static var supportFolderName: String {
        isProduction ? "MeetingScribe-Production" : "MeetingScribe"
    }
    static var cacheFolderName: String {
        isProduction ? "MeetingScribe-Production" : "MeetingScribe"
    }

    static let applicationSupportBase = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let cachesBase = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask)[0]

    static var supportDirectory: URL {
        applicationSupportBase.appendingPathComponent(supportFolderName, isDirectory: true)
    }
    static var cacheDirectory: URL {
        cachesBase.appendingPathComponent(cacheFolderName, isDirectory: true)
    }
    /// Existing engines remain in the original directory so installing the
    /// production app does not duplicate several gigabytes of local models.
    static var sharedEngineDirectory: URL {
        applicationSupportBase.appendingPathComponent("MeetingScribe", isDirectory: true)
    }
    static var testSupportDirectory: URL {
        applicationSupportBase.appendingPathComponent("MeetingScribe", isDirectory: true)
    }

    /// Copy stable processing preferences once. Library navigation state,
    /// debug switches, backup destinations and usage figures intentionally
    /// start clean in production.
    static func bootstrapProductionDefaultsIfNeeded() {
        guard isProduction else { return }
        let destination = UserDefaults.standard
        let marker = "productionDefaultsSeeded.v1"
        guard !destination.bool(forKey: marker),
              let source = UserDefaults.standard.persistentDomain(
                forName: "com.meetingscribe.app") else { return }
        let copiedKeys = [
            "backend", "frameDensity", "transcriptionPerformance", "glossary",
            "minutesInstructions", "alwaysReviewIssues", "tokenWarningThreshold",
            "providerID", "providerBaseURL", "providerModel",
            "toolPath.whisper", "toolPath.claude", "toolPath.codex"
        ]
        for key in copiedKeys {
            if let value = source[key] { destination.set(value, forKey: key) }
        }
        destination.set(true, forKey: marker)
    }

    static func prepareForLaunch() {
        bootstrapProductionDefaultsIfNeeded()
        guard isProduction else { return }
        do {
            _ = try ProductionEnvironmentSeeder.seedIfNeeded()
            UserDefaults.standard.removeObject(forKey: startupErrorKey)
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: startupErrorKey)
        }
    }
}
