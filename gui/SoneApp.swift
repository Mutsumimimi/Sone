/*
 * Sone — a tiny desktop-window app for dB-uniform output volume.
 *
 * It opens a single window holding a slider that drives the default output
 * device's floating-point volume scalar on a dB-uniform scale, so quiet levels
 * are as adjustable as loud ones. Mirrors the `sone` CLI.
 *
 * The window is the main UI. A menu-bar extra (NSStatusItem) offers the common
 * actions: left-click reopens the window, right-click shows a menu. The app
 * keeps running (Dock icon) after the window is closed.
 *
 * License: MIT
 */

import AppKit
import CoreAudio
import AudioToolbox
import Carbon.HIToolbox

// ------------------------------------------------------------------
// CoreAudio helpers
// ------------------------------------------------------------------

let kDefaultRangeDB: Double = 60.0 /* level 0 -> -60 dB, level 100 -> 0 dB */

/* The dB span the 0-100 scale covers. Stored in UserDefaults so the Settings
 * window can change it; falls back to the CLI's default when unset. Note the
 * CLI (sone.c) is untouched - this is GUI-only state. */
let kRangeDBKey = "rangeDB"

var kRangeDB: Double {
    let v = UserDefaults.standard.double(forKey: kRangeDBKey)
    return v > 0 ? v : kDefaultRangeDB
}

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
    FileHandle.standardError.write(Data("sone-diag: \(msg)\n".utf8))
}

// ------------------------------------------------------------------
// perceptual <-> amplitude mapping (same as the sone CLI)
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
// global hot keys (Carbon RegisterEventHotKey)
//
// Real system-wide hot keys: unlike NSEvent.addGlobalMonitorForEvents these
// need no Accessibility permission *and* actually claim the combination, so a
// press cannot also leak through to whatever app is frontmost. The system
// delivers kEventHotKeyPressed on the main event loop; we hop to the main
// queue anyway rather than assume it.
// ------------------------------------------------------------------

/* The in-window +/- shortcut delta for a key event, or nil if the local
 * monitor must leave the event alone. Crucially it claims *only* combos with
 * no Command/Option/Control: those belong to a menu shortcut or a global hot
 * key, and handling them here as well would double-fire (e.g. a hot key
 * recorded as ⌃= or ⌥= would step the volume twice in one press). Shift is
 * deliberately kept, since ⇧= types "+" and ⇧- types "_" - the very
 * characters this shortcut is meant to catch. */
func localHotKeyDelta(characters: String, modifiers: NSEvent.ModifierFlags) -> Double? {
    guard modifiers.intersection([.command, .option, .control]).isEmpty else { return nil }
    switch characters {
    case "+", "=": return 2
    case "-", "_": return -2
    default:       return nil
    }
}

/* A physical key plus its Carbon modifier mask (cmdKey/optionKey/...). Stored
 * in UserDefaults as two Ints, so no custom codable plumbing is needed. */
struct HotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

let kHotKeyUpKey = "hotKeyUp"
let kHotKeyDownKey = "hotKeyDown"

/* Master on/off for the global hot keys, stored in UserDefaults. Unset means
 * enabled, so an existing install keeps working after this setting is added
 * (UserDefaults.bool alone would wrongly read "off" for an absent key). */
let kHotKeysEnabledKey = "hotKeysEnabled"

var hotKeysEnabled: Bool {
    let ud = UserDefaults.standard
    return ud.object(forKey: kHotKeysEnabledKey) == nil ? true
                                                       : ud.bool(forKey: kHotKeysEnabledKey)
}

/* Defaults: Option + '=' (shown as '+') raises, Option + '-' lowers - the same
 * +-2 step as the in-window shortcuts. '=' is the physical key; '+' itself
 * would require Shift, so it is the usual stand-in for it. */
let defaultHotKeyUp = HotKey(keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(optionKey))
let defaultHotKeyDown = HotKey(keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(optionKey))

func loadHotKey(_ key: String, fallingBackTo def: HotKey) -> HotKey {
    if let a = UserDefaults.standard.array(forKey: key) as? [Int], a.count == 2 {
        return HotKey(keyCode: UInt32(a[0]), modifiers: UInt32(a[1]))
    }
    return def
}

func saveHotKey(_ key: String, _ hk: HotKey) {
    UserDefaults.standard.set([Int(hk.keyCode), Int(hk.modifiers)], forKey: key)
}

/* NSEvent modifiers -> Carbon mask. Only the four "real" modifiers, so caps
 * lock and friends can never make a binding unreachable. */
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.option)  { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    if flags.contains(.shift)   { m |= UInt32(shiftKey) }
    return m
}

/* The reverse, for display: Control, Option, Shift, Command - the order macOS
 * prints modifier symbols in. */
func modifierSymbols(_ m: UInt32) -> String {
    var s = ""
    if m & UInt32(controlKey) != 0 { s += "\u{2303}" } /* ⌃ */
    if m & UInt32(optionKey)  != 0 { s += "\u{2325}" } /* ⌥ */
    if m & UInt32(shiftKey)   != 0 { s += "\u{21E7}" } /* ⇧ */
    if m & UInt32(cmdKey)     != 0 { s += "\u{2318}" } /* ⌘ */
    return s
}

