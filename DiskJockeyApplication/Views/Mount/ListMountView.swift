//
//  ListMountView.swift
//  DiskJockey
//
//  Created by Chris Thomas on 20.06.25.
//

import DiskJockeyLibrary
import SwiftUI

struct ListMountView: View {
    @EnvironmentObject private var mountRepository: MountRepository
    @StateObject private var mountManager = MountManager.shared

    var body: some View {
        VStack {
            ScrollView {
                ZStack {
                    Grid(alignment: .leading) {
                        // Header
                        GridRow {
                            Text("mounts_column_name").bold()
                            Text("mounts_column_type").bold()
                            Text("mounts_column_speed").bold()
                            Text("mounts_column_action").bold()
                        }
                        Divider().gridCellColumns(4)
                        // Rows
                        ForEach(mountRepository.mounts, id: \.id) { mount in
                            GridRow {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(mount.name).font(.headline)
                                    if mount.path.isEmpty {
                                        Text(mount.path).font(.subheadline).foregroundColor(.secondary)
                                    }
                                }
                                Text(mount.diskType.rawValue.capitalized).font(.subheadline)
                                Text("64 KB/sec").font(.subheadline)
                                if mountManager.isMounted(mount) {
                                    Button(action: {
                                        Task { try? await mountManager.unmount(mount) }
                                    }) {
                                        Text("Unmount")
                                            .font(.caption)
                                    }
                                } else {
                                    Button(action: {
                                        Task { try? await mountManager.mount(mount) }
                                    }) {
                                        Text("Mount")
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.green.opacity(0.2)))
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(Color.white)
    }

}
