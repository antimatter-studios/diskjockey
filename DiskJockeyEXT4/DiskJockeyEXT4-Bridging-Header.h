//
// DiskJockeyEXT4-Bridging-Header.h
// Bridging header exposing the fs_ext4 C ABI to Swift.
// The published fs_ext4 crate is linked into lib/bundle_ext4/libdj_ext4_bundle.a.
//

#ifndef DISKJOCKEY_EXT4_BRIDGING_HEADER_H
#define DISKJOCKEY_EXT4_BRIDGING_HEADER_H

// lib/bundle_ext4/include is on HEADER_SEARCH_PATHS, so a bare include works.
#import "fs_ext4.h"

// fs_core.h + qcow2.h ship alongside fs_ext4.h (same include dir). The
// matching symbols are linked into libdj_ext4_bundle.a via the am-fs-core +
// am-img-* cargo deps, so Swift code in this extension can call
// fs_core_device_from_callbacks + qcow2_open_rw_on_device without
// pulling in a separate static archive.
#import "fs_core.h"
#import "qcow2.h"
#import "vhd.h"
#import "vhdx.h"
#import "vmdk.h"

#endif