/* Human name for a key code; covers what people actually bind and falls back
 * to "Key<n>" for anything exotic. */
func keyName(_ keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_ANSI_Equal: return "+"        /* the physical '=' key */
    case kVK_ANSI_Minus: return "-"
    case kVK_ANSI_LeftBracket: return "["
    case kVK_ANSI_RightBracket: return "]"
    case kVK_ANSI_Slash: return "/"
    case kVK_ANSI_Backslash: return "\\"
    case kVK_ANSI_Comma: return ","
    case kVK_ANSI_Period: return "."
    case kVK_ANSI_Semicolon: return ";"
    case kVK_ANSI_Quote: return "'"
    case kVK_ANSI_Grave: return "`"
    case kVK_Space: return "Space"
    case kVK_Return: return "\u{21A9}"     /* ↩ */
    case kVK_Tab: return "\u{21E5}"        /* ⇥ */
    case kVK_Delete: return "\u{232B}"     /* ⌫ */
    case kVK_Escape: return "\u{238B}"     /* ⎋ */
    case kVK_LeftArrow: return "\u{2190}"  /* ← */
    case kVK_RightArrow: return "\u{2192}" /* → */
    case kVK_UpArrow: return "\u{2191}"    /* ↑ */
    case kVK_DownArrow: return "\u{2193}"  /* ↓ */
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    default: return "Key\(keyCode)"
    }
}

func shortcutDisplay(_ hk: HotKey) -> String {
    modifierSymbols(hk.modifiers) + " " + keyName(hk.keyCode)
}

/* Keyboard auto-repeat timing, in seconds: the delay before a held key first
 * repeats, then the steady repeat interval. These are read from the same
 * NSGlobalDomain settings the system's own key handling uses, where
 * InitialKeyRepeat / KeyRepeat are counts of 1/60 s frames. Anything missing
 * or outside a sane range falls back to a sensible default, so a bogus value
 * can never make the repeat spin at 0 s or feel frozen for minutes. */
func systemKeyRepeatIntervals() -> (delay: TimeInterval, interval: TimeInterval) {
    let defaultDelay: TimeInterval = 0.4     /* ~24 frames */
    let defaultInterval: TimeInterval = 0.05 /* ~3 frames */
    let domain = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")

    func seconds(_ key: String, maxFrames: Double) -> TimeInterval? {
        guard let n = domain?[key] as? NSNumber else { return nil }
        let frames = n.doubleValue
        guard frames > 0, frames <= maxFrames else { return nil }
        return frames / 60.0
    }

    /* Reject absurd values: a delay over ~3 s or an interval over ~0.5 s would
     * make holding the key feel broken. (When the user turns keyboard repeat
     * off, KeyRepeat is set to a huge sentinel, which lands here too and
     * falls back to the default interval.) */
    let delay = seconds("InitialKeyRepeat", maxFrames: 180) ?? defaultDelay
    let interval = seconds("KeyRepeat", maxFrames: 30) ?? defaultInterval
    return (delay, interval)
}

/* Owns the Carbon registrations. One shared event handler routes every
 * kEventHotKeyPressed to the closure registered for that hot key's id
 * (1 = up, 2 = down) and every kEventHotKeyReleased to that id's repeat
 * stopper. Holding a key fires once, then repeats on a timer until release. */
final class HotKeyManager {
    private static let signature = OSType(0x73_6F_6E_65) /* 'sone' */

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

    /* Auto-repeat while a hot key is held. One timer per hot-key id, so the up
     * and down keys never interfere with each other, plus the delay/interval
     * in effect (re-read from NSGlobalDomain on every re-bind). */
    private var repeatTimers: [UInt32: Timer] = [:]
    /* Monotonic start time of each id's in-flight repeat, keyed the same as
     * repeatTimers. systemUptime can't go backwards on a wall-clock change, so
     * the watchdog below can never fire early after a time adjustment. */
    private var repeatStart: [UInt32: TimeInterval] = [:]
    private var repeatDelay: TimeInterval = 0.4
    private var repeatInterval: TimeInterval = 0.05

    /* Hard ceiling on how long one held key may keep repeating. If Carbon's
     * "released" event is ever dropped - e.g. the menu bar is opened while the
     * hot key is held, moving the main thread into an event-tracking run-loop
     * mode that swallows the release - the 30 Hz repeat timer would otherwise
     * spin forever, stepping the volume long after it hit 0 or 100. At 30/s x
     * 60 steps this ceiling spans far beyond the whole 0-100 range, so no
     * genuine hold (a few seconds at most) can ever reach it. */
    private static let maxRepeatDuration: TimeInterval = 10.0

    /* The last pair that registered cleanly. Kept so a failed re-bind can be
     * rolled back to a working state instead of silently leaving the user
     * with no global hot key at all. */
    private var lastGoodUp: HotKey?
    private var lastGoodDown: HotKey?

