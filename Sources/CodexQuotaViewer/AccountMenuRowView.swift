import AppKit

struct AccountMenuRowModel {
    let name: String
    let primaryRemainingText: String
    let secondaryRemainingText: String
    let primaryResetText: String
    let secondaryResetText: String
    let indicatorColor: NSColor
    let isCurrent: Bool
    let isEnabled: Bool
    let accessibilityLabel: String
}

@MainActor
final class AccountMenuRowView: NSView {
    static let minimumWidth: CGFloat = 400
    static let height: CGFloat = 62
    private static let cardInset: CGFloat = 5
    private static let horizontalPadding: CGFloat = 12
    private static let quotaGroupSpacing: CGFloat = 8

    private let cardView = NSView()
    private let indicatorView = AccountStatusDotView()
    private let nameField = NSTextField(labelWithString: "")
    private let primaryQuotaView = AccountQuotaMetricView(accentColor: .systemIndigo, resetWidth: 34)
    private let secondaryQuotaView = AccountQuotaMetricView(accentColor: .systemGreen, resetWidth: 50)

    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false {
        didSet {
            updateAppearance()
        }
    }

    private(set) var model: AccountMenuRowModel

    init(model: AccountMenuRowModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: Self.height))
        setupView()
        apply(model: model)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.minimumWidth, height: Self.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        if model.isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard model.isEnabled else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        guard model.isEnabled else { return }

        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location),
              let menuItem = enclosingMenuItem,
              let action = menuItem.action else {
            return
        }

        menuItem.menu?.cancelTracking()
        NSApp.sendAction(action, to: menuItem.target, from: menuItem)
    }

    func apply(model: AccountMenuRowModel) {
        self.model = model
        nameField.stringValue = menuDisplayName(from: model.name)
        primaryQuotaView.apply(
            AccountQuotaMetricModel(
                remainingText: model.primaryRemainingText,
                resetText: model.primaryResetText,
                fallbackLabel: "5h"
            )
        )
        secondaryQuotaView.apply(
            AccountQuotaMetricModel(
                remainingText: model.secondaryRemainingText,
                resetText: model.secondaryResetText,
                fallbackLabel: "7d"
            )
        )
        indicatorView.fillColor = model.indicatorColor
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        alphaValue = 1
        updateAppearance()
        window?.invalidateCursorRects(for: self)
        setAccessibilityLabel(model.accessibilityLabel)
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 15
        cardView.layer?.cornerCurve = .continuous
        addSubview(cardView)

        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicatorView)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.textColor = .labelColor
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameField)

        [primaryQuotaView, secondaryQuotaView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.minimumWidth),
            heightAnchor.constraint(equalToConstant: Self.height),

            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.topAnchor.constraint(equalTo: topAnchor, constant: Self.cardInset),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.cardInset),

            indicatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            indicatorView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            indicatorView.widthAnchor.constraint(equalToConstant: 8),
            indicatorView.heightAnchor.constraint(equalToConstant: 8),

            secondaryQuotaView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            secondaryQuotaView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

            primaryQuotaView.trailingAnchor.constraint(
                equalTo: secondaryQuotaView.leadingAnchor,
                constant: -Self.quotaGroupSpacing
            ),
            primaryQuotaView.centerYAnchor.constraint(equalTo: secondaryQuotaView.centerYAnchor),

            nameField.leadingAnchor.constraint(equalTo: indicatorView.trailingAnchor, constant: 8),
            nameField.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: primaryQuotaView.leadingAnchor, constant: -10),
        ])
    }

    private func updateAppearance() {
        var backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.36)
        var borderColor = NSColor.separatorColor.withAlphaComponent(0.18)
        let borderWidth: CGFloat = 1

        if isHovered && model.isEnabled {
            backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.54)
            borderColor = NSColor.separatorColor.withAlphaComponent(0.28)
        }

        if model.isCurrent {
            backgroundColor = isHovered && model.isEnabled
                ? NSColor.systemGreen.withAlphaComponent(0.16)
                : NSColor.systemGreen.withAlphaComponent(0.11)
            borderColor = NSColor.systemGreen.withAlphaComponent(0.28)
        }

        cardView.layer?.backgroundColor = backgroundColor.cgColor
        cardView.layer?.borderColor = borderColor.cgColor
        cardView.layer?.borderWidth = borderWidth
    }
}

private func menuDisplayName(from name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let atIndex = trimmed.firstIndex(of: "@") else {
        return trimmed
    }

    let localPart = trimmed[..<atIndex].trimmingCharacters(in: .whitespacesAndNewlines)
    return localPart.isEmpty ? trimmed : String(localPart)
}

private struct AccountQuotaMetricModel {
    let labelText: String
    let percentText: String
    let resetValueText: String
    let progressFraction: CGFloat?

    init(remainingText: String, resetText: String, fallbackLabel: String) {
        let remainingParts = Self.splitLabelAndValue(remainingText, fallbackLabel: fallbackLabel)
        let resetParts = Self.splitLabelAndValue(resetText, fallbackLabel: remainingParts.label)
        labelText = remainingParts.label
        percentText = remainingParts.value
        resetValueText = resetParts.value
        progressFraction = Self.progressFraction(from: remainingParts.value)
    }

