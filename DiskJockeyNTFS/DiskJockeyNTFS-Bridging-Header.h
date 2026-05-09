//
// DiskJockeyNTFS-Bridging-Header.h
// Bridging header exposing the fs_ntfs C ABI to Swift.
// Static lib vendored under vendor/fs_ntfs/.
// Upstream: github.com/christhomas/rust-fs-ntfs
//

#ifndef DISKJOCKEY_NTFS_BRIDGING_HEADER_H
#define DISKJOCKEY_NTFS_BRIDGING_HEADER_H

#import "fs_ntfs.h"

// fs_core.h + qcow2.h ship alongside fs_ntfs.h (same include dir). The
// matching symbols are linked into libfs_ntfs.a via the am-fs-core +
// am-img-qcow2 cargo deps, so Swift code in this extension can call
// fs_core_device_from_callbacks + qcow2_open_rw_on_device without
// pulling in a separate static archive.
#import "fs_core.h"
#import "qcow2.h"

#endif
