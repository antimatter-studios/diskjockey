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

// Mount describes an active plugin instance
// (unique name, plugin type, config, Backend)
type Mount struct {
	Name       string
	PluginType string
	Backend    Backend
}

// FileInfo describes a file or directory returned by plugins
type FileInfo struct {
	Name  string
	Size  int64
	IsDir bool
}

// Backend defines the plugin instance interface (for a mount)
type Backend interface {
	List(path string) ([]FileInfo, error)
	Read(path string) ([]byte, error)
	Write(path string, data []byte) error
	Delete(path string) error
	Reconnect() error
}

// PluginType defines a plugin type (template)
type PluginType interface {
	New(mount *models.Mount) (Backend, error)
	Name() string
	Description() string
	ConfigTemplate() PluginConfigTemplate
}

// ListPluginTypes returns all registered plugin types
type PluginTypeInfo struct {
	Name        string
	Description string
	Config      PluginConfigTemplate
}

// PluginConfigTemplate describes config options for a plugin type
// (e.g., fields, types, description, required)
type PluginConfigTemplate map[string]PluginConfigField

type PluginConfigField struct {
	Type        string // e.g. "string", "int", "bool"
	Description string
	Required    bool
}
