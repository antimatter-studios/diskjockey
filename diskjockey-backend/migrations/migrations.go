package migrations

import (
	"fmt"
	"time"

	"gorm.io/gorm"
)

// MigrationFunc represents a function that performs a database migration
type MigrationFunc func(db *gorm.DB) (bool, error)

// Migration represents a single database migration
type Migration struct {
	Name string
	Up   MigrationFunc
}

var migrations []Migration

// RegisterMigration adds a new migration to the list
func RegisterMigration(name string, up MigrationFunc) {
	migrations = append(migrations, Migration{Name: name, Up: up})
}

// OnMigrationChange is a callback function that is called when a migration is applied
type OnMigrationChange func(name string, changed bool)

// RunMigrations runs all registered migrations in order
func RunMigrations(db *gorm.DB, onChange OnMigrationChange) error {
	fmt.Println("Running migrations...")

	// Create migrations table if it doesn't exist
	if err := db.Table("migrations").AutoMigrate(&struct {
		ID        uint   `gorm:"primarykey"`
		Name      string `gorm:"uniqueIndex"`
		AppliedAt int64
	}{}); err != nil {
		return fmt.Errorf("failed to create migrations table: %v", err)
	}

	// Run each migration
	for _, m := range migrations {
		// Check if migration has been applied
		var count int64
		db.Table("migrations").Where("name = ?", m.Name).Count(&count)
		if count > 0 {
			fmt.Printf("Migration %s already applied, skipping\n", m.Name)
			continue
		}

		fmt.Printf("Applying migration %s...\n", m.Name)

		// Run migration in a transaction
		var didChange bool
		err := db.Transaction(func(tx *gorm.DB) error {
			// Run the migration
			changed, err := m.Up(tx)
			if err != nil {
				return err
			}
			didChange = changed

			// Record that the migration was applied
			result := tx.Table("migrations").Create(map[string]interface{}{
				"name":       m.Name,
				"applied_at": time.Now().Unix(),
			})
			return result.Error
		})

		if err != nil {
			return fmt.Errorf("failed to apply migration %s: %v", m.Name, err)
		}

		// Notify about the migration change
		if onChange != nil {
			onChange(m.Name, didChange)
		}

		fmt.Printf("Migration %s applied successfully\n", m.Name)
	}

	return nil
}