    /* Replace the whole set. Returns true only if *every* key registered.
     * Old registrations are dropped first, so a combo is never registered
     * twice. If any key fails, the half-applied registration is undone and the
     * previously working pair is put back, so the return value never lies
     * about the live state. */
    @discardableResult
    func register(up: HotKey, upAction: @escaping () -> Void,
                  down: HotKey, downAction: @escaping () -> Void) -> Bool {
        /* Remember the pair to restore on failure *before* touching anything. */
        let prevUp = lastGoodUp
        let prevDown = lastGoodDown

        unregisterAll()
        installHandler()
        actions = [1: upAction, 2: downAction]

        /* Match the hand-feel of the system's own key repeat. Read once per
         * bind; a change in System Settings is picked up on the next re-bind. */
        let rate = systemKeyRepeatIntervals()
        repeatDelay = rate.delay
        repeatInterval = rate.interval

        let upOK = add(up, id: 1)
        let downOK = add(down, id: 2)

        if upOK && downOK {
            lastGoodUp = up
            lastGoodDown = down
            return true
        }

        /* Roll back: drop whatever half-applied pair landed, then re-register
         * the last pair that worked (if there ever was one). */
        unregisterAll()
        if let pu = prevUp, let pd = prevDown {
            if add(pu, id: 1) && add(pd, id: 2) {
                lastGoodUp = pu
                lastGoodDown = pd
            } else {
                /* Unlikely: the previously working pair no longer registers
                 * (e.g. another app grabbed it in the meantime). */
                unregisterAll()
                lastGoodUp = nil
                lastGoodDown = nil
            }
        }
        NSSound.beep()
        diag("hotkey rebind failed (up keyCode=\(up.keyCode) mods=\(up.modifiers), "
             + "down keyCode=\(down.keyCode) mods=\(down.modifiers)); restored previous binding")
        return false
    }

    /* Register one key. Returns whether it landed. */
    @discardableResult
    private func add(_ hk: HotKey, id: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: HotKeyManager.signature, id: id)
        let st = RegisterEventHotKey(hk.keyCode, hk.modifiers, hkID,
                                     GetEventDispatcherTarget(), 0, &ref)
        if st == noErr, let ref {
            refs.append(ref)
            return true
        }
        /* Most often the combo is already taken by another app. */
        diag("hotkey \(id == 1 ? "up" : "down") register failed: status=\(st) "
             + "keyCode=\(hk.keyCode) mods=\(hk.modifiers)")
        return false
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        /* Listen for both edges: pressed starts the action and its repeat,
         * released stops the repeat. */
        var spec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let st = InstallEventHandler(GetEventDispatcherTarget(),
                                     hotKeyEventCallback,
                                     spec.count, &spec,
                                     Unmanaged.passUnretained(self).toOpaque(),
                                     &handlerRef)
        if st != noErr { diag("hotkey InstallEventHandler failed: status=\(st)") }
    }

    private func unregisterAll() {
        /* Cancel any in-flight repeats first, so a freshly unregistered hot key
         * can never keep stepping the volume. */
        stopAllRepeats()
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
    }

    /* Drop every registration (the master switch's "off" path) without
     * clearing lastGood*, so a later re-enable can restore the same pair. The
     * combos stop being claimed system-wide, i.e. they are released for other
     * apps. No-op if nothing is registered. */
    func unregisterAllKeys() {
        unregisterAll()
    }

    /* Called from the C callback for either edge; run on the main thread (the
     * Carbon handler already is, but the hop keeps us safe if that changes,
     * and Timer needs a live run loop - the main one). */
    fileprivate func dispatch(id: UInt32, kind: UInt32) {
        let run = { [weak self] in
            guard let self else { return }
            if kind == UInt32(kEventHotKeyReleased) {
                self.handleReleased(id: id)
            } else {
                self.handlePressed(id: id)
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    /* Press: fire once right away (unchanged single-press behaviour), then
     * start a repeat that fires after the system's initial delay and then at
     * the steady interval until the key is released. */
    private func handlePressed(id: UInt32) {
        guard let action = actions[id] else { return }
        action()
        /* A lost "released" would leave a stale timer behind; drop any first so
         * repeats can never stack up. */
        stopRepeat(id: id)
        /* Stamp the monotonic start time for this press; the watchdog measures
         * from here. Done after stopRepeat so it can't read a stale stamp. */
        repeatStart[id] = ProcessInfo.processInfo.systemUptime
        /* Build the timers manually and add them to .common rather than using a
         * scheduledTimer (which is pre-added to .default only, so the repeat
         * would pause while the main loop sits in a modal/tracking mode, e.g.
         * with a menu open). Adding manually also avoids double-firing. */
        let delayTimer = Timer(timeInterval: repeatDelay, repeats: false) { [weak self] _ in
            guard let self, self.actions[id] != nil else { self?.stopRepeat(id: id); return }
            self.repeatTick(id: id)
            /* Switch to the steady interval once the first repeat has fired. */
            let steady = Timer(timeInterval: self.repeatInterval, repeats: true) { [weak self] _ in
                self?.repeatTick(id: id)
            }
            RunLoop.main.add(steady, forMode: .common)
            self.repeatTimers[id] = steady
        }
        RunLoop.main.add(delayTimer, forMode: .common)
        repeatTimers[id] = delayTimer
    }

    /* Release: stop repeating at once. */
    private func handleReleased(id: UInt32) {
        stopRepeat(id: id)
    }

    /* One repeat step, guarded: if the id is no longer registered, stop. */
    private func repeatTick(id: UInt32) {
        guard let action = actions[id] else { stopRepeat(id: id); return }
        /* Watchdog: if the matching "released" was lost, cut the repeat off
         * instead of stepping the volume forever. The duration is measured from
         * the monotonic press time; on expiry we stop *without* running the
         * action so the volume can't take one more step past the ceiling. */
        if let start = repeatStart[id],
           ProcessInfo.processInfo.systemUptime - start > HotKeyManager.maxRepeatDuration {
            diag("hotkey \(id == 1 ? "up" : "down") repeat hit maxRepeatDuration "
                 + "(\(HotKeyManager.maxRepeatDuration)s); release likely lost, stopping")
            stopRepeat(id: id)
            return
        }
        action()
    }

    private func stopRepeat(id: UInt32) {
        repeatTimers.removeValue(forKey: id)?.invalidate()
        repeatStart.removeValue(forKey: id)
    }

    private func stopAllRepeats() {
        for (_, t) in repeatTimers { t.invalidate() }
        repeatTimers.removeAll()
        repeatStart.removeAll()
    }
}

/* The C callback cannot capture, so it finds its owner through the userData
 * pointer handed to InstallEventHandler. */
private let hotKeyEventCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hkID = EventHotKeyID()
    let st = GetEventParameter(event,
                               EventParamName(kEventParamDirectObject),
                               EventParamType(typeEventHotKeyID),
                               nil,
                               MemoryLayout<EventHotKeyID>.size,
                               nil,
                               &hkID)
    guard st == noErr else { return OSStatus(eventNotHandledErr) }
    let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    mgr.dispatch(id: hkID.id, kind: GetEventKind(event))
    return noErr
}

/* A button that doubles as a shortcut recorder: click it and the next key
 * press is captured (Esc cancels). The combo must include at least one of
 * Command/Option/Control/Shift, so a binding can never swallow plain typing. */
final class ShortcutRecorderButton: NSButton {
    /* (keyCode, Carbon modifier mask) of the captured combo. */
    var onCapture: ((UInt32, UInt32) -> Void)?

    private var shortcutText = ""
    private var recording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
    }

    /* Drives the idle label. Ignored while recording, so the prompt stays. */
    func setShortcut(_ text: String) {
        shortcutText = text
        if !recording { title = text }
    }

    /* NSButton refuses first responder by default; the recorder needs it to
     * receive keyDown. */
    override var acceptsFirstResponder: Bool { true }

    /* Swallow the click instead of firing an action; a click while recording
     * cancels it. */
    override func mouseDown(with event: NSEvent) {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        recording = true
        title = "Press a key\u{2026}"
        if let w = window { w.makeFirstResponder(self) }
    }

    private func stopRecording() {
        recording = false
        title = shortcutText
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        /* Esc cancels the capture and keeps the previous binding. */
        if Int(event.keyCode) == kVK_Escape { stopRecording(); return }

        let mods = carbonModifiers(from: event.modifierFlags)
        guard mods != 0 else {
            /* No modifier would hijack ordinary typing. */
            NSSound.beep()
            return
        }
        recording = false
        let kc = UInt32(event.keyCode)
        shortcutText = shortcutDisplay(HotKey(keyCode: kc, modifiers: mods))
        title = shortcutText
        onCapture?(kc, mods)
    }
}

