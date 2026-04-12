package disktypes

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
	"github.com/christhomas/diskjockey/diskjockey-backend/types"
)

// LocalDirectoryDiskType implements DiskType for mounting a local directory as a filesystem
// Each mount gets its own root directory

type LocalDirectoryDiskType struct{}

type LocalDirectoryBackend struct {
	mount *models.Mount
	Path  string
}

func (l LocalDirectoryDiskType) New(mount *models.Mount) (types.Backend, error) {
	b := &LocalDirectoryBackend{mount: mount}
	if err := b.connect(); err != nil {
		return nil, err
	}
	return b, nil
}

// DiskType interface implementation
func (l LocalDirectoryDiskType) Name() string {
	return "localdirectory"
}

func (l LocalDirectoryDiskType) Description() string {
	return "Local directory filesystem disktype"
}

func (l LocalDirectoryDiskType) ConfigTemplate() types.DiskTypeConfigTemplate {
	return types.DiskTypeConfigTemplate{
		"path": types.DiskTypeConfigField{
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

// safePath resolves the requested path within the root and ensures it doesn't escape.
func (b *LocalDirectoryBackend) safePath(requested string) (string, error) {
	joined := filepath.Join(b.Path, requested)
	resolved, err := filepath.Abs(joined)
	if err != nil {
		return "", fmt.Errorf("invalid path: %w", err)
	}
	root, err := filepath.Abs(b.Path)
	if err != nil {
		return "", fmt.Errorf("invalid root path: %w", err)
	}
	if !strings.HasPrefix(resolved, root+string(filepath.Separator)) && resolved != root {
		return "", fmt.Errorf("path traversal not allowed")
	}
	return resolved, nil
}

func (b *LocalDirectoryBackend) Stat(path string) (types.FileInfo, error) {
	safe, err := b.safePath(path)
	if err != nil {
		return types.FileInfo{}, err
	}
	info, err := os.Stat(safe)
	if err != nil {
		return types.FileInfo{}, err
	}
	return types.FileInfo{
		Name:  info.Name(),
		Size:  info.Size(),
		IsDir: info.IsDir(),
	}, nil
}

// Backend interface implementation
func (b *LocalDirectoryBackend) List(path string) ([]types.FileInfo, error) {
	dir, err := b.safePath(path)
	if err != nil {
		return nil, err
	}
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
	safe, err := b.safePath(path)
	if err != nil {
		return nil, err
	}
	return os.ReadFile(safe)
}

func (b *LocalDirectoryBackend) Write(path string, data []byte) error {
	safe, err := b.safePath(path)
	if err != nil {
		return err
	}
	dir := filepath.Dir(safe)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	return os.WriteFile(safe, data, 0644)
}

func (b *LocalDirectoryBackend) Delete(path string) error {
	safe, err := b.safePath(path)
	if err != nil {
		return err
	}
	return os.Remove(safe)
}

func (b *LocalDirectoryBackend) Reconnect() error {
	return nil
}
