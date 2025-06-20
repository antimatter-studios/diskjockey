import SwiftUI
import DiskJockeyLibrary

// Helper extension to erase view types
extension View {
    func eraseToAnyView() -> AnyView {
        AnyView(self)
    }
}

struct ContentView: View {
    // MARK: - Properties
    
    let container: AppContainer
    
    // MARK: - State
    
    @StateObject private var sidebarModel = SidebarModel()
    
    // MARK: - Body
    
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebarView
                .navigationTitle("DiskJockey")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: toggleSidebar) {
                            Image(systemName: "sidebar.left")
                        }
                    }
                }
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 600)
    }
    
    // MARK: - Subviews
    
    private var sidebarView: some View {
        List(selection: $sidebarModel.selectedItem) {
            NavigationLink(value: SidebarItem.about) {
                Label("About", systemImage: "info.circle")
            }
            
            NavigationLink(value: SidebarItem.mounts) {
                Label("Mounts", systemImage: "externaldrive")
            }
            
            NavigationLink(value: SidebarItem.diskTypes) {
                Label("Disk Types", systemImage: "puzzlepiece.extension")
            }
            
            NavigationLink(value: SidebarItem.systemLog) {
                Label("System Log", systemImage: "terminal")
            }
            
            NavigationLink(value: SidebarItem.quit) {
                Label("Quit", systemImage: "power")
            }
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        switch sidebarModel.selectedItem {
        case .about:
            AboutView()
                .eraseToAnyView()
                
        case .mounts:
            MountView()
                .environmentObject(container.mountRepository)
                .environmentObject(container.diskTypeRepository)
                .eraseToAnyView()
            
        case .diskTypes:
            DiskTypeView(repository: container.diskTypeRepository)
                .eraseToAnyView()
            
        case .systemLog:
            LogView()
                .environmentObject(container.logRepository)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .eraseToAnyView()
            
        case .quit:
            EmptyView()
                .eraseToAnyView()
        }
    }
    
    // MARK: - Actions
    
    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            with: nil
        )
    }
}
