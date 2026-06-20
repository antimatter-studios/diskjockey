//! Aggregator staticlib for the DiskJockeyEXT4 extension. Forces each
//! driver/reader rlib to be linked; their `#[no_mangle] extern "C"` symbols
//! are reachability roots, so they survive into this single staticlib.
extern crate fs_ext4;
extern crate qcow2;
extern crate vhd;
extern crate vhdx;
extern crate vmdk;
