/*
 * lvol — a tiny desktop-window app for dB-uniform output volume.
 *
 * It opens a single window holding a slider that drives the default output
 * device's floating-point volume scalar on a dB-uniform scale, so quiet levels
 * are as adjustable as loud ones. Mirrors the `lvol` CLI.
 *
 * The window is the whole UI: there is no menu-bar extra, and the app keeps
 * running (Dock icon) after the window is closed.
 *
 * License: MIT
 */

import AppKit
import CoreAudio
import AudioToolbox

// ------------------------------------------------------------------
// CoreAudio helpers
// ------------------------------------------------------------------

let kRangeDB: Double = 60.0 /* level 0 -> -60 dB, level 100 -> 0 dB */

func propAddr(_ sel: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
              _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
}

func defaultOutput() -> AudioDeviceID {
    var a = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
    return st == noErr ? dev : AudioDeviceID(0)
}

func outputDeviceName(_ dev: AudioDeviceID) -> String {
    var a = propAddr(kAudioObjectPropertyName)
    var cf: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(dev, &a, 0, nil, &size, $0)
    }
    if st == noErr, let s = cf { return s.takeRetainedValue() as String }
    return "Output"
}

func getF32(_ dev: AudioDeviceID, _ a: AudioObjectPropertyAddress) -> Float32? {
    var aa = a
    guard AudioObjectHasProperty(dev, &aa) else { return nil }
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(dev, &aa, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

func setF32(_ dev: AudioDeviceID, _ a: AudioObjectPropertyAddress, _ v: Float32) -> Bool {
    var aa = a
    guard AudioObjectHasProperty(dev, &aa) else { return false }
    var x = v
    return AudioObjectSetPropertyData(dev, &aa, 0, nil,
                                      UInt32(MemoryLayout<Float32>.size), &x) == noErr
}

/* Virtual main volume is the property the system volume keys drive. Fall back
 * to the plain device volume scalar if a device does not expose it. */
let vmvAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    mScope: kAudioObjectPropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain)

let volAddrs: [AudioObjectPropertyAddress] = [
    vmvAddr,
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                               mScope: kAudioObjectPropertyScopeOutput,
                               mElement: kAudioObjectPropertyElementMain),
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                               mScope: kAudioObjectPropertyScopeOutput,
                               mElement: 1)
]

func readVolume(_ dev: AudioDeviceID) -> Float32? {
    for a in volAddrs { if let v = getF32(dev, a) { return v } }
    return nil
}

@discardableResult
func writeVolume(_ dev: AudioDeviceID, _ v: Float32) -> Bool {
    for a in volAddrs { if setF32(dev, a, v) { return true } }
    return false
}

let muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                          mScope: kAudioObjectPropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)

func readMute(_ dev: AudioDeviceID) -> Bool {
    var a = muteAddr
    guard AudioObjectHasProperty(dev, &a) else { return false }
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr && v != 0
}

func writeMute(_ dev: AudioDeviceID, _ on: Bool) {
    var a = muteAddr
    guard AudioObjectHasProperty(dev, &a) else { return }
    var v: UInt32 = on ? 1 : 0
    _ = AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
}

// ------------------------------------------------------------------
// diagnostics: written to stderr, so run the binary in a terminal to see them
// ------------------------------------------------------------------

func diag(_ msg: String) {
    FileHandle.standardError.write(Data("lvol-diag: \(msg)\n".utf8))
}

// ------------------------------------------------------------------
// perceptual <-> amplitude mapping (same as the lvol CLI)
// ------------------------------------------------------------------

func levelToScalar(_ level: Double) -> Float32 {
    let l = min(max(level, 0), 100)
    let db = (l / 100.0 - 1.0) * kRangeDB
    let s = pow(10.0, db / 20.0)
    return Float32(min(max(s, 1e-7), 1.0))
}

func scalarToLevel(_ s: Float32) -> Double {
    if s <= 0 { return 0 }
    let db = 20.0 * log10(Double(s))
    return min(max(100.0 * (1.0 + min(db, 0) / kRangeDB), 0), 100)
}

func scalarToDb(_ s: Float32) -> Double {
    s <= 0 ? -120.0 : 20.0 * log10(Double(s))
}

// ------------------------------------------------------------------
// the popover panel
// ------------------------------------------------------------------

