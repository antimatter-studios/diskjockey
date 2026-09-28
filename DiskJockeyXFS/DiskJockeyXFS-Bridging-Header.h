//
// DiskJockeyXFS-Bridging-Header.h
// Bridging header exposing the fs_xfs C ABI to Swift.
// The published fs_xfs crate is linked into lib/bundle_xfs/libdj_xfs_bundle.a.
// Upstream: github.com/antimatter-studios/rust-fs-xfs
//

#ifndef DISKJOCKEY_XFS_BRIDGING_HEADER_H
#define DISKJOCKEY_XFS_BRIDGING_HEADER_H

#import "fs_xfs.h"

// fs_core.h ships alongside fs_xfs.h (same include dir). Its symbols
// (fs_core_device_from_callbacks, fs_core_device_slice_ro, …) are linked
// into libdj_xfs_bundle.a via the am-fs-core cargo dep, so this read-only
// extension can wrap an FSBlockDeviceResource as an FsCoreDevice and slice
// a partition out of it before mounting.
#import "fs_core.h"

#endif
