import AppKit
import OpenFinderCore

@MainActor
final class FileTagCellView: NSTableCellView {
    let contentStack = NSStackView()
    private var configuredTags: [FileTag] = []
    private var configuredScopes: [FileTagScope] = []
    private var renderedWidth: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let currentWidth = bounds.width
        guard currentWidth > 0,
              renderedWidth.map({ abs($0 - currentWidth) >= 1 }) ?? false
        else {
            return
        }
        render(availableWidth: currentWidth)
    }

    func configure(
        tags: [FileTag],
        scopes: [FileTagScope] = [],
        availableWidth: CGFloat
    ) {
        configuredTags = tags
        configuredScopes = scopes
        render(availableWidth: availableWidth)
    }

    private func render(availableWidth: CGFloat) {
        renderedWidth = availableWidth
        clearRenderedState()

        let ordered = FileTagPresentation.descriptor(
            tags: configuredTags,
            scopes: configuredScopes,
            maxVisibleTags: configuredTags.count,
            localLabelIndex: Self.publicLabelIndex(named:)
        )
        let visibleCount = maximumVisibleTagCount(in: ordered.visible, availableWidth: availableWidth)
        let descriptor = FileTagPresentation.descriptor(
            tags: configuredTags,
            scopes: configuredScopes,
            maxVisibleTags: visibleCount,
            localLabelIndex: Self.publicLabelIndex(named:)
        )

        for tag in descriptor.visible {
            contentStack.addArrangedSubview(makeTagView(tag))
        }
        if descriptor.overflowCount > 0 {
            let overflow = NSTextField(labelWithString: "+\(descriptor.overflowCount)")
            overflow.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            overflow.textColor = .secondaryLabelColor
            overflow.lineBreakMode = .byClipping
            contentStack.addArrangedSubview(overflow)
        }

        toolTip = descriptor.toolTip
        setAccessibilityLabel(descriptor.accessibilityLabel)
        setAccessibilityValue(descriptor.toolTip)
    }

    private func clearRenderedState() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        imageView?.image = nil
        textField?.stringValue = ""
        toolTip = nil
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
    }

    private func maximumVisibleTagCount(
        in tags: [FileTagCellTag],
        availableWidth: CGFloat
    ) -> Int {
        let usableWidth = max(0, availableWidth - 12)
        var usedWidth: CGFloat = 0
        var visibleCount = 0
        for (index, tag) in tags.enumerated() {
            let interTagSpacing: CGFloat = index == 0 ? 0 : contentStack.spacing
            let tagWidth = Self.width(of: tag.name) + 12
            let remainingCount = tags.count - index - 1
            let overflowWidth = remainingCount > 0
                ? contentStack.spacing + Self.width(of: "+\(remainingCount)")
                : 0
            guard usedWidth + interTagSpacing + tagWidth + overflowWidth <= usableWidth else {
                break
            }
            usedWidth += interTagSpacing + tagWidth
            visibleCount += 1
        }
        return visibleCount
    }

    private func makeTagView(_ tag: FileTagCellTag) -> NSView {
        let marker = NSTextField(labelWithString: "●")
        marker.font = .systemFont(ofSize: 9)
        marker.textColor = Self.color(for: tag.marker)
        marker.setAccessibilityElement(false)

        let name = NSTextField(labelWithString: tag.name)
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [marker, name])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.setAccessibilityElement(false)
        return stack
    }

    private static func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width)
    }

    private static func publicLabelIndex(named name: String) -> Int? {
        NSWorkspace.shared.fileLabels.firstIndex(of: name)
    }

    private static func color(for marker: FileTagMarker) -> NSColor {
        switch marker {
        case .neutral:
            return .tertiaryLabelColor
        case .canonical(let color):
            switch color {
            case .none: return .tertiaryLabelColor
            case .red: return .systemRed
            case .orange: return .systemOrange
            case .yellow: return .systemYellow
            case .green: return .systemGreen
            case .blue: return .systemBlue
            case .purple: return .systemPurple
            case .gray: return .systemGray
            }
        case .localLabel(let index):
            let colors = NSWorkspace.shared.fileLabelColors
            return colors.indices.contains(index) ? colors[index] : .tertiaryLabelColor
        }
    }
}
