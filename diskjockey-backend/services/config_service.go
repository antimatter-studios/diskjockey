package services

import (
	"errors"
	"strconv"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
)

// ConfigService provides access to config, mount, and socket path data from the database.

type ConfigService struct {
	db        *SQLiteService
	socketPath string
}

// NewConfigService creates a ConfigService using the given SQLiteService.
func NewConfigService(db *SQLiteService, socketPath string) *ConfigService {
	return &ConfigService{db: db, socketPath: socketPath}
}

// DeleteMount deletes a mount config row by ID
func (cs *ConfigService) DeleteMount(mountID uint32) error {
	db := cs.db.GetDB()
	if err := db.Delete(&models.Mount{}, mountID).Error; err != nil {
		return err
	}
	return nil
}

// GetMountByName returns the Mount model for the given mount name
func (cs *ConfigService) GetMountByName(mountName string) (*models.Mount, error) {
	db := cs.db.GetDB()

	var mount models.Mount
	if err := db.Preload("Plugin").Where("name = ?", mountName).First(&mount).Error; err != nil {
		return nil, err
	}

	return &mount, nil
}

// GetMountByID fetches a mount by its primary key, including plugin.
func (cs *ConfigService) GetMountByID(id uint32) (*models.Mount, error) {
	db := cs.db.GetDB()
	var mount models.Mount
	if err := db.Preload("Plugin").First(&mount, id).Error; err != nil {
		return nil, err
	}
	return &mount, nil
}

// CreateMount inserts a new mount into the database, linking to the plugin by name.
// It enforces that no mounts overlap (same or parent/child path).
// CreateMount creates a new mount config row and returns its ID
func (cs *ConfigService) CreateMount(name string, pluginType string, config map[string]string) (uint32, error) {
	db := cs.db.GetDB()
	var plugin models.Plugin
	if err := db.Where("name = ?", pluginType).First(&plugin).Error; err != nil {
		return 0, err
	}
	mount := models.Mount{
		Name:   name,
		Plugin: plugin,
	}
	// Set config fields if present
	if v, ok := config["host"]; ok {
		mount.Host = v
	}
	if v, ok := config["port"]; ok {
		mount.Port, _ = strconv.Atoi(v)
	}
	if v, ok := config["username"]; ok {
		mount.Username = v
	}
	if v, ok := config["password"]; ok {
		mount.Password = v
	}
	if v, ok := config["path"]; ok {
		mount.Path = v
	}
	// Enforce no overlapping mounts
	var existing []models.Mount
	if err := db.Find(&existing).Error; err != nil {
		return 0, err
	}
	for _, ex := range existing {
		if ex.Path == mount.Path || isPathOverlap(ex.Path, mount.Path) {
			return 0, errors.New("mount path overlaps with existing mount: " + ex.Path)
		}
	}
	if err := db.Create(&mount).Error; err != nil {
		return 0, err
	}
	return uint32(mount.ID), nil
}

// isPathOverlap returns true if a or b is a parent/child of the other
func isPathOverlap(a, b string) bool {
	if a == b {
		return true
	}
	if len(a) > 0 && len(b) > 0 {
		if len(a) > len(b) && a[:len(b)] == b && a[len(b)] == '/' {
			return true
		}
		if len(b) > len(a) && b[:len(a)] == a && b[len(a)] == '/' {
			return true
		}
	}
	return false
}

// ListMountpoints returns all mounts from the database.
func (cs *ConfigService) ListMountpoints() ([]models.Mount, error) {
	db := cs.db.GetDB()

	var mounts []models.Mount
	if err := db.Preload("Plugin").Find(&mounts).Error; err != nil {
		return nil, err
	}

	return mounts, nil
}

// SetMountMounted sets the IsMounted field for a mount by ID.
func (cs *ConfigService) SetMountMounted(mountID uint32, mounted bool) error {
	db := cs.db.GetDB()
	return db.Model(&models.Mount{}).Where("id = ?", mountID).Update("is_mounted", mounted).Error
}

// GetSocketPath returns the socket path from the config table.
func (cs *ConfigService) GetSocketPath() (string, error) {
	if cs.socketPath == "" {
		return "", errors.New("socket path not set")
	}
	return cs.socketPath, nil
}
