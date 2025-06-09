package migrations

import (
	"fmt"
	"time"

	"gorm.io/gorm"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
)

func init() {
	RegisterMigration("20250608171400_create_plugins", func(db *gorm.DB) (bool, error) {
		fmt.Print(" [up migration] creating plugins table and seeding existing plugins... ")

		// Create plugins table
		if err := db.AutoMigrate(&models.Plugin{}); err != nil {
			return false, err
		}

		madeChanges := false

		// List of existing plugin names (one for each .go file in plugins/)
		pluginNames := []string{
			"dropbox",
			"ftp",
			"local_directory",
			"sftp",
			"smb",
			"webdav",
		}

		for _, name := range pluginNames {
			var count int64
			if err := db.Model(&models.Plugin{}).Where("name = ?", name).Count(&count).Error; err != nil {
				return false, err
			}
			if count == 0 {
				plugin := &models.Plugin{
					Name:    name,
					Enabled: true,
					CreatedAt: time.Now(),
					UpdatedAt: time.Now(),
				}
				if err := db.Create(plugin).Error; err != nil {
					return false, fmt.Errorf("failed to create plugin entry for %s: %v", name, err)
				}
				madeChanges = true
			}
		}

		fmt.Println("done")
		return madeChanges, nil
	})
}
