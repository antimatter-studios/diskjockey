import Cocoa

class SettingsViewController: NSViewController {
    @IBOutlet weak var sidebarList: NSOutlineView!
    @IBOutlet weak var contentContainer: NSView!

    let sidebarItems = ["Mount 1", "Mount 2", "Mount 3"]

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarList.delegate = self
        sidebarList.dataSource = self
        sidebarList.reloadData()
        sidebarList.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateContent(for: 0)
    }

    func updateContent(for index: Int) {
        // Remove previous subviews
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard index >= 0 && index < sidebarItems.count else { return }
        let label = NSTextField(labelWithString: sidebarItems[index])
        label.frame = contentContainer.bounds
        label.font = NSFont.systemFont(ofSize: 24, weight: .medium)
        label.alignment = .center
        label.autoresizingMask = [.width, .height]
        contentContainer.addSubview(label)
    }
}

extension SettingsViewController: NSOutlineViewDelegate, NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return sidebarItems.count
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return false
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        return sidebarItems[index]
    }
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        return item as? String
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selected = sidebarList.selectedRow
        updateContent(for: selected)
    }
}
