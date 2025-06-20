package migrations

import (
	"fmt"
	"time"

	"gorm.io/gorm"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
)

func init() {
	RegisterMigration("20250608171400_create_disk_types", func(db *gorm.DB) (bool, error) {
		fmt.Print(" [up migration] creating disk_types table and seeding existing disk types... ")

		// Create disk types table
		if err := db.AutoMigrate(&models.DiskType{}); err != nil {
			return false, err
		}

		madeChanges := false

		// List of existing disk type names (one for each .go file in disktypes/)
		diskTypeNames := []string{
			"dropbox",
			"ftp",
			"local_directory",
			"sftp",
			"smb",
			"webdav",
		}

		for _, name := range diskTypeNames {
			var count int64
			if err := db.Model(&models.DiskType{}).Where("name = ?", name).Count(&count).Error; err != nil {
				return false, err
			}
			if count == 0 {
				disktype := &models.DiskType{
					Name:      name,
					Enabled:   true,
					CreatedAt: time.Now(),
					UpdatedAt: time.Now(),
				}
				if err := db.Create(disktype).Error; err != nil {
					return false, fmt.Errorf("failed to create disk type entry for %s: %v", name, err)
				}
				madeChanges = true
			}
		}

		fmt.Println("done")
		return madeChanges, nil
	})
}
