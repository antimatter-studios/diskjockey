// cmd/gofs/main.go - Go network drivers with cgo exports
// This builds as a C static library for Swift/Obj-C linking

package main

/*
#include <stdlib.h>
#include <string.h>

// Forward declarations for C types used in exports
typedef struct { const char* name; const char* value; } ConfigEntry;
typedef struct { const char* path; int isDir; int64_t size; } DirEntry;
typedef struct { const char* data; size_t len; } ByteSlice;
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"unsafe"

	"github.com/christhomas/diskjockey/diskjockey-backend/types"
)

// DriverManager holds driver instances for mounted volumes
// Note: In cgo builds, main() is not called - we init at first export
type DriverManager struct {
	// Map of active mountID -> driver backend
	backends map[int]types.Backend
}

var manager *DriverManager

func initManager() {
	if manager != nil {
		return
	}
	// Initialize driver manager
	// In production, this would register all available drivers
	manager = &DriverManager{
		backends: make(map[int]types.Backend),
	}
}

// Returns JSON array of available driver types
//
//export DriverListTypes
func DriverListTypes() *C.char {
	initManager()
	drivers := []string{"dropbox", "ftp", "sftp", "smb", "webdav", "local"}
	jsonBytes, _ := json.Marshal(drivers)
	return C.CString(string(jsonBytes))
}

// mountID: unique identifier for this mount instance
// driverType: "ftp", "smb", etc.
// configJSON: JSON object with connection params
// Returns: 0 on success, error code on failure
//
//export DriverMount
func DriverMount(mountID C.int, driverType *C.char, configJSON *C.char) C.int {
	initManager()

	dType := C.GoString(driverType)
	configStr := C.GoString(configJSON)

	var config map[string]string
	if err := json.Unmarshal([]byte(configStr), &config); err != nil {
		return -1 // Invalid JSON
	}

	fmt.Printf("[gofs] Mount request: %s (type: %s)\n", config["name"], dType)

	// TODO: Initialize driver and store in mountService
	// This would create the appropriate disktypes.Backend

	return 0
}

//export DriverUnmount
func DriverUnmount(mountID C.int) C.int {
	fmt.Printf("[gofs] Unmount: %d\n", mountID)
	// TODO: Cleanup driver instance
	return 0
}

// Returns file info as JSON
//
//export VolumeStat
func VolumeStat(mountID C.int, path *C.char) *C.char {
	cPath := C.GoString(path)

	// TODO: Get backend from mountService, call Stat
	info := types.FileInfo{
		Name:  cPath,
		IsDir: false,
		Size:  0,
	}

	jsonBytes, _ := json.Marshal(info)
	return C.CString(string(jsonBytes))
}

// Returns directory entries as JSON array
//
//export VolumeListDir
func VolumeListDir(mountID C.int, path *C.char) *C.char {
	cPath := C.GoString(path)
	fmt.Printf("[gofs] ListDir: mount=%d path=%s\n", mountID, cPath)

	// TODO: Get backend, call List
	entries := []types.FileInfo{}

	jsonBytes, _ := json.Marshal(entries)
	return C.CString(string(jsonBytes))
}

// Returns file contents (caller must free with FreeBytes)
//
//export VolumeReadFile
func VolumeReadFile(mountID C.int, path *C.char, outBytes *C.ByteSlice) C.int {
	cPath := C.GoString(path)
	fmt.Printf("[gofs] ReadFile: mount=%d path=%s\n", mountID, cPath)

	// TODO: Get backend, call Read
	data := []byte("placeholder")

	if len(data) > 0 {
		outBytes.data = (*C.char)(C.CBytes(data))
		outBytes.len = C.size_t(len(data))
	}
	return 0
}

// Frees memory allocated by Go (for returned byte slices)
//
//export FreeBytes
func FreeBytes(data *C.char) {
	C.free(unsafe.Pointer(data))
}

// main is required for c-archive buildmode but never called
func main() {}
