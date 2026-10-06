//! Aggregator staticlib for the DiskJockeyEROFS extension. Forces each
//! driver/reader rlib to be linked; their `#[no_mangle] extern "C"` symbols
//! are reachability roots, so they survive into this single staticlib.
extern crate fs_erofs;
extern crate img_qcow2;
extern crate img_vhd;
extern crate img_vhdx;
extern crate img_vmdk;
