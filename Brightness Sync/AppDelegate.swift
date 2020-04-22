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
        refreshDisplays()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        refreshDisplays()
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
        let CGDisplays = AppDelegate.getAllDisplays()
        let IODisplays = AppDelegate.getDisplayInfoDictionaries()

        let diagnostics = """
        CGDisplayList:
        \(CGDisplays.map {
                            ["VendorNumber": CGDisplayVendorNumber($0),
                                                                         "ModelNumber": CGDisplayModelNumber($0),
                                                                         "SerialNumber": CGDisplaySerialNumber($0)]
                                 })

        IODisplayList:
        \(IODisplays)
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
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

    static let updateInterval = 0.1

    var cancelBag = Set<AnyCancellable>()

    func setup() {
        let statusPublisher = displaysPublisher
            .combineLatest(pausedPublisher)
            .map { [monitorOffsets] displays, paused -> AnyPublisher<Status, Never> in
                // We don't want the timer running unless necessary to save energy
                if paused {
                    os_log("Paused...")
                    return Just(.paused).eraseToAnyPublisher()
                } else if let source = displays.source, !displays.targets.isEmpty {
                    os_log("Activated...")
                    return Timer.publish(every: Self.updateInterval, on: .current, in: .common)
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
                if brightnessStatus == .deactivated, case let .running(_, targets) = brightnessStatusTwoSecondsAgo {
                    return targets
                } else {
                    return nil
                }
            }

        statusPublisher
            .scan(nil) { previouslySynced, newStatus -> [Target]? in
                guard case let .running(sourceBrightness, targets) = newStatus else { return nil }

                return targets.map { target in
                    var offset = target.offset
                    if let expectedBrightness = previouslySynced?.first(where: { $0.id == target.id })?.brightness, abs(target.brightness - expectedBrightness) > 0.0001 {
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
            .compactMap { $0 }
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

    func refreshDisplays() {
        os_log("Starting display refresh...")

        // Resetting first on every refresh will cause a rollback + reset the offset capture and fixes issues where connecting/disconnecting a monitor will corrupt its offset.
        displaysPublisher.send((nil, []))

        let isOnConsole = (CGSessionCopyCurrentDictionary() as NSDictionary?)?[kCGSessionOnConsoleKey] as? Bool ?? false

        if isOnConsole {
            let allDisplays = AppDelegate.getAllDisplays()
            let lgDisplayIdentifiers = AppDelegate.getConnectedUltraFineDisplayIdentifiers()

            let builtin = allDisplays
                .filter { CGDisplayIsBuiltin($0) == 1 }
                .compactMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
                .first

            let targets = allDisplays
                .filter { lgDisplayIdentifiers.contains(DisplayIdentifier(vendorNumber: CGDisplayVendorNumber($0), modelNumber: CGDisplayModelNumber($0))) }
                .compactMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }

                displaysPublisher.send((builtin, targets))
        } else {
            os_log("User not active")
        }
    }

    static let maxDisplays: UInt32 = 8

    static func getAllDisplays() -> [CGDirectDisplayID] {
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        CGGetOnlineDisplayList(maxDisplays, &onlineDisplays, &displayCount)

        return Array(onlineDisplays[0..<Int(displayCount)])
    }

    static func getConnectedUltraFineDisplayIdentifiers() -> Set<DisplayIdentifier> {
        var ultraFineDisplays = Set<DisplayIdentifier>()

        for displayInfo in getDisplayInfoDictionaries() {
            if
                let displayNames = displayInfo[kDisplayProductName] as? NSDictionary,
                let displayName = displayNames["en_US"] as? NSString
            {
                if
                    displayName.contains("LG UltraFine"),
                    let vendorNumber = displayInfo[kDisplayVendorID] as? UInt32,
                    let modelNumber = displayInfo[kDisplayProductID] as? UInt32
                {
                    os_log("Found compatible display: %{public}@", displayName)
                    ultraFineDisplays.insert(DisplayIdentifier(vendorNumber: vendorNumber, modelNumber: modelNumber))
                }
                else {
                    os_log("Found incompatible display: %{public}@", displayName)
                }
            }
            else {
                os_log("Display without en_US name found.")
            }
        }

        return ultraFineDisplays
    }

    static func getDisplayInfoDictionaries() -> [NSDictionary] {
        var diplayInfoDictionaries = [NSDictionary]()

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == 0 else {
            return diplayInfoDictionaries
        }

        var display = IOIteratorNext(iterator)

        while display != 0 {
            if let displayInfo = IODisplayCreateInfoDictionary(display, 0)?.takeRetainedValue() {
                diplayInfoDictionaries.append(displayInfo)
            }

            IOObjectRelease(display)

            display = IOIteratorNext(iterator)
        }

        IOObjectRelease(iterator)

        return diplayInfoDictionaries
    }

    struct DisplayIdentifier: Hashable {
        let vendorNumber: UInt32
        let modelNumber: UInt32
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
