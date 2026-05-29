//! diskprobe — open a disk image (raw or container), walk its partition
//! table, emit JSON describing what's inside.
//!
//! Usage:
//!   diskprobe <path>
//!   diskprobe <path> --container=qcow2|vhd|vhdx|vmdk
//!
//! When `--container` is omitted, container kind is auto-detected from
//! the magic at offset 0 (or the trailing 512-byte footer for fixed
//! VHDs). If no container is recognised the file is treated as a raw
//! disk image (which is correct for whole-disk `.img` / `.dd` dumps).
//!
//! Exit codes:
//!   0  — JSON written to stdout
//!   1  — argument / option error
//!   2  — file open / container layer error
//!   3  — partition probe error
//!
//! JSON shape:
//!   {
//!     "path": "/path/to/file",
//!     "container": "qcow2"|"vhd"|"vhdx"|"vmdk"|"raw",
//!     "container_size_bytes": 12345,        // virtual size after container unwrap
//!     "table": "gpt"|"mbr"|"none",
//!     "partitions": [
//!       {
//!         "index": 0,
//!         "start": 1048576,
//!         "length": 268435456,
//!         "fs_kind": "ext4"|"ntfs"|"fat32"|"fat16"|"exfat"|"hfs_plus"|"apfs"|"linux_swap"|"iso9660"|"squashfs"|"unknown",
//!         "type_byte": 131,                 // MBR partition type byte (0 for GPT)
//!         "type_guid": "0fc63daf-8483-...", // GPT type GUID (zeros for MBR)
//!         "label": "boot"                   // optional, may be absent
//!       },
//!       ...
//!     ]
//!   }

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

use fs_core::ffi::{
    fs_core_device_close, fs_core_device_size_bytes, fs_core_file_open,
    fs_core_last_error_message, FsCoreDevice,
};
use partitions::capi::{
    partitions_count, partitions_get, partitions_list_free, partitions_probe,
    partitions_sniff, partitions_sniff_device, partitions_table_kind, FsKindCode, PartitionInfo,
    PartitionList, TableKindCode,
};

// Force the container-reader rlibs to be linked. We only call into them
// via extern "C" declarations below (since we don't want to depend on
// each crate's Rust API surface), but cargo would otherwise drop the
// rlibs entirely because nothing in this crate refers to them by name
// in Rust source. The `use ... as _;` keeps the rlib in the link line
// so the `#[no_mangle]` symbols resolve.
#[allow(unused_imports)]
use qcow2 as _;
#[allow(unused_imports)]
use vhd as _;
#[allow(unused_imports)]
use vhdx as _;
#[allow(unused_imports)]
use vmdk as _;

const USAGE: &str = "usage: diskprobe <path> [--container=qcow2|vhd|vhdx|vmdk]";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Container {
    Raw,
    Qcow2,
    Vhd,
    Vhdx,
    Vmdk,
}

impl Container {
    fn label(self) -> &'static str {
        match self {
            Container::Raw => "raw",
            Container::Qcow2 => "qcow2",
            Container::Vhd => "vhd",
            Container::Vhdx => "vhdx",
            Container::Vmdk => "vmdk",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        match s {
            "raw" => Some(Container::Raw),
            "qcow2" => Some(Container::Qcow2),
            "vhd" => Some(Container::Vhd),
            "vhdx" => Some(Container::Vhdx),
            "vmdk" => Some(Container::Vmdk),
            _ => None,
        }
    }
}

fn auto_detect_container(path: &str) -> std::io::Result<Container> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path)?;
    let mut head = [0u8; 16];
    let n = f.read(&mut head).unwrap_or(0);
    if n >= 4
        && head[0] == 0x51
        && head[1] == 0x46
        && head[2] == 0x49
        && head[3] == 0xfb
    {
        return Ok(Container::Qcow2);
    }
    if n >= 8 && &head[..8] == b"vhdxfile" {
        return Ok(Container::Vhdx);
    }
    if n >= 4 && &head[..4] == b"KDMV" {
        return Ok(Container::Vmdk);
    }
    if n >= 8 && &head[..8] == b"conectix" {
        return Ok(Container::Vhd);
    }
    // Fixed VHD: footer at file_size - 512.
    let len = f.metadata()?.len();
    if len >= 512 {
        f.seek(SeekFrom::Start(len - 512))?;
        let mut footer = [0u8; 8];
        if f.read(&mut footer).unwrap_or(0) == 8 && &footer == b"conectix" {
            return Ok(Container::Vhd);
        }
    }
    Ok(Container::Raw)
}