// ------------------------------------------------------------------
// the popover panel
// ------------------------------------------------------------------

final class ControlViewController: NSViewController {
    private let deviceLabel = NSTextField(labelWithString: "Output")
    private let valueLabel = NSTextField(labelWithString: "--")
    private let slider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let muteButton = NSButton(title: "Mute", target: nil, action: nil)

    /* The last perceptual level the device was heard at, i.e. its volume while
     * *not* muted. macOS parks the volume scalar at 0 when the system volume
     * keys mute the device, so the raw reading is useless for "where should we
     * resume". Kept up to date whenever the device is unmuted (0 included) and
     * left untouched while muted. Starts at 0, so booting into a muted device
     * resumes from 0 as requested. */
    private var lastAudibleLevel: Double = 0

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 134))

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

        let stack = NSStackView(views: [deviceLabel, valueLabel, slider, muteButton])
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
        let muted = readMute(d)
        if muted {
            /* Muted: the device often reports volume 0 (the system parked it
             * there), so show the level the user last heard instead of that 0.
             * Dim the slider as a cue that it is muted, but leave it draggable -
             * a drag still adjusts the volume (and unmutes) from this value. */
            slider.doubleValue = lastAudibleLevel
            updateValueLabel(levelToScalar(lastAudibleLevel))
            slider.alphaValue = 0.5
        } else if let s = readVolume(d) {
            lastAudibleLevel = scalarToLevel(s) /* remember it, 0 included */
            slider.doubleValue = scalarToLevel(s)
            updateValueLabel(s)
            slider.alphaValue = 1.0
        } else {
            valueLabel.stringValue = "n/a"
            slider.alphaValue = 1.0
        }
        updateMuteButton(muted)
    }

    private func updateValueLabel(_ s: Float32) {
        valueLabel.stringValue = String(
            format: "%.0f / 100     %+.1f dB     %.2f%%",
            scalarToLevel(s), scalarToDb(s), Double(s) * 100.0)
    }

    @objc private func sliderChanged() {
        applyLevel(slider.doubleValue)
    }

    @objc private func toggleMute() {
        let d = defaultOutput()
        if readMute(d) {
            /* Unmute: also restore the remembered level, so playback resumes
             * where the user left off instead of at the 0 the system wrote. */
            applyLevel(lastAudibleLevel)
        } else {
            /* Mute only - leave the volume scalar alone so the remembered level
             * survives for the next unmute. refresh() dims the slider. */
            writeMute(d, true)
            refresh()
        }
    }

    /* The button label names the action it will perform next. */
    private func updateMuteButton(_ muted: Bool) {
        muteButton.title = muted ? "Unmute" : "Mute"
    }

    /* Write a new perceptual level and, as part of the same gesture, clear
     * mute: adjusting the volume is an explicit "I want to hear it" action, so
     * it must not leave the device silent. This matters because macOS's volume
     * keys drive the mute property *and* the volume, and clearing one does not
     * clear the other. Order matters - volume first, then unmute - so audio
     * never briefly plays at the old level. The slider and label are rendered
     * from the requested level, and lastAudibleLevel is refreshed because the
     * device is now unmuted. Every interactive volume path (slider drag,
     * in-window +/-, global hot key) funnels through here. */
    private func applyLevel(_ level: Double) {
        let d = defaultOutput()
        let next = min(max(level, 0), 100)
        let s = levelToScalar(next)
        writeVolume(d, s)
        if readMute(d) { writeMute(d, false) }
        lastAudibleLevel = next
        slider.doubleValue = next
        slider.alphaValue = 1.0
        updateValueLabel(s)
        updateMuteButton(false)
    }

    /* Step the perceptual level; used by the +/- keyboard shortcuts. While
     * muted the raw volume is meaningless (the system parks it at 0), so step
     * from the remembered audible level instead. */
    func adjustLevel(_ delta: Double) {
        let d = defaultOutput()
        let base = readMute(d)
            ? lastAudibleLevel
            : (readVolume(d).map(scalarToLevel) ?? lastAudibleLevel)
        applyLevel(base + delta)
    }
}

