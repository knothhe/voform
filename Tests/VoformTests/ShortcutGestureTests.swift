import XCTest
@testable import Voform

final class ShortcutGestureTests: XCTestCase {
    func testToggleOnlyOnFreshPress() {
        var gesture = ShortcutGesture(shortcut: .optionSpace, mode: .toggle)
        XCTAssertEqual(gesture.handle(.down, keyCode: 49, modifiers: .option, time: 0).action, .toggle)
        let repeated = gesture.handle(.down, keyCode: 49, modifiers: .option, isRepeat: true, time: 0.1)
        XCTAssertNil(repeated.action)
        XCTAssertTrue(repeated.consume)
        let release = gesture.handle(.up, keyCode: 49, modifiers: [], time: 0.2)
        XCTAssertNil(release.action)
        XCTAssertTrue(release.consume)
        XCTAssertEqual(gesture.handle(.down, keyCode: 49, modifiers: .option, time: 0.3).action, .toggle)
    }

    func testHoldEndsWhenModifierReleasedFirst() {
        var gesture = ShortcutGesture(shortcut: .optionSpace, mode: .hold)
        XCTAssertEqual(gesture.handle(.down, keyCode: 49, modifiers: .option, time: 0).action, .begin)
        XCTAssertEqual(gesture.handle(.flagsChanged, keyCode: 58, modifiers: [], time: 0.1).action, .finish)
        let release = gesture.handle(.up, keyCode: 49, modifiers: [], time: 0.2)
        XCTAssertNil(release.action)
        XCTAssertTrue(release.consume)
    }

    func testHoldEndsWhenSpaceReleasedFirst() {
        var gesture = ShortcutGesture(shortcut: .optionSpace, mode: .hold)
        XCTAssertEqual(gesture.handle(.down, keyCode: 49, modifiers: .option, time: 0).action, .begin)
        XCTAssertEqual(gesture.handle(.up, keyCode: 49, modifiers: .option, time: 0.1).action, .finish)
        XCTAssertNil(gesture.handle(.flagsChanged, keyCode: 58, modifiers: [], time: 0.2).action)
    }

    func testOtherCombinationsPassThrough() {
        var gesture = ShortcutGesture(shortcut: .optionSpace, mode: .toggle)
        for modifiers: ShortcutModifiers in [[], .command, [.option, .shift]] {
            let result = gesture.handle(.down, keyCode: 49, modifiers: modifiers, time: 0)
            XCTAssertNil(result.action)
            XCTAssertFalse(result.consume)
        }
    }