extern "C" {
    fn qcow2_open_rw_on_device(inner: *mut FsCoreDevice) -> *mut FsCoreDevice;
    fn qcow2_open_on_device(inner: *mut FsCoreDevice) -> *mut FsCoreDevice;
    fn vhd_open_rw_on_device(inner: *mut FsCoreDevice) -> *mut FsCoreDevice;
    fn vhd_open_on_device(inner: *mut FsCoreDevice) -> *mut FsCoreDevice;
    fn vhdx_open_rw_on_device(inner: *mut FsCoreDevice) -> *mut FsCoreDevice;
    fn vhdx_open_on_device(inner: *mut FsCoreDevice) -> *mut FsCoreDevice;
    fn vmdk_open_rw_on_device(inner: *mut FsCoreDevice) -> *mut FsCoreDevice;
    fn vmdk_open_on_device(inner: *mut FsCoreDevice) -> *mut FsCoreDevice;
}

unsafe fn open_container_on(
    inner: *mut FsCoreDevice,
    kind: Container,
    writable: bool,
) -> *mut FsCoreDevice {
    match (kind, writable) {
        (Container::Raw, _) => inner,
        (Container::Qcow2, true) => qcow2_open_rw_on_device(inner),
        (Container::Qcow2, false) => qcow2_open_on_device(inner),
        (Container::Vhd, true) => vhd_open_rw_on_device(inner),
        (Container::Vhd, false) => vhd_open_on_device(inner),
        (Container::Vhdx, true) => vhdx_open_rw_on_device(inner),
        (Container::Vhdx, false) => vhdx_open_on_device(inner),
        (Container::Vmdk, true) => vmdk_open_rw_on_device(inner),
        (Container::Vmdk, false) => vmdk_open_on_device(inner),
    }
}

fn last_error() -> String {
    unsafe {
        let p = fs_core_last_error_message();
        if p.is_null() {
            String::new()
        } else {
            CStr::from_ptr(p).to_string_lossy().into_owned()
        }
    }
}

fn fs_kind_label(code: i32) -> &'static str {
    // Mirror the partitions::FsKindCode enum.
    match code {
        x if x == FsKindCode::Ext2 as i32 => "ext2",
        x if x == FsKindCode::Ext3 as i32 => "ext3",
        x if x == FsKindCode::Ext4 as i32 => "ext4",
        x if x == FsKindCode::Ntfs as i32 => "ntfs",
        x if x == FsKindCode::ExFat as i32 => "exfat",
        x if x == FsKindCode::Fat32 as i32 => "fat32",
        x if x == FsKindCode::Fat16 as i32 => "fat16",
        x if x == FsKindCode::HfsPlus as i32 => "hfs_plus",
        x if x == FsKindCode::Apfs as i32 => "apfs",
        x if x == FsKindCode::LinuxSwap as i32 => "linux_swap",
        x if x == FsKindCode::Iso9660 as i32 => "iso9660",
        x if x == FsKindCode::Squashfs as i32 => "squashfs",
        _ => "unknown",
    }
}

fn table_kind_label(code: i32) -> &'static str {
    match code {
        x if x == TableKindCode::Gpt as i32 => "gpt",
        x if x == TableKindCode::Mbr as i32 => "mbr",
        _ => "none",
    }
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out
}

fn fmt_guid(b: &[u8; 16]) -> String {
    // Standard GPT GUID byte layout: first 4 bytes little-endian, next 2 LE,
    // next 2 LE, last 8 bytes big-endian.
    let d1 = u32::from_le_bytes([b[0], b[1], b[2], b[3]]);
    let d2 = u16::from_le_bytes([b[4], b[5]]);
    let d3 = u16::from_le_bytes([b[6], b[7]]);
    format!(
        "{:08x}-{:04x}-{:04x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        d1, d2, d3, b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
    )
}

