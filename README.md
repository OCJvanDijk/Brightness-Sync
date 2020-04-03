#  Brightness Sync

__Download:__ [here](https://github.com/OCJvanDijk/Brightness-Sync/releases/latest/download/Brightness.Sync.app.zip) (macOS Catalina required, app is signed and notarized)  
Alternatively, you can use [Homebrew Cask](https://github.com/Homebrew/homebrew-cask): `$ brew cask install brightness-sync`

_The app doesn't automatically check for updates. If you want to stay up-to-date, I recommend selecting "Watch->Releases only" at the top of this page if you have a GitHub account, or using the Homebrew Cask installation method._

This is a small menu bar app to mitigate the problem of the first-generation LG UltraFine not being able to automatically adjust brightness.
It will poll the brightness of your built-in display and synchronize it to your LG monitors.
This way you can use the ambient light sensor of your MBP or iMac for all your (UltraFine) displays!
This also means manually adjusting the brightness of all your displays at once is easier, a single swipe on your Touch Bar or press on your keyboard will do.

The difference between this app and some existing apps is that this app uses a private framework of macOS to control the backlight of the LG UltraFine the same way the secondary slider of your Touch Bar will do.
Other apps might virtually darken the display with the backlight staying the same, this will greatly reduce contrast.

Because this app relies on your Mac’s ambient light sensor, unfortunately it won't help with automatic brightness if your MacBook is in clamshell mode or you have connected your UltraFine to for example a Mac Mini.

I only have one 27-inch LG UltraFine display, so I could do only limited testing. Let me know if you have issues.

Requires macOS 10.15. If you're on 10.14, you can download v1 from the releases page.

You'll probably want to add the app to your Login Items.

## Energy impact
The app polls the brightness pretty aggressively, which results in a small energy impact of around 0.3-0.5 according to Activity Monitor.
_However_ it will automatically stop the polling when no UltraFine displays are connected and because those monitors are also a power source, this effectively means it will never run when on battery power.

## Known issues
If you enter/exit clamshell mode by closing/opening your lid with the monitor attached, it might go completely bright for a second before restoring to the last synchronized brightness.
