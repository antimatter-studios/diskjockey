package services

import (
	"errors"
	"fmt"
	"sync"

	"github.com/christhomas/diskjockey/diskjockey-backend/types"
)

type PluginService struct {
	mu            sync.RWMutex
	pluginTypes   map[string]types.PluginType  // plugin type name -> template
	mounts        map[string]*types.Mount      // mount name -> Mount
	mountOrder    []string                     // mount names in config order
	configService types.ConfigServiceInterface // interface for config service
}

func NewPluginService(configService types.ConfigServiceInterface) *PluginService {
	return &PluginService{
		pluginTypes:   make(map[string]types.PluginType),
		mounts:        make(map[string]*types.Mount),
		configService: configService,
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

// RemoveMount removes a mount by name
func (r *PluginService) RemoveMount(name string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.mounts[name]; !exists {
		return errors.New("mount not found")
	}
	delete(r.mounts, name)
	// Remove from mountOrder
	for i, n := range r.mountOrder {
		if n == name {
			r.mountOrder = append(r.mountOrder[:i], r.mountOrder[i+1:]...)
			break
		}
	}
	return nil
}

// RegisterPluginType registers a plugin type (template)
func (r *PluginService) RegisterPluginType(ptype types.PluginType) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pluginTypes[ptype.Name()] = ptype
}

// AddMount instantiates a mount from a plugin type and config
func (r *PluginService) AddMount(name, pluginType string, _ map[string]interface{}) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.mounts[name]; exists {
		return errors.New("mount already exists")
	}
	ptype, ok := r.pluginTypes[pluginType]
	if !ok {
		return fmt.Errorf("plugin type '%s' not registered", pluginType)
	}
	backend, err := ptype.New(name, r.configService)
	if err != nil {
		return err
	}
	mount := &types.Mount{
		Name:       name,
		PluginType: pluginType,
		Backend:    backend,
	}
	r.mounts[name] = mount
	r.mountOrder = append(r.mountOrder, name)
	return nil
}

func (r *PluginService) ListPluginTypes() []types.PluginTypeInfo {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var infos []types.PluginTypeInfo
	for _, pt := range r.pluginTypes {
		infos = append(infos, types.PluginTypeInfo{
			Name:        pt.Name(),
			Description: pt.Description(),
			Config:      pt.ConfigTemplate(),
		})
	}
	return infos
}

// ListMounts returns all active mounts
func (r *PluginService) ListMounts() []*types.Mount {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var ms []*types.Mount
	for _, name := range r.mountOrder {
		if m, ok := r.mounts[name]; ok {
			ms = append(ms, m)
		}
	}
	return ms
}

// GetBackend returns the Backend for a given mount name
func (r *PluginService) GetBackend(mountName string) (types.Backend, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	m, ok := r.mounts[mountName]
	if !ok {
		return nil, errors.New("mount not found")
	}
	return m.Backend, nil
}
