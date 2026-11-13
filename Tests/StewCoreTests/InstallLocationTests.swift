import Foundation
import Testing
@testable import StewCore

/// A file system of resolved paths: `links` maps a link to where it leads, `files` are
/// paths that exist as they are.
private struct FakeFiles {
    var directories: Set<String> = []
    var files: Set<String> = []
    var links: [String: String] = [:]

    func resolve(_ path: String) -> String? {
        if let target = links[path] { return resolve(target) }
        return files.contains(path) ? path : nil
    }
}

private let caskApp = "/Applications/Stew.app"
private let caskTool = "/Applications/Stew.app/Contents/MacOS/stew"

private func homebrewInstall(prefix: String = "/opt/homebrew") -> FakeFiles {
    FakeFiles(directories: [prefix + "/Caskroom/stew"], files: [caskTool], links: [prefix + "/bin/stew": caskTool])
}

private func isCask(_ files: FakeFiles, app: String = caskApp, prefixes: [String] = ["/opt/homebrew", "/usr/local"]) -> Bool {
    InstallLocation.isHomebrewCask(app: app, prefixes: prefixes, directoryExists: files.directories.contains, resolve: files.resolve)
}

@Suite struct InstallLocationTests {
    @Test func updatesTheAppThisBinaryRunsFrom() {
        #expect(InstallLocation.app(override: nil, runningExecutable: caskTool, home: "/Users/test") == caskApp)
        #expect(InstallLocation.app(override: nil, runningExecutable: "/Users/test/Applications/Stew.app/Contents/MacOS/stew", home: "/Users/test")
            == "/Users/test/Applications/Stew.app")
        #expect(InstallLocation.app(override: nil, runningExecutable: "/Volumes/Tools/Stew.app/Contents/MacOS/stew", home: "/Users/test")
            == "/Volumes/Tools/Stew.app")
    }

    @Test func aBinaryOutsideAnAppLooksInTheHomeApplicationsFolder() {
        #expect(InstallLocation.app(override: nil, runningExecutable: "/Users/test/stew/.build/debug/stew", home: "/Users/test")
            == "/Users/test/Applications/Stew.app")
    }

    @Test func theTestOverrideWins() {
        #expect(InstallLocation.app(override: "/tmp/x/Stew.app", runningExecutable: caskTool, home: "/Users/test") == "/tmp/x/Stew.app")
        #expect(InstallLocation.app(override: "", runningExecutable: caskTool, home: "/Users/test") == caskApp)
    }

    @Test func homebrewPrefixesPutHomebrewPrefixFirst() {
        #expect(InstallLocation.homebrewPrefixes(environment: [:]) == ["/opt/homebrew", "/usr/local"])
        #expect(InstallLocation.homebrewPrefixes(environment: ["HOMEBREW_PREFIX": "/usr/local/"]) == ["/usr/local", "/opt/homebrew"])
        #expect(InstallLocation.homebrewPrefixes(environment: ["HOMEBREW_PREFIX": "/tmp/brew"]) == ["/tmp/brew", "/opt/homebrew", "/usr/local"])
        #expect(InstallLocation.homebrewPrefixes(environment: ["HOMEBREW_PREFIX": "relative"]) == ["/opt/homebrew", "/usr/local"])
    }

    @Test func aCaskInstallHasTheCaskroomAndTheBinaryLink() {
        #expect(isCask(homebrewInstall()))
        #expect(isCask(homebrewInstall(prefix: "/usr/local")))
    }

    @Test func theCaskroomAloneIsNotEnough() {
        // An older copy from the script runs while the cask is installed too.
        var files = homebrewInstall()
        files.files.insert("/Users/test/Applications/Stew.app/Contents/MacOS/stew")
        #expect(!isCask(files, app: "/Users/test/Applications/Stew.app"))
    }

    @Test func aLinkWithoutTheCaskroomIsNotACask() {
        var files = homebrewInstall()
        files.directories = []
        #expect(!isCask(files))
    }

    @Test func theLinkAndCaskroomMustShareAPrefix() {
        var files = homebrewInstall()
        files.directories = ["/usr/local/Caskroom/stew"]
        #expect(!isCask(files))
    }

    @Test func aCaskInstalledInAnotherAppFolderStillCounts() {
        // brew install --cask --appdir=~/Applications stew
        let app = "/Users/test/Applications/Stew.app"
        let tool = app + "/Contents/MacOS/stew"
        let files = FakeFiles(directories: ["/opt/homebrew/Caskroom/stew"], files: [tool], links: ["/opt/homebrew/bin/stew": tool])
        #expect(isCask(files, app: app))
    }

    @Test func aMissingAppIsNotACask() {
        var files = homebrewInstall()
        files.files = []
        #expect(!isCask(files))
    }
}