// ------------------------------------------------------------------
// settings window
// ------------------------------------------------------------------

/* A code-built Settings window (NSStackView + Auto Layout, like the main one).
 * It hosts the settings the GUI exposes over the CLI; for now just the dB
 * range. Grow it by adding rows to the vertical stack. */
final class SettingsViewController: NSViewController {
    private let rangeTitleLabel = NSTextField(labelWithString: "Minimum volume")
    private let rangeValueLabel = NSTextField(labelWithString: "-- dB")
    /* The slider runs over negative dB values: its value is the dB that level 0
     * maps to ("how low the scale reaches"), e.g. -60 dB. It is stored in
     * UserDefaults as the positive span rangeDB = -sliderValue, so kRangeDB /
     * kDefaultRangeDB and the level<->scalar mappings stay untouched. */
    private let rangeSlider = NSSlider(value: -kDefaultRangeDB, minValue: -120, maxValue: -30,
                                       target: nil, action: nil)

    /* Global-hot-key recorders, one per direction, plus a master switch that
     * unregisters them (freeing the combos for other apps). While it is off
     * the recorders and the Restore button stay clickable - edits are still
     * saved - but are dimmed, since they have no live effect. */
    private let upRecorder = ShortcutRecorderButton()
    private let downRecorder = ShortcutRecorderButton()
    private let hotKeysTitleLabel = NSTextField(labelWithString: "Global hot keys")
    private let hotKeysSwitch = NSSwitch()
    private let restoreButton = NSButton(title: "Restore Defaults", target: nil, action: nil)

    /* Invoked after a setting changes, so the main window can re-render. */
    var onChange: (() -> Void)?

    /* Wired by the app delegate: read the live bindings, and apply a new pair
     * (persist + re-register) when the user records or restores one. */
    var currentHotKeys: (() -> (up: HotKey, down: HotKey))?
    var applyHotKeys: ((HotKey, HotKey) -> Void)?

