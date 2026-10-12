//
// DiskJockeyBCACHEFS-Bridging-Header.h
// Bridging header exposing the fs_bcachefs C ABI to Swift.
// The published rust-fs-bcachefs crate, built with its `write` feature, is
// linked into lib/bundle_bcachefs/libdj_bcachefs_bundle.a.
// Upstream: github.com/antimatter-studios/rust-fs-bcachefs
//

#ifndef DISKJOCKEY_BCACHEFS_BRIDGING_HEADER_H
#define DISKJOCKEY_BCACHEFS_BRIDGING_HEADER_H

#import "fs_bcachefs.h"

// fs_core.h ships alongside fs_bcachefs.h (same include dir). Its symbols
// (fs_core_device_from_callbacks, fs_core_device_slice_ro/rw, …) are linked
// into libdj_bcachefs_bundle.a via rust-fs-core, so the extension can wrap an
// FSBlockDeviceResource as an FsCoreDevice, slice a partition out of it, and
// hand the same device to the driver's read and write handles.
#import "fs_core.h"

#endif
