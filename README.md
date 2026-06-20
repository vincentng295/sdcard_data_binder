# Adoptable Storage AppData Binder

A smart dynamic bind-mount daemon for Android Adoptable Storage.

## Why is it?
When you move advanced apps (like `com.termux`) to an expanded SD card, they often crash because their binaries look for **hardcoded paths** in the internal storage (`/data/user/...`), while the system actually moved them to `/mnt/expand/[UUID]/user/...`.

**Adoptable Storage AppData Binder** fixes this silently in the background without modifying the apps.

## How it works
* **Boot Sync:** Automatically detects your SD Card UUID and bind-mounts relocated apps back to their expected internal directory.
* **Real-time Watch:** Uses `inotifyd` to intercept new app installations or **Second Space** creations, linking them instantly.
* **Clean Lifecycle:** Uses `lazy unmount` to safely detach paths when an app or dual profile is uninstalled, preventing zombie mounts.

## Installation
1. Flash the zip via Magisk / KernelSU.
2. Reboot.
3. Check logs anytime at `/data/adb/modules/adoptsdbind/logging.txt`.