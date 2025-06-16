import SwiftUI
import DiskJockeyLibrary

struct LogView: View {
    // MARK: - Properties
    
    @EnvironmentObject private var logRepository: LogRepository
    @State private var searchText = ""
    @State private var selectedLogLevel: LogLevel = .all
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Picker("Log Level", selection: $selectedLogLevel) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.displayName)
                            .tag(level)
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
                .disabled(logRepository.logs.isEmpty)
                
                Button(action: refreshLogs) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(logRepository.isLoading)
                
                Button(action: exportLogs) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(logRepository.logs.isEmpty)
            }
            .padding()
            
            Divider()
            
            // Log List
            if logRepository.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if logRepository.logs.isEmpty {
                ContentUnavailableView(
                    "No Logs",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Logs will appear here as they are generated")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredLogs) { log in
                    LogRow(log: log)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("System Logs")
        .onAppear {
            refreshLogs()
        }
    }
    
    // MARK: - Computed Properties
    
    private var filteredLogs: [LogEntry] {
        var logs = logRepository.logs
        
        // Filter by log level
        if selectedLogLevel != .all {
            logs = logs.filter { $0.level.rawValue == selectedLogLevel.rawValue }
        }
        
        // Filter by search text
        if !searchText.isEmpty {
            let searchLowercased = searchText.lowercased()
            logs = logs.filter {
                $0.message.lowercased().contains(searchLowercased) ||
                $0.source.lowercased().contains(searchLowercased)
            }
        }
        
        return logs
    }
    
    // MARK: - Private Methods
    
    private func refreshLogs() {
        Task {
            await logRepository.fetchLogs()
        }
    }
    
    private func clearLogs() {
        Task {
            try? await logRepository.clearLogs()
        }
    }
    
    private func exportLogs() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "DiskJockey-Logs-\(Date().formatted(date: .numeric, time: .shortened)).csv"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            let csvString = logRepository.logs
                .map { "\($0.timestamp),\"\($0.level.rawValue)\",\"\($0.source)\",\"\($0.message.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: "\n")
            
            let header = "Timestamp,Level,Source,Message\n"
            let csvData = (header + csvString).data(using: .utf8)
            
            do {
                try csvData?.write(to: url)
            } catch {
                print("Error exporting logs: \(error)")
            }
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
            
            // Log level
            Text(log.level.rawValue.uppercased())
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(logLevelColor)
                .cornerRadius(4)
                .frame(width: 60)
            
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
    
    private var logLevelColor: Color {
        switch log.level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .fatal: return .purple
        default: return .secondary
        }
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
