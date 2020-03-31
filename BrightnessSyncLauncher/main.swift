import Cocoa

let launcherURL = Bundle.main.bundleURL
let appURL = launcherURL.appendingPathComponent("../../../..").standardized

NSWorkspace.shared.launchApplication(appURL.path)
