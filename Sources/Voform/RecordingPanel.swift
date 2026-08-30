import AppKit
import QuartzCore

final class CapsuleVisualEffectView: NSVisualEffectView {
    private var maskSize = NSSize.zero

    override func layout() {
        super.layout()

        let radius = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        CATransaction.commit()

        guard bounds.size != maskSize, bounds.width > 0, bounds.height > 0 else { return }
        maskSize = bounds.size

        // Layer clipping alone does not always clip NSVisualEffectView's material
        // sampling while its window is resizing. maskImage clips the material itself,
        // preventing light-mode corners from briefly appearing as square blocks.
        maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        window?.invalidateShadow()
    }
}

final class WaveformView: NSView {
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private var targetLevel: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var timer: Timer?

    override var isFlipped: Bool { true }

    func setAudioLevel(_ value: Double) {
        targetLevel = CGFloat(max(0, min(1, value)))
    }

    func startAnimating() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let smoothing: CGFloat = self.targetLevel > self.displayedLevel ? 0.40 : 0.15
            self.displayedLevel += (self.targetLevel - self.displayedLevel) * smoothing
            self.needsDisplay = true
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        targetLevel = 0
        displayedLevel = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let barWidth: CGFloat = 5
        let gap: CGFloat = 4
        let totalWidth = CGFloat(weights.count) * barWidth + CGFloat(weights.count - 1) * gap
        let startX = (bounds.width - totalWidth) / 2
        let baseHeight: CGFloat = 8
        let dynamicHeight: CGFloat = 24
        NSColor.controlAccentColor.setFill()

        for (index, weight) in weights.enumerated() {
            let jitter = CGFloat.random(in: 0.96...1.04)
            let height = max(5, min(bounds.height, (baseHeight + displayedLevel * dynamicHeight) * weight * jitter))
            let rect = NSRect(
                x: startX + CGFloat(index) * (barWidth + gap),
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

@MainActor
final class RecordingPanelController {
    private let panel: NSPanel
    private let visualEffectView: CapsuleVisualEffectView
    private let waveformView = WaveformView(frame: NSRect(x: 18, y: 12, width: 44, height: 32))
    private let textLabel = NSTextField(labelWithString: "Listening…")
    private let height: CGFloat = 56
    private let minimumTextWidth: CGFloat = 160
    private let maximumTextWidth: CGFloat = 560
    private let leftPadding: CGFloat = 18
    private let waveformWidth: CGFloat = 44
    private let spacing: CGFloat = 12
    private let rightPadding: CGFloat = 20
    private var visibilityGeneration = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 254, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false

        visualEffectView = CapsuleVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true

        textLabel.font = .systemFont(ofSize: 16, weight: .medium)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byTruncatingHead
        textLabel.maximumNumberOfLines = 1
        textLabel.alignment = .left
        textLabel.frame = NSRect(x: 74, y: 17, width: 160, height: 22)

        visualEffectView.addSubview(waveformView)
        visualEffectView.addSubview(textLabel)
        panel.contentView = visualEffectView
        visualEffectView.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
    }

    func show(text: String = "Listening…") {
        visibilityGeneration += 1
        updateText(text, animated: false)
        positionPanel()
        waveformView.startAnimating()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        guard let layer = visualEffectView.layer else { return }
        layer.transform = CATransform3DIdentity
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.72
        spring.toValue = 1.0
        spring.mass = 0.8
        spring.stiffness = 260
        spring.damping = 20
        spring.initialVelocity = 0.4
        spring.duration = 0.35
        layer.add(spring, forKey: "entryScale")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.20
        layer.add(fade, forKey: "entryFade")
    }

    func updateText(_ text: String, animated: Bool = true) {
        textLabel.stringValue = text.isEmpty ? "Listening…" : text
        let measured = ceil((textLabel.stringValue as NSString).size(withAttributes: [.font: textLabel.font!]).width + 6)
        let textWidth = max(minimumTextWidth, min(maximumTextWidth, measured))
        let panelWidth = leftPadding + waveformWidth + spacing + textWidth + rightPadding
        let labelFrame = NSRect(x: leftPadding + waveformWidth + spacing, y: 17, width: textWidth, height: 22)

        guard panel.isVisible else {
            textLabel.frame = labelFrame
            panel.setContentSize(NSSize(width: panelWidth, height: height))
            visualEffectView.layoutSubtreeIfNeeded()
            panel.invalidateShadow()
            return
        }
        let oldFrame = panel.frame
        let newFrame = NSRect(x: oldFrame.midX - panelWidth / 2, y: oldFrame.minY, width: panelWidth, height: height)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? 0.25 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            textLabel.animator().frame = labelFrame
            panel.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak panel, weak visualEffectView] in
            MainActor.assumeIsolated {
                visualEffectView?.layoutSubtreeIfNeeded()
                panel?.invalidateShadow()
            }
        })
    }

    func setAudioLevel(_ level: Double) {
        waveformView.setAudioLevel(level)
    }

    func hide() {
        waveformView.stopAnimating()
        guard panel.isVisible else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        if let layer = visualEffectView.layer {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 0.82
            scale.duration = 0.22
            scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(scale, forKey: "exitScale")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, generation == self.visibilityGeneration else { return }
                panel?.orderOut(nil)
                panel?.alphaValue = 1
            }
        })
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.minY + 48))
    }
}
