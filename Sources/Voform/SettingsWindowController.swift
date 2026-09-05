import AppKit
import ApplicationServices
import AVFoundation
import Speech

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum Pane: String, CaseIterable {
        case general
        case refinement
        case privacy

        var title: String {
            switch self {
            case .general: return "General"
            case .refinement: return "AI Refinement"
            case .privacy: return "Privacy"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .refinement: return "wand.and.stars"
            case .privacy: return "hand.raised"
            }
        }

        var toolbarIdentifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("settings.\(rawValue)")
        }
    }

    private enum PermissionKind: CaseIterable {
        case microphone
        case speechRecognition
        case accessibility
        case inputMonitoring

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .speechRecognition: return "Speech Recognition"
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var detail: String {
            switch self {
            case .microphone: return "Captures audio during dictation."
            case .speechRecognition: return "Turns speech into text on your Mac."
            case .accessibility: return "Inserts the transcript into the active app."
            case .inputMonitoring: return "Detects the dictation shortcut system-wide."
            }
        }

        var settingsURL: String {
            switch self {
            case .microphone:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .speechRecognition:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .inputMonitoring:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
        }
    }

    private let paneHost = NSView()
    private var paneViews: [Pane: NSView] = [:]
    private var selectedPane = Pane.general

    private let languageButton = NSPopUpButton()
    private let recordingModeButton = NSPopUpButton()
    private let useFnButton = NSButton(title: "Use Fn", target: nil, action: nil)
    private let currentShortcutLabel = NSTextField()
    private let changeShortcutButton = NSButton(title: "Record…", target: nil, action: nil)
    private let resetShortcutButton = NSButton(title: "Use Default", target: nil, action: nil)
    private let shortcutStatusLabel = NSTextField(labelWithString: "")

    private let refinementToggle = NSButton(checkboxWithTitle: "Enable AI refinement", target: nil, action: nil)
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let refinementStatusLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: "Test Connection", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Configuration", target: nil, action: nil)

    private var permissionStatusLabels: [PermissionKind: NSTextField] = [:]
    private let refiner: LLMRefiner
    private var pendingShortcut = HoldShortcut.defaultShortcut
    private var shortcutEventMonitor: Any?

    var onSave: (() -> Void)?
    var onShortcutRecordingChanged: ((Bool) -> Void)?

    init(refiner: LLMRefiner) {
        self.refiner = refiner
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voform Settings"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.tabbingMode = .disallowed
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        window.delegate = self
        buildUI()
        buildToolbar()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(pane: Pane = .general) {
        pendingShortcut = Preferences.shared.holdShortcut
        updateGeneralControls()
        updateRefinementControls()
        refreshPermissionStatuses()
        selectPane(pane)

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "VoformSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window?.toolbar = toolbar
        window?.toolbar?.selectedItemIdentifier = Pane.general.toolbarIdentifier
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(paneHost)
        NSLayoutConstraint.activate([
            paneHost.topAnchor.constraint(equalTo: content.topAnchor),
            paneHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            paneHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneHost.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        paneViews[.general] = buildGeneralPane()
        paneViews[.refinement] = buildRefinementPane()
        paneViews[.privacy] = buildPrivacyPane()
        selectPane(.general)
    }

    private func buildGeneralPane() -> NSView {
        languageButton.removeAllItems()
        for language in RecognitionLanguage.allCases {
            languageButton.addItem(withTitle: language.title)
            languageButton.lastItem?.representedObject = language.rawValue
        }
        languageButton.target = self
        languageButton.action = #selector(languageChanged)
        languageButton.controlSize = .large

        currentShortcutLabel.isEditable = false
        currentShortcutLabel.isSelectable = false
        currentShortcutLabel.isBezeled = true
        currentShortcutLabel.bezelStyle = .roundedBezel
        currentShortcutLabel.drawsBackground = true
        currentShortcutLabel.alignment = .center
        currentShortcutLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        currentShortcutLabel.controlSize = .large
        currentShortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        currentShortcutLabel.widthAnchor.constraint(equalToConstant: 126).isActive = true

        changeShortcutButton.target = self
        changeShortcutButton.action = #selector(beginShortcutRecording)
        changeShortcutButton.bezelStyle = .rounded
        changeShortcutButton.controlSize = .large

        resetShortcutButton.target = self
        resetShortcutButton.action = #selector(resetShortcut)
        resetShortcutButton.bezelStyle = .inline
        resetShortcutButton.isBordered = false
        resetShortcutButton.contentTintColor = .controlAccentColor

        let shortcutControls = NSStackView(views: [currentShortcutLabel, changeShortcutButton])
        shortcutControls.orientation = .horizontal
        shortcutControls.alignment = .centerY
        shortcutControls.spacing = 8

        shortcutStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcutStatusLabel.textColor = .secondaryLabelColor
        shortcutStatusLabel.lineBreakMode = .byTruncatingTail
        shortcutStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        useFnButton.target = self
        useFnButton.action = #selector(useFnShortcut)
        useFnButton.bezelStyle = .inline
        useFnButton.isBordered = false
        let shortcutFooter = NSStackView(views: [shortcutStatusLabel, flexibleSpace(), useFnButton, resetShortcutButton])
        shortcutFooter.orientation = .horizontal
        shortcutFooter.alignment = .centerY
        shortcutFooter.spacing = 8

        let shortcutCard = makeCard([
            settingRow(
                title: "Dictation shortcut",
                detail: "Choose a key combination or use Fn.",
                control: shortcutControls,
                height: 68
            ),
            separator(),
            paddedView(shortcutFooter, top: 8, bottom: 8)
        ])

        let languageCard = makeCard([
            settingRow(
                title: "Recognition language",
                detail: "Used by Apple Speech Recognition.",
                control: languageButton,
                height: 68
            )
        ])

        for mode in RecordingMode.allCases {
            recordingModeButton.addItem(withTitle: mode.title)
            recordingModeButton.lastItem?.representedObject = mode.rawValue
        }
        recordingModeButton.target = self
        recordingModeButton.action = #selector(recordingModeChanged)
        let modeCard = makeCard([
            settingRow(
                title: "Recording mode",
                detail: "Toggle: press again to finish. Hold: release to finish.",
                control: recordingModeButton,
                height: 68
            )
        ])

        return makePane(
            title: "General",
            subtitle: "Choose how Voform listens and starts dictation.",
            cards: [languageCard, shortcutCard, modeCard]
        )
    }

    private func buildRefinementPane() -> NSView {
        refinementToggle.target = self
        refinementToggle.action = #selector(refinementToggled)
        refinementToggle.controlSize = .large

        let toggleCard = makeCard([
            settingRow(
                title: "Improve transcripts with AI",
                detail: "Polishes wording and punctuation before text is inserted.",
                control: refinementToggle,
                height: 68,
                hidesTitle: true
            )
        ])

        baseURLField.placeholderString = "https://api.openai.com/v1"
        apiKeyField.placeholderString = "API key"
        modelField.placeholderString = "gpt-4.1-mini"
        for field in [baseURLField, apiKeyField, modelField] {
            field.controlSize = .large
        }

        let grid = NSGridView(views: [
            [formLabel("API Base URL"), baseURLField],
            [formLabel("API Key"), apiKeyField],
            [formLabel("Model"), modelField]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 390
        grid.translatesAutoresizingMaskIntoConstraints = false

        refinementStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        refinementStatusLabel.textColor = .secondaryLabelColor
        refinementStatusLabel.lineBreakMode = .byTruncatingTail
        refinementStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveLLMSettings)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let actions = NSStackView(views: [refinementStatusLabel, flexibleSpace(), testButton, saveButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let formStack = NSStackView(views: [grid, separator(), actions])
        formStack.orientation = .vertical
        formStack.alignment = .width
        formStack.spacing = 14
        formStack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)

        let configurationCard = makeCard([formStack], inset: false)
        return makePane(
            title: "AI Refinement",
            subtitle: "Use any OpenAI-compatible endpoint to clean up transcripts.",
            cards: [toggleCard, configurationCard]
        )
    }

    private func buildPrivacyPane() -> NSView {
        var rows: [NSView] = []
        for (index, permission) in PermissionKind.allCases.enumerated() {
            let status = NSTextField(labelWithString: "Checking…")
            status.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            status.alignment = .right
            permissionStatusLabels[permission] = status

            let openButton = NSButton(title: "Open Settings…", target: self, action: #selector(openPermissionSettings(_:)))
            openButton.bezelStyle = .rounded
            openButton.controlSize = .small
            openButton.identifier = NSUserInterfaceItemIdentifier(permission.settingsURL)

            let controls = NSStackView(views: [status, openButton])
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = 10
            rows.append(settingRow(title: permission.title, detail: permission.detail, control: controls, height: 62))
            if index < PermissionKind.allCases.count - 1 { rows.append(separator()) }
        }

        let permissionsCard = makeCard(rows)
        let note = NSTextField(wrappingLabelWithString: "After changing a permission in System Settings, return to Voform. Some changes may require relaunching the app.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        return makePane(
            title: "Privacy & Permissions",
            subtitle: "Voform only needs access required for voice input.",
            cards: [permissionsCard],
            footer: note
        )
    }

    private func makePane(title: String, subtitle: String, cards: [NSView], footer: NSView? = nil) -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3

        var arranged = cards
        if let footer { arranged.append(footer) }
        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14

        header.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(header)
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: pane.topAnchor, constant: 26),
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor, constant: -22)
        ])
        return pane
    }

    private func makeCard(_ views: [NSView], inset: Bool = true) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = 0
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        if inset {
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        return box
    }

    private func settingRow(
        title: String,
        detail: String,
        control: NSView,
        height: CGFloat,
        hidesTitle: Bool = false
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor

        let labels = NSStackView(views: hidesTitle ? [detailLabel] : [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labels, flexibleSpace(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        return row
    }

    private func paddedView(_ view: NSView, top: CGFloat, bottom: CGFloat) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom)
        ])
        return container
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func formLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    private func selectPane(_ pane: Pane) {
        if pane != .general { endShortcutRecording() }
        selectedPane = pane
        paneHost.subviews.forEach { $0.removeFromSuperview() }
        guard let paneView = paneViews[pane] else { return }
        paneHost.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: paneHost.topAnchor),
            paneView.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
            paneView.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor)
        ])
        window?.toolbar?.selectedItemIdentifier = pane.toolbarIdentifier
        window?.title = "\(pane.title) — Voform Settings"
        if pane == .privacy { refreshPermissionStatuses() }
    }

    private func updateGeneralControls() {
        if let index = RecognitionLanguage.allCases.firstIndex(of: Preferences.shared.language) {
            languageButton.selectItem(at: index)
        }
        currentShortcutLabel.stringValue = pendingShortcut.displayTitle
        currentShortcutLabel.textColor = .labelColor
        changeShortcutButton.title = "Record…"
        changeShortcutButton.action = #selector(beginShortcutRecording)
        resetShortcutButton.isEnabled = true
        resetShortcutButton.isHidden = pendingShortcut == .defaultShortcut
        recordingModeButton.selectItem(at: RecordingMode.allCases.firstIndex(of: Preferences.shared.recordingMode) ?? 0)
        shortcutStatusLabel.stringValue = pendingShortcut.isModifierOnly
            ? "Set the macOS Globe-key action to Do Nothing."
            : "⌥ Space recommended. Esc cancels a recording."
        shortcutStatusLabel.toolTip = pendingShortcut.isModifierOnly
            ? "In System Settings → Keyboard, set Press Globe key to to Do Nothing. In toggle mode, tap Fn alone within 0.5 seconds; Fn combinations are ignored. In hold mode, another key cancels the recording."
            : nil
        shortcutStatusLabel.textColor = .secondaryLabelColor
    }

    private func updateRefinementControls() {
        let configuration = Preferences.shared.llmConfiguration
        refinementToggle.state = Preferences.shared.llmEnabled ? .on : .off
        baseURLField.stringValue = configuration.baseURL
        apiKeyField.stringValue = configuration.apiKey
        modelField.stringValue = configuration.model
        refinementStatusLabel.stringValue = ""
        updateRefinementFieldState()
    }

    private func updateRefinementFieldState() {
        let enabled = refinementToggle.state == .on
        for control in [baseURLField, apiKeyField, modelField, testButton, saveButton] {
            control.isEnabled = enabled
        }
    }

    @objc private func languageChanged() {
        guard let rawValue = languageButton.selectedItem?.representedObject as? String,
              let language = RecognitionLanguage(rawValue: rawValue) else { return }
        Preferences.shared.language = language
        onSave?()
    }

    @objc private func recordingModeChanged() {
        endShortcutRecording()
        guard let value = recordingModeButton.selectedItem?.representedObject as? String,
              let mode = RecordingMode(rawValue: value) else { return }
        Preferences.shared.recordingMode = mode
        updateGeneralControls()
        onSave?()
    }

    @objc private func useFnShortcut() {
        endShortcutRecording()
        pendingShortcut = .function
        commitShortcut()
    }

    @objc private func refinementToggled() {
        Preferences.shared.llmEnabled = refinementToggle.state == .on
        updateRefinementFieldState()
        refinementStatusLabel.textColor = .secondaryLabelColor
        refinementStatusLabel.stringValue = Preferences.shared.llmEnabled ? "Refinement enabled." : "Refinement disabled."
        onSave?()
    }

    @objc private func saveLLMSettings() {
        Preferences.shared.llmConfiguration = currentConfiguration
        refinementStatusLabel.textColor = .systemGreen
        refinementStatusLabel.stringValue = "Configuration saved."
        onSave?()
    }

    @objc private func beginShortcutRecording() {
        endShortcutRecording()
        currentShortcutLabel.stringValue = "Press keys…"
        currentShortcutLabel.textColor = .secondaryLabelColor
        shortcutStatusLabel.stringValue = "Press a shortcut once, or press Esc to cancel."
        changeShortcutButton.title = "Cancel"
        changeShortcutButton.action = #selector(cancelShortcutRecording)
        resetShortcutButton.isEnabled = false

        shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                cancelShortcutRecording()
                return nil
            }
            guard !event.isARepeat else { return nil }
            let shortcut = HoldShortcut(event: event)
            guard !shortcut.modifiers.isEmpty else {
                shortcutStatusLabel.stringValue = "Include a modifier, e.g. ⌥ Space, or choose Use Fn."
                return nil
            }
            pendingShortcut = shortcut
            endShortcutRecording()
            commitShortcut()
            return nil
        }
        onShortcutRecordingChanged?(true)
    }

    @objc private func cancelShortcutRecording() {
        endShortcutRecording()
        shortcutStatusLabel.stringValue = "No changes made."
    }

    @objc private func resetShortcut() {
        endShortcutRecording()
        pendingShortcut = .defaultShortcut
        commitShortcut()
    }

    private func commitShortcut() {
        Preferences.shared.holdShortcut = pendingShortcut
        updateGeneralControls()
        shortcutStatusLabel.textColor = .systemGreen
        if !pendingShortcut.isModifierOnly {
            shortcutStatusLabel.stringValue = "Shortcut updated — it applies immediately."
        }
        onSave?()
    }

    private func endShortcutRecording() {
        if let shortcutEventMonitor {
            NSEvent.removeMonitor(shortcutEventMonitor)
            self.shortcutEventMonitor = nil
            onShortcutRecordingChanged?(false)
        }
        changeShortcutButton.title = "Record…"
        changeShortcutButton.action = #selector(beginShortcutRecording)
        resetShortcutButton.isEnabled = true
        currentShortcutLabel.stringValue = pendingShortcut.displayTitle
        currentShortcutLabel.textColor = .labelColor
    }

    private var currentConfiguration: LLMConfiguration {
        LLMConfiguration(
            baseURL: baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @objc private func testConnection() {
        let configuration = currentConfiguration
        guard configuration.isConfigured else {
            refinementStatusLabel.textColor = .systemRed
            refinementStatusLabel.stringValue = "Complete all three fields first."
            return
        }
        testButton.isEnabled = false
        saveButton.isEnabled = false
        refinementStatusLabel.textColor = .secondaryLabelColor
        refinementStatusLabel.stringValue = "Testing…"
        Task {
            do {
                _ = try await refiner.refine("测试 Python 和 JSON。", configuration: configuration)
                Preferences.shared.llmConfiguration = configuration
                refinementStatusLabel.textColor = .systemGreen
                refinementStatusLabel.stringValue = "Connection successful and saved."
                onSave?()
            } catch {
                refinementStatusLabel.textColor = .systemRed
                refinementStatusLabel.stringValue = error.localizedDescription
            }
            updateRefinementFieldState()
        }
    }

    @objc private func openPermissionSettings(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func applicationDidBecomeActive() {
        if selectedPane == .privacy { refreshPermissionStatuses() }
    }

    private func refreshPermissionStatuses() {
        setPermissionStatus(
            .microphone,
            allowed: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            pending: AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        )
        setPermissionStatus(
            .speechRecognition,
            allowed: SFSpeechRecognizer.authorizationStatus() == .authorized,
            pending: SFSpeechRecognizer.authorizationStatus() == .notDetermined
        )
        setPermissionStatus(.accessibility, allowed: AXIsProcessTrusted(), pending: false)
        setPermissionStatus(.inputMonitoring, allowed: CGPreflightListenEventAccess(), pending: false)
    }

    private func setPermissionStatus(_ permission: PermissionKind, allowed: Bool, pending: Bool) {
        guard let label = permissionStatusLabels[permission] else { return }
        if allowed {
            label.stringValue = "● Allowed"
            label.textColor = .systemGreen
        } else if pending {
            label.stringValue = "● Not requested"
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = "● Required"
            label.textColor = .systemOrange
        }
    }

    func windowWillClose(_ notification: Notification) {
        endShortcutRecording()
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = Pane.allCases.first(where: { $0.toolbarIdentifier == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarPaneSelected(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.toolbarIdentifier)
    }

    @objc private func toolbarPaneSelected(_ sender: NSToolbarItem) {
        guard let pane = Pane.allCases.first(where: { $0.toolbarIdentifier == sender.itemIdentifier }) else { return }
        selectPane(pane)
    }
}
