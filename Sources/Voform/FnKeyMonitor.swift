import AppKit
import ApplicationServices

final class ShortcutMonitor {
    var onHeldChanged: ((Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false
    private(set) var shortcut: HoldShortcut

    init(shortcut: HoldShortcut) {
        self.shortcut = shortcut
    }

    func setShortcut(_ shortcut: HoldShortcut) {
        guard shortcut != self.shortcut else { return }
        if isHeld {
            isHeld = false
            onHeldChanged?(false)
        }
        self.shortcut = shortcut
    }

    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if monitor.isHeld {
                    monitor.isHeld = false
                    DispatchQueue.main.async { monitor.onHeldChanged?(false) }
                }
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }

            if monitor.shortcut.isModifierOnly {
                guard type == .flagsChanged else {
                    return Unmanaged.passUnretained(event)
                }
                let held = ShortcutModifiers(eventFlags: event.flags).contains(monitor.shortcut.modifiers)
                guard held != monitor.isHeld else {
                    return Unmanaged.passUnretained(event)
                }
                monitor.isHeld = held
                DispatchQueue.main.async { monitor.onHeldChanged?(held) }
                return nil
            }

            let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == monitor.shortcut.keyCode else {
                return Unmanaged.passUnretained(event)
            }

            switch type {
            case .keyDown:
                let modifiers = ShortcutModifiers(eventFlags: event.flags)
                guard modifiers == monitor.shortcut.modifiers else {
                    return Unmanaged.passUnretained(event)
                }
                if !monitor.isHeld {
                    monitor.isHeld = true
                    DispatchQueue.main.async { monitor.onHeldChanged?(true) }
                }
                // Swallow the initial press and key-repeat events.
                return nil
            case .keyUp where monitor.isHeld:
                monitor.isHeld = false
                DispatchQueue.main.async { monitor.onHeldChanged?(false) }
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        }

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: opaqueSelf
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        runLoopSource = nil
        eventTap = nil
        isHeld = false
    }

    deinit { stop() }

}
