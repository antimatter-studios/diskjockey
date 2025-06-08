package services

import (
	"encoding/json"
	"errors"
	"os"
	"sync"

	"github.com/christhomas/diskjockey/diskjockey-backend/types"
)

// ConfigService provides up-to-date mount config for any backend by name.
type ConfigService struct {
	path   string
	mu     sync.RWMutex
	config *types.AppConfig
}

func NewConfigService(path string) (*ConfigService, error) {
	cs := &ConfigService{path: path}
	if err := cs.LoadConfig(); err != nil {
		return nil, err
	}
	return cs, nil
}

// LoadConfig loads config from a JSON file
func (cs *ConfigService) LoadConfig() error {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	f, err := os.Open(cs.path)
	if err != nil {
		return err
	}
	defer f.Close()
	var cfg types.AppConfig
	if err := json.NewDecoder(f).Decode(&cfg); err != nil {
		return err
	}
	cs.config = &cfg
	return nil
}

// ListMountpoints returns a slice of all mountpoint configs.
func (cs *ConfigService) ListMountpoints() ([]types.MountpointConfig, error) {
	cs.mu.RLock()
	defer cs.mu.RUnlock()

	if cs.config == nil {
		return nil, errors.New("config not loaded")
	}

	return cs.config.Mountpoints, nil
}

// GetMountConfig returns a copy of the config for the given mount name.
func (cs *ConfigService) GetMountConfig(mountName string) (map[string]interface{}, error) {
	cs.mu.RLock()
	defer cs.mu.RUnlock()

	if cs.config == nil {
		return nil, errors.New("config not loaded")
	}

	for _, m := range cs.config.Mountpoints {
		if m.Name == mountName {
			copy := make(map[string]interface{})
			for k, v := range m.Config {
				copy[k] = v
			}
			return copy, nil
		}
	}

	return nil, errors.New("mount not found")
}

func (cs *ConfigService) GetSocketPath() (string, error) {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	if cs.config == nil {
		return "", errors.New("config not loaded")
	}

	if cs.config.SocketPath == "" {
		return "", errors.New("socket path not configured")
	}

	return cs.config.SocketPath, nil
}
