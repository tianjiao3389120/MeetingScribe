import Foundation

/// Shared on-disk locations for the app.
/// Development builds use a separate namespace so they can run next to a
/// release build without reading or modifying the release library.
enum AppDirectories {
    private static let applicationSupportBase = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]

    private static var namespace: String {
        Bundle.main.bundleIdentifier == "com.meetingscribe.dev"
            ? "MeetingScribe-Dev"
            : "MeetingScribe"
    }

    static let applicationSupport = applicationSupportBase
        .appendingPathComponent(namespace, isDirectory: true)
    static let caches = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(namespace, isDirectory: true)
}
