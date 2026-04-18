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

#endif