@Suite struct UpdateRouteTests {
    @Test func aWritableAppUpdatesInPlace() {
        #expect(UpdateRoute.choose(app: caskApp, appWritable: true, folderWritable: true, homebrewCask: true) == .inPlace)
        #expect(UpdateRoute.choose(app: caskApp, appWritable: true, folderWritable: true, homebrewCask: false) == .inPlace)
        #expect(UpdateRoute.inPlace.note == nil)
    }

    @Test func aReadOnlyCaskInstallPointsAtBrewUpgrade() {
        let route = UpdateRoute.choose(app: caskApp, appWritable: true, folderWritable: false, homebrewCask: true)
        #expect(route == .homebrew)
        #expect(route.note?.hasSuffix("brew upgrade --cask stew") == true)
        #expect(UpdateRoute.choose(app: caskApp, appWritable: false, folderWritable: true, homebrewCask: true) == .homebrew)
    }

    @Test func aReadOnlyFolderWithoutHomebrewNamesTheFolder() {
        let route = UpdateRoute.choose(app: caskApp, appWritable: true, folderWritable: false, homebrewCask: false)
        #expect(route == .notWritable(folder: "/Applications"))
        #expect(route.note?.contains("in /Applications, because this user cannot write there") == true)
    }
}

@Suite struct LaunchAgentPlistTests {
    @Test func runsTheDaemonFromTheGivenTool() throws {
        let data = try LaunchAgentPlist.data(label: "nl.koode.stew", executable: caskTool, logPath: "/Users/test/Library/Logs/stew.log")
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "nl.koode.stew")
        #expect(plist["ProgramArguments"] as? [String] == [caskTool, "daemon"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(plist["StandardOutPath"] as? String == "/Users/test/Library/Logs/stew.log")
        #expect(plist["StandardErrorPath"] as? String == "/Users/test/Library/Logs/stew.log")
    }
}

@Suite struct CommandLinkPlanTests {
    @Test func scriptInstallsGetALink() {
        #expect(CommandLinkPlan.choose(existing: nil, tool: caskTool, homebrewProvidesCommand: false) == .create)
        #expect(CommandLinkPlan.choose(existing: caskTool, tool: caskTool, homebrewProvidesCommand: false) == .keep)
    }

    @Test func homebrewInstallsGetNoNewLink() {
        #expect(CommandLinkPlan.choose(existing: nil, tool: caskTool, homebrewProvidesCommand: true) == .none)
        #expect(CommandLinkPlan.choose(existing: caskTool, tool: caskTool, homebrewProvidesCommand: true) == .keep)
    }

    @Test func anOldBinaryOrAnotherCopyIsReplaced() {
        // A plain binary resolves to itself; a link to an older copy resolves into that app.
        for homebrew in [false, true] {
            #expect(CommandLinkPlan.choose(existing: "/Users/test/.local/bin/stew", tool: caskTool, homebrewProvidesCommand: homebrew) == .replace)
            #expect(CommandLinkPlan.choose(existing: "/Users/test/Applications/Stew.app/Contents/MacOS/stew", tool: caskTool, homebrewProvidesCommand: homebrew) == .replace)
            #expect(CommandLinkPlan.choose(existing: "", tool: caskTool, homebrewProvidesCommand: homebrew) == .replace)
        }
    }
}
