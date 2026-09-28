//
// DiskJockeySQUASHFS-Bridging-Header.h
// Bridging header exposing the fs_squashfs C ABI to Swift.
// The published fs_squashfs crate is linked into lib/bundle_squashfs/libdj_squashfs_bundle.a.
// Upstream: github.com/antimatter-studios/rust-fs-squashfs
//

#ifndef DISKJOCKEY_SQUASHFS_BRIDGING_HEADER_H
#define DISKJOCKEY_SQUASHFS_BRIDGING_HEADER_H

#import "fs_squashfs.h"

// fs_core.h ships alongside fs_squashfs.h (same include dir). Its symbols
// (fs_core_device_from_callbacks, fs_core_device_slice_ro, …) are linked
// into libdj_squashfs_bundle.a via the am-fs-core cargo dep, so this read-only
// extension can wrap an FSBlockDeviceResource as an FsCoreDevice and slice
// a partition out of it before mounting.
#import "fs_core.h"

#endif
