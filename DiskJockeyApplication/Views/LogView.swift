import DiskJockeyLibrary
import SwiftUI

struct LogView: View {
    // MARK: - Properties

    @EnvironmentObject private var appLogModel: AppLogModel
    @State private var searchText = ""
    @State private var selectedCategory: String = "all"
    @State private var refreshID = UUID()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Picker("Category", selection: $selectedCategory) {
                    ForEach(categories, id: \.self) { cat in
                        Text(cat.capitalized).tag(cat)
                    }
                }
                .frame(width: 150)
                .labelsHidden()

                SearchBar(text: $searchText, placeholder: "Filter logs...")
                    .frame(maxWidth: 300)

                ScopeFilterMenu(suppressed: $appLogModel.suppressedScopes)

                Spacer()

                Button(action: clearLogs) {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(appLogModel.messages.isEmpty)

                Button(action: exportLogs) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(appLogModel.messages.isEmpty)
            }
            .padding()

            Divider()

            // Log List
            if appLogModel.messages.isEmpty {
                ContentUnavailableView(
                    "No Logs",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Logs will appear here as they are generated")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredMessages, id: \.id) { msg in
                    HStack(alignment: .top, spacing: 8) {
                        Text("[") + Text(msg.category.capitalized).bold() + Text("] ")
                        Text(msg.message)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Text(msg.timestamp, style: .time)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
                .id(refreshID)
                .listStyle(.plain)
            }
        }
        .navigationTitle("System Logs")
    }

    // MARK: - Actions

    private func clearLogs() {
        appLogModel.clearLogs()
    }

    private func exportLogs() {
        appLogModel.exportLogs()
    }

    // MARK: - Computed Properties

    private var categories: [String] {
        let cats = Set(appLogModel.messages.map { $0.category })
        return ["all"] + cats.sorted()
    }

    private var filteredMessages: [LogEntry] {
        let logs: [LogEntry]
        if selectedCategory == "all" {
            logs = appLogModel.messages
        } else {
            logs = appLogModel.messages.filter { $0.category == selectedCategory }
        }
        if searchText.isEmpty {
            return logs
        } else {
            return logs.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
        }
    }
}

// MARK: - LogRow

struct LogRow: View {
    let log: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(log.timestamp.formatted(date: .omitted, time: .standard))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)

            // Category
            Text(log.category.capitalized)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(4)
                .frame(width: 80)

            // Source
            Text(log.source)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)

            // Message
            Text(log.message)
                .font(.caption)
                .lineLimit(2)

            Spacer()
        }
        .padding(.vertical, 4)
    }

}

// MARK: - ScopeFilterMenu
//
// Dropdown of scope toggles. Each entry is one of `AppLogScope.all`;
// checking it removes the scope from the suppressed set (i.e. shows
// those entries), unchecking suppresses them. The button label shows
// a count when any scope is hidden so the user knows the current view
// is filtered.

struct ScopeFilterMenu: View {
    @Binding var suppressed: Set<String>

    var body: some View {
        Menu {
            ForEach(AppLogScope.all, id: \.self) { scope in
                Button {
                    if suppressed.contains(scope) {
                        suppressed.remove(scope)
                    } else {
                        suppressed.insert(scope)
                    }
                } label: {
                    HStack {
                        Image(systemName: suppressed.contains(scope) ? "square" : "checkmark.square.fill")
                        Text(scope.capitalized)
                    }
                }
            }
            Divider()
            Button("Show All") { suppressed.removeAll() }
                .disabled(suppressed.isEmpty)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                if !suppressed.isEmpty {
                    Text("\(suppressed.count) hidden")
                        .font(.caption)
                }
            }
        }
        .frame(width: suppressed.isEmpty ? 36 : 110)
    }
}

// MARK: - SearchBar

struct SearchBar: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholder
        searchField.delegate = context.coordinator
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        nsView.stringValue = text
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            if let searchField = notification.object as? NSSearchField {
                text = searchField.stringValue
            }
        }
    }
}
