package plugins

import (
	"fmt"
	"os"
	"path/filepath"
)

// LocalDirectoryPlugin implements PluginType for mounting a local directory as a filesystem
// Each mount gets its own root directory

type LocalDirectoryPlugin struct{}

type LocalDirectoryBackend struct {
	mountName string
	configSvc ConfigServiceIface
	Path      string
}

// PluginType interface implementation
func (l LocalDirectoryPlugin) Name() string        { return "localdirectory" }
func (l LocalDirectoryPlugin) Description() string { return "Local directory filesystem plugin" }
func (l LocalDirectoryPlugin) ConfigTemplate() PluginConfigTemplate {
	return PluginConfigTemplate{
		"path": PluginConfigField{
			Type:        "string",
			Description: "Path prefix for all requests in this mount",
			Required:    true,
		},
	}
}

func (l LocalDirectoryPlugin) New(mountName string, configSvc ConfigServiceIface) (Backend, error) {
	b := &LocalDirectoryBackend{mountName: mountName, configSvc: configSvc}
	if err := b.connect(); err != nil {
		return nil, err
	}
	return b, nil
}

func (b *LocalDirectoryBackend) connect() error {
	if b.configSvc == nil {
		return fmt.Errorf("config service not set")
	}
	config, ok := b.configSvc.GetMountConfig(b.mountName)
	if !ok {
		return fmt.Errorf("config for mount '%s' not found", b.mountName)
	}
	path, ok := config["path"].(string)
	if !ok || path == "" {
		return fmt.Errorf("localdirectory: missing required config 'path'")
	}
	b.Path = path
	return nil
}

// Backend interface implementation
func (b *LocalDirectoryBackend) List(path string) ([]FileInfo, error) {
	dir := filepath.Join(b.Path, path)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var infos []FileInfo
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			continue
		}
		infos = append(infos, FileInfo{
			Name:  entry.Name(),
			Size:  info.Size(),
			IsDir: entry.IsDir(),
		})
	}
	return infos, nil
}

func (b *LocalDirectoryBackend) Read(path string) ([]byte, error) {
	return os.ReadFile(filepath.Join(b.Path, path))
}

func (b *LocalDirectoryBackend) Write(path string, data []byte) error {
	fullPath := filepath.Join(b.Path, path)
	dir := filepath.Dir(fullPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	return os.WriteFile(fullPath, data, 0644)
}

func (b *LocalDirectoryBackend) Delete(path string) error {
	return os.Remove(filepath.Join(b.Path, path))
}

func (b *LocalDirectoryBackend) Reconnect() error {
	return nil
}