    func testStandaloneFnTogglesOnRelease() {
        var gesture = ShortcutGesture(shortcut: .function, mode: .toggle)
        let down = gesture.handle(.flagsChanged, keyCode: 63, modifiers: .function, time: 0)
        XCTAssertNil(down.action)
        XCTAssertFalse(down.consume)
        XCTAssertEqual(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], time: 0.1).action, .toggle)
        XCTAssertNil(gesture.handle(.flagsChanged, keyCode: 63, modifiers: .function, time: 1).action)
        XCTAssertEqual(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], time: 1.1).action, .toggle)
    }

    func testFnFunctionKeyDoesNotToggleOrConsume() {
        for releaseFnFirst in [false, true] {
            var gesture = ShortcutGesture(shortcut: .function, mode: .toggle)
            var results = [gesture.handle(.flagsChanged, keyCode: 63, modifiers: .function, time: 0)]
            results.append(gesture.handle(.down, keyCode: 122, modifiers: .function, time: 0.1))
            if releaseFnFirst {
                results.append(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], time: 0.2))
                results.append(gesture.handle(.up, keyCode: 122, modifiers: [], time: 0.3))
            } else {
                results.append(gesture.handle(.up, keyCode: 122, modifiers: .function, time: 0.2))
                results.append(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], time: 0.3))
            }
            XCTAssertTrue(results.allSatisfy { $0.action == nil && !$0.consume })
        }
    }

    func testFnWithModifiersAndLongHoldDoNotToggle() {
        var gesture = ShortcutGesture(shortcut: .function, mode: .toggle)
        _ = gesture.handle(.flagsChanged, keyCode: 63, modifiers: .function, time: 0)
        _ = gesture.handle(.flagsChanged, keyCode: 55, modifiers: [.function, .command], time: 0.1)
        _ = gesture.handle(.flagsChanged, keyCode: 55, modifiers: .function, time: 0.2)
        XCTAssertNil(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], time: 0.3).action)
        _ = gesture.handle(.flagsChanged, keyCode: 63, modifiers: .function, time: 1)
        XCTAssertNil(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], time: 2).action)
    }

    func testKeyHeldBeforeFnDoesNotToggle() {
        var gesture = ShortcutGesture(shortcut: .function, mode: .toggle)
        _ = gesture.handle(.down, keyCode: 0, modifiers: [], time: 0)
        _ = gesture.handle(.flagsChanged, keyCode: 63, modifiers: .function, time: 0.1)
        XCTAssertNil(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], time: 0.2).action)
    }

    func testEscapeCancelsAndSwallowsReleaseOnlyWhileRecording() {
        var gesture = ShortcutGesture(shortcut: .optionSpace, mode: .hold)
        XCTAssertFalse(gesture.handle(.down, keyCode: 53, modifiers: [], time: 0).consume)
        _ = gesture.handle(.down, keyCode: 49, modifiers: .option, time: 1)
        XCTAssertEqual(gesture.handle(.down, keyCode: 53, modifiers: .option, time: 1.1, canCancel: true).action, .cancel)
        let repeated = gesture.handle(.down, keyCode: 53, modifiers: [], isRepeat: true, time: 1.2)
        XCTAssertNil(repeated.action)
        XCTAssertTrue(repeated.consume)
        XCTAssertTrue(gesture.handle(.up, keyCode: 53, modifiers: [], time: 1.3).consume)
        XCTAssertNil(gesture.handle(.up, keyCode: 49, modifiers: [], time: 1.4).action)
    }

    func testHoldingReturnFinishesOnlyWhileRecording() {
        var gesture = ShortcutGesture(shortcut: .optionSpace, mode: .toggle)
        let idlePress = gesture.handle(.down, keyCode: 36, modifiers: [], time: 0)
        XCTAssertNil(idlePress.action)
        XCTAssertFalse(idlePress.consume)

        let press = gesture.handle(.down, keyCode: 36, modifiers: [], time: 1, canCancel: true)
        XCTAssertNil(press.action)
        XCTAssertTrue(press.consume)
        XCTAssertEqual(press.enterHoldEvent, .began)
        let held = gesture.handle(.down, keyCode: 36, modifiers: [], isRepeat: true, time: 1.5, canCancel: true)
        XCTAssertNil(held.action)
        XCTAssertNil(held.enterHoldEvent)
        XCTAssertTrue(held.consume)
        let repeated = gesture.handle(.down, keyCode: 36, modifiers: [], isRepeat: true, time: 1.6, canCancel: true)
        XCTAssertNil(repeated.action)
        XCTAssertTrue(repeated.consume)
        let release = gesture.handle(.up, keyCode: 36, modifiers: [], time: 1.7)
        XCTAssertTrue(release.consume)
        XCTAssertEqual(release.enterHoldEvent, .ended)
    }

    func testTappingEnterDoesNotFinishAndKeypadEnterAlsoWorks() {
        var gesture = ShortcutGesture(shortcut: .optionSpace, mode: .toggle)
        XCTAssertNil(gesture.handle(.down, keyCode: 36, modifiers: [], time: 0, canCancel: true).action)
        let release = gesture.handle(.up, keyCode: 36, modifiers: [], time: 0.1, canCancel: true)
        XCTAssertTrue(release.consume)
        XCTAssertEqual(release.enterHoldEvent, .ended)
        let keypadEnter = gesture.handle(.down, keyCode: 76, modifiers: [], time: 1, canCancel: true)
        XCTAssertNil(keypadEnter.action)
        XCTAssertEqual(keypadEnter.enterHoldEvent, .began)
    }

    func testModifiedReturnCanStillBeUsedAsConfiguredShortcut() {
        let shortcut = HoldShortcut(keyCode: 36, modifiers: .option, keyTitle: "Return")
        var gesture = ShortcutGesture(shortcut: shortcut, mode: .toggle)
        XCTAssertEqual(
            gesture.handle(.down, keyCode: 36, modifiers: .option, time: 0, canCancel: true).action,
            .toggle
        )
    }

    func testFnHoldCombinationCancelsWithoutSubmitting() {
        var gesture = ShortcutGesture(shortcut: .function, mode: .hold)
        XCTAssertEqual(gesture.handle(.flagsChanged, keyCode: 63, modifiers: .function, time: 0).action, .begin)
        XCTAssertEqual(gesture.handle(.down, keyCode: 122, modifiers: .function, time: 0.1).action, .cancel)
        XCTAssertNil(gesture.handle(.flagsChanged, keyCode: 63, modifiers: [], time: 0.2).action)
    }
}
