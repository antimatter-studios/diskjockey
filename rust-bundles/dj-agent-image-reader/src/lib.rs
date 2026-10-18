//! Host-only adapter: authorization happens in the agent, decoding in the
//! published reader, and bounded requests arrive through transport #421.
#![deny(unsafe_op_in_unsafe_fn)]

use fs_core::{BlockDevice, BlockRead};
use img_vhdx::VhdxReader;
use std::fs::File;
use std::os::fd::FromRawFd;
use std::os::unix::fs::FileExt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

struct Backing {
    file: File,
    size: u64,
}
impl BlockRead for Backing {
    fn size_bytes(&self) -> u64 {
        self.size
    }
    fn read_at(&self, offset: u64, buffer: &mut [u8]) -> fs_core::Result<()> {
        // Fixed size and positioned reads preserve the caller's file cursor.
        if offset > self.size || buffer.len() as u64 > self.size - offset {
            return Err(fs_core::Error::OutOfBounds {
                offset,
                len: buffer.len() as u64,
                size: self.size,
            });
        }
        self.file
            .read_exact_at(buffer, offset)
            .map_err(fs_core::Error::Io)
    }
}
impl BlockDevice for Backing {} // The default write operation refuses writes.

pub struct DJAgentImageReader(VhdxReader);
#[repr(C)]
pub struct DJAgentImageGeometry {
    virtual_size: u64,
    logical_sector_size: u32,
    reserved: u32,
}

/// # Safety
/// geometry must be writable and aligned. The caller keeps fd open during this
/// call, proves its authority first, and owns the returned handle until close.
#[no_mangle]
pub unsafe extern "C" fn dj_agent_vhdx_open(
    fd: i32,
    geometry: *mut DJAgentImageGeometry,
) -> *mut DJAgentImageReader {
    if fd < 0 || geometry.is_null() {
        return std::ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        // dup is checked before constructing an owned File, including for a
        // closed descriptor. CLOEXEC prevents a later child inheriting proof.
        let duplicate = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
        if duplicate < 0 {
            return None;
        }
        let file = unsafe { File::from_raw_fd(duplicate) };
        let metadata = file.metadata().ok()?;
        if !metadata.is_file() {
            return None;
        }
        let reader = VhdxReader::open_on_device(Arc::new(Backing {
            file,
            size: metadata.len(),
        }))
        .ok()?;
        let size = reader.virtual_size();
        let sector = reader.sector_size();
        if !matches!(sector, 512 | 4096) || size == 0 || size % u64::from(sector) != 0 {
            return None;
        }
        let handle = Box::new(DJAgentImageReader(reader));
        unsafe {
            geometry.write(DJAgentImageGeometry {
                virtual_size: size,
                logical_sector_size: sector,
                reserved: 0,
            });
        }
        Some(Box::into_raw(handle))
    }))
    .ok()
    .flatten()
    .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// reader must be live and buffer must hold len writable bytes without aliasing
/// the reader. Close cannot overlap this call. Discard output on any failure.
#[no_mangle]
pub unsafe extern "C" fn dj_agent_image_read(
    reader: *const DJAgentImageReader,
    offset: u64,
    buffer: *mut u8,
    len: usize,
) -> i32 {
    if reader.is_null() || buffer.is_null() || len == 0 || len > 1024 * 1024 {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let reader = unsafe { &(*reader).0 };
        if offset > reader.virtual_size() || len as u64 > reader.virtual_size() - offset {
            return -1;
        }
        let output = unsafe { std::slice::from_raw_parts_mut(buffer, len) };
        if reader.read_at(offset, output).is_ok() {
            0
        } else {
            -1
        }
    }))
    .unwrap_or(-1)
}

/// # Safety
/// reader is NULL or a handle returned by open, with no read in flight.
#[no_mangle]
pub unsafe extern "C" fn dj_agent_image_close(reader: *mut DJAgentImageReader) {
    if !reader.is_null() {
        drop(unsafe { Box::from_raw(reader) });
    }
}
