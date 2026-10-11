# Sone — Fine-grained volume control for macOS

The macOS volume slider is too coarse at low volume: one step can mean a jump of several dB. When you want to listen quietly with headphones, the result is either still too loud or suddenly muted.

Sone replaces it with a **dB-uniform** scale—each step represents the same dB change, and therefore the same perceived change in loudness—and controls the device's floating-point volume directly, reaching lower levels than the system slider allows.

## Installation

```sh
make
make install-gui        # Installs to ~/Applications/Sone.app
```

Requires macOS 12 or later and the Xcode Command Line Tools.

## Usage

Open `Sone.app` and move the slider. The value is displayed simultaneously as level / dB / linear amplitude.

- **Menu bar icon** — left-click to show the window; right-click for a shortcut menu with volume controls, a global hotkey toggle, and the minimum volume setting
- **Global hotkeys** — `⌥-` / `⌥+` adjust the volume by default; **hold to adjust continuously**. You can record any key combination in Settings
- **Settings** — `⌘,`
- Adjusting the volume **automatically unmutes** the device; when the device is muted, the slider appears dimmed but can still be dragged

When the window is focused, use `+` / `=` to increase the volume by 2 steps, or `-` to decrease it by 2 steps.

## Settings

Press `⌘,` to open the Settings window:

- **Minimum volume** — how low the scale can go (−30 … −120 dB)
- **Volume up / Volume down** — record global hotkeys (at least one modifier key is required)
- **Global hot keys** — master switch for global hotkeys

## Command line

```sh
make install            # Installs to /usr/local/bin/sone

sone 70                 # Set to scale level 70
sone +5  /  sone -5     # Adjust relatively
sone -30dB              # Set an absolute gain
sone mute / unmute      # Mute / unmute
sone list               # List output devices
```

Run `sone -h` to see all options (`-d` selects a device and `-r` adjusts the scale range).

## Can't open the app?

The app is locally signed and not notarized by Apple, so Gatekeeper may block it the first time you open it after downloading it.

In Finder, **right-click → Open**, or run:

```sh
xattr -dr com.apple.quarantine ~/Applications/Sone.app
```

An app built locally with `make` will not have this issue.

## License

[MIT](LICENSE)
