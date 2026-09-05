import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences = Preferences.shared
    private lazy var shortcutMonitor = ShortcutMonitor(shortcut: preferences.holdShortcut, mode: preferences.recordingMode)
    private let transcriber = SpeechTranscriber()
    private let recordingPanel = RecordingPanelController()
    private let textInjector = TextInjector()
    private lazy var settingsController = SettingsWindowController()
    private var statusItem: NSStatusItem!
    private var languageItems: [RecognitionLanguage: NSMenuItem] = [:]
    private var shortcutHintItem: NSMenuItem!
    private var isRecording = false
    private var isProcessing = false
    private var isShowingCancelConfirmation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenuBar()

        shortcutMonitor.onAction = { [weak self] action in self?.handleShortcut(action) }
        shortcutMonitor.onInterrupted = { [weak self] in self?.cancelRecordingImmediately() }
        recordingPanel.onFinish = { [weak self] in self?.finishRecording() }
        recordingPanel.onCancel = { [weak self] in self?.requestCancelRecording() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(cancelRecordingImmediately), name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(cancelRecordingImmediately), name: NSWorkspace.sessionDidResignActiveNotification, object: nil
        )
        applyRecognitionEngine(promptForPermissions: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutMonitor.stop()
        transcriber.cancel()
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenuStates() }

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "Voform")
            button.toolTip = shortcutToolTip
        }

        let menu = NSMenu()
        menu.delegate = self
        shortcutHintItem = NSMenuItem(title: shortcutHint, action: nil, keyEquivalent: "")
        shortcutHintItem.isEnabled = false
        menu.addItem(shortcutHintItem)
        menu.addItem(.separator())

        let languageMenu = NSMenu()
        for language in RecognitionLanguage.allCases {
            let item = NSMenuItem(title: language.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            languageMenu.addItem(item)
            languageItems[language] = item
        }
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let permissions = NSMenuItem(title: "Privacy & Permissions…", action: #selector(openPrivacySettings), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Voform", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        updateMenuStates()

        settingsController.onSave = { [weak self] in
            guard let self else { return }
            shortcutMonitor.configure(shortcut: preferences.holdShortcut, mode: preferences.recordingMode)
            applyRecognitionEngine(promptForPermissions: true)
            updateMenuStates()
        }
        settingsController.onShortcutRecordingChanged = { [weak self] isRecordingShortcut in
            guard let self else { return }
            if isRecordingShortcut {
                shortcutMonitor.stop()
            } else if preferences.recognitionEngine == .apple && !shortcutMonitor.start() {
                showPermissionAlert(message: "Voform could not resume shortcut monitoring. Check Input Monitoring and Accessibility permissions, then relaunch it.")
            }
        }
    }

    private func updateMenuStates() {
        for (language, item) in languageItems {
            item.state = language == preferences.language ? .on : .off
        }
        shortcutHintItem?.title = shortcutHint
        statusItem?.button?.toolTip = shortcutToolTip
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = RecognitionLanguage(rawValue: rawValue) else { return }
        preferences.language = language
        updateMenuStates()
    }

    @objc private func openSettings() { settingsController.show() }

    @objc private func openPrivacySettings() {
        settingsController.show(pane: .privacy)
    }

    private func handleShortcut(_ action: ShortcutGesture.Action) {
        switch action {
        case .begin: beginRecording()
        case .finish: finishRecording()
        case .toggle:
            if isRecording { finishRecording() } else { beginRecording() }
        case .cancel: requestCancelRecording()
        }
    }

    private func requestCancelRecording() {
        guard isRecording, !isShowingCancelConfirmation else { return }
        isShowingCancelConfirmation = true
        shortcutMonitor.canCancel = false
        defer {
            isShowingCancelConfirmation = false
            shortcutMonitor.canCancel = isRecording
        }

        let previousApplication = NSWorkspace.shared.frontmostApplication
        let settingsWindow = settingsController.window
        let shouldRestoreSettingsWindow = settingsWindow?.isVisible == true
        settingsWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Cancel this recording?"
        alert.informativeText = "The current transcript will be discarded."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Discard Recording")
        alert.window.level = .floating
        if alert.runModal() == .alertSecondButtonReturn {
            cancelRecordingImmediately()
        }
        if shouldRestoreSettingsWindow {
            settingsWindow?.orderFront(nil)
        }
        previousApplication?.activate(options: [])
    }

    @objc private func cancelRecordingImmediately() {
        guard isRecording else { return }
        isRecording = false
        shortcutMonitor.canCancel = false
        transcriber.cancel()
        recordingPanel.hide()
    }

    private var shortcutHint: String {
        if preferences.recognitionEngine == .codex {
            return "Use the global dictation shortcut configured in ChatGPT"
        }
        let key = preferences.holdShortcut.displayTitle
        if preferences.recordingMode == .hold { return "Hold \(key) to dictate; release to finish" }
        let verb = preferences.holdShortcut.isModifierOnly ? "Tap" : "Press"
        return "\(verb) \(key) to start / finish dictation"
    }

    private var shortcutToolTip: String {
        "Voform — \(shortcutHint)"
    }

    private func beginRecording() {
        guard preferences.recognitionEngine == .apple, !isRecording, !isProcessing else { return }
        do {
            try transcriber.start(
                language: preferences.language,
                onPartial: { [weak self] text in
                    guard let self, isRecording else { return }
                    recordingPanel.updateText(text)
                },
                onAudioLevel: { [weak self] level in
                    guard let self, isRecording else { return }
                    recordingPanel.setAudioLevel(level)
                },
                onError: { [weak self] _ in
                    guard let self, isRecording else { return }
                    recordingPanel.updateText("Recognition unavailable — finish or cancel")
                }
            )
            isRecording = true
            shortcutMonitor.canCancel = true
            recordingPanel.setRecording(true)
            recordingPanel.show()
        } catch {
            showPermissionAlert(message: error.localizedDescription)
        }
    }

    private func applyRecognitionEngine(promptForPermissions: Bool) {
        if preferences.recognitionEngine == .codex {
            shortcutMonitor.stop()
            transcriber.cancel()
            return
        }

        if promptForPermissions {
            requestSystemPermissions()
            Task { await transcriber.requestPermissions() }
        }
        if !shortcutMonitor.start() {
            showPermissionAlert(message: "Voform could not monitor the dictation shortcut. Enable Input Monitoring and Accessibility for Voform in System Settings, then relaunch it.")
        }
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        shortcutMonitor.canCancel = false
        isProcessing = true
        recordingPanel.setRecording(false)
        recordingPanel.updateText("Transcribing…")
        recordingPanel.setAudioLevel(0)

        Task {
            var transcript: String
            do {
                transcript = try await transcriber.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                recordingPanel.updateText(error.localizedDescription)
                try? await Task.sleep(for: .seconds(1.8))
                recordingPanel.hide()
                isProcessing = false
                return
            }

            do {
                try await textInjector.inject(transcript)
            } catch {
                NSLog("Voform text injection failed: %@", error.localizedDescription)
                showPermissionAlert(message: error.localizedDescription)
            }
            recordingPanel.hide()
            isProcessing = false
        }
    }

    private func requestSystemPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
    }

    private func showPermissionAlert(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Voform"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
