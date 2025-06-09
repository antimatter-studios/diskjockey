package plugins

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
	"github.com/christhomas/diskjockey/diskjockey-backend/types"
)

// LocalDirectoryPlugin implements PluginType for mounting a local directory as a filesystem
// Each mount gets its own root directory

type LocalDirectoryPlugin struct{}

type LocalDirectoryBackend struct {
	mount *models.Mount
	Path  string
}

func (l LocalDirectoryPlugin) New(mount *models.Mount) (types.Backend, error) {
	b := &LocalDirectoryBackend{mount: mount}
	if err := b.connect(); err != nil {
		return nil, err
	}
	return b, nil
}

// PluginType interface implementation
func (l LocalDirectoryPlugin) Name() string {
	return "localdirectory"
}

func (l LocalDirectoryPlugin) Description() string {
	return "Local directory filesystem plugin"
}

func (l LocalDirectoryPlugin) ConfigTemplate() types.PluginConfigTemplate {
	return types.PluginConfigTemplate{
		"path": types.PluginConfigField{
			Type:        "string",
			Description: "Path prefix for all requests in this mount",
			Required:    true,
		},
	}
}

func (b *LocalDirectoryBackend) connect() error {
	path := b.mount.Path
	if path == "" {
		return fmt.Errorf("localdirectory: missing required config 'path'")
	}

	b.Path = path

	return nil
}

// Backend interface implementation
func (b *LocalDirectoryBackend) List(path string) ([]types.FileInfo, error) {
	dir := filepath.Join(b.Path, path)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}

	var infos []types.FileInfo
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			continue
		}
		infos = append(infos, types.FileInfo{
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