fn die(code: i32, msg: &str) -> ! {
    eprintln!("diskprobe: {msg}");
    std::process::exit(code);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
        println!("{USAGE}");
        std::process::exit(0);
    }
    let mut path: Option<String> = None;
    let mut explicit: Option<Container> = None;
    for a in &args {
        if let Some(rest) = a.strip_prefix("--container=") {
            match Container::parse(rest) {
                Some(c) => explicit = Some(c),
                None => die(1, &format!("unknown container kind: {rest}")),
            }
        } else if a.starts_with("--") {
            die(1, &format!("unknown flag: {a}\n{USAGE}"));
        } else if path.is_none() {
            path = Some(a.clone());
        } else {
            die(1, &format!("unexpected positional: {a}"));
        }
    }
    let path = path.unwrap_or_else(|| die(1, USAGE));

    // Auto-detect when not specified.
    let container = match explicit {
        Some(c) => c,
        None => match auto_detect_container(&path) {
            Ok(c) => c,
            Err(e) => die(2, &format!("auto-detect: {e}")),
        },
    };

    // Open underlying file.
    let cpath = CString::new(path.as_str()).unwrap();
    // Always open RO for probe — partition probe is read-only and we
    // don't want to risk taking a write lock just to inspect.
    let file = unsafe { fs_core_file_open(cpath.as_ptr(), false) };
    if file.is_null() {
        die(2, &format!("fs_core_file_open: {}", last_error()));
    }

    // Stack the container reader (RO since we only probe).
    let dev = unsafe { open_container_on(file, container, false) };
    if dev.is_null() {
        die(
            2,
            &format!("{}_open_on_device: {}", container.label(), last_error()),
        );
    }

    let dev_size = unsafe { fs_core_device_size_bytes(dev) };

    // Probe partitions.
    let mut list: *mut PartitionList = ptr::null_mut();
    let rc = unsafe { partitions_probe(dev, &mut list) };
    if rc != fs_core::ffi::FsCoreErrorCode::Ok || list.is_null() {
        // No partition table — sniff the whole device as one filesystem.
        let sniffed = unsafe { partitions_sniff_device(dev, dev_size) };
        let dev_fs_label = if sniffed >= 0 { fs_kind_label(sniffed) } else { "unknown" };
        let json = format!(
            "{{\"path\":\"{}\",\"container\":\"{}\",\"container_size_bytes\":{},\"table\":\"none\",\"device_fs_kind\":\"{}\",\"partitions\":[]}}",
            json_escape(&path),
            container.label(),
            dev_size,
            dev_fs_label,
        );
        println!("{json}");
        unsafe { fs_core_device_close(dev) };
        std::process::exit(0);
    }

    let table_rc = unsafe { partitions_table_kind(list) };
    let count = unsafe { partitions_count(list) };

    let mut entries: Vec<String> = Vec::with_capacity(count);
    for i in 0..count {
        let mut info = PartitionInfo {
            start: 0,
            length: 0,
            fs_kind: FsKindCode::Unknown as i32,
            table_kind: 0,
            type_guid: [0u8; 16],
            type_byte: 0,
            _pad: [0u8; 7],
            label: ptr::null(),
            label_len: 0,
            bootable: 0,
            _pad2: [0u8; 7],
            attributes: 0,
        };
        let grc = unsafe { partitions_get(list, i, &mut info) };
        if grc != fs_core::ffi::FsCoreErrorCode::Ok {
            continue;
        }
        // Sniff the FS — partitions_sniff fills the kind in-place but
        // we already have a copy of info, so capture the returned code.
        let sniffed = unsafe { partitions_sniff(list, i) };
        let fs_label = if sniffed >= 0 {
            fs_kind_label(sniffed)
        } else {
            "unknown"
        };
        let label_str = if !info.label.is_null() && info.label_len > 0 {
            let bytes = unsafe {
                std::slice::from_raw_parts(info.label as *const u8, info.label_len)
            };
            std::str::from_utf8(bytes).ok().map(|s| s.to_string())
        } else {
            None
        };

        let mut entry = format!(
            "{{\"index\":{},\"start\":{},\"length\":{},\"fs_kind\":\"{}\",\"type_byte\":{},\"type_guid\":\"{}\"",
            i,
            info.start,
            info.length,
            fs_label,
            info.type_byte,
            fmt_guid(&info.type_guid),
        );
        if let Some(l) = label_str {
            entry.push_str(&format!(",\"label\":\"{}\"", json_escape(&l)));
        }
        entry.push('}');
        entries.push(entry);
    }

    let json = format!(
        "{{\"path\":\"{}\",\"container\":\"{}\",\"container_size_bytes\":{},\"table\":\"{}\",\"partitions\":[{}]}}",
        json_escape(&path),
        container.label(),
        dev_size,
        table_kind_label(table_rc),
        entries.join(","),
    );
    println!("{json}");

    unsafe {
        partitions_list_free(list);
        fs_core_device_close(dev);
    }
}

// Suppress unused-import lint when this binary is built without
// referring to specific types.
#[allow(dead_code)]
fn _unused(_a: c_char) {}
