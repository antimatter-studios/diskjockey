package services

import (
	"sync"

	"github.com/christhomas/diskjockey/diskjockey-backend/types"
)

type DiskTypeService struct {
	mu        sync.RWMutex
	diskTypes map[string]types.DiskType // disk type name -> Go object
}

func NewDiskTypeService() *DiskTypeService {
	return &DiskTypeService{
		diskTypes: make(map[string]types.DiskType),
	}
}

// WithReconnect wraps a backend operation and retries once after reconnect if error
func WithReconnect(b types.Backend, op func() error, isConnError func(error) bool) error {
	err := op()
	if isConnError != nil && isConnError(err) {
		recErr := b.Reconnect()
		if recErr != nil {
			return recErr
		}
		return op()
	}
	return err
}

// RegisterDiskType registers a disk type (template)
func (ds *DiskTypeService) RegisterDiskType(dtype types.DiskType) {
	ds.mu.Lock()
	defer ds.mu.Unlock()
	ds.diskTypes[dtype.Name()] = dtype
}

// LookupDiskType safely retrieves a disk type by name.
func (ds *DiskTypeService) LookupDiskType(name string) (types.DiskType, bool) {
	ds.mu.RLock()
	defer ds.mu.RUnlock()
	dt, ok := ds.diskTypes[name]
	return dt, ok
}

func (ds *DiskTypeService) ListDiskTypes() []types.DiskTypeInfo {
	ds.mu.RLock()
	defer ds.mu.RUnlock()
	var diskTypes []types.DiskTypeInfo
	for _, dt := range ds.diskTypes {
		diskTypes = append(diskTypes, types.DiskTypeInfo{
			Name:        dt.Name(),
			Description: dt.Description(),
			Config:      dt.ConfigTemplate(),
		})
	}
	return diskTypes
}
