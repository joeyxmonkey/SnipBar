# SnipBar

SnipBar brings the Windows-style snipping shortcut to macOS. Press **⌘⇧S** from any app, pick a capture mode, and use the crosshair to make a selection. SnipBar runs in the background without a Dock icon.

## Install from source

You’ll need **macOS 14 Sonoma or later** and Apple’s Xcode Command Line Tools. If you need the tools, run `xcode-select --install` first. The build uses the system Swift compiler and Apple frameworks.

```sh
git clone https://github.com/joeyxmonkey/SnipBar.git
cd SnipBar
bash build.sh
open "$HOME/Applications/SnipBar.app"
```

The script installs a locally signed app in `~/Applications` and builds for the Mac’s architecture. To install in another folder, pass it to the script, for example `bash build.sh ./build`. For updates, quit SnipBar, pull the new source, run the build again, and reopen the app.

The first capture needs **Screen & System Audio Recording** permission. In SnipBar, click **Screen Recording Access…**, then enable SnipBar under **System Settings → Privacy & Security → Screen & System Audio Recording**. Quit and reopen SnipBar if macOS prompts you.

## Capture a screenshot

| Mode | How to use it |
| --- | --- |
| Rectangle | Drag a box around the area you want. This is the default mode. |
| Freeform | Draw around the area you want. The PNG is transparent outside the outline. |
| Window | Point to a window to highlight it, then click. |
| Full Screen | Click the toolbar’s full-screen button to capture the display where you opened the overlay. |

Press **Esc** to cancel. After a capture, SnipBar briefly confirms what it did.

## Settings

Open SnipBar from Applications or Spotlight to show settings. If you enable **Show menu bar icon**, you can also open settings or start a snip from the icon.

| Setting | What it does |
| --- | --- |
| After capture | **Copy only** puts the image on the clipboard without creating a file. **Save only** writes a PNG. **Save and copy** does both. The default is **Copy only**. |
| Save location | Choose a folder for PNGs. The default is `~/Pictures/SnipBar`. |
| Global shortcut | Click the displayed shortcut and press a new combination using Command, Control, or Option. Use **Reset** to restore **⌘⇧S**. |
| Show menu bar icon | Show or hide the icon. Off by default. Closing settings leaves the shortcut active. |
| Start at login | Launch SnipBar in the background when you sign in. Off by default. If macOS requests approval, use **Approve in Login Items…**. |

SnipBar processes captures locally and uses the screen recording permission to read screen pixels. It does not upload screenshots or collect telemetry.

## Troubleshooting

- **The shortcut doesn’t open the overlay.** Open SnipBar to make sure it’s running. Try **New Snip** to check screen recording access. If another app owns the shortcut, record a different combination.
- **Capture still asks for access after an update.** Check that the installed copy of SnipBar is enabled in Screen & System Audio Recording, then quit and reopen it.
- **The screenshot couldn’t be saved.** Choose a folder you can write to. Check that external drives and shared folders are mounted.

To uninstall, turn off **Start at login**, use **Quit SnipBar** in settings, and move `SnipBar.app` to the Trash. Saved PNGs stay in your chosen folder.

## Development

`Sources/App.swift` manages the app lifecycle and capture flow. `Sources/Overlay.swift` handles the on-screen selection. `Sources/Capture.swift` uses ScreenCaptureKit to read pixels and writes the result to the clipboard or a PNG. `Sources/Settings.swift` and `Sources/Shortcut.swift` manage preferences and the global shortcut.

Before submitting a change, run `bash build.sh ./build` and test the affected capture mode or setting in the built app. When reporting an issue, include your macOS version, display setup, and steps to reproduce it.

## License

[MIT](LICENSE)
