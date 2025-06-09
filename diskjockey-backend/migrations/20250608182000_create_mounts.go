package migrations

import (
	"fmt"

	"gorm.io/gorm"

	"github.com/christhomas/diskjockey/diskjockey-backend/models"
)

func init() {
	RegisterMigration("20250608182000_create_mounts", func(db *gorm.DB) (bool, error) {
		fmt.Print(" [up migration] creating mounts table... ")

		// Create mounts table
		if err := db.AutoMigrate(&models.Mount{}); err != nil {
			return false, err
		}

		fmt.Println("done")
		return true, nil
	})
}
