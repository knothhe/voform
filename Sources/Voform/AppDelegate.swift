import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences = Preferences.shared
    private lazy var shortcutMonitor = ShortcutMonitor(shortcut: preferences.holdShortcut)
    private let transcriber = SpeechTranscriber()
    private let recordingPanel = RecordingPanelController()
    private let textInjector = TextInjector()
    private let llmRefiner = LLMRefiner()
    private lazy var settingsController = SettingsWindowController(refiner: llmRefiner)
    private var statusItem: NSStatusItem!
    private var languageItems: [RecognitionLanguage: NSMenuItem] = [:]
    private var refinementToggleItem: NSMenuItem!
    private var shortcutHintItem: NSMenuItem!
    private var isRecording = false
    private var isProcessing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenuBar()
        requestSystemPermissions()

        shortcutMonitor.onHeldChanged = { [weak self] held in self?.handleShortcut(held: held) }
        if !shortcutMonitor.start() {
            showPermissionAlert(message: "Voform could not monitor the dictation shortcut. Enable Input Monitoring and Accessibility for Voform in System Settings, then relaunch it.")
        }
        Task { await transcriber.requestPermissions() }
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

        let refinementMenu = NSMenu()
        refinementToggleItem = NSMenuItem(title: "Enabled", action: #selector(toggleRefinement(_:)), keyEquivalent: "")
        refinementToggleItem.target = self
        refinementMenu.addItem(refinementToggleItem)
        let refinementItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        refinementItem.submenu = refinementMenu
        menu.addItem(refinementItem)

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
            shortcutMonitor.setShortcut(preferences.holdShortcut)
            updateMenuStates()
        }
        settingsController.onShortcutRecordingChanged = { [weak self] isRecordingShortcut in
            guard let self else { return }
            if isRecordingShortcut {
                shortcutMonitor.stop()
            } else if !shortcutMonitor.start() {
                showPermissionAlert(message: "Voform could not resume shortcut monitoring. Check Input Monitoring and Accessibility permissions, then relaunch it.")
            }
        }
    }

    private func updateMenuStates() {
        for (language, item) in languageItems {
            item.state = language == preferences.language ? .on : .off
        }
        refinementToggleItem?.state = preferences.llmEnabled ? .on : .off
        shortcutHintItem?.title = shortcutHint
        statusItem?.button?.toolTip = shortcutToolTip
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = RecognitionLanguage(rawValue: rawValue) else { return }
        preferences.language = language
        updateMenuStates()
    }

    @objc private func toggleRefinement(_ sender: NSMenuItem) {
        preferences.llmEnabled.toggle()
        updateMenuStates()
    }

    @objc private func openSettings() { settingsController.show() }

    @objc private func openPrivacySettings() {
        settingsController.show(pane: .privacy)
    }

    private func handleShortcut(held: Bool) {
        if held { beginRecording() } else { finishRecording() }
    }

    private var shortcutHint: String {
        "Hold \(preferences.holdShortcut.displayTitle) to dictate"
    }

    private var shortcutToolTip: String {
        "Voform — \(shortcutHint)"
    }

    private func beginRecording() {
        guard !isRecording, !isProcessing else { return }
        do {
            try transcriber.start(
                language: preferences.language,
                onPartial: { [weak self] text in self?.recordingPanel.updateText(text) },
                onAudioLevel: { [weak self] level in self?.recordingPanel.setAudioLevel(level) },
                onError: { [weak self] _ in self?.recordingPanel.updateText("Recognition unavailable — release to retry") }
            )
            isRecording = true
            recordingPanel.show()
        } catch {
            showPermissionAlert(message: error.localizedDescription)
        }
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        isProcessing = true
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

            let configuration = preferences.llmConfiguration
            if preferences.llmEnabled && configuration.isConfigured {
                recordingPanel.updateText("Refining…")
                do {
                    transcript = try await llmRefiner.refine(transcript, configuration: configuration)
                } catch {
                    // Refinement is optional: preserve and inject the original transcript on API failure.
                    NSLog("Voform refinement failed: %@", error.localizedDescription)
                }
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
