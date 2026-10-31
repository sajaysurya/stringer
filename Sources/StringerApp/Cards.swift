import AppKit

/// A non-activating card at the top right, just below the menu bar. Unlike a
/// notification its buttons are always visible and it needs no permission.
/// A new card replaces the old one.
final class Cards {
    private var panel: NSPanel?
    private var dismissTimer: Timer?

    struct Button {
        var title: String
        var action: () -> Void
    }

    func show(title: String, message: String, buttons: [Button], timeout: TimeInterval? = 20) {
        dismiss()
        let width: CGFloat = 340
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        let body = NSTextField(wrappingLabelWithString: message)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = width - 32

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addArrangedSubview(NSView())  // push buttons right
        for (i, b) in buttons.enumerated() {
            let button = ActionButton(title: b.title) { [weak self] in
                self?.dismiss()
                b.action()
            }
            if i == buttons.count - 1 { button.keyEquivalent = "\r" }
            row.addArrangedSubview(button)
        }
        let stack = NSStackView(views: [titleLabel, body, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        panel.contentView = bg
        bg.layoutSubtreeIfNeeded()
        let h = stack.fittingSize.height
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.maxX - width - 12, y: f.maxY - h - 8, width: width, height: h), display: true)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        if let timeout {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

final class ActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