    /* Wired by the app delegate: read the master switch state, and apply a
     * change (persist + register/unregister). */
    var currentHotKeysEnabled: (() -> Bool)?
    var onToggleHotKeys: ((Bool) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 248))

        rangeTitleLabel.font = .systemFont(ofSize: 11)
        rangeTitleLabel.textColor = .secondaryLabelColor
        rangeTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rangeTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        rangeValueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        rangeValueLabel.alignment = .right
        rangeValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        rangeSlider.isContinuous = true
        rangeSlider.target = self
        rangeSlider.action = #selector(minimumVolumeChanged)

        /* low / high name the two ends of the track, matching the title's style. */
        let lowLabel = NSTextField(labelWithString: "low")
        let highLabel = NSTextField(labelWithString: "high")
        for l in [lowLabel, highLabel] {
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
        }
        /* A spacer pulls the two labels to opposite ends of the row. */
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let scaleRow = NSStackView(views: [lowLabel, spacer, highLabel])
        scaleRow.orientation = .horizontal
        scaleRow.distribution = .fill

        /* Title on the left, live value on the right; the slider and its
         * low/high scale span the full width below. */
        let header = NSStackView(views: [rangeTitleLabel, rangeValueLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.distribution = .fill

        /* Shortcut rows, in the same title style, plus a way back to defaults.
         * Each recorder shows its combo and captures a new one on click. */
        let upRow = hotKeyRow(title: "Volume up", recorder: upRecorder)
        let downRow = hotKeyRow(title: "Volume down", recorder: downRecorder)
        upRecorder.onCapture = { [weak self] kc, mods in
            self?.captured(up: true, keyCode: kc, modifiers: mods)
        }
        downRecorder.onCapture = { [weak self] kc, mods in
            self?.captured(up: false, keyCode: kc, modifiers: mods)
        }
        restoreButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(restoreDefaultHotKeys)

        let hotKeysRow = hotKeysToggleRow()

        let stack = NSStackView(views: [header, rangeSlider, scaleRow,
                                        hotKeysRow, upRow, downRow, restoreButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
            rangeSlider.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
            scaleRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
            hotKeysRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
            upRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
            downRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
        ])

        self.view = root
    }

    /* A "title ... recorder" row that fills the width, matching the style of
     * the Minimum volume header. */
    private func hotKeyRow(title: String, recorder: ShortcutRecorderButton) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, spacer, recorder])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    /* The master switch row: "Global hot keys ... [switch]", same style as the
     * recorder rows above. */
    private func hotKeysToggleRow() -> NSStackView {
        hotKeysTitleLabel.font = .systemFont(ofSize: 11)
        hotKeysTitleLabel.textColor = .secondaryLabelColor
        hotKeysTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hotKeysTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hotKeysSwitch.target = self
        hotKeysSwitch.action = #selector(hotKeysToggled)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [hotKeysTitleLabel, spacer, hotKeysSwitch])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }

    /* Re-read on every show: the window is reused, so loadView runs only once. */
    override func viewWillAppear() {
        super.viewWillAppear()
        /* slider value = level 0's dB (negative); storage rangeDB = -sliderValue. */
        rangeSlider.doubleValue = -kRangeDB
        updateMinVolumeLabel(-kRangeDB)
        refreshRecorderLabels()
        let on = currentHotKeysEnabled?() ?? true
        hotKeysSwitch.state = on ? .on : .off
        updateHotKeyControlsEnabled(on)
    }

    private func updateMinVolumeLabel(_ db: Double) {
        rangeValueLabel.stringValue = String(format: "%.0f dB", db)
    }

    @objc private func minimumVolumeChanged() {
        let db = rangeSlider.doubleValue.rounded() /* step 1 */
        rangeSlider.doubleValue = db
        UserDefaults.standard.set(-db, forKey: kRangeDBKey) /* store the positive span */
        updateMinVolumeLabel(db)
        onChange?()
    }

    /* ---- global hot keys ---- */

    private func refreshRecorderLabels() {
        let hk = currentHotKeys?() ?? (up: defaultHotKeyUp, down: defaultHotKeyDown)
        upRecorder.setShortcut(shortcutDisplay(hk.up))
        downRecorder.setShortcut(shortcutDisplay(hk.down))
    }

    /* A recorder captured a combo: keep the other direction, apply and show it. */
    private func captured(up: Bool, keyCode: UInt32, modifiers: UInt32) {
        var hk = currentHotKeys?() ?? (up: defaultHotKeyUp, down: defaultHotKeyDown)
        let new = HotKey(keyCode: keyCode, modifiers: modifiers)
        if up { hk.up = new } else { hk.down = new }
        applyHotKeys?(hk.up, hk.down)
        refreshRecorderLabels()
    }

    @objc private func restoreDefaultHotKeys() {
        applyHotKeys?(defaultHotKeyUp, defaultHotKeyDown)
        refreshRecorderLabels()
    }

    /* ---- master hot-key switch ---- */

    @objc private func hotKeysToggled() {
        let on = hotKeysSwitch.state == .on
        updateHotKeyControlsEnabled(on)
        onToggleHotKeys?(on)
    }

    /* Dim the controls that only matter while the hot keys are live, the same
     * 0.5 alpha the main window uses for its muted slider. They stay enabled:
     * a captured combo is still saved (and takes effect when switched back
     * on), it just is not registered while off. */
    private func updateHotKeyControlsEnabled(_ enabled: Bool) {
        let a: CGFloat = enabled ? 1.0 : 0.5
        upRecorder.alphaValue = a
        downRecorder.alphaValue = a
        restoreButton.alphaValue = a
    }
}

