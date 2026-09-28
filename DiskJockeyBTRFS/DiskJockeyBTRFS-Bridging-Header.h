//
// DiskJockeyBTRFS-Bridging-Header.h
// Bridging header exposing the fs_btrfs C ABI to Swift.
// The published fs_btrfs crate is linked into lib/bundle_btrfs/libdj_btrfs_bundle.a.
// Upstream: github.com/antimatter-studios/rust-fs-btrfs
//

#ifndef DISKJOCKEY_BTRFS_BRIDGING_HEADER_H
#define DISKJOCKEY_BTRFS_BRIDGING_HEADER_H

#import "fs_btrfs.h"

// fs_core.h ships alongside fs_btrfs.h (same include dir). Its symbols
// (fs_core_device_from_callbacks, fs_core_device_slice_ro, …) are linked
// into libdj_btrfs_bundle.a via the am-fs-core cargo dep, so this read-only
// extension can wrap an FSBlockDeviceResource as an FsCoreDevice and slice
// a partition out of it before mounting.
#import "fs_core.h"

#endif
