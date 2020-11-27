import Cocoa
import Combine
import os
import ServiceManagement
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Menu / App

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statusIndicator = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")

    let pauseButton = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")

    let monitorOffsets = MonitorOffsets()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "StatusBarButtonImage")
        }

        let menu = NSMenu()
        menu.addItem(statusIndicator)
        menu.addItem(pauseButton)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Brightness Offset:", action: nil, keyEquivalent: ""))
        let slidersItem = NSMenuItem()
        let slidersView = NSHostingView(rootView: SlidersView(monitorPublisher: displaysPublisher.map { $0.targets }.eraseToAnyPublisher()).environmentObject(monitorOffsets))
        slidersView.translatesAutoresizingMaskIntoConstraints = false
        slidersView.widthAnchor.constraint(equalToConstant: 250).isActive = true
        slidersView.layoutSubtreeIfNeeded()
        slidersItem.view = slidersView
        menu.addItem(slidersItem)
        menu.addItem(NSMenuItem(title: "Reset", action: #selector(brightnessOffsetReset), keyEquivalent: ""))
        lockOffsetMenuItem.state = lockOffset ? .on : .off
        menu.addItem(lockOffsetMenuItem)
        menu.addItem(NSMenuItem.separator())

        let launchAtLoginEnabled = (SMJobCopyDictionary(kSMDomainUserLaunchd, Self.launcherId)?.takeRetainedValue() as NSDictionary?)?["OnDemand"] as? Bool ?? false
        launchAtLoginMenuItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(NSMenuItem.separator())

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        menu.addItem(NSMenuItem(title: "v\(appVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check For Updates", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let copyDiagnosticsButton = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnosticsToPasteboard), keyEquivalent: "c")
        copyDiagnosticsButton.isHidden = true
        copyDiagnosticsButton.allowsKeyEquivalentWhenHidden = true
        menu.addItem(copyDiagnosticsButton)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: ""))
        statusItem.menu = menu

        setup()
        setupDisplayMonitor()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    let pausedPublisher = CurrentValueSubject<Bool, Never>(false)
    @objc func togglePause() {
        pausedPublisher.send(!pausedPublisher.value)
        pauseButton.title = pausedPublisher.value ? "Resume" : "Pause"
    }

    @objc func brightnessOffsetReset() {
        UserDefaults.standard
            .dictionaryRepresentation()
            .keys
            .filter { $0.starts(with: "BSBrightnessOffset_") }
            .forEach { key in
                UserDefaults.standard.removeObject(forKey: key)
            }
    }

    var lockOffset: Bool {
        get {
            UserDefaults.standard.object(forKey: "BSLockBrightness") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "BSLockBrightness")
        }
    }

    let lockOffsetMenuItem = NSMenuItem(title: "Lock", action: #selector(toggleLockOffset), keyEquivalent: "")
    @objc func toggleLockOffset() {
        lockOffset.toggle()
        lockOffsetMenuItem.state = lockOffset ? .on : .off
    }

    let launchAtLoginMenuItem = NSMenuItem(title: "Launch At Login", action: #selector(toggleLaunchAtLoginEnabled), keyEquivalent: "")
    static let launcherId = "dev.vandijk.BrightnessSyncLauncher" as CFString
    @objc func toggleLaunchAtLoginEnabled() {
        let enable = launchAtLoginMenuItem.state == .off
        let success = SMLoginItemSetEnabled(Self.launcherId, enable)
        if success {
            launchAtLoginMenuItem.state = enable ? .on : .off
        }
    }

    @objc func checkForUpdates() {
        NSWorkspace.shared.open(URL(string: "https://github.com/OCJvanDijk/Brightness-Sync/releases")!)
    }

    @objc func copyDiagnosticsToPasteboard() {
        let displayInfoDict = Dictionary(uniqueKeysWithValues: Self.getActiveDisplays().map { ($0, CoreDisplay_DisplayCreateInfoDictionary($0)?.takeRetainedValue()) })

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(describing: displayInfoDict), forType: .string)
    }

    // MARK: - Brightness Sync

    enum Status: Equatable {
        case deactivated
        case paused
        case running(sourceBrightness: Double, targets: [Target])
    }

    struct Target: Equatable {
        let id: CFUUID
        let brightness: Double
        let offset: Double
    }

    var cancelBag = Set<AnyCancellable>()

    func setup() {
        UserDefaults.standard.register(defaults: ["BSUpdateInterval": 0.1])
        let updateInterval = UserDefaults.standard.double(forKey: "BSUpdateInterval")
        if updateInterval != 0.1 {
            os_log("Using custom polling interval: %fs", updateInterval)
        }

        let statusPublisher = displaysPublisher
            .combineLatest(pausedPublisher)
            .map { [monitorOffsets] displays, paused -> AnyPublisher<Status, Never> in
                // We don't want the timer running unless necessary to save energy
                if paused {
                    os_log("Paused...")
                    return Just(.paused).eraseToAnyPublisher()
                } else if let source = displays.source, !displays.targets.isEmpty {
                    os_log("Activated...")
                    return Timer.publish(every: updateInterval, on: .current, in: .common)
                        .autoconnect()
                        .map { _ in
                            .running(
                                sourceBrightness: CoreDisplay_Display_GetLinearBrightness(CGDisplayGetDisplayIDFromUUID(source)),
                                targets: displays.targets.map {
                                    .init(
                                        id: $0,
                                        brightness: CoreDisplay_Display_GetLinearBrightness(CGDisplayGetDisplayIDFromUUID($0)),
                                        offset: monitorOffsets[$0]
                                    )
                                }
                            )
                        }
                        .eraseToAnyPublisher()
                } else {
                    os_log("Deactivated...")
                    return Just(.deactivated).eraseToAnyPublisher()
                }
            }
            .switchToLatest()
            .removeDuplicates()
            .multicast(subject: PassthroughSubject())

        // There is a quirk in CoreDisplay, that causes it to read incorrect values just before you close the lid and enter clamshell mode or disconnect a monitor.
        // This causes different kinds of problems, so we roll back to two seconds ago.
        // This is probably desirable anyway because even without the quirk closing the lid will briefly affect brightness readings.
        let pastStatusPublisher = statusPublisher
            .delay(for: .seconds(2), scheduler: RunLoop.current)
            .prepend(.deactivated)
        let rollbackInjector = statusPublisher
            .withLatestFrom(pastStatusPublisher)
            .compactMap { brightnessStatus, brightnessStatusTwoSecondsAgo -> [Target]? in
                if brightnessStatus == .deactivated, case .running(_, let targets) = brightnessStatusTwoSecondsAgo {
                    return targets
                } else {
                    return nil
                }
            }

        statusPublisher
            .scan([]) { [weak self] previouslySynced, newStatus -> [Target] in
                guard case .running(let sourceBrightness, let targets) = newStatus else { return [] }

                return targets.map { target in
                    var offset = target.offset
                    let lockOffset = self?.lockOffset ?? true
                    if !lockOffset, let expectedBrightness = previouslySynced.first(where: { $0.id == target.id })?.brightness, abs(target.brightness - expectedBrightness) > 0.0001 {
                        let currentTargetUserBrightness = estimatedLinearToUserBrightness(target.brightness)
                        let expectedTargetUserBrightness = estimatedLinearToUserBrightness(expectedBrightness)
                        let offsetDelta = currentTargetUserBrightness - expectedTargetUserBrightness
                        offset += offsetDelta
                    }

                    // Brightness offset set by the user is naturally a "User" brightness.
                    // Ideally we would map this to "Linear" brightness exactly like CoreDisplay does, but I've been unable to reverse engineer the formula.
                    // (Probably something to do with CoreDisplay_Display_GetDynamicSliderParameters, CoreDisplay_Display_GetLuminanceCorrectionFactor etc)
                    // Instead I've curve fitted an exponential function to observed user->linear values of my own MBP's screen which I hope is a reasonable approximation for offset values.
                    // This approximation is only applied to the offset so if offset is 0 we keep the exact Linear brightness as reported by CoreDisplay.
                    let adjustedEstimatedLinearBrightness = estimatedUserToLinearBrightness(estimatedLinearToUserBrightness(sourceBrightness) + offset).clamped(to: 0.0...1.0)
                    return .init(id: target.id, brightness: adjustedEstimatedLinearBrightness, offset: offset)
                }
            }
            .merge(with: rollbackInjector)
            .sink { [monitorOffsets] targets in
                for target in targets {
                    CoreDisplay_Display_SetLinearBrightness(CGDisplayGetDisplayIDFromUUID(target.id), target.brightness)
                    monitorOffsets[target.id] = target.offset
                }
            }
            .store(in: &cancelBag)

        statusPublisher
            .map {
                switch $0 {
                case .deactivated:
                    return "Deactivated"
                case .paused:
                    return "Paused"
                case .running:
                    return "Activated"
                }
            }
            .removeDuplicates()
            .assign(to: \.title, on: statusIndicator)
            .store(in: &cancelBag)

        statusPublisher.connect().store(in: &cancelBag)
    }

    // MARK: - Displays

    let displaysPublisher: PassthroughSubject<(source: CFUUID?, targets: [CFUUID]), Never> = .init()

    var displayReconfigurationCounter = 0

    func setupDisplayMonitor() {
        // We use reconfiguration callback to track if display reconfiguration is done, which is the only reliable way I've found to know if all displays are "brightness writable" to prevent offset shift.
        // All calls with beginConfigurationFlag are balanced with another call when configuration is done, so we keep track with a counter.
        CGDisplayRegisterReconfigurationCallback({ id, flags, selfPointer in
            let `self` = Unmanaged<AppDelegate>.fromOpaque(selfPointer!).takeUnretainedValue()

            if flags.contains(.beginConfigurationFlag) {
                if self.displayReconfigurationCounter == 0 {
                    os_log("Display reconfiguration started...")
                    self.displaysPublisher.send((nil, [])) // Deactivate during reconfiguration
                }
                self.displayReconfigurationCounter += 1
            }
            else {
                self.displayReconfigurationCounter -= 1
                if self.displayReconfigurationCounter == 0 {
                    os_log("Display reconfiguration ended...")
                    self.refreshDisplays()
                }
            }
        }, Unmanaged<AppDelegate>.passUnretained(self).toOpaque())

        refreshDisplays()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if displayReconfigurationCounter == 0 {
            refreshDisplays()
        }
    }

    func refreshDisplays() {
        os_log("Starting display refresh...")

        let activeDisplays = Self.getActiveDisplays()
        os_log("Displays: %{public}@", activeDisplays)

        let isOnConsole = (CGSessionCopyCurrentDictionary() as NSDictionary?)?[kCGSessionOnConsoleKey] as? Bool ?? false

        if isOnConsole {
            let lgVendorNumber: UInt32 = 7789
//            let ultraFine4k1stGenModelNumber: UInt32 = 23312
//            let ultraFine5k1stGenModelNumber: UInt32 = 23313
            let ultraFine4k2ndGenModelNumber: UInt32 = 23419
            let ultraFine5k2ndGenModelNumber: UInt32 = 23412

            func is2ndGenUltraFine(_ display: CGDirectDisplayID) -> Bool {
                switch (CGDisplayVendorNumber(display), CGDisplayModelNumber(display)) {
                case (lgVendorNumber, ultraFine4k2ndGenModelNumber), (lgVendorNumber, ultraFine5k2ndGenModelNumber):
                    return true
                default:
                    return false
                }
            }

            let builtin = activeDisplays
                .filter { CGDisplayIsBuiltin($0) == 1 }
                .compactMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
                .first

            let source = builtin ?? activeDisplays
                .filter { is2ndGenUltraFine($0) }
                .compactMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
                .first

            let targets = activeDisplays
                .filter {
                    if let displayInfo = CoreDisplay_DisplayCreateInfoDictionary($0)?.takeRetainedValue() as NSDictionary? {
                        if
                            let displayNames = displayInfo[kDisplayProductName] as? NSDictionary,
                            let displayName = displayNames["en_US"] as? NSString
                        {
                            if
                                displayName.contains("LG UltraFine")
                            {
                                os_log("Found compatible display: %{public}@", displayName)
                                return true
                            }
                            else {
                                os_log("Found incompatible display: %{public}@", displayName)
                                return false
                            }
                        }
                        else {
                            os_log("Display without en_US name found.")
                            return false
                        }
                    } else {
                        os_log("Display without retrievable info found.")
                        return false
                    }
                }
                .compactMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
                .filter { $0 != source }

            displaysPublisher.send((source, targets))
        } else {
            displaysPublisher.send((nil, []))
            os_log("User not active")
        }
    }

    static let maxDisplays: UInt32 = 8

    static func getActiveDisplays() -> Set<CGDirectDisplayID> {
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        CGGetActiveDisplayList(maxDisplays, &activeDisplays, &displayCount)

        return Set(activeDisplays[0..<Int(displayCount)])
    }
}

class MonitorOffsets: ObservableObject {
    subscript(monitor: CFUUID) -> Double {
        get {
            UserDefaults.standard.double(forKey: "BSBrightnessOffset_\(CFUUIDCreateString(nil, monitor)!)")
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "BSBrightnessOffset_\(CFUUIDCreateString(nil, monitor)!)")
        }
    }
}

func estimatedLinearToUserBrightness(_ brightness: Double) -> Double {
    log(brightness / 0.0079) / 4.6533
}

func estimatedUserToLinearBrightness(_ brightness: Double) -> Double {
    exp(brightness * 4.6533) * 0.0079
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension Publisher {
    func withLatestFrom<A, P: Publisher>(_ second: P)
        -> Publishers.SwitchToLatest<Publishers.Map<Self, (Self.Output, A)>, Publishers.Map<P, Publishers.Map<Self, (Self.Output, A)>>> where P.Output == A, P.Failure == Failure {
        second.map { latestValue in
            self.map { ownValue in (ownValue, latestValue) }
        }
        .switchToLatest()
    }
}
