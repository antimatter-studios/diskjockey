import SwiftUI

struct AboutView: View {
    // MARK: - Properties
    
    private let appName = "DiskJockey"
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 20) {
            // App Icon and Name
            VStack(spacing: 16) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                    .resizable()
                    .frame(width: 80, height: 80)
                    .cornerRadius(16)
                    .shadow(radius: 4)
                
                VStack(spacing: 4) {
                    Text(appName)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Version \(version) (\(buildNumber))")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 20)
            
            // Description
            Text("A powerful tool for managing disk mounts and file systems.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            // Links
            VStack(spacing: 12) {
                Link("Visit our website", destination: URL(string: "https://diskjockey.app")!)
                Link("View documentation", destination: URL(string: "https://docs.diskjockey.app")!)
                Link("Support", destination: URL(string: "mailto:support@diskjockey.app")!)
            }
            .padding(.vertical, 8)
            
            // Copyright
            Text(" \(Calendar.current.component(.year, from: Date())) DiskJockey. All rights reserved.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
