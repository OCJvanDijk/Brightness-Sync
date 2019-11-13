#  Brightness Sync

__Download:__ [here](https://github.com/OCJvanDijk/Brightness-Sync/releases/latest/download/Brightness.Sync.app.zip) (macOS >= 10.14.4, signed and notarized)

This is a small menu bar app to mitigate the problem of the LG UltraFine not being able to automatically adjust brightness.
It will poll the brightness of your builtin display and synchronize it with your LG monitors.
So you can use your MBP's ambient light sensor for all your (UltraFine) displays!
This also means manually adjusting the brightness of all your displays is easier, a single swipe over the brightness button on your Touch Bar will do.

The difference between this app and some existing apps is that this app uses a private framework of macOS to control the backlight of the LG UltraFine the same way the secondary slider of your Touch Bar will do.
Other apps might virtually darken the display with the backlight staying the same, this will greatly reduce contrast.

Because it uses your laptop’s ambient light sensor, this won’t work in clamshell mode.

I only have one 27-inch LG UltraFine display, so I could do only limited testing. Let me know if you have issues.

Requires (and tested on) macOS 10.14.4, but could be built for earlier versions too.

You'll probably want to add the app to your Login Items.

## Energy impact
The app polls the brightness pretty aggressively, which results in a small energy impact of around 0.3-0.5 according to Activity Monitor.
_However_ it will automatically stop the polling when no UltraFine displays are connected and because those monitors are also a power source, this effectively means it will never run when on battery power.

## Known issues
If you enter/exit clamshell mode by closing/opening your lid with the monitor attached, it might go completely bright for a second before restoring to the last synchronized brightness.
