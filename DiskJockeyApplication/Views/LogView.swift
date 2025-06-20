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

                Spacer()

                Button(action: clearLogs) {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(appLogModel.messages.isEmpty)

                Button(action: refreshLogs) {
                    Label("Refresh", systemImage: "arrow.clockwise")
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
        .onAppear {
            refreshLogs()
        }
    }

    // MARK: - Actions

    private func clearLogs() {
        appLogModel.clearLogs()
    }

    private func refreshLogs() {
        appLogModel.refreshLogs()
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
