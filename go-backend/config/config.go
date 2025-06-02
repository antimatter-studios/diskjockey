package config

import (
	"encoding/json"
	"os"
)

// AppConfig holds configuration for mountpoints, cache, etc.
type AppConfig struct {
	Mountpoints []MountpointConfig `json:"mountpoints"`
	CacheDir string        `json:"cache_dir"`
	MaxCacheSize int64     `json:"max_cache_size"`
}

type MountpointConfig struct {
	Type   string                 `json:"type"`
	Name   string                 `json:"name"`
	Config map[string]interface{} `json:"config"`
}

// LoadConfig loads config from a JSON file
func LoadConfig(path string) (*AppConfig, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var cfg AppConfig
	if err := json.NewDecoder(f).Decode(&cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}
