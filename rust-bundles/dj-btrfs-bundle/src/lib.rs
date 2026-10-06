//! Aggregator staticlib for the DiskJockeyBTRFS extension. Forces each
//! driver/reader rlib to be linked; their `#[no_mangle] extern "C"` symbols
//! are reachability roots, so they survive into this single staticlib.
extern crate fs_btrfs;
extern crate img_qcow2;
extern crate img_vhd;
extern crate img_vhdx;
extern crate img_vmdk;