    private static func splitLabelAndValue(
        _ text: String,
        fallbackLabel: String
    ) -> (label: String, value: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (fallbackLabel, "-")
        }

        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first else {
            return (fallbackLabel, "-")
        }

        let label = String(first)
        guard parts.count > 1 else {
            return (label, "-")
        }

        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (label, value.isEmpty ? "-" : value)
    }

    private static func progressFraction(from value: String) -> CGFloat? {
        let numericText = value
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericValue = Double(numericText) else {
            return nil
        }

        return CGFloat(min(1, max(0, numericValue / 100)))
    }
}

@MainActor
private final class AccountQuotaMetricView: NSView {
    private static let pillWidth: CGFloat = 26
    private static let trackWidth: CGFloat = 28
    private static let percentWidth: CGFloat = 30
    private static let height: CGFloat = 24

    private let accentColor: NSColor
    private let resetWidth: CGFloat
    private let pillView: AccountQuotaPillView
    private let progressView: AccountQuotaProgressView
    private let percentField = NSTextField(labelWithString: "")
    private let resetField = NSTextField(labelWithString: "")

    init(accentColor: NSColor, resetWidth: CGFloat) {
        self.accentColor = accentColor
        self.resetWidth = resetWidth
        pillView = AccountQuotaPillView(accentColor: accentColor)
        progressView = AccountQuotaProgressView(fillColor: accentColor)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.intrinsicWidth(resetWidth: resetWidth), height: Self.height))
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: intrinsicWidth, height: Self.height)
    }

    func apply(_ model: AccountQuotaMetricModel) {
        pillView.text = model.labelText
        progressView.progress = model.progressFraction ?? 0
        progressView.isDimmed = model.progressFraction == nil
        percentField.stringValue = model.percentText
        resetField.stringValue = model.resetValueText
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false

        pillView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pillView)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressView)

        percentField.translatesAutoresizingMaskIntoConstraints = false
        percentField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentField.textColor = .labelColor
        percentField.alignment = .right
        percentField.maximumNumberOfLines = 1
        percentField.lineBreakMode = .byTruncatingTail
        addSubview(percentField)

        resetField.translatesAutoresizingMaskIntoConstraints = false
        resetField.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        resetField.textColor = .tertiaryLabelColor
        resetField.alignment = .left
        resetField.maximumNumberOfLines = 1
        resetField.lineBreakMode = .byTruncatingTail
        addSubview(resetField)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: intrinsicWidth),
            heightAnchor.constraint(equalToConstant: Self.height),

            pillView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillView.centerYAnchor.constraint(equalTo: centerYAnchor),
            pillView.widthAnchor.constraint(equalToConstant: Self.pillWidth),
            pillView.heightAnchor.constraint(equalToConstant: 20),

            progressView.leadingAnchor.constraint(equalTo: pillView.trailingAnchor, constant: 4),
            progressView.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressView.widthAnchor.constraint(equalToConstant: Self.trackWidth),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            percentField.leadingAnchor.constraint(equalTo: progressView.trailingAnchor, constant: 4),
            percentField.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentField.widthAnchor.constraint(equalToConstant: Self.percentWidth),

            resetField.leadingAnchor.constraint(equalTo: percentField.trailingAnchor, constant: 3),
            resetField.centerYAnchor.constraint(equalTo: centerYAnchor),
            resetField.widthAnchor.constraint(equalToConstant: resetWidth),
        ])
    }

    private var intrinsicWidth: CGFloat {
        Self.intrinsicWidth(resetWidth: resetWidth)
    }

    private static func intrinsicWidth(resetWidth: CGFloat) -> CGFloat {
        pillWidth + 4 + trackWidth + 4 + percentWidth + 3 + resetWidth
    }
}

@MainActor
private final class AccountQuotaPillView: NSView {
    var text: String = "" {
        didSet {
            textField.stringValue = text
        }
    }

    private let accentColor: NSColor
    private let textField = NSTextField(labelWithString: "")

    init(accentColor: NSColor) {
        self.accentColor = accentColor
        super.init(frame: .zero)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = accentColor.withAlphaComponent(0.14).cgColor

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        textField.textColor = accentColor
        textField.alignment = .center
        textField.maximumNumberOfLines = 1
        addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

private final class AccountQuotaProgressView: NSView {
    var progress: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }

    var isDimmed = false {
        didSet {
            needsDisplay = true
        }
    }

    private let fillColor: NSColor

    init(fillColor: NSColor) {
        self.fillColor = fillColor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackBounds = bounds.insetBy(dx: 0, dy: (bounds.height - 4) / 2)
        let trackPath = NSBezierPath(roundedRect: trackBounds, xRadius: 2, yRadius: 2)
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        trackPath.fill()

        guard !isDimmed, progress > 0 else {
            return
        }

        let fillWidth = max(4, trackBounds.width * min(1, max(0, progress)))
        let fillRect = NSRect(
            x: trackBounds.minX,
            y: trackBounds.minY,
            width: fillWidth,
            height: trackBounds.height
        )
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2)
        fillColor.setFill()
        fillPath.fill()
    }
}

private final class AccountStatusDotView: NSView {
    var fillColor: NSColor = .systemGreen {
        didSet {
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 8, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        fillColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
