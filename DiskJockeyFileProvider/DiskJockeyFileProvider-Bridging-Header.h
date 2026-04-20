//
// DiskJockeyFileProvider-Bridging-Header.h
// Exposes the libnetworkfs.a C ABI (from go-networkfs, cgo c-archive
// build) to Swift code inside the DiskJockeyFileProvider extension.
//
// One combined archive replaces the earlier per-driver imports
// (libftp.h, libsftp.h, …). Driver selection happens at runtime via
// the `driver_type` argument to `networkfs_mount`.
//

#ifndef DiskJockeyFileProvider_Bridging_Header_h
#define DiskJockeyFileProvider_Bridging_Header_h

#import "libnetworkfs.h"

#endif
