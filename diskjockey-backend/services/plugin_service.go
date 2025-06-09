package services

import (
	"sync"

	"github.com/christhomas/diskjockey/diskjockey-backend/types"
)

type PluginService struct {
	mu          sync.RWMutex
	pluginTypes map[string]types.PluginType // plugin type name -> Go object
}

func NewPluginService() *PluginService {
	return &PluginService{
		pluginTypes: make(map[string]types.PluginType),
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

// RegisterPluginType registers a plugin type (template)
func (ps *PluginService) RegisterPluginType(ptype types.PluginType) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	ps.pluginTypes[ptype.Name()] = ptype
}

// LookupPluginType safely retrieves a plugin type by name.
func (ps *PluginService) LookupPluginType(name string) (types.PluginType, bool) {
	ps.mu.RLock()
	defer ps.mu.RUnlock()
	pt, ok := ps.pluginTypes[name]
	return pt, ok
}

func (ps *PluginService) ListPluginTypes() []types.PluginTypeInfo {
	ps.mu.RLock()
	defer ps.mu.RUnlock()
	var infos []types.PluginTypeInfo
	for _, pt := range ps.pluginTypes {
		infos = append(infos, types.PluginTypeInfo{
			Name:        pt.Name(),
			Description: pt.Description(),
			Config:      pt.ConfigTemplate(),
		})
	}
	return infos
}
