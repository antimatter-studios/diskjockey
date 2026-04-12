package services

import (
	"fmt"
	"sync"

	"github.com/christhomas/diskjockey/diskjockey-backend/types"
)

// MountService tracks active (mounted) Backend instances by mount ID.
// It creates backends on mount, destroys them on unmount, and routes
// file operations to the correct backend.
type MountService struct {
	mu       sync.RWMutex
	backends map[uint32]types.Backend
	config   *ConfigService
	disktype *DiskTypeService
}

func NewMountService(config *ConfigService, disktype *DiskTypeService) *MountService {
	return &MountService{
		backends: make(map[uint32]types.Backend),
		config:   config,
		disktype: disktype,
	}
}

// Mount activates a mount by creating a Backend instance for it.
func (ms *MountService) Mount(mountID uint32) error {
	ms.mu.Lock()
	defer ms.mu.Unlock()

	if _, exists := ms.backends[mountID]; exists {
		return fmt.Errorf("mount %d is already active", mountID)
	}

	mount, err := ms.config.GetMountByID(mountID)
	if err != nil {
		return fmt.Errorf("mount %d not found: %w", mountID, err)
	}

	dt, ok := ms.disktype.LookupDiskType(mount.DiskType)
	if !ok {
		return fmt.Errorf("unknown disk type: %s", mount.DiskType)
	}

	backend, err := dt.New(mount)
	if err != nil {
		return fmt.Errorf("failed to create backend for mount %d: %w", mountID, err)
	}

	ms.backends[mountID] = backend

	if err := ms.config.SetMountMounted(mountID, true); err != nil {
		fmt.Printf("[MountService] Warning: failed to update IsMounted for %d: %v\n", mountID, err)
	}

	fmt.Printf("[MountService] Mount %d activated (type: %s)\n", mountID, mount.DiskType)
	return nil
}

// Unmount deactivates a mount and closes its Backend.
func (ms *MountService) Unmount(mountID uint32) error {
	ms.mu.Lock()
	defer ms.mu.Unlock()

	backend, exists := ms.backends[mountID]
	if !exists {
		return fmt.Errorf("mount %d is not active", mountID)
	}

	// Try to close if the backend supports it
	if closer, ok := backend.(interface{ Close() error }); ok {
		if err := closer.Close(); err != nil {
			fmt.Printf("[MountService] Warning: error closing backend for mount %d: %v\n", mountID, err)
		}
	}

	delete(ms.backends, mountID)

	if err := ms.config.SetMountMounted(mountID, false); err != nil {
		fmt.Printf("[MountService] Warning: failed to update IsMounted for %d: %v\n", mountID, err)
	}

	fmt.Printf("[MountService] Mount %d deactivated\n", mountID)
	return nil
}

// GetBackend returns the active Backend for a mount, or an error if not mounted.
func (ms *MountService) GetBackend(mountID uint32) (types.Backend, error) {
	ms.mu.RLock()
	defer ms.mu.RUnlock()

	backend, exists := ms.backends[mountID]
	if !exists {
		return nil, fmt.Errorf("mount %d is not active", mountID)
	}
	return backend, nil
}

// ListDir lists files in a directory on an active mount.
func (ms *MountService) ListDir(mountID uint32, path string) ([]types.FileInfo, error) {
	backend, err := ms.GetBackend(mountID)
	if err != nil {
		return nil, err
	}
	return backend.List(path)
}

// StatFile returns metadata for a single file/directory on an active mount.
func (ms *MountService) StatFile(mountID uint32, path string) (types.FileInfo, error) {
	backend, err := ms.GetBackend(mountID)
	if err != nil {
		return types.FileInfo{}, err
	}
	return backend.Stat(path)
}

// ReadFile reads the contents of a file on an active mount.
func (ms *MountService) ReadFile(mountID uint32, path string) ([]byte, error) {
	backend, err := ms.GetBackend(mountID)
	if err != nil {
		return nil, err
	}
	return backend.Read(path)
}
