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
                            Text("mounts_column_status").bold()
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
                                Text(mount.isMounted ? "Mounted" : "Unmounted")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(mount.isMounted ? Color.green.opacity(0.2) : Color.red.opacity(0.2)))
                                    .foregroundColor(mount.isMounted ? .green : .red)
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
