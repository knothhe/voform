import Foundation

/// Keyboard gesture recognition, independent of the event tap and microphone.
struct ShortcutGesture {
    enum Action: Equatable { case begin, finish, toggle, cancel }
    enum Event { case down, up, flagsChanged }
    enum EnterHoldEvent: Equatable { case began, ended }
    struct Result {
        var action: Action? = nil
        var consume = false
        var enterHoldEvent: EnterHoldEvent? = nil
    }

    var shortcut: HoldShortcut
    var mode: RecordingMode
    private var keyHeld = false
    private var holdActive = false
    private var fnHeld = false
    private var fnCandidate = false
    private var fnPressedAt: TimeInterval = 0
    private var otherKeys: Set<UInt16> = []
    private var escapeHeld = false
    private var enterHeld = false

    init(shortcut: HoldShortcut, mode: RecordingMode) {
        self.shortcut = shortcut
        self.mode = mode
    }

    mutating func handle(_ event: Event, keyCode: UInt16, modifiers: ShortcutModifiers,
                         isRepeat: Bool = false, time: TimeInterval,
                         canCancel: Bool = false) -> Result {
        if keyCode == 53 {
            if event == .down && (canCancel || escapeHeld) {
                let action: Action? = !escapeHeld && !isRepeat ? .cancel : nil
                escapeHeld = true
                fnCandidate = false
                holdActive = false
                return Result(action: action, consume: true)
            }
            if event == .up && escapeHeld {
                escapeHeld = false
                return Result(consume: true)
            }
        }

        // A bare Return or keypad Enter is reserved while recording. The monitor
        // turns this press/release pair into a deliberate, timed hold gesture.
        if (keyCode == 36 || keyCode == 76) && modifiers.isEmpty && (canCancel || enterHeld) {
            if event == .down {
                if !enterHeld {
                    enterHeld = true
                    return Result(consume: true, enterHoldEvent: .began)
                }
                return Result(consume: true)
            }
            if event == .up && enterHeld {
                enterHeld = false
                return Result(consume: true, enterHoldEvent: .ended)
            }
        }

        if shortcut.isModifierOnly {
            // Leave Fn events available to macOS so Fn+F1, Fn+arrows, etc. keep working.
            if event == .down { otherKeys.insert(keyCode) }
            if event == .up { otherKeys.remove(keyCode) }
            let held = modifiers.contains(.function)
            if event == .flagsChanged && held && !fnHeld {
                fnHeld = true
                fnPressedAt = time
                fnCandidate = modifiers == .function && otherKeys.isEmpty
                if mode == .hold && fnCandidate {
                    holdActive = true
                    return Result(action: .begin)
                }
            }
            if fnHeld && (event == .down || event == .up || (held && modifiers != .function)) {
                fnCandidate = false
                if holdActive {
                    holdActive = false
                    return Result(action: .cancel)
                }
            }
            if event == .flagsChanged && !held && fnHeld {
                fnHeld = false
                defer { fnCandidate = false; holdActive = false }
                if mode == .hold { return Result(action: holdActive ? .finish : nil) }
                // Only a standalone, brief tap toggles recording; long Fn holds do nothing.
                if fnCandidate && modifiers.isEmpty && time - fnPressedAt <= 0.5 {
                    return Result(action: .toggle)
                }
            }
            return Result()
        }

        if event == .flagsChanged && holdActive && modifiers != shortcut.modifiers {
            holdActive = false
            return Result(action: .finish)
        }
        guard keyCode == shortcut.keyCode else { return Result() }
        if event == .down {
            if keyHeld { return Result(consume: true) }
            guard !isRepeat, modifiers == shortcut.modifiers else { return Result() }
            keyHeld = true
            holdActive = mode == .hold
            return Result(action: mode == .toggle ? .toggle : .begin, consume: true)
        }
        if event == .up && keyHeld {
            keyHeld = false
            defer { holdActive = false }
            return Result(action: holdActive ? .finish : nil, consume: true)
        }
        return Result()
    }
}
