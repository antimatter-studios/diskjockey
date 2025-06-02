package plugins

import (
	"errors"
	"fmt"
	"sync"
)

// FileInfo describes a file or directory returned by plugins
type FileInfo struct {
	Name  string
	Size  int64
	IsDir bool
}

// PluginConfigTemplate describes config options for a plugin type
// (e.g., fields, types, description, required)
type PluginConfigTemplate map[string]PluginConfigField

type PluginConfigField struct {
	Type        string // e.g. "string", "int", "bool"
	Description string
	Required    bool
}

// Backend defines the plugin instance interface (for a mount)
type Backend interface {
	List(path string) ([]FileInfo, error)
	Read(path string) ([]byte, error)
	Write(path string, data []byte) error
	Delete(path string) error
	Reconnect() error
}

// WithReconnect wraps a backend operation and retries once after reconnect if error
func WithReconnect(b Backend, op func() error, isConnError func(error) bool) error {
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

// PluginType defines a plugin type (template)
type PluginType interface {
	Name() string
	Description() string
	ConfigTemplate() PluginConfigTemplate
	New(mountName string, configSvc ConfigServiceIface) (Backend, error)
}

// Mount describes an active plugin instance
// (unique name, plugin type, config, Backend)
type Mount struct {
	Name       string
	PluginType string
	Backend    Backend
}

type PluginRegistry struct {
	mu          sync.RWMutex
	pluginTypes map[string]PluginType // plugin type name -> template
	mounts      map[string]*Mount     // mount name -> Mount
	mountOrder  []string              // mount names in config order
	configSvc   ConfigServiceIface    // interface for config service
}

// ConfigServiceIface allows mocking in tests
// (matches ConfigService methods used by registry and backends)
type ConfigServiceIface interface {
	GetMountConfig(mountName string) (map[string]interface{}, bool)
	ReloadConfig() error
}

func NewRegistry(configSvc ConfigServiceIface) *PluginRegistry {
	return &PluginRegistry{
		pluginTypes: make(map[string]PluginType),
		mounts:      make(map[string]*Mount),
		configSvc:   configSvc,
	}
}

// RegisterPluginType registers a plugin type (template)
func (r *PluginRegistry) RegisterPluginType(ptype PluginType) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pluginTypes[ptype.Name()] = ptype
}

// AddMount instantiates a mount from a plugin type and config
func (r *PluginRegistry) AddMount(name, pluginType string, _ map[string]interface{}) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.mounts[name]; exists {
		return errors.New("mount already exists")
	}
	ptype, ok := r.pluginTypes[pluginType]
	if !ok {
		return fmt.Errorf("plugin type '%s' not registered", pluginType)
	}
	backend, err := ptype.New(name, r.configSvc)
	if err != nil {
		return err
	}
	mount := &Mount{
		Name:       name,
		PluginType: pluginType,
		Backend:    backend,
	}
	r.mounts[name] = mount
	r.mountOrder = append(r.mountOrder, name)
	return nil
}

// ListPluginTypes returns all registered plugin types
type PluginTypeInfo struct {
	Name        string
	Description string
	Config      PluginConfigTemplate
}

func (r *PluginRegistry) ListPluginTypes() []PluginTypeInfo {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var infos []PluginTypeInfo
	for _, pt := range r.pluginTypes {
		infos = append(infos, PluginTypeInfo{
			Name:        pt.Name(),
			Description: pt.Description(),
			Config:      pt.ConfigTemplate(),
		})
	}
	return infos
}

// ListMounts returns all active mounts
func (r *PluginRegistry) ListMounts() []*Mount {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var ms []*Mount
	for _, name := range r.mountOrder {
		if m, ok := r.mounts[name]; ok {
			ms = append(ms, m)
		}
	}
	return ms
}

// GetBackend returns the Backend for a given mount name
func (r *PluginRegistry) GetBackend(mountName string) (Backend, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	m, ok := r.mounts[mountName]
	if !ok {
		return nil, errors.New("mount not found")
	}
	return m.Backend, nil
}
