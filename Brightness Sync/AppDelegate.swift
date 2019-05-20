//
//  AppDelegate.swift
//  Brightness Sync
//
//  Created by Onne van Dijk on 19/05/2019.
//  Copyright © 2019 Onne van Dijk. All rights reserved.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    
    var syncTimer: Timer?
    var invokedTimerCount = 0
    
    static let maxDisplays: UInt32 = 8
    var mainDisplay: CGDirectDisplayID = 0
    var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
    var displayCount: UInt32 = 0

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "StatusBarButtonImage")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: ""))
        statusItem.menu = menu
        
        let timer = Timer.scheduledTimer(timeInterval: 0.2, target: self, selector: #selector(handleTimer), userInfo: nil, repeats: true)
        timer.tolerance = 1
        syncTimer = timer
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        print("Params changed")
        refreshMonitorList()
    }
    
    @objc func handleTimer() {
        invokedTimerCount += 1
//        print("hoi\(invokedTimerCount)")
//        print(CoreDisplay_Display_GetUserBrightness(0))
    }
    
    func refreshMonitorList() {
        mainDisplay = CGMainDisplayID()
        
        CGGetOnlineDisplayList(AppDelegate.maxDisplays, &onlineDisplays, &displayCount)
        
        print(mainDisplay)
        print(onlineDisplays[0...Int(displayCount)-1])
    }
}