// ------------------------------------------------------------------
// app
// ------------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let vc = ControlViewController()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var timer: Timer?

    /* Menu-bar extra. Left-click reopens/refronts the main window; right-click
     * shows a menu of the common actions. Its icon mirrors the mute state, and
     * its menu is rebuilt on every open so it always shows live values. */
    private var statusItem: NSStatusItem?

    /* System-wide hot keys. Loaded from UserDefaults at launch, replaced when
     * the Settings recorder changes a binding. */
    private let hotKeys = HotKeyManager()
    private var hotKeyUp = defaultHotKeyUp
    private var hotKeyDown = defaultHotKeyDown
    /* Mirrors the Settings master switch: when false the Carbon hot keys are
     * not registered at all, so their combos stay free for other apps. */
    private var hotKeysOn = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        diag("didFinishLaunching bundleID=\(Bundle.main.bundleIdentifier ?? "nil")")
        installMainMenu()

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 214),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Sone"
        win.contentViewController = vc
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
        NSApp.activate(ignoringOtherApps: true)
        diag("window shown")

        installStatusItem()

        /* Local key monitor: it only fires for events delivered to this app's
         * key window, so nothing happens while the app is not focused. It
         * ignores any combo that carries Cmd/Option/Control, because those are
         * menu shortcuts or global hot keys and must not be handled a second
         * time here (see localHotKeyDelta). */
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let win = self.window, event.window === win else { return event }
            guard let delta = localHotKeyDelta(characters: event.characters ?? "",
                                               modifiers: event.modifierFlags) else {
                return event
            }
            self.vc.adjustLevel(delta)
            return nil
        }

        /* System-wide hot keys, from UserDefaults (defaults when unset). Unlike
         * the local monitor above these work even when the app is unfocused or
         * its window is closed, because the window object stays alive. */
        hotKeyUp = loadHotKey(kHotKeyUpKey, fallingBackTo: defaultHotKeyUp)
        hotKeyDown = loadHotKey(kHotKeyDownKey, fallingBackTo: defaultHotKeyDown)
        hotKeysOn = hotKeysEnabled
        if hotKeysOn { applyHotKeys(hotKeyUp, hotKeyDown) }

        /* Keep the display in sync if the volume changes elsewhere
         * (volume keys, another app) while the window is visible. */
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            /* The status icon must track mute even while the main window is
             * closed, so update it before the visibility guard below. */
            self.updateStatusIcon()
            guard self.window?.isVisible == true else { return }
            self.vc.refresh()
        }
    }

    /* (Re)register the global hot keys. The actions reuse vc.adjustLevel(_:),
     * the same +-2 step as the in-window +/- shortcuts, so both paths stay in
     * sync and no volume logic is duplicated. Only on full success do we adopt
     * the new pair as the live one; a failure leaves hotKeyUp/hotKeyDown (and
     * HotKeyManager's own state) pointing at whatever is actually registered,
     * so the Settings window keeps showing the real binding. */
    @discardableResult
    private func applyHotKeys(_ up: HotKey, _ down: HotKey) -> Bool {
        let ok = hotKeys.register(up: up,
                                  upAction: { [weak self] in self?.vc.adjustLevel(2) },
                                  down: down,
                                  downAction: { [weak self] in self?.vc.adjustLevel(-2) })
        if ok {
            hotKeyUp = up
            hotKeyDown = down
        }
        return ok
    }

    /* The Settings recorder's write path: re-register first, and persist the
     * new combo only if it fully took. On failure the live binding is rolled
     * back (with a beep) and UserDefaults keeps the old value, so the next
     * launch does not retry the same broken pair. */
    func setHotKeys(up: HotKey, down: HotKey) {
        if hotKeysOn {
            if applyHotKeys(up, down) {
                saveHotKey(kHotKeyUpKey, up)
                saveHotKey(kHotKeyDownKey, down)
            }
        } else {
            /* Master switch is off: remember the combo but leave the Carbon
             * hot keys unregistered; it takes effect when switched back on. */
            hotKeyUp = up
            hotKeyDown = down
            saveHotKey(kHotKeyUpKey, up)
            saveHotKey(kHotKeyDownKey, down)
        }
    }

    func currentHotKeys() -> (up: HotKey, down: HotKey) { (hotKeyUp, hotKeyDown) }

    /* The master switch's write path: persist the flag and, on "on", register
     * the current pair; on "off", drop every registration so the combos are
     * released. */
    func setHotKeysEnabled(_ on: Bool) {
        hotKeysOn = on
        UserDefaults.standard.set(on, forKey: kHotKeysEnabledKey)
        if on {
            applyHotKeys(hotKeyUp, hotKeyDown)
        } else {
            hotKeys.unregisterAllKeys()
        }
    }

    func currentHotKeysEnabled() -> Bool { hotKeysOn }

    /* A minimal programmatic main menu. AppKit only routes the Cmd+Q
     * shortcut to -[NSApplication terminate:] when a menu item carrying it
     * exists, so without this the app could never quit from the keyboard. */
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        /* Settings lives in the App menu, above Quit, per the macOS convention
         * (Cmd+,). target is self, so the action reaches our own method. */
        let settingsItem = NSMenuItem(title: "Settings\u{2026}",
                                      action: #selector(showSettings),
                                      keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command] /* the default, made explicit */
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Sone",
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

    /* Cmd+, (and the menu item). Create the Settings window once and reuse it:
     * a second click must re-front the same window, not stack a new one. */
    @objc private func showSettings() {
        if settingsWindow == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 248),
                               styleMask: [.titled, .closable],
                               backing: .buffered, defer: false)
            win.title = "Sone Settings"
            let svc = SettingsViewController()
            /* Re-render the main window with the new range, if it is open. */
            svc.onChange = { [weak self] in self?.vc.refresh() }
            /* Bridge the shortcut recorders to our live bindings. */
            svc.currentHotKeys = { [weak self] in
                self?.currentHotKeys() ?? (up: defaultHotKeyUp, down: defaultHotKeyDown)
            }
            svc.applyHotKeys = { [weak self] up, down in
                self?.setHotKeys(up: up, down: down)
            }
            /* Bridge the master switch to the live Carbon registrations. */
            svc.currentHotKeysEnabled = { [weak self] in self?.currentHotKeysEnabled() ?? true }
            svc.onToggleHotKeys = { [weak self] on in self?.setHotKeysEnabled(on) }
            win.contentViewController = svc
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    // ------------------------------------------------------------------
    // menu-bar extra (NSStatusItem)
    // ------------------------------------------------------------------

    /* Create the status item once. Left-click reopens the window, right-click
     * pops the menu; -statusItemClicked tells the two apart via the current
     * event. */
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            /* Fire the action for both buttons; the default is left only. */
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        updateStatusIcon()
    }

    /* Mirror the default output's mute state in the icon: speaker.slash while
     * muted, speaker.wave.2 otherwise. Called right after creation and then off
     * the 2 s timer, so it stays correct even while the window is closed. */
    private func updateStatusIcon() {
        let muted = readMute(defaultOutput())
        let name = muted ? "speaker.slash" : "speaker.wave.2"
        let image = NSImage(systemSymbolName: name,
                            accessibilityDescription: muted ? "Muted" : "Volume")
        image?.isTemplate = true /* let the menu bar tint it for light/dark */
        statusItem?.button?.image = image
    }

    /* One action for both mouse buttons; NSApp.currentEvent (not the sender,
     * which is the status button either way) says which button fired. */
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popUpStatusMenu()
        } else {
            showMainWindow()
        }
    }

    /* Open the main window, creating it if it was somehow never built, and
     * bring it to the front without stacking a duplicate. */
    private func showMainWindow() {
        if window == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 214),
                               styleMask: [.titled, .closable, .miniaturizable],
                               backing: .buffered, defer: false)
            win.title = "Sone"
            win.contentViewController = vc
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /* Show the menu. Rather than the deprecated popUpStatusMenu, hand the item a
     * menu and click the button so AppKit runs its normal menu path, then clear
     * the menu again so a later left-click reopens the window. performClick runs
     * the menu modally and only returns once it has been dismissed. */
    private func popUpStatusMenu() {
        guard let item = statusItem else { return }
        item.menu = buildStatusMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    /* Rebuilt on every open, so the shortcut labels, the check mark and the
     * minimum-volume selection all reflect the live state. */
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        /* Show the current binding as text, but leave keyEquivalent empty: the
         * real shortcut is the system-wide hot key, and a key equivalent here
         * would only work while this menu is open. */
        let upItem = NSMenuItem(title: "Volume Up    " + shortcutDisplay(hotKeyUp),
                                action: #selector(statusVolumeUp), keyEquivalent: "")
        upItem.target = self
        menu.addItem(upItem)

        let downItem = NSMenuItem(title: "Volume Down    " + shortcutDisplay(hotKeyDown),
                                  action: #selector(statusVolumeDown), keyEquivalent: "")
        downItem.target = self
        menu.addItem(downItem)

        menu.addItem(.separator())

        let hotKeysItem = NSMenuItem(title: "Global Hot Keys",
                                     action: #selector(statusToggleHotKeys), keyEquivalent: "")
        hotKeysItem.target = self
        hotKeysItem.state = hotKeysOn ? .on : .off
        menu.addItem(hotKeysItem)

        menu.addItem(minimumVolumeItem())

        menu.addItem(.separator())

        /* Same Cmd+, as the App menu, reusing the existing Settings action. */
        let settingsItem = NSMenuItem(title: "Settings\u{2026}",
                                      action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Sone",
                                  action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        return menu
    }

    /* The six preset spans. Each item carries the positive rangeDB value (the
     * negative dB level 0 maps to) - the same convention as the Settings
     * slider - so selecting one writes exactly what that slider would. */
    private func minimumVolumeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Minimum Volume", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = -kRangeDB /* the negative dB level 0 currently maps to */
        for db in [30.0, 45.0, 60.0, 75.0, 90.0, 120.0] {
            let choice = NSMenuItem(title: "\(Int(db)) dB",
                                    action: #selector(statusSetMinimumVolume(_:)),
                                    keyEquivalent: "")
            choice.target = self
            choice.representedObject = db /* positive span, stored verbatim */
            choice.state = abs(current + db) < 0.5 ? .on : .off
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    @objc private func statusVolumeUp() { vc.adjustLevel(2) }

    @objc private func statusVolumeDown() { vc.adjustLevel(-2) }

    @objc private func statusToggleHotKeys() { setHotKeysEnabled(!hotKeysOn) }

    /* Write the chosen span and re-render the main window, mirroring the
     * Settings slider's onChange path. */
    @objc private func statusSetMinimumVolume(_ sender: NSMenuItem) {
        guard let span = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(span, forKey: kRangeDBKey)
        vc.refresh()
    }
}

// ------------------------------------------------------------------
// headless use / self-test:  Sone.app/Contents/MacOS/SoneApp --get
//                            SoneApp --set <0-100>
// ------------------------------------------------------------------

func printUsage(_ to: FileHandle) {
    let text = """
    usage:
      SoneApp --get            print the current output volume
      SoneApp --set <0-100>    set the perceptual level (dB-uniform, 0-100)
      SoneApp -h, --help       show this help

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
        FileHandle.standardError.write(Data("sone: --set needs a number 0-100 (see --help)\n".utf8))
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
