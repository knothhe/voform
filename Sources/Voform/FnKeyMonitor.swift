import AppKit
import ApplicationServices

final class ShortcutMonitor {
    var onAction: ((ShortcutGesture.Action) -> Void)?
    var onInterrupted: (() -> Void)?
    var canCancel = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var generation = 0
    private var gesture: ShortcutGesture
    var shortcut: HoldShortcut { gesture.shortcut }
    var mode: RecordingMode { gesture.mode }

    init(shortcut: HoldShortcut, mode: RecordingMode) {
        gesture = ShortcutGesture(shortcut: shortcut, mode: mode)
    }

    func configure(shortcut: HoldShortcut, mode: RecordingMode) {
        guard shortcut != self.shortcut || mode != self.mode else { return }
        generation += 1
        onInterrupted?()
        gesture = ShortcutGesture(shortcut: shortcut, mode: mode)
    }

    func start() -> Bool {
        guard eventTap == nil else { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.generation += 1
                monitor.gesture = ShortcutGesture(shortcut: monitor.shortcut, mode: monitor.mode)
                monitor.onInterrupted?()
                if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let kind: ShortcutGesture.Event
            switch type {
            case .keyDown: kind = .down
            case .keyUp: kind = .up
            case .flagsChanged: kind = .flagsChanged
            default: return Unmanaged.passUnretained(event)
            }
            let result = monitor.gesture.handle(
                kind,
                keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: ShortcutModifiers(eventFlags: event.flags),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                time: ProcessInfo.processInfo.systemUptime,
                canCancel: monitor.canCancel
            )
            // Keep microphone startup and UI work out of the event-tap callback.
            if let action = result.action {
                let generation = monitor.generation
                DispatchQueue.main.async { [weak monitor] in
                    guard let monitor, generation == monitor.generation else { return }
                    monitor.onAction?(action)
                }
            }
            return result.consume ? nil : Unmanaged.passUnretained(event)
        }
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: opaqueSelf
        ) else { return false }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        generation += 1
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        gesture = ShortcutGesture(shortcut: shortcut, mode: mode)
        onInterrupted?()
    }

    deinit { stop() }
}
