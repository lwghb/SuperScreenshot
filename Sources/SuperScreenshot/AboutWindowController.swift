import AppKit

@MainActor
final class AboutWindowController: NSWindowController {
    private enum Link {
        static let repository = URL(string: "https://github.com/lwghb/SuperScreenshot")!
        static let issues = URL(string: "https://github.com/lwghb/SuperScreenshot/issues")!
        static let newIssue = URL(string: "https://github.com/lwghb/SuperScreenshot/issues/new")!
        static let license = URL(string: "https://github.com/lwghb/SuperScreenshot/blob/main/LICENSE")!
        static let email = URL(string: "mailto:lwghb@users.noreply.github.com?subject=SuperScreenshot%20Feedback")!
    }

    init() {
        let window = AboutWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 510),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("关于超强截图")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = NSViewController()
        window.contentViewController?.view = makeContentView()
    }

    required init?(coder: NSCoder) { nil }

    private func makeContentView() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = label(L("超强截图"), size: 20, weight: .semibold)
        let version = label(versionText(), size: 13, color: .secondaryLabelColor)
        let summary = label(L("轻量、原生、完全本地运行的 macOS 截图与标注工具"), size: 13, color: .secondaryLabelColor)
        summary.alignment = .center

        let header = NSStackView(views: [icon, name, version, summary])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 7
        header.setCustomSpacing(12, after: icon)

        let bug = linkButton(L("提交错误报告"), symbol: "exclamationmark.bubble", url: Link.issues)
        let github = linkButton(L("在 GitHub 查看"), symbol: "arrow.triangle.branch", url: Link.repository)
        let feature = linkButton(L("提出功能建议"), symbol: "lightbulb", url: Link.newIssue)
        let email = linkButton(L("发送电子邮件"), symbol: "envelope", url: Link.email)
        let license = linkButton(L("版权与许可证"), symbol: "doc.text", url: Link.license)
        let firstRow = linkRow(bug, github)
        let secondRow = linkRow(feature, email)
        let links = NSStackView(views: [firstRow, secondRow, license])
        links.orientation = .vertical
        links.alignment = .centerX
        links.distribution = .fillEqually
        links.spacing = 12

        let divider = NSBox()
        divider.boxType = .separator

        let privacy = label(L("截图内容仅在本机处理，不会上传到服务器。"), size: 12, color: .tertiaryLabelColor)
        privacy.alignment = .center

        let content = NSStackView(views: [header, divider, links, privacy])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 24
        content.setCustomSpacing(28, after: links)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 88),
            icon.heightAnchor.constraint(equalToConstant: 88),
            divider.widthAnchor.constraint(equalToConstant: 380),
            links.widthAnchor.constraint(equalToConstant: 350),
            bug.widthAnchor.constraint(equalToConstant: 169),
            github.widthAnchor.constraint(equalToConstant: 169),
            feature.widthAnchor.constraint(equalToConstant: 169),
            email.widthAnchor.constraint(equalToConstant: 169),
            license.widthAnchor.constraint(equalToConstant: 350),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24)
        ])
        return root
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byWordWrapping
        return field
    }

    private func linkButton(_ title: String, symbol: String, url: URL) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: 15, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )
        button.imagePosition = .imageLeading
        button.alignment = .center
        button.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        return button
    }

    private func linkRow(_ first: NSButton, _ second: NSButton) -> NSStackView {
        let row = NSStackView(views: [first, second])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 12
        return row
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func versionText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? L("未知")
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return LF("版本 %@（%@）", version, build)
    }
}

private final class AboutWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}
