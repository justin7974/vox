import Cocoa

// Shared form-building helpers for all Settings tabs.
// Ensures consistent typography, spacing, and layout across the entire Settings UI.

enum SettingsUI {

    // MARK: - Scrollable Tab Content

    /// Creates a standard scrollable content area with a vertical stack.
    /// All form-style tabs use this as their root layout.
    static func makeScrollableContent() -> (scroll: NSScrollView, stack: NSStackView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        // Flipped clip view: content sticks to top when shorter than viewport.
        // Without this, AppKit's bottom-up coordinates push short content to the bottom.
        let clipView = _FlippedClipView()
        clipView.drawsBackground = false
        scroll.contentView = clipView

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .vertical)
        content.addSubview(stack)

        // Pin stack with padding; cap max width so large windows don't over-stretch.
        // Content height = stack natural height + padding. No fill-viewport constraint,
        // so the stack stays compact regardless of window size.
        let maxWidth: CGFloat = 520

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])

        scroll.documentView = content
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        return (scroll, stack)
    }

    // MARK: - Typography

    /// Section title: 11pt semibold, uppercase, secondary label color.
    /// Matches Apple HIG section header style.
    static func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Primary label: 13pt, label color.
    static func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        return label
    }

    /// Sublabel: 11pt, tertiary label color, wrapping.
    static func makeSublabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    // MARK: - Layout Components

    /// Standard separator line.
    static func makeSeparator() -> NSView {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        return sep
    }

    /// Standard form row: label (+ optional sublabel) on left, control on right.
    static func makeFormRow(label: String, sublabel: String? = nil, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView()
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let mainLabel = makeLabel(label)
        leftStack.addArrangedSubview(mainLabel)

        if let sub = sublabel {
            let subLabel = makeSublabel(sub)
            leftStack.addArrangedSubview(subLabel)
        }

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)

        row.addSubview(leftStack)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            leftStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            leftStack.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 4),
            leftStack.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -4),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])

        // Row height driven by content, not stretchable
        row.setContentHuggingPriority(.required, for: .vertical)
        row.setContentCompressionResistancePriority(.required, for: .vertical)

        return row
    }

    /// Standard button with rounded bezel.
    static func makeButton(_ title: String) -> NSButton {
        let btn = NSButton(title: title, target: nil, action: nil)
        btn.bezelStyle = .rounded
        btn.font = .systemFont(ofSize: 13)
        return btn
    }

    /// Config card: rounded background for grouped settings (e.g., provider config).
    static func makeConfigCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        return card
    }

    /// Label + text field row inside a config card.
    static func makeCardRow(label: String, field: NSTextField) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let lbl = makeLabel(label)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(lbl)
        row.addSubview(field)

        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            lbl.widthAnchor.constraint(equalToConstant: 80),
            field.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 28),
        ])

        return row
    }

    /// Permission status row: colored dot + label text.
    static func makePermissionRow(label: String) -> (view: NSView, dot: NSView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemGray.cgColor
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        row.addArrangedSubview(dot)

        let lbl = makeLabel(label)
        row.addArrangedSubview(lbl)

        return (row, dot)
    }
}

// MARK: - Internal Helpers

/// Flipped clip view so scroll content is pinned to the top (not bottom).
private class _FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
