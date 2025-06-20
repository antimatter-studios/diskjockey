package types

import (
	"github.com/christhomas/diskjockey/diskjockey-backend/models"
)

// AppConfig holds configuration for mountpoints, cache, etc.
type AppConfig struct {
	SocketPath   string        `json:"socket_path"`
	Mountpoints  []interface{} `json:"mountpoints"`
	CacheDir     string        `json:"cache_dir"`
	MaxCacheSize int64         `json:"max_cache_size"`
}

// Mount describes an active disk type instance
// (unique name, disk type, config, Backend)
type Mount struct {
	Name     string
	DiskType string
	Backend  Backend
}

// FileInfo describes a file or directory returned by disk types
type FileInfo struct {
	Name  string
	Size  int64
	IsDir bool
}

// Backend defines the disk type instance interface (for a mount)
type Backend interface {
	List(path string) ([]FileInfo, error)
	Read(path string) ([]byte, error)
	Write(path string, data []byte) error
	Delete(path string) error
	Reconnect() error
}

// DiskType defines a disk type (template)
type DiskType interface {
	New(mount *models.Mount) (Backend, error)
	Name() string
	Description() string
	ConfigTemplate() DiskTypeConfigTemplate
}

// ListDiskTypes returns all registered disk types
type DiskTypeInfo struct {
	Name        string
	Description string
	Config      DiskTypeConfigTemplate
}

// DiskTypeConfigTemplate describes config options for a disk type
// (e.g., fields, types, description, required)
type DiskTypeConfigTemplate map[string]DiskTypeConfigField

type DiskTypeConfigField struct {
	Type        string // e.g. "string", "int", "bool"
	Description string
	Required    bool
}
