import Cocoa

// Settings window with sidebar navigation, matching the Vox design prototype.
// Uses NSVisualEffectView(.sidebar) for authentic macOS sidebar material,
// and NSTableView with .sourceList style for proper selection behavior.

class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var sidebarTableView: NSTableView!
    private var contentContainer: NSView!
    private var currentTabView: NSView?
    private var currentTabId: String = "general"

    struct Tab {
        let id: String
        let title: String
        let icon: String
    }

    private let tabs: [Tab] = [
        Tab(id: "general", title: "General", icon: "gearshape"),
        Tab(id: "voice", title: "Voice", icon: "waveform"),
        Tab(id: "history", title: "History", icon: "clock.arrow.circlepath"),
        Tab(id: "about", title: "About", icon: "info.circle"),
    ]

    // Cache built views and their controllers (keep strong refs)
    private var tabViews: [String: NSView] = [:]
    private var tabControllers: [String: AnyObject] = [:]

    // MARK: - Public API

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Vox Settings"
        w.minSize = NSSize(width: 660, height: 420)
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        let rootView = NSView()

        let sidebar = buildSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(sidebar)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer = content
        rootView.addSubview(content)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),

            content.topAnchor.constraint(equalTo: rootView.topAnchor),
            content.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
        ])

        w.contentView = rootView

        // Select first tab
        switchToTab("general")
        sidebarTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showTab(_ tabId: String) {
        show()
        switchToTab(tabId)
        if let idx = tabs.firstIndex(where: { $0.id == tabId }) {
            sidebarTableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    // MARK: - Sidebar

    private func buildSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .sourceList
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 2)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)

        tableView.dataSource = self
        tableView.delegate = self

        sidebarTableView = tableView

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        sidebar.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sidebar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
        ])

        return sidebar
    }

    // MARK: - Content Switching

    private func switchToTab(_ tabId: String) {
        guard tabId != currentTabId || currentTabView == nil else { return }

        currentTabView?.removeFromSuperview()

        let tabView: NSView
        if let cached = tabViews[tabId] {
            tabView = cached
        } else {
            tabView = buildTab(tabId)
            tabViews[tabId] = tabView
        }

        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            tabView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])

        currentTabView = tabView
        currentTabId = tabId
    }

    private func buildTab(_ tabId: String) -> NSView {
        switch tabId {
        case "general":
            let vc = GeneralSettingsVC()
            tabControllers[tabId] = vc
            return vc.view
        case "voice":
            let vc = VoiceSettingsVC()
            tabControllers[tabId] = vc
            return vc.view
        case "history":
            let vc = HistorySettingsVC()
            tabControllers[tabId] = vc
            return vc.view
        case "about":
            let vc = AboutSettingsVC()
            tabControllers[tabId] = vc
            return vc.view
        default:
            return NSView()
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        tabViews.removeAll()
        tabControllers.removeAll()
        currentTabView = nil
        currentTabId = "general"
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        return tabs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tab = tabs[row]

        let cell = NSTableCellView()

        let imageView = NSImageView()
        if let img = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.title) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            imageView.image = img.withSymbolConfiguration(config)
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentTintColor = .secondaryLabelColor

        let textField = NSTextField(labelWithString: tab.title)
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .labelColor
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.textField = textField
        cell.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
        ])

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarTableView.selectedRow
        guard row >= 0 && row < tabs.count else { return }
        switchToTab(tabs[row].id)
    }
}
