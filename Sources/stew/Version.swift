import Foundation
import StewCore

extension AppVersion {
    /// The version of this process: from the app bundle it runs in, else from the
    /// VERSION file of the source checkout it was built in.
    static var running: AppVersion {
        let executable = Paths.executable
        if let plist = infoPlistPath(forExecutable: executable),
           let data = FileManager.default.contents(atPath: plist),
           let version = AppVersion(infoPlist: data) {
            return version
        }
        var folder = (executable as NSString).deletingLastPathComponent
        while folder != "/" && !folder.isEmpty {
            let versionFile = folder + "/VERSION"
            if FileManager.default.fileExists(atPath: folder + "/Package.swift"),
               let data = FileManager.default.contents(atPath: versionFile) {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return AppVersion(version: text.isEmpty ? "0.0.0" : text, build: nil)
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return AppVersion(version: "0.0.0", build: nil)
    }

    /// The version of the app at `path`, or nil when there is none or it is unreadable.
    static func installed(at path: String) -> AppVersion? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist") else { return nil }
        return AppVersion(infoPlist: data)
    }
}
