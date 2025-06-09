package migrations

import (
	"fmt"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
	"gorm.io/gorm"
)

func init() {
	RegisterMigration("20250608182300_create_configs", func(db *gorm.DB) (bool, error) {
		fmt.Print(" [up migration] creating configs table and seeding defaults... ")

		// Create configs table
		if err := db.AutoMigrate(&models.Config{}); err != nil {
			return false, err
		}

		madeChanges := false

		defaults := []struct {
			Key   string
			Value string
		}{
			{"cache_dir", "./cache"},
			{"max_cache_size", "104857600"},
		}

		for _, entry := range defaults {
			var count int64
			if err := db.Model(&models.Config{}).Where("key = ?", entry.Key).Count(&count).Error; err != nil {
				return false, err
			}
			if count == 0 {
				cfg := &models.Config{Key: entry.Key, Value: entry.Value}
				if err := db.Create(cfg).Error; err != nil {
					return false, fmt.Errorf("failed to create config entry for %s: %v", entry.Key, err)
				}
				madeChanges = true
			}
		}

		fmt.Println("done")
		return madeChanges, nil
	})
}
