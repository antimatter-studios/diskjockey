//
// DiskJockeyEXT4-Bridging-Header.h
// Bridging header exposing the fs_ext4 C ABI to Swift.
// The fs_ext4 library is built from vendored source at vendor/rust-fs-ext4/
// and output to vendor/fs_ext4/.
//

#ifndef DISKJOCKEY_EXT4_BRIDGING_HEADER_H
#define DISKJOCKEY_EXT4_BRIDGING_HEADER_H

// vendor/fs_ext4/include is on HEADER_SEARCH_PATHS, so a bare include works.
#import "fs_ext4.h"

// fs_core.h + qcow2.h ship alongside fs_ext4.h (same include dir). The
// matching symbols are linked into libfs_ext4.a via the am-fs-core +
// am-img-qcow2 cargo deps, so Swift code in this extension can call
// fs_core_device_from_callbacks + qcow2_open_rw_on_device without
// pulling in a separate static archive.
#import "fs_core.h"
#import "qcow2.h"
#import "vhd.h"
#import "vhdx.h"
#import "vmdk.h"

#endif
