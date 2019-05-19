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

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "StatusBarButtonImage")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: ""))
        statusItem.menu = menu
        
        let timer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(handleTimer), userInfo: nil, repeats: true)
        timer.tolerance = 1
        syncTimer = timer
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    @objc func handleTimer() {
        invokedTimerCount += 1
        print("hoi\(invokedTimerCount)")
    }
}

