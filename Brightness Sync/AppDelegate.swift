//
//  AppDelegate.swift
//  Brightness Sync
//
//  Created by Onne van Dijk on 19/05/2019.
//  Copyright © 2019 Onne van Dijk. All rights reserved.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var running = false
    
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statusIndicator = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
    
    var syncTimer: Timer?
    
    var brightness = 0.0
    var changeCount = 0
    
    static let maxDisplays: UInt32 = 8
    var mainDisplay: CGDirectDisplayID = 0
    var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
    var displayCount: UInt32 = 0
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "StatusBarButtonImage")
        }
        
        let menu = NSMenu()
        menu.addItem(statusIndicator)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: ""))
        statusItem.menu = menu
        
        refreshMonitorList()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        print("Params changed")
        refreshMonitorList()
    }
    
    func refreshMonitorList() {
        mainDisplay = CGMainDisplayID()
        CGGetOnlineDisplayList(AppDelegate.maxDisplays, &onlineDisplays, &displayCount)
        
        print(mainDisplay)
        print(onlineDisplays[0...Int(displayCount) - 1])
        
        displayCount > 1 ? start() : stop()
    }
    
    func start() {
        if !running {
            startNewTimer()
            running = true
            statusIndicator.title = "Activated"
        }
    }
    
    func stop() {
        if running {
            stopTimer()
            running = false
            statusIndicator.title = "Paused"
        }
    }
    
    func startNewTimer() {
        assert(!(syncTimer?.isValid ?? false), "Didn't invalidate previous timer.")
        
        let timer = Timer.scheduledTimer(timeInterval: 0.2, target: self, selector: #selector(handleTimer), userInfo: nil, repeats: true)
        timer.tolerance = 1
        syncTimer = timer
        print("started new timer")
    }
    
    func stopTimer() {
        syncTimer?.invalidate()
    }
    
    @objc func handleTimer() {
        let newBrightness = CoreDisplay_Display_GetUserBrightness(mainDisplay)
        
        if abs(brightness - newBrightness) > 0.01 {
            changeCount += 1
            print("Brightness changed\(changeCount)")
            for display in onlineDisplays[0...Int(displayCount) - 1] {
                if display != mainDisplay {
                    CoreDisplay_Display_SetUserBrightness(display, newBrightness)
                }
            }
            
            brightness = newBrightness
        }
        //        print("hoi\(invokedTimerCount)")
        //        print(CoreDisplay_Display_GetUserBrightness(0))
    }
}
