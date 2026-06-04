import AppKit
import Foundation

@MainActor
final class SettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.05)
        shadow?.shadowBlurRadius = 8
        shadow?.shadowOffset = NSSize(width: 0, height: -1)
    }
}

@MainActor
final class SettingsSidebarItemView: NSControl {
    private let indicatorView = NSView()
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    var symbolName: String? {
        didSet {
            guard let symbolName else {
                imageView.image = nil
                return
            }
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            image?.isTemplate = true
            imageView.image = image
        }
    }

    var isSelectedItem = false {
        didSet {
            updateAppearance()
        }
    }

    init(title: String, symbolName: String, tag: Int) {
        super.init(frame: .zero)
        self.tag = tag
        self.title = title
        self.symbolName = symbolName
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\n":
            sendAction(action, to: target)
        default:
            super.keyDown(with: event)
        }
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        indicatorView.wantsLayer = true
        indicatorView.layer?.cornerRadius = 2
        addSubview(indicatorView)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .labelColor

        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [imageView, titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            indicatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            indicatorView.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicatorView.widthAnchor.constraint(equalToConstant: 4),
            indicatorView.heightAnchor.constraint(equalToConstant: 28),

            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        let accent = NSColor.controlAccentColor
        layer?.backgroundColor = isSelectedItem
            ? accent.withAlphaComponent(0.13).cgColor
            : NSColor.clear.cgColor
        indicatorView.layer?.backgroundColor = isSelectedItem
            ? accent.cgColor
            : NSColor.clear.cgColor
        imageView.contentTintColor = isSelectedItem ? accent : .labelColor
        titleLabel.textColor = isSelectedItem ? accent : .labelColor
    }
}

@MainActor
final class SettingsAdvancedView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let placeholderLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyLocalizedText() {
        titleLabel.stringValue = AppLocalization.localized(en: "Advanced", zh: "高级")
        placeholderLabel.stringValue = AppLocalization.localized(en: "No advanced settings.", zh: "暂无高级设置。")
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("settings.advanced.view")

        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .labelColor

        let card = SettingsCardView()
        placeholderLabel.font = .systemFont(ofSize: 14)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.maximumNumberOfLines = 0
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(placeholderLabel)

        let stack = NSStackView(views: [titleLabel, card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),

            placeholderLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            placeholderLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            placeholderLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            placeholderLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
    }
}
