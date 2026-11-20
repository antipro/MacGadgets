# MacGadgets

A native macOS menu bar utility built entirely with Swift, AppKit, IOKit, and CoreGraphics. Only Xcode Command Line Tools are required to build (no full Xcode installation, Homebrew, or macFUSE needed).

## Features

1. **Keep Awake (Prevent Sleep)**
   - Uses native `IOKit` power assertions (`IOPMAssertionCreateWithName`), matching `caffeinate -d -t 57600` without spawning child processes.
   - One-click **16-hour (57,600s)** activation from the menu, plus presets (15 minutes to 16 hours, or indefinitely) and custom durations (such as `90`, `45m`, `2h`, `1h30m`, `57600s`, `16:00:00`).
   - Displays a live countdown in the menu bar, with controls to **Cancel Keep Awake**, **Extend by 1 Hour**, and toggle whether the display is allowed to sleep.

2. **Reverse Scroll Direction (Independent Mouse Wheel & Trackpad Controls)**
   - Intercepts scroll events via `CoreGraphics` (`CGEvent.tapCreate`) without changing the global macOS "Natural scrolling" setting, allowing independent toggles for:
     - **Reverse Mouse Wheel**
     - **Reverse Trackpad Scroll**
     - **Also Reverse Horizontal Scroll**
   - When enabled for the first time, it prompts you to grant Accessibility permission for `MacGadgets` in **System Settings → Privacy & Security → Accessibility**, taking effect automatically once authorized.

3. **Android Drive (Mount Android Devices in Finder Like a USB Drive)**
   - Built on native `IOKit` USB + a custom Swift MTP stack + a local user-space NFSv3 server (SunRPC/XDR/MOUNTv3/NFSv3) + macOS native `mount_nfs` (no macFUSE or third-party kernel extensions required).
   - After plugging in an Android phone and selecting **File Transfer (MTP)** on the device, MacGadgets automatically detects it and mounts it as a read-write NFS volume. A built-in mDNS responder registers a local hostname alias (`<device-name>.local` → `127.0.0.1`) so the phone appears directly under **Locations** in the Finder sidebar (similar to OrbStack), letting you click straight into shares such as `MI 9`.
   - Supports browsing, drag-and-drop copying, creating folders, renaming, and deleting files in **Finder**, while isolating macOS-generated `._*` and `.DS_Store` metadata files in memory.
   - Shows storage capacity in the Control Center card with one-click **Open in Finder** and **Safely Eject**, and automatically cleans up the mount when unplugging the cable or ejecting from Finder. If macOS `ptpcamerad` holds the USB interface, you can release it and retry with one click.

4. **Background Presence & System Integration**
   - Runs as a menu bar-only app without a Dock icon (`LSUIElement = true`), and supports **Launch at Login** via native `SMAppService`.

## Building, Testing, and Running

```bash
# Run core unit tests (no Xcode / XCTest required)
make test

# Build release binary and package dist/MacGadgets.app
make app

# Run directly
make run

# Install to /Applications/MacGadgets.app
make install
```
