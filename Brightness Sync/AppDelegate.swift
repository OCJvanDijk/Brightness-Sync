import Cocoa
import Combine
import os
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Menu / App

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statusIndicator = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")

    let pauseButton = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")

    lazy var slider = NSSlider(value: brightnessOffset, minValue: -0.4, maxValue: 0.4, target: self, action: #selector(brightnessOffsetUpdated))
    lazy var sliderView: NSView = {
        let container = NSView(frame: NSRect(origin: CGPoint.zero, size: CGSize(width: 200, height: 30)))

        container.addSubview(slider)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22).isActive = true
        slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12).isActive = true
        slider.centerYAnchor.constraint(equalTo: container.centerYAnchor).isActive = true

        return container
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "StatusBarButtonImage")
        }

        let menu = NSMenu()
        menu.addItem(statusIndicator)
        menu.addItem(pauseButton)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Brightness Offset:", action: nil, keyEquivalent: ""))
        let menuSlider = NSMenuItem()
        menuSlider.view = sliderView
        menu.addItem(menuSlider)
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

    static let brightnessOffsetKey = "BSBrightnessOffsetNew"
    var brightnessOffset: Double {
        get {
            UserDefaults.standard.double(forKey: Self.brightnessOffsetKey)
        }
        set(newValue) {
            UserDefaults.standard.set(newValue, forKey: Self.brightnessOffsetKey)
            brightnessOffsetPublisher.send(newValue)
        }
    }

    lazy var brightnessOffsetPublisher = CurrentValueSubject<Double, Never>(brightnessOffset)

    @objc func brightnessOffsetUpdated(slider: NSSlider) {
        brightnessOffset = slider.doubleValue
    }

    @objc func brightnessOffsetReset() {
        brightnessOffset = 0
        slider.doubleValue = 0
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
        case running(Double)

        var isRunning: Bool {
            self != .deactivated && self != .paused
        }
    }

    static let updateInterval = 0.1

    var cancelBag = Set<AnyCancellable>()

    func setup() {
        let brightnessPublisher = sourceDisplayPublisher
            .combineLatest(targetDisplaysPublisher.map { !$0.isEmpty }.removeDuplicates(), pausedPublisher)
            .map { source, hasTargets, paused -> AnyPublisher<Status, Never> in
                // We don't want the timer running unless necessary to save energy
                if paused {
                    os_log("Paused...")
                    return Just(.paused).eraseToAnyPublisher()
                } else if let source = source, hasTargets {
                    os_log("Activated...")
                    return Timer.publish(every: Self.updateInterval, on: .current, in: .common)
                        .autoconnect()
                        .map { _ in
                            .running(CoreDisplay_Display_GetLinearBrightness(source))
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

        // There is a quirk in CoreDisplay, that causes the builtin display to read a brightness value of 1.0 just after you closed the lid and enter clamshell mode.
        // As a result, entering clamshell mode at night might cause your external display to suddenly light up with blinding light.
        // We fix this by restoring the brightness of two seconds back after deactivation.
        // This is probably desirable anyway because even without the quirk closing the lid will briefly affect brightness readings.
        let pastBrightnessPublisher = brightnessPublisher.delay(for: .seconds(2), scheduler: RunLoop.current).prepend(.deactivated)

        brightnessPublisher
            .withLatestFrom(pastBrightnessPublisher)
            .flatMap { brightnessStatus, brightnessStatusTwoSecondsAgo in
                Publishers.Sequence(
                    // If status turns to deactivated, we "inject" the brightness of two seconds ago before the deactivation to reset the brightness.
                    sequence: brightnessStatus == .deactivated && brightnessStatusTwoSecondsAgo.isRunning ? [brightnessStatusTwoSecondsAgo, brightnessStatus] : [brightnessStatus]
                )
            }
            .combineLatest(brightnessOffsetPublisher, targetDisplaysPublisher)
            .sink { brightnessStatus, userBrightnessOffset, targets in
                guard case let .running(linearBrightness) = brightnessStatus else { return }

                // Brightness offset set by the user is naturally a "User" brightness.
                // Ideally we would map this to "Linear" brightness exactly like CoreDisplay does, but I've been unable to reverse engineer the formula.
                // (Probably something to do with CoreDisplay_Display_GetDynamicSliderParameters, CoreDisplay_Display_GetLuminanceCorrectionFactor etc)
                // Instead I've curve fitted an exponential function to observed user->linear values of my own MBP's screen which I hope is a reasonable approximation for offset values.
                // This approximation is only applied to the offset so if offset is 0 we keep the exact Linear brightness as reported by CoreDisplay.
                let estimatedUserBrightness = log(linearBrightness / 0.0079) / 4.6533
                let adjustedEstimatedUserBrightness = estimatedUserBrightness + userBrightnessOffset
                let adjustedEstimatedLinearBrightness = (exp(adjustedEstimatedUserBrightness * 4.6533) * 0.0079).clamped(to: 0.0...1.0)

                for target in targets {
                    CoreDisplay_Display_SetLinearBrightness(target, adjustedEstimatedLinearBrightness)
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

    let sourceDisplayPublisher: CurrentValueSubject<CGDirectDisplayID?, Never> = .init(nil)
    let targetDisplaysPublisher: CurrentValueSubject<[CGDirectDisplayID], Never> = .init([])

    func refreshDisplays() {
        os_log("Starting display refresh...")

        let allDisplays = AppDelegate.getAllDisplays()
        let lgDisplayIdentifiers = AppDelegate.getConnectedUltraFineDisplayIdentifiers()

        let builtin = allDisplays.first { CGDisplayIsBuiltin($0) == 1 }
        let targets = allDisplays.filter { lgDisplayIdentifiers.contains(DisplayIdentifier(vendorNumber: CGDisplayVendorNumber($0), modelNumber: CGDisplayModelNumber($0))) }

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

extension Publisher {
    func withLatestFrom<A, P: Publisher>(_ second: P)
        -> Publishers.SwitchToLatest<Publishers.Map<Self, (Self.Output, A)>, Publishers.Map<P, Publishers.Map<Self, (Self.Output, A)>>> where P.Output == A, P.Failure == Failure {
        second.map { latestValue in
            self.map { ownValue in (ownValue, latestValue) }
        }
        .switchToLatest()
    }
}
