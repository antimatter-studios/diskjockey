import Cocoa

class SettingsViewController: NSViewController {
    @IBOutlet weak var sidebarList: NSOutlineView!
    @IBOutlet weak var contentContainer: NSView!

    // The sidebar will show plugin names dynamically.
    var plugins: [Api_PluginTypeInfo] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        // Listen for plugin updates
        NotificationCenter.default.addObserver(self, selector: #selector(handlePluginsListUpdated(_:)), name: NSNotification.Name("PluginsListUpdated"), object: nil)
        // Optional: set up sidebar if needed
        sidebarList.delegate = self
        sidebarList.dataSource = self
        sidebarList.reloadData()
        // Select first plugin if available
        if !plugins.isEmpty {
            sidebarList.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            updateContentForPlugin(at: 0)
        } else {
            updateContentForPlugin(at: nil)
        }
    }

    func updateContentForPlugin(at index: Int?) {
        // Remove previous subviews
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let index = index, index >= 0, index < plugins.count else {
            // Show a default message if nothing is selected
            let label = NSTextField(labelWithString: "Select a plugin to view details.")
            label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
            label.alignment = .center
            label.frame = contentContainer.bounds
            label.autoresizingMask = [.width, .height]
            contentContainer.addSubview(label)
            return
        }
        let plugin = plugins[index]
        let label = NSTextField(labelWithString: plugin.name)
        label.font = NSFont.systemFont(ofSize: 24, weight: .medium)
        label.alignment = .center
        label.frame = contentContainer.bounds
        label.autoresizingMask = [.width, .height]
        contentContainer.addSubview(label)
    }

    @objc func handlePluginsListUpdated(_ notification: Notification) {
        if let plugins = notification.userInfo?["plugins"] as? [Api_PluginTypeInfo] {
            self.plugins = plugins
            sidebarList.reloadData()
            // Select first plugin if available
            if !plugins.isEmpty {
                sidebarList.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                updateContentForPlugin(at: 0)
            } else {
                updateContentForPlugin(at: nil)
            }
        }
    }
}

extension SettingsViewController: NSOutlineViewDelegate, NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return plugins.count
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return false
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        return plugins[index].name
    }
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        return item as? String
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selected = sidebarList.selectedRow
        updateContentForPlugin(at: selected)
    }
}