final class ControlViewController: NSViewController {
    private let deviceLabel = NSTextField(labelWithString: "Output")
    private let valueLabel = NSTextField(labelWithString: "--")
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let muteButton = NSButton(title: "Mute", target: nil, action: nil)

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 168))

        deviceLabel.font = .systemFont(ofSize: 11)
        deviceLabel.textColor = .secondaryLabelColor
        deviceLabel.lineBreakMode = .byTruncatingTail
        deviceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)

        muteButton.bezelStyle = .rounded
        muteButton.target = self
        muteButton.action = #selector(toggleMute)

        var presets: [NSButton] = []
        for p in [25, 50, 75, 100] {
            let b = NSButton(title: "\(p)", target: self, action: #selector(presetTapped(_:)))
            b.bezelStyle = .rounded
            b.tag = p
            presets.append(b)
        }
        let presetRow = NSStackView(views: presets)
        presetRow.orientation = .horizontal
        presetRow.spacing = 6
        presetRow.distribution = .fillEqually

        let stack = NSStackView(views: [deviceLabel, valueLabel, slider, presetRow, muteButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            slider.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            presetRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            muteButton.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
        ])

        self.view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func refresh() {
        let d = defaultOutput()
        deviceLabel.stringValue = d == 0 ? "No output device" : outputDeviceName(d)
        if let s = readVolume(d) {
            slider.doubleValue = scalarToLevel(s)
            updateValueLabel(s)
        } else {
            valueLabel.stringValue = "n/a"
        }
        updateMuteButton(readMute(d))
    }

    private func updateValueLabel(_ s: Float32) {
        valueLabel.stringValue = String(
            format: "%.0f / 100     %+.1f dB     %.2f%%",
            scalarToLevel(s), scalarToDb(s), Double(s) * 100.0)
    }

    @objc private func sliderChanged() {
        let s = levelToScalar(slider.doubleValue)
        writeVolume(defaultOutput(), s)
        updateValueLabel(s)
    }

    @objc private func presetTapped(_ sender: NSButton) {
        slider.doubleValue = Double(sender.tag)
        sliderChanged()
    }

    @objc private func toggleMute() {
        let d = defaultOutput()
        let muted = !readMute(d)
        writeMute(d, muted)
        updateMuteButton(muted)
    }

    /* The button label names the action it will perform next. */
    private func updateMuteButton(_ muted: Bool) {
        muteButton.title = muted ? "Unmute" : "Mute"
    }

    /* Step the perceptual level; used by the +/- keyboard shortcuts. */
    func adjustLevel(_ delta: Double) {
        let d = defaultOutput()
        let cur = readVolume(d).map(scalarToLevel) ?? 0
        let next = min(max(cur + delta, 0), 100)
        let s = levelToScalar(next)
        writeVolume(d, s)
        slider.doubleValue = next
        updateValueLabel(s)
    }
}

// ------------------------------------------------------------------
// app
// ------------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let vc = ControlViewController()
    private var window: NSWindow?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        diag("didFinishLaunching bundleID=\(Bundle.main.bundleIdentifier ?? "nil")")
        installMainMenu()

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 214),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "lvol"
        win.contentViewController = vc
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
        NSApp.activate(ignoringOtherApps: true)
        diag("window shown")

        /* Local key monitor: it only fires for events delivered to this app's
         * key window, so nothing happens while the app is not focused. */
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let win = self.window, event.window === win else { return event }
            switch event.characters ?? "" {
            case "+", "=": self.vc.adjustLevel(2);  return nil
            case "-", "_": self.vc.adjustLevel(-2); return nil
            default:       return event
            }
        }

        /* Keep the display in sync if the volume changes elsewhere
         * (volume keys, another app) while the window is visible. */
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.vc.refresh()
        }
    }

    /* A minimal programmatic main menu. AppKit only routes the Cmd+Q
     * shortcut to -[NSApplication terminate:] when a menu item carrying it
     * exists, so without this the app could never quit from the keyboard. */
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let quitItem = NSMenuItem(title: "Quit " + ProcessInfo.processInfo.processName,
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command] /* the default, made explicit */
        appMenu.addItem(quitItem)

        /* A File menu carrying the Close item, per the usual macOS layout.
         * AppKit routes Cmd+W through the main menu to -[NSWindow performClose:],
         * so without a menu item holding that shortcut the window never closes.
         * target stays nil so the key window handles it via the responder chain. */
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)

        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        let closeItem = NSMenuItem(title: "Close",
                                   action: #selector(NSWindow.performClose(_:)),
                                   keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command] /* the default, made explicit */
        fileMenu.addItem(closeItem)

        NSApp.mainMenu = mainMenu
    }

    /* Clicking the Dock icon reopens the window after it was closed. */
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

// ------------------------------------------------------------------
// headless use / self-test:  lvol.app/Contents/MacOS/LvolApp --get
//                            LvolApp --set <0-100>
// ------------------------------------------------------------------

func printUsage(_ to: FileHandle) {
    let text = """
    usage:
      LvolApp --get            print the current output volume
      LvolApp --set <0-100>    set the perceptual level (dB-uniform, 0-100)
      LvolApp -h, --help       show this help

    With no arguments the desktop window opens instead.
    """
    to.write(Data((text + "\n").utf8))
}

let cliArgs = CommandLine.arguments
if cliArgs.contains("-h") || cliArgs.contains("--help") {
    printUsage(FileHandle.standardOutput)
    exit(0)
}
if cliArgs.contains("--get") {
    let d = defaultOutput()
    if let s = readVolume(d) {
        print(String(format: "%@\nlevel %.1f/100   %+.1f dB   %.3f%%",
                     outputDeviceName(d), scalarToLevel(s), scalarToDb(s), Double(s) * 100))
    } else {
        print("could not read volume")
    }
    exit(0)
}
if let i = cliArgs.firstIndex(of: "--set") {
    guard i + 1 < cliArgs.count, let lv = Double(cliArgs[i + 1]) else {
        FileHandle.standardError.write(Data("lvol: --set needs a number 0-100 (see --help)\n".utf8))
        exit(2)
    }
    let d = defaultOutput()
    let s = levelToScalar(lv)
    let ok = writeVolume(d, s)
    print(String(format: "set %.1f -> %.3f%%  (%@)", lv, Double(s) * 100, ok ? "ok" : "failed"))
    exit(ok ? 0 : 1)
}

// ------------------------------------------------------------------
// GUI
// ------------------------------------------------------------------

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
