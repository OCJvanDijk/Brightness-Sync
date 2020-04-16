import Cocoa
import Combine
import os
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Menu / App

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statusIndicator = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")

    let pauseButton = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "StatusBarButtonImage")
        }

        let menu = NSMenu()
        menu.addItem(statusIndicator)
        menu.addItem(pauseButton)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Reset Offsets", action: #selector(brightnessOffsetReset), keyEquivalent: ""))
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

        refreshDisplays()
        setup()
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
        case running(sourceLinearBrightness: Double, targetUserBrightnesses: [CFUUID: Double])

        var isRunning: Bool {
            self != .deactivated && self != .paused
        }
    }

    static let updateInterval = 0.1

    var expectedTargetUserBrightnesses = [CFUUID: Double]()

    @objc func brightnessOffsetReset() {
        UserDefaults.standard
            .dictionaryRepresentation()
            .keys
            .filter { $0.starts(with: "BSBrightnessOffset_") }
            .forEach { key in
                UserDefaults.standard.removeObject(forKey: key)
            }

        // Poor man's resync
        if !pausedPublisher.value {
            pausedPublisher.send(true)
            pausedPublisher.send(false)
        }
    }

    var cancelBag = Set<AnyCancellable>()

    func setup() {
        let brightnessPublisher = sourceDisplayPublisher
            .combineLatest(targetDisplaysPublisher, pausedPublisher)
            .map { source, targets, paused -> AnyPublisher<Status, Never> in
                // We don't want the timer running unless necessary to save energy
                if paused {
                    os_log("Paused...")
                    return Just(.paused).eraseToAnyPublisher()
                } else if let source = source, !targets.isEmpty {
                    os_log("Activated...")
                    return Timer.publish(every: Self.updateInterval, on: .current, in: .common)
                        .autoconnect()
                        .map { _ in
                            .running(
                                sourceLinearBrightness: CoreDisplay_Display_GetLinearBrightness(CGDisplayGetDisplayIDFromUUID(source)),
                                targetUserBrightnesses: .init(uniqueKeysWithValues: targets.map { ($0, CoreDisplay_Display_GetUserBrightness(CGDisplayGetDisplayIDFromUUID($0))) })
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

        brightnessPublisher
            .sink { [weak self] brightnessStatus in
                guard let self = self else { return }
                guard case let .running(sourceLinearBrightness, targets) = brightnessStatus else {
                    self.expectedTargetUserBrightnesses.removeAll()
                    return
                }

                for (key, _) in self.expectedTargetUserBrightnesses {
                    if targets[key] == nil {
                        self.expectedTargetUserBrightnesses.removeValue(forKey: key)
                    }
                }

                for (target, currentTargetBrightness) in targets {
                    var offset = 0.0
                    if let uuidString = CFUUIDCreateString(nil, target) {
                        let offsetKey = "BSBrightnessOffset_\(uuidString)"
                        offset = UserDefaults.standard.double(forKey: offsetKey)

                        if let expectedTargetBrightness = self.expectedTargetUserBrightnesses[target] {
                            let offsetDelta = currentTargetBrightness - expectedTargetBrightness
                            if offsetDelta != 0 {
                                offset += offsetDelta
                                UserDefaults.standard.set(offset, forKey: offsetKey)
                            }
                        }
                    }

                    // Brightness offset set by the user is naturally a "User" brightness.
                    // Ideally we would map this to "Linear" brightness exactly like CoreDisplay does, but I've been unable to reverse engineer the formula.
                    // (Probably something to do with CoreDisplay_Display_GetDynamicSliderParameters, CoreDisplay_Display_GetLuminanceCorrectionFactor etc)
                    // Instead I've curve fitted an exponential function to observed user->linear values of my own MBP's screen which I hope is a reasonable approximation for offset values.
                    // This approximation is only applied to the offset so if offset is 0 we keep the exact Linear brightness as reported by CoreDisplay.
                    let estimatedUserBrightness = log(sourceLinearBrightness / 0.0079) / 4.6533
                    let adjustedEstimatedUserBrightness = estimatedUserBrightness + offset
                    let adjustedEstimatedLinearBrightness = (exp(adjustedEstimatedUserBrightness * 4.6533) * 0.0079).clamped(to: 0.0...1.0)

                    let displayID = CGDisplayGetDisplayIDFromUUID(target)
                    CoreDisplay_Display_SetLinearBrightness(displayID, adjustedEstimatedLinearBrightness)

                    self.expectedTargetUserBrightnesses[target] = CoreDisplay_Display_GetUserBrightness(displayID)
                }
            }
            .store(in: &cancelBag)

        brightnessPublisher
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

        brightnessPublisher.connect().store(in: &cancelBag)
    }

    // MARK: - Displays

    let sourceDisplayPublisher: CurrentValueSubject<CFUUID?, Never> = .init(nil)
    let targetDisplaysPublisher: CurrentValueSubject<[CFUUID], Never> = .init([])

    func refreshDisplays() {
        os_log("Starting display refresh...")

        let allDisplays = AppDelegate.getAllDisplays()
        let lgDisplayIdentifiers = AppDelegate.getConnectedUltraFineDisplayIdentifiers()

        let builtin = allDisplays
            .filter { CGDisplayIsBuiltin($0) == 1 }
            .compactMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
            .first
        let targets = allDisplays
            .filter { lgDisplayIdentifiers.contains(DisplayIdentifier(vendorNumber: CGDisplayVendorNumber($0), modelNumber: CGDisplayModelNumber($0))) }
            .compactMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }

        sourceDisplayPublisher.send(builtin)
        targetDisplaysPublisher.send(targets)
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

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension Strideable where Stride: SignedInteger {
    func clamped(to limits: CountableClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}
