import Cocoa

let launcherURL = Bundle.main.bundleURL
let appURL = launcherURL.appendingPathComponent("../../../..").standardized

if NSRunningApplication.runningApplications(withBundleIdentifier: "dev.vandijk.Brightness-Sync").isEmpty {
    NSWorkspace.shared.launchApplication(appURL.path)
}
