package config

import (
	"encoding/json"
	"os"
	"sync"
)

// ConfigService provides up-to-date mount config for any backend by name.
type ConfigService struct {
	path   string
	mu     sync.RWMutex
	config *AppConfig
}

func NewConfigService(path string) (*ConfigService, error) {
	cs := &ConfigService{path: path}
	if err := cs.reload(); err != nil {
		return nil, err
	}
	return cs, nil
}

// reload reloads config from disk.
func (cs *ConfigService) reload() error {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	f, err := os.Open(cs.path)
	if err != nil {
		return err
	}
	defer f.Close()
	var cfg AppConfig
	if err := json.NewDecoder(f).Decode(&cfg); err != nil {
		return err
	}
	cs.config = &cfg
	return nil
}

// ListMountpoints returns a slice of all mountpoint configs.
func (cs *ConfigService) ListMountpoints() []MountpointConfig {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	if cs.config == nil {
		return nil
	}
	return cs.config.Mountpoints
}

// GetMountConfig returns a copy of the config for the given mount name.
func (cs *ConfigService) GetMountConfig(mountName string) (map[string]interface{}, bool) {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	if cs.config == nil {
		return nil, false
	}
	for _, m := range cs.config.Mountpoints {
		if m.Name == mountName {
			copy := make(map[string]interface{})
			for k, v := range m.Config {
				copy[k] = v
			}
			return copy, true
		}
	}
	return nil, false
}

// ReloadConfig can be called to reload from disk (e.g., on SIGHUP)
func (cs *ConfigService) ReloadConfig() error {
	return cs.reload()
}
