//
// DiskJockeyNTFS-Bridging-Header.h
// Bridging header exposing the fs_ntfs C ABI to Swift.
// The published fs_ntfs crate is linked into lib/bundle_ntfs/libdj_ntfs_bundle.a.
// Upstream: github.com/christhomas/rust-fs-ntfs
//

#ifndef DISKJOCKEY_NTFS_BRIDGING_HEADER_H
#define DISKJOCKEY_NTFS_BRIDGING_HEADER_H

#import "fs_ntfs.h"

// fs_core.h + qcow2.h ship alongside fs_ntfs.h (same include dir). The
// matching symbols are linked into libdj_ntfs_bundle.a via the am-fs-core +
// am-img-* cargo deps, so Swift code in this extension can call
// fs_core_device_from_callbacks + qcow2_open_rw_on_device without
// pulling in a separate static archive.
#import "fs_core.h"
#import "qcow2.h"
#import "vhd.h"
#import "vhdx.h"
#import "vmdk.h"

#endif
