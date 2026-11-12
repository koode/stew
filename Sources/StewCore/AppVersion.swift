import Foundation

/// The version of a stew build: the marketing version from the repository's VERSION
/// file and the build number (the commit count when it was built).
public struct AppVersion: Equatable, Sendable, CustomStringConvertible {
    public var version: String
    /// Nil for a development build that is not inside Stew.app.
    public var build: Int?

    public init(version: String, build: Int?) {
        self.version = version
        self.build = build
    }

    /// Reads CFBundleShortVersionString and CFBundleVersion from an Info.plist.
    public init?(infoPlist data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty,
              let buildText = plist["CFBundleVersion"] as? String, let build = Int(buildText)
        else { return nil }
        self.init(version: version, build: build)
    }

    public var description: String {
        if let build { return "\(version) (build \(build))" }
        return "\(version) (development build, not in an app bundle)"
    }

    /// The Info.plist of the app that contains `executable`, when it sits at
    /// Name.app/Contents/MacOS/executable.
    public static func infoPlistPath(forExecutable executable: String) -> String? {
        let macOSFolder = (executable as NSString).deletingLastPathComponent
        let contents = (macOSFolder as NSString).deletingLastPathComponent
        guard (macOSFolder as NSString).lastPathComponent == "MacOS",
              (contents as NSString).lastPathComponent == "Contents",
              (contents as NSString).deletingLastPathComponent.hasSuffix(".app")
        else { return nil }
        return contents + "/Info.plist"
    }

    /// The app bundle that contains `executable`, if any.
    public static func appBundle(forExecutable executable: String) -> String? {
        guard let infoPlist = infoPlistPath(forExecutable: executable) else { return nil }
        return ((infoPlist as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }
}
